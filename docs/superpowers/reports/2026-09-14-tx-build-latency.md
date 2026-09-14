# Send preview latency investigation — 2026-09-14

The measured node work already costs roughly 1 second on kadia or 2.6 seconds on eutxo for a warm, one-address send, and prepare repeats the unspent-plus-mempool sequence serially for every spend address; local box processing adds a separate scaling problem for large input sets.

The original investigation below examined `perf/tx-build-investigation` at `d2b22c7`, without changing production behavior. **Rank 1 is now implemented on `perf/concurrent-gather`, based on `feat/watch-xpub`; see the implementation follow-up at the end for measurements and verification.** Before and after counts are identical: **3 HTTP requests warm / 5 cold** for one address with fewer than 500 confirmed boxes, ordinary ERG fee, successful first node. The author's phone and wallet were not available. The measurements below establish real endpoint/client costs and synthetic local costs, not a measured button-to-sheet time on that phone.

## Call graph and await ledger

Paths below are relative to the repository root. Line numbers refer to the investigated revision.

```text
SendScreen._send (app/lib/ui/send_screen.dart:431)
  form validation, recipients, existing balance check                    LOCAL
  [stealth recipients: await resolveStealthRecipients]                   LOCAL FRB/crypto
  [stealth inputs: await newSelfChangeAddress]                           LOCAL FRB/crypto
  await walletService.prepareSend (wallet_service.dart:991)
    await crateApiPrepareSend                                           LOCAL FRB dispatch
      await api::prepare_send -> prepare (api.rs:1756,1963)
        validate change ownership; resolve/sort/dedup spend addresses    LOCAL
        await node_client                                              CACHE or COLD NETWORK
          cache hit: clone Arc-backed client                           LOCAL
          miss: await ErgoNodeClient::connect
            for preferred URL, then configured fallbacks, serially:
              await new -> from_url_str -> from_url_with_probe
                await GET /blockchain/indexedHeight                    NETWORK C1
              await current_height -> current_block_height
                await GET /info; await response body                   NETWORK C2
        await gather_unspent -> gather_unspent_all
          for each sorted spend address a, serially:
            owns_address                                               LOCAL
            await get_effective_unspent(a)
              await get_unspent -> all_unspent_boxes
                loop: await unspent_boxes_by_address
                  await POST /blockchain/box/unspent/byAddress
                    ?offset=0,500,...&limit=500; await response body    NETWORK U[a,page]
                  JSON -> Value -> ErgoBox                             LOCAL
                ErgoBox -> EIP-12 for ALL confirmed boxes               LOCAL
              address -> ErgoTree                                      LOCAL (no HTTP)
              await mempool_txs_for
                await POST /transactions/unconfirmed/byErgoTree
                  ?offset=0&limit=100; await response body              NETWORK M[a]
              merge spent IDs / unconfirmed outputs; EIP-12 conversion  LOCAL
            deduplicate boxes across addresses                         LOCAL
          filter local funding reservations                            LOCAL
        [parse supplied stealth JSON, detect ownership]                 LOCAL crypto
        apply mixed-box policy                                         LOCAL
        [await find_babel if fee token selected]
          await unspent_boxes_by_ergo_tree
            await POST /blockchain/box/unspent/byErgoTree
              ?offset=0&limit=100; await response body                  NETWORK B
          parse both shapes from each same item, pick best              LOCAL
        select inputs; [ensure babel tokens]                            LOCAL
        await current_height -> current_block_height
          await GET /info; await response body                         NETWORK H
        address trees, build unsigned tx, fees/change, match full boxes  LOCAL
      store_preparation; serialize preview JSON                         LOCAL
    FRB result decode; jsonDecode; SendPreview.fromJson                  LOCAL
  await _confirmAndSend
    [ordinary single, untrusted recipient: await Clipboard.getData]     LOCAL platform IPC
    [different valid clipboard address: await warning dialog]           USER WAIT
    build rows from preview, cached token metadata, cached fiat          LOCAL
    await showConfirmTransactionChoice -> showModalBottomSheet           SHEET SHOWN / USER WAIT
```

The response-body awaits complete the preceding HTTP request; they are **not additional round trips**. Nested wrapper awaits likewise do not add requests. There are no further awaits inside ordinary `prepare` beyond client, gather, optional babel and height. Validation/insufficient-funds failures can return before later requests. A bad address conversion can bypass mempool, but a normal owned spend address does not.

`prepare_send_multi` (`api.rs:2829`) has the same client → gather → optional babel → height network sequence, with local recipient parsing and multi-token selection instead of the single builder. Multiple tokens to one recipient can also choose this builder. It does not issue a request per recipient.

The dependency graph as implemented is:

```text
[C1 -> C2 on cold connection] -> U[1,1] -> ... -> U[1,P1] -> M[1]
  -> U[2,1] -> ... -> M[2] -> ... -> U[A,PA] -> M[A]
  -> local ownership/policy -> [B] -> selection -> H -> build -> bridge -> clipboard -> sheet
```

All requests after connection use the chosen node, including babel. Ordinary prepare has **zero explorer requests**, zero balance requests, zero history reads, zero token-price requests, zero headers/reduction/signature requests, and zero per-selected-box HTTP lookups. The last group occurs after approval in `sign_prepared_tx` / send; it is not preview latency. Details expansion (`confirm_transaction_sheet.dart:238`, `widgets/tx_details.dart:25`) reads the stored preparation through FRB on expansion; it neither blocks showing the sheet nor fetches inputs again.

### Counts, paging and address fan-out

Let A be the number of distinct nonempty resolved spend addresses, P[a] the number of unspent pages actually requested for address a, and B be 1 with a babel fee or 0 otherwise. A successful warm prepare costs:

**R = sum(P[a]) + A + B + 1.**

A successful first cold candidate adds 2. With complete parseable 500-item pages, P[a] = min(20, floor(confirmed_boxes[a] / 500) + 1). Thus an empty address costs one empty unspent page **and one mempool request**; exactly 500 boxes requires a second, empty unspent page. The cap is 10,000 boxes **per address**, not per wallet. A one-page wallet spread over 10 addresses costs 21 warm requests, 23 cold; adding babel makes these 22/24.

Evidence: `wallet-net/src/client.rs:14,378,518,607`; `api.rs:1263,1532`. Paging ends on the length of the **parsed/filtered** page, not the raw response length. Skipped spent/unparseable entries can therefore terminate enumeration early. At the cap the client warns and returns a truncated set. These are existing correctness limitations, not savings opportunities to extend.

The UI's default is not just the current receive address: `_allSpendAddresses` (`send_screen.dart:281`) uses `historyAddresses`. `wallet_sync_controller.dart:547` includes used addresses, frontier addresses and the receive address, even when some currently have no boxes. Rust sorts/deduplicates addresses and deduplicates returned box IDs, so there is no duplicate-address N+1 in this send call. There **is** serial per-address work even for empty historical/frontier addresses.

The entire enumerated set is fetched and parsed before selection, even with explicit coin control. Ordinary selection prefers token-safe boxes, sorts by value, tries pocket policies and sometimes falls back to other boxes. A transaction often needs only one input, but stopping when the amount appears covered can change selected IDs, token change, fees and privacy. Keeping the same selection semantics requires retaining the candidate set or proving an equivalent selection strategy. Cached zero balances do not prove an address is still empty.

### Connection and failure behavior

`api.rs:201–234` already caches `ErgoNodeClient` by preferred URL for 60 seconds from insertion, not last use. Clones share `Arc<NodeInterface>` and its pooled reqwest client. A cache hit does **not** construct or explicitly handshake a new client. Actual TCP/TLS reuse still depends on the pool/server; it was not packet-traced. Expiration or `set_network` creates a new client and runs both probes. Concurrent cache misses are not coalesced, so simultaneous sync/prepare can duplicate cold connection work.

The pinned `ergo-node-interface-rust` revision `0264f6f` was inspected locally (`src/node_interface.rs:119–220,315` and `src/requests.rs`). Its constructor probes `/blockchain/indexedHeight`; Argus then separately probes `/info`. The capability response is dropped without explicitly consuming its body, which can affect reuse depending on transport; do not assume C1 and C2 share one handshake. The later prepare `/info` repeats the height read on cold calls. Returning that same-call probe height instead of issuing the final GET would reduce a one-address cold call from 5 to 4 requests, saving one height request. That is a proposal, not a change here: it changes height sampling and potentially output creationHeight/signed bytes across a block boundary; it is not immutable-value caching.

The underlying client timeout is **30 seconds per request**, not the 8-second timeout of the separate `probe_height` helper. No application retry/backoff loop was found in ordinary requests. Connection fallbacks are serial; a candidate can spend approximately 30 seconds on capability and another 30 on height before the next candidate. An inconclusive capability probe still permits the height attempt. A cached node that subsequently fails is not immediately reselected here. A mempool failure can consume a timeout and then degrade to confirmed-only inputs; prepare may proceed with a box already spent in the mempool. Preserve awareness of this existing correctness risk when evaluating faster failure policies.

## Measurements

### Method and scope

Read-only mainnet requests on 2026-09-14, starting at approximately 09:51 UTC, from this Linux x86-64 development host (Ryzen 7 7800X3D). Public sample address, already used in the repository's earlier sync reports:

```text
9hcvzUtMhsNnbfewYErk65mUxjWGn9DxQdiRVkMesg5fpZHwqF7
ErgoTree: 0008cd03986ae12afbc27b9436ce23cb90faf7864376c5250b6a019d45a7aabfc7c910c9
```

1. Temporary Python 3 / requests 2.33.1 probe: one persistent Session per host; GET indexedHeight, GET info, then three serial repetitions of POST unspent(address JSON string), POST mempool(tree JSON string), GET info. Endpoints/query parameters match the ledger. `perf_counter` covered request through body receipt, with JSON decoding separately timed. Hosts were probed concurrently, but requests within each host remained serial. Timeout 35 seconds. All responses were HTTP 200; each node unspent page held one box, each mempool response was empty. Python full-body consumption is not an exact reproduction of the capability probe's Rust transport behavior.
2. Temporary Rust example in wallet-ffi, built with `cargo run --manifest-path rust/Cargo.toml -p wallet-ffi --example tx_latency_probe --release`. It restricted configured candidates to the one measured URL, timed the real `ErgoNodeClient::connect`, then three serial repetitions of the real `get_effective_unspent` and `current_height`. This includes real Rust parsing, EIP-12 conversion and merge logic, but omits FFI, wallet ownership/policy, full prepare and Flutter. No fallback ambiguity; all heights in this run were 1,872,873.
3. The same release example benchmarked local processing using that real box as a template, making distinct boxes with indices 0..N via `ErgoBox::new`. Three trials per N. All boxes had the template's value/tokens/registers; this is not a representative random wallet or a valid spendable synthetic transaction. Construction/initial JSON generation occurred outside timers. Parsing used JSON → Value → ErgoBox with an extra Value clone per item, so it approximates rather than exactly times the production parser. EIP-12 conversion and selection called production functions. Selection requested 2,000,000 nanoERG; unsigned building sent 1,000,000 to the template tree with the same change tree, using height 1,000,000 and the resolved dev fee config. The lookup stress case deliberately selected **all N IDs**, separately from the ordinary small selection, and compared the current nested `find` to an indexed reference lookup including index construction and result cloning.

All build output, temporary files and logs stayed inside `.tx-latency` in this worktree; nothing used `/tmp` or `~/.cache`. The temporary example and instrumentation were removed. No transaction was signed, checked for submission or broadcast.

### Observed network costs

Python complete-request times, seconds, all three trials:

| Endpoint | kadia | eutxo |
|---|---|---|
| Cold indexedHeight, single sample | 1.277 | 0.796 |
| Cold info, single sample | 0.341 | 0.183 |
| Unspent page | 0.343 / 0.339 / 0.340 | 0.548 / 0.201 / 0.184 |
| Empty mempool by tree | 0.341 / 0.340 / 0.341 | 2.192 / 2.185 / 2.182 |
| Final height | 0.339 / 0.338 / 0.340 | 0.180 / 0.180 / 0.181 |
| Sum of three warm requests | 1.024 / 1.018 / 1.021 | 2.921 / 2.566 / 2.547 |

On eutxo the empty mempool lookup accounts for about **85%** of the median warm three-request sequence; on kadia the three stages are approximately equal. A tiny 3-byte response can still take over two seconds: payload size alone does not explain this wait. The samples do not separate server execution, proxy behavior and geographic network latency.

Actual Rust client timings, milliseconds:

| Stage | kadia | eutxo |
|---|---|---|
| Connect, single cold sample | 1275.894 | 1054.478 |
| Effective unspent, three trials | 638.682 / 639.836 / 636.928 | 2696.894 / 2418.566 / 2409.344 |
| Height, same trials | 317.727 / 317.448 / 317.527 | 201.361 / 201.382 / 206.258 |
| Sum, same trials | 956.409 / 957.284 / 954.455 | 2898.255 / 2619.948 / 2615.602 |

These independently support roughly 1 second vs 2.6 seconds of warm node work for this tiny wallet sample. A cold client adds about 1.1–1.3 seconds in this Rust run. They are not measurements of the author's configured endpoint or wallet. Dart currently lists kadia first (`network_controller.dart:136`); Rust's standalone default is eutxo unless configured (`wallet-net/src/client.rs:18`). Existing selections/fallbacks can differ. Inspect the actual selected **and connected** URL before recommending a switch.

As a small explorer control, GET `https://api.sigmaspace.io/api/v1/boxes/unspent/byAddress/{address}?offset=0&limit=500` took 1.134 / 0.438 / 0.386 seconds, HTTP 200, bodies 2041 / 1979 / 1979 bytes. This is a small address query, not a bulk script query or a parity test. The quoted “half a minute per page” note is in **`app/lib/services/mix_service.dart:835–846`**, and the “ten to thirty seconds” note at :411. They describe the mixer's `_listByTree` node-first/explorer-fallback path. That helper is not invoked by ordinary prepare. The measurements neither reproduce nor disprove that bulk-script observation. Switching ordinary prepare from explorer to node would save nothing: it already uses the node.

### Observed local costs and scaling

Median milliseconds across three synthetic release trials:

| Boxes N | Parse to ErgoBox | EIP-12 conversion | Selection | Match all N with current nested find | Match all N with reference index |
|---:|---:|---:|---:|---:|---:|
| 1 | 0.023 | 0.007 | 0.001 | <0.001 | <0.001 |
| 100 | 1.615 | 0.585 | 0.002 | 0.259 | 0.026 |
| 500 | 7.926 | 3.027 | 0.009 | 4.903 | 0.179 |
| 1,000 | 15.827 | 5.759 | 0.016 | 18.829 | 0.287 |
| 10,000 | 164.840 | 58.548 | 0.199 | 1936.608 | 7.198 |

The small selected transaction's builder took 0.002–0.009 ms across all trials; its unsigned JSON serialization took 0.002–0.006 ms. This does not time full-preview JSON, FRB copies, Dart decode, large selected transactions, or phone execution. Equal-valued template boxes make sorting easy; selection is generally O(N log N), not guaranteed as cheap as this sample.

`prepare` (`api.rs:1926`) uses selected-input × full-box nested search, including repeated hex formatting of IDs: **O(K×N)**, quadratic if K=N. The stress test's ~1.94 seconds at 10,000 selected boxes is real measured local time, but it is not the usual one-input send, nor evidence that such a huge transaction is valid. With one selected box this work is at most O(N). `ordered_user_boxes` (`api.rs:3271`) already builds a map, but is used by other protocol builders, **not** ordinary send. Blindly reusing it also clones every full box; an index of references and cloning only selected results is preferable, with equivalent duplicate-ID/error semantics.

Parsing/serialization of every fetched box is unavoidable work under the current enumeration policy, but repeated work is not: when mempool is nonempty, `get_effective_unspent` discards the first EIP-12 vector and converts retained confirmed boxes again. Both parse cost and conversion cost scale with registers/tokens and total boxes. A valid immutable box can be cached by verified ID; its current unspent status cannot.

Ownership is already cached by address (`wallet-core/src/wallet.rs:31,128`). A fresh synthetic wallet seeded with 64 bytes of value 42 took **35.699 ms** to reject the public sample address on the first lookup, then **0.004 / 0.004 ms**. Wallet creation was excluded. The first miss derives remaining addresses through index 512 under the handle lock; known addresses use the map. `wallet_can_spend_change` tries ordinary ownership before recognizing a stealth tree, so a new stealth change address can trigger that cold miss. No claim is made about phone timing or lock contention from background sync.

## Optional/background work and correctness boundaries

- **Coin-control picker:** `_openInputPicker` (`send_screen.dart:140`) separately awaits `listUnspentBoxes`, which uses the same effective gather and can incur sum(P)+A requests before the send button. Prepare fetches fresh data again. It is a duplicate enumeration across two user actions, but reusing the picker snapshot without revalidation risks spending stale boxes. The picker is not called automatically by `_send`.
- **Stealth:** ordinary public sends pass no stealth body. Stealth sends derive recipient/change targets locally before the main bridge call; recipient derivations are awaited serially. Prepare receives the cached explorer scan JSON, parses it and repeats cryptographic ownership detection (single prepare across identities; multi prepare uses its existing single-secret path). It does not await a network scan. `spendableBoxesJson` rejects disabled/failed/truncated scans, but a successful cached scan still ages. Cryptographic ownership is immutable for a verified box and wallet identity; unspent status is not. Detection scales with boxes × identities, and pocket/selected-tree membership also contains nested searches. This probe did not benchmark stealth crypto.
- **Mixer:** reservation and mixed-box rules on prepare are local in-memory filtering. No mix explorer paging occurs there.
- **Babel:** only selecting a token fee adds the one by-tree request. Both input representations come from that same response; no per-box refetch. It examines only the first 100 returned boxes and picks the best usable price within them. That limited search is existing behavior. Reusing a stale offer can change the fee-token amount or select a spent external input.
- **Prices/routes:** `initState` starts `buyableTokens()` asynchronously; quote requests are scheduled only for the buy-and-send option. Ordinary send uses cached balances, token labels and fiat. Buy-and-send branches into `_sendViaRoute` / `tokenRouter.build`, a different protocol build path; the 3/5-request count does not describe it. Background sync/quotes/scans can contend for network/CPU but are not awaited by ordinary prepare; contention was not measured.
- **Preview/signing:** unsigned inputs/outputs and full selected boxes are retained in `CachedPreparation`; sign uses that preparation after approval. There is no ordinary prepare-time transaction reduction or signing crypto. A stale input is generally rejected by validation rather than magically made spendable, but it can still produce a misleading preview and a signature over a transaction that will fail. Fresh enumeration is itself non-atomic across pages/addresses and can race new spends. Performance work must not expand that race silently.

## Original ranked improvements (rank 1 implemented in the follow-up)

Savings below are conditional estimates from the samples and dependency structure unless explicitly marked measured. They are not additive guarantees. “Safe” here means preserving candidate data, ownership checks, selection order and final preview/signing behavior for the same node snapshot; live requests never form an atomic wallet snapshot.

| Rank | Improvement | Expected saving | Effort / safety and observable effect |
|---:|---|---|---|
| 1 | At button press, gather different addresses with bounded concurrency, preserving each address's pages → mempool order and merging in the original sorted address order. | Same request count. For equal one-page addresses and concurrency c, approximate gather changes from A×g to ceil(A/c)×g. At A=10,c=4: ~4.5 s kadia / ~16.9 s eutxo saved using the Rust median g=0.639/2.419 s. **Inferred**, not an overlap benchmark. One-address wallets gain nothing. | Medium; safe scheduling candidate with bounded node load and stable ordering/error policy. No old box cache. Tests must cover transfer/chaining across addresses, duplicate boxes, reservations, cancellation and failures. Different sampling times can still change a live box set; preserve existing per-address mempool freshness, and never silently rebuild a reviewed preparation. |
| 2 | Diagnose selected/connected node and investigate the slow by-tree mempool endpoint with its operator; use existing validated node selection where appropriate. | Samples show ~1.84 s less per empty-mempool query on kadia; actual combined gather difference ~1.78 s/address. Height is slower on kadia, so net one-address gain ~1.66 s in the Rust medians. | Low diagnostic effort; endpoint switching is **behavior-affecting**, because nodes can disagree on mempool/index freshness and therefore inputs/change. Kadia is already first for fresh Dart defaults; do not blindly rewrite user settings or drop mempool awareness to save time. |
| 3 | Replace ordinary single/multi send's nested selected-box lookup with a local ID → reference index; preserve selected order, first-match semantics and missing-input errors. | **Measured synthetic** all-selected lookup: 18.829→0.287 ms at N=1,000; 1936.608→7.198 ms at N=10,000. Usually much less for small K; index construction can cost more when K=1. No request reduction. | Low; safe/self-contained, no preview or signed-byte changes for identical inputs. Benchmark K=1 and realistic K before choosing unconditional indexing or an adaptive threshold. No code change here because the stress result alone does not justify adding an unconditional O(N) allocation to the common early-match case. |
| 4 | Overlap final height with gather; optionally start babel lookup alongside gather once the button's fee inputs are fixed. | Same count, shorter critical path: up to the height request (~0.318 s kadia / ~0.201 s eutxo in Rust), plus overlapped babel time (unmeasured). | Low–medium. Independent computational inputs, but **proposal requiring transaction-metadata review**: earlier height can change output creationHeight and signed bytes across a block boundary. Earlier babel sampling can change the offer/fee shown and ages an external input longer. Do not call either value immutable. Preserve validation/error precedence. |
| 5 | Avoid the discarded EIP-12 conversion on the nonempty-mempool branch; retain/reuse confirmed representations while merging. | Up to one confirmed-set conversion: ~3 ms at 500 or ~59 ms at 10,000 template boxes locally; only when mempool response is nonempty. | Low–medium; safe local reuse of exactly the same objects. Preserve unconfirmed output replacement, ordering and spent filtering. No new UTXO staleness, no intended preview/signature changes. |
| 6 | Separate reusable HTTP transport from 60-second health freshness; coalesce concurrent connection misses. | Coalescing can eliminate duplicate two-probe attempts; persistent transport may reduce cold transport overhead. Cold connect measured ~1.1–1.3 s, but not all of that is removable handshake time. | Medium; transport-only reuse is safe with the same URL/API-key/network boundaries. Preserve probe/fallback policy, network invalidation and failure behavior. Extending health TTL or skipping probes is a separate behavior change. Do not reuse cold `/info` as permanently cached height. |
| 7 | Cache verified immutable box parsing/ownership results in Rust, keyed by box ID/content and wallet identity/session; recognize stealth change without exhausting the ordinary address scan first. | Save repeated parsing/detection; local parser ~165 ms at 10,000 template boxes and one cold ownership miss ~36 ms. Stealth-crypto saving not measured. | Medium; safe only for immutable content/ownership, with bounded memory and lock/session invalidation. Still fetch current effective membership. Never treat Dart's ownership assertion as authority. Reordering change validation needs tests preserving accepted scripts and errors. |
| 8 | Warm only client/immutable address/script data while send screen is open; consider debounced speculative data fetches separately. | Could move ~1.1–1.3 s cold connection work before the click if the 60-second entry remains usable. Immutable work savings depend on cache state. | Medium; **earlier-fetch proposal**, not implemented under this investigation. Client warming does not stale a UTXO set but changes network timing/load. Prefetched boxes/height/babel are dynamic: require revalidation at prepare, cancel/discard across wallet/network/input changes, and measure whether any latency survives that revalidation. |
| 9 | Fetch fewer addresses/pages or reuse picker/sync/typing-time box snapshots; show a provisional preview immediately. | Potentially removes much of sum(P)+A from click latency; no defensible wall-clock saving without a correctness-preserving validation design. | High; **behavior-changing and stale-box risk**. Can change selected inputs, token/NFT change, fees, privacy/pocket choice, available amount and signed transaction. An optimistic sheet must explicitly remain provisional, disallow signing until validated, and require renewed review if anything changes. Not recommended as the first fix. |

Confirmed pages, mempool and height all supply necessary information for the current fresh, mempool-aware behavior, but their serial ordering is not all computationally necessary. In particular, confirmed and mempool requests for one address could technically overlap. This is **not** included as an unqualified safe recommendation: querying mempool earlier than the confirmed read completes can miss an intervening spend or include an output that has since confirmed. Keep confirmed→mempool ordering for the first concurrency experiment, then explicitly test block-boundary and pending-chain races before considering intra-address overlap.

No proposal should replace immutable-box caching with an “unspent for 60 seconds” cache. Fresh membership and a reviewed immutable preparation are distinct requirements. Preserve ownership checks, reservations, exact coin control, token/pocket policies, and the requirement that the user approves precisely what gets signed.

## Original investigation validation and next work

`cargo test --manifest-path rust/Cargo.toml --workspace` passed: **803 passed, 0 failed, 12 ignored**, including the workspace doc-test summaries. It used worktree-local `CARGO_TARGET_DIR` and `TMPDIR`. The temporary example was removed before this run.

`flutter analyze --no-pub` and `flutter test --no-pub` could not start: the installed Flutter launcher tries to write `/home/rkadias/coding/development/flutter/bin/cache/engine.stamp`, which is read-only in this sandbox. These are environment blocks, not passing Flutter checks. FRB codegen-match was not rerun; production Rust, Dart, generated bindings and API signatures are byte-for-byte unchanged in the final diff. `git diff --check` passed. The final deliverable is this report only. Staging it failed because Git could not create `/home/rkadias/coding/arkadianet/Argus/.git/worktrees/perf/index.lock` on the read-only filesystem outside this worktree. Per the task instructions, the report is left uncommitted; nothing was pushed and no PR was opened.

Next, capture a release-build phone trace with actual connected URL, cache age/hit, address count, per-address page/box counts, mempool durations, local stage durations, bridge completion and first sheet frame. Log counts/times rather than private addresses or secrets. Include public ERG, token, explicit-input, stealth and multi-send cases. This will distinguish the author's likely node/address fan-out delay from large-box/stealth CPU cost or platform/bridge delays. Then test bounded inter-address concurrency with deterministic delayed responses and block/mempool race fixtures, plus K=1 versus larger-K lookup benchmarks, before choosing an implementation.

## Implementation follow-up — bounded address gather, 2026-09-14

Implemented rank 1 on `perf/concurrent-gather`, with the diff reviewed against `feat/watch-xpub`. `gather_unspent_all` now admits at most **four** address sequences through `FuturesOrdered`. The adjacent `GATHER_ADDRESS_CONCURRENCY` constant makes the limit easy to find. Four overlaps several network waits while keeping per-gather load modest even on a user's own node; it is a conservative choice, not a measured optimal limit. The bound includes completed results waiting behind an earlier address, so a slow first address can reduce utilization. It also bounds buffered address results. Independent simultaneous gathers can each use four slots; this is not a global node rate limiter.

Ownership checks still call `with_handle` synchronously in input order, before each address's fetch. A failed check stops admission, including all addresses after the foreign address. Its error is delivered in address order, preserving an earlier address's node-error precedence. Owned addresses already admitted can run concurrently, but no foreign boxes are fetched or returned. The first error in original address order aborts the entire gather and drops outstanding futures; no partial tuple reaches selection. Some later owned requests may already have reached the server when an earlier request fails, an unavoidable consequence of overlap. Caller cancellation also drops pending futures without detached tasks.

Each future calls the unchanged `get_effective_unspent`, retaining confirmed pages → mempool order, request contents, paging limits and node choice. Results are merged in the caller's original sorted address order, using the original paired zip and first-box-ID-wins deduplication. Reservation filtering remains after the complete gather. Height, babel, node selection, caching, selected-input lookups, EIP-12 conversion and bridge signatures were left alone. No optional optimization was bundled.

### Ordering and behavior proof

`rust/crates/wallet-ffi/src/api/tests/concurrent_gather.rs` contains an independent copy of the old serial merge as the test oracle. A delayed ten-address fixture makes later addresses finish first, verifies that four fetches actually overlap, and compares **serialized bytes of the entire `(boxes, eip12)` tuple** against the serial reference. Duplicate boxes occur under every address. The same result is then filtered through real mix funding reservations, checking exclusion without disturbing the other boxes.

A threaded local HTTP node exercises the real `ErgoNodeClient` and production `gather_unspent_all`: address A has 500 confirmed boxes and a second empty page; mempool transactions spend A → B → A. B finishes first. The test checks that the spent confirmed box and intermediate B output are absent, the final A output is present, both tuple representations match the serial reference byte-for-byte, and each address's request log is pages followed by mempool. Separate tests cover single-address/empty-string handling and fetch count, a mid-gather error with a later error finishing first, dropping outstanding fetches on failure and caller cancellation, and actual wallet ownership rejection without fetching the foreign or subsequent addresses. An earlier node error still wins over a later ownership error.

### Measurement method

The retained opt-in `live_gather_benchmark` test uses the real Rust client in release mode and ten distinct, sorted owned addresses derived from the deterministic test seed `[42; 64]`. Each host is constructed directly with `ErgoNodeClient::new`, so there is no fallback ambiguity and no production network configuration change. A complete warmup gather precedes timing. Connection and wallet construction are excluded; ownership checks, requests, parsing, merge and deduplication are included. The serial baseline runs the same gather helper with concurrency **1**, reproducing the old per-address await schedule; the new setting is **4**. This is a scheduling comparison, not two historical binaries. Three trials alternate order (1→4, 4→1, 1→4) for A=1 and A=10. Every returned box set was empty, and each serial/concurrent pair had identical serialized tuple bytes. Thus successful request counts remain 2 and 20 respectively, with no height or babel request in the timed interval.

Reproduce from the repository root (build output and temporary files remain in the worktree):

```bash
mkdir -p rust/target/tmp
CARGO_TARGET_DIR="$PWD/rust/target" TMPDIR="$PWD/rust/target/tmp" \
  cargo test --manifest-path rust/Cargo.toml -p wallet-ffi --release \
  live_gather_benchmark -- --ignored --nocapture
```

These are development-host gather timings, not phone button-to-preview timings or a funded wallet benchmark. Empty addresses are relevant because historical/frontier addresses still perform both requests. Nonempty, duplicate, multi-page and chained box behavior is covered by deterministic tests, not claimed as a live performance measurement. No transaction was signed or submitted.

### Measured results

Release timings in milliseconds, three trials in trial-number order:

| Node | Addresses | Serial (limit 1) | Concurrent (limit 4) | Median serial → concurrent | Median saving |
|---|---:|---|---|---|---|
| node.kadia.io | 1 | 678.545 / 677.938 / 680.974 | 681.439 / 679.911 / 677.155 | 678.545 → 679.911 | -1.366 |
| node.kadia.io | 10 | 6807.323 / 6803.472 / 6803.032 | 2037.474 / 2038.367 / 2038.815 | 6803.472 → 2038.367 | 4765.105 |
| ergo-node.eutxo.de | 1 | 2364.322 / 2367.224 / 2364.369 | 2654.080 / 2446.669 / 2361.841 | 2364.369 → 2446.669 | -82.300 |
| ergo-node.eutxo.de | 10 | 32177.129 / 23793.763 / 23829.356 | 7238.516 / 7132.576 / 7213.233 | 23829.356 → 7213.233 | 16616.123 |

The ten-address median saving is **4.765 s on kadia** and **16.616 s on eutxo**, compared with the original inferred 4.5 s and 16.9 s. The estimates were close for these samples, but the first eutxo serial run took 32.177 s; three samples do not characterize tail latency. The one-address kadia medians differ by 1.366 ms; eutxo's concurrent median was 82.300 ms slower, with individual samples spanning 2.362–2.654 s. With only one address, both limit settings execute the same request sequence and queue operations. These noisy live samples show no benefit and do not establish statistical non-regression against the historical implementation. The single-address correctness test proves the same bytes and fetch count. The benchmark completed successfully, including all tuple equality assertions.

### Verification and scope corrections

`cd rust && cargo test --workspace` passed on the final Rust sources: **814 passed, 0 failed, 13 ignored**, including doc tests. Six new deterministic tests passed; the live benchmark is explicitly ignored in the default suite and run separately. `cd app && flutter analyze` and `cd app && flutter test` both failed before analysis/testing: Flutter's launcher attempted to write `/home/rkadias/coding/development/flutter/bin/cache/engine.stamp`, outside the writable sandbox. These are blocked checks, not passes. No bridge signature changed, so bindings were not regenerated. This Rust change **does land in the native library**: tracked `jniLibs/*.so` were not rebuilt, and `scripts/release_check.sh libs` was not run; the binaries still need rebuilding for release. All build output, temporary files and logs used the existing ignored `rust/target` directory, with no ignore-rule changes and nothing under `/tmp`.

The original equal-latency `ceil(A/4) × g` estimate is a useful approximation, not a guarantee: live endpoint variation and waiting for the oldest outstanding address can affect the result. Single-address wallets have no latency overlap to exploit. The shared gather also serves callers other than button-press prepare, including the coin-control listing and mix funding path. The original report's successful request-count ledger remains valid. Its existing warning about mempool failures still applies: `get_effective_unspent` catches those failures and returns confirmed-only boxes. The new gather aborts every error actually returned by that method; this work neither fixes nor introduces the client's pre-existing fallback. Live enumeration remains non-atomic, so byte equality is guaranteed for identical address responses, not for two queries separated by a chain or mempool change.

`git diff --check` and formatting validation of the new test module passed. Staging the implementation, tests and report failed with `Unable to create '/home/rkadias/coding/arkadianet/Argus/.git/worktrees/conc/index.lock': Read-only file system`. Per the requested failure policy, all work remains uncommitted on `perf/concurrent-gather`; no push or PR was attempted. Intended commit message: `Gather wallet addresses with bounded concurrency`.


## Safe remainder — `perf/safe-wins`, 2026-09-14

The baseline for this follow-up is **`feat/cold-wallet-signing`**, not `main`.
That branch already contains rank 1. Ranks 4, 7, 8 and 9 are untouched.
All measurements below use this Linux development host, not a phone; no real
transaction was signed or submitted. Build output, scratch files and logs stay
in the already ignored `rust/target`, with `CARGO_TARGET_DIR` and `TMPDIR` set
there; no ignore rules were added.

### Rank 3 — built: incremental reference index with a single-input fast path

Before choosing the algorithm, `selected_lookup_benchmark` measured the independent
old nested search against unconditional indexing at N=1,100,500,1000,10000 and
K=1,4,10,N, both first-K and reverse-last-K selections. K=4 and K=10 model small
multi-input sends; they are synthetic scenarios, not a measured wallet distribution.
At N=10000, initial K=1 first-match medians were roughly 0.0002 ms old versus
0.9 ms unconditional indexing. The unconditional allocation is rejected.

Both ordinary single and multi send now call `selected_ergo_boxes`. The adaptive
threshold is **K > 1**: K=0/1 retains the old search without an index; K>1 builds a
local string-ID → reference map incrementally as it scans only the needed prefix.
Each candidate is formatted at most once, and the map starts empty rather than
allocating N slots. This handles early matches without constructing a full index
and bounds the all-selected path to expected O(N+K). Selected order and repeated
selected IDs remain intact. `entry().or_insert()` retains the first candidate;
missing IDs are omitted exactly as before, and both callers retain their existing
length checks and exact `TxBuildFailed("UTXO set mismatch")` errors.

Final release comparison, median milliseconds of three trials. Each trial times
20 repetitions except all-selected N>=1000 (one repetition). Inputs/fixtures and
JSON comparisons are outside timing; ID formatting, index construction and selected
box cloning are inside. Algorithm order alternates per trial; this compares the
independent old implementation with production helper in one binary, not historical
binaries. Synthetic boxes have distinct indices and the report's public sample tree.

| N | K | Selected positions | Old nested | Full index (rejected) | Adaptive (built) |
|---:|---:|---|---:|---:|---:|
| 100 | 1 | first K | 0.000157 | 0.008570 | 0.000165 |
| 100 | 1 | last K, reversed | 0.004513 | 0.009387 | 0.003807 |
| 100 | 4 | first K | 0.000732 | 0.008839 | 0.000778 |
| 100 | 4 | last K, reversed | 0.017412 | 0.009912 | 0.013300 |
| 100 | 10 | first K | 0.003040 | 0.011179 | 0.002065 |
| 100 | 10 | last K, reversed | 0.041636 | 0.010643 | 0.012508 |
| 100 | 100 | first K | 0.208150 | 0.023134 | 0.029794 |
| 100 | 100 | last K, reversed | 0.201319 | 0.021621 | 0.024626 |
| 10000 | 1 | first K | 0.000171 | 0.904338 | 0.000237 |
| 10000 | 1 | last K, reversed | 0.388532 | 0.897982 | 0.386302 |
| 10000 | 4 | first K | 0.000751 | 0.911404 | 0.000902 |
| 10000 | 4 | last K, reversed | 1.543820 | 0.951083 | 1.360290 |
| 10000 | 10 | first K | 0.003448 | 0.921330 | 0.002095 |
| 10000 | 10 | last K, reversed | 3.905680 | 0.998821 | 1.387343 |
| 10000 | 10000 | first K | 1959.057132 | 3.729501 | 3.155148 |
| 10000 | 10000 | last K, reversed | 2010.426768 | 2.891355 | 2.850708 |

The microsecond/sub-microsecond early-match differences are below a meaningful
preview latency claim. The selected-all N=10000 first-K case falls from **1959.057
→ 3.155 ms**. Late K=10 falls **3.906 → 1.387 ms**; early K=10 falls **0.003448
→ 0.002095 ms**. K=1 executes the same old algorithm. The incremental index costs
more than a preallocated full index for some late matches, intentionally avoiding
its unconditional cost for early matches.

Equivalence: `api/tests/selected_lookup.rs` contains an independent copy of the old
nested search. Deterministic tests compare serialized complete ErgoBox vectors and
missing-count outcomes for empty candidates/selections, single input, reverse order,
repeated candidate/selected IDs and multiple missing IDs. The release benchmark also
checks old/full-index equality for every N/K/position fixture. The selected EIP-12
inputs and already-built unsigned transaction are untouched; exactly the same full
boxes reach cached signing. This is the same byte-comparison proof boundary as rank
1; it is not a claim to have benchmarked signing or a funded live preview.

Reproduce the final comparison (add `--release`; debug timings are not comparable):

```bash
CARGO_TARGET_DIR="$PWD/rust/target" TMPDIR="$PWD/rust/target/tmp" \
  cargo test --manifest-path rust/Cargo.toml -p wallet-ffi --release \
  selected_lookup -- --include-ignored --nocapture
```

Intended rank-3 commit: `Index selected boxes only as needed`.


### Rank 5 — built: retain confirmed EIP-12 representations

`get_effective_unspent` still calls `get_unspent`, resolves the tree, then queries
mempool. Invalid-address, empty-mempool and failed-mempool branches are unchanged.
The nonempty branch now passes the paired confirmed representations to
`mempool::merge_confirmed`, filters both together, and converts only retained
unconfirmed outputs. The pair-length/order invariant comes directly from
`get_unspent` (one conversion per confirmed box); the helper is crate-private.
Spent IDs still come from all returned transactions, confirmed survivors precede
pending outputs, and duplicates are retained exactly as before. There is no new
replacement/deduplication rule. Intermediate pending outputs spent by another
pending transaction remain excluded.

`mempool_merge_tests.rs` independently reimplements the entire old nonempty merge,
including dropping the first EIP-12 vector and reconverting the retained boxes.
It compares serialized **complete `(ErgoBox vector, EIP-12 vector)` bytes** for empty
confirmed sets, duplicate confirmed/pending outputs, no spends, partial/all spends,
confirmed → pending → pending chains, foreign/malformed outputs, missing transaction
IDs, and boxes with tokens and R4 registers. The same unchanged selection/build
functions therefore receive byte-identical ordered inputs for identical responses;
this does not claim live reads at different times are atomic or equal.

Release benchmark uses the same public-tree, distinct-index synthetic boxes as
rank 3. Each fixture has a nonempty mempool spending the first confirmed box and
creating one new owned output. Construction/cloning is excluded; initial confirmed
conversion plus the complete merge are timed, including the old discarded
conversion. Three trials alternate old/new order; assertions compare complete tuple
bytes before timing. N=1 has no retained confirmed box to reconvert, so it shows no
saving. Larger N measures conversion reuse, not network or phone preview time.

| Confirmed N | Old ms, three trials | Reuse ms, three trials | Median ms |
|---:|---|---|---|
| 1 | 0.023164 / 0.022563 / 0.022543 | 0.022763 / 0.022813 / 0.022763 | 0.022563 → 0.022763 |
| 100 | 1.118059 / 1.114863 / 1.113531 | 0.571799 / 0.575746 / 0.579614 | 1.114863 → 0.575746 |
| 500 | 6.039289 / 6.651245 / 6.340152 | 3.027144 / 3.361170 / 3.418950 | 6.340152 → 3.361170 |
| 1000 | 14.155263 / 14.086483 / 14.270684 | 6.643711 / 6.672505 / 6.560713 | 14.155263 → 6.643711 |
| 10000 | 109.114501 / 109.081368 / 111.243935 | 57.074048 / 55.171946 / 55.013293 | 109.114501 → 55.171946 |

Reproduce:

```bash
CARGO_TARGET_DIR="$PWD/rust/target" TMPDIR="$PWD/rust/target/tmp" \
  cargo test --manifest-path rust/Cargo.toml -p wallet-net --release \
  merge -- --include-ignored --nocapture
```

Intended rank-5 commit: `Reuse confirmed inputs during mempool merging`.

### Rank 6 — rejected: pinned transport API couples reuse to stale capability state

No production connection/cache code was changed. The 60-second health TTL,
capability → info probes, fallback ordering, network invalidation and final height
read all remain as before. Concurrent misses remain uncoalesced. There is **no
measured safe before/after latency number** for this rank, and no claimed saving.

Inspection of pinned `ergo-node-interface-rust` **0264f6f** found that its reqwest
client is `pub(crate)`, every constructor creates a new transport, and there is no
constructor accepting a reusable client or resetting health state independently.
The exposed `refresh_capabilities()` is not equivalent to reconstruction: an
inconclusive probe retains the old capability, whereas a fresh constructor records
unknown. In addition, clones share the capability atomic through Arc, so refreshing
a retained interface also mutates capability state observed by existing callers.
The simple proposed reuse path thus exceeds transport-only behavior.

A retained local-HTTP diagnostic,
`transport_reuse_tests::reused_capability_after_inconclusive_probe_differs_from_fresh_client`,
proves the first difference against the actual pinned dependency: initial 404 sets
false; a reused interface probed with 503 retains **false**, while a new interface
probed with the same 503 records **unknown**. Exactly three capability requests
are checked. This matters because false can prevent extraIndex operations locally
where unknown allows trying the endpoint. It is a behavior experiment, not an RTT
benchmark or a production implementation.

Separating transport without this difference needs an upstream transport-injection
or reconstruction API (or vendoring/changing that dependency), plus independent
per-health-generation capability state. Miss coalescing also needs cancellation,
failed-attempt, fallback and network-generation tests. That is materially broader
risk than the report's assumed small cache refactor. Under the explicit instruction
to reject ranks whose risk is higher than assumed, the complete rank is deferred;
a partial cache/coalescing change is not bundled with the box optimizations.

Intended rank-6 diagnostic commit: `Document transport reuse capability mismatch`.


### Rank 2 — diagnostic completed; no production behavior change

The slow result is **not specific to the sample tree or solely to byErgoTree**.
Eutxo shows an approximately two-second additional wait across several mempool
routes, including ID-only listing. Its confirmed unspent and height routes remain
fast. This is consistent with a mempool subsystem, scheduling or reverse-proxy
issue on that service, but client measurements cannot identify which. Contacting
the operator with these results is the next step; no operator was contacted here.
No selected node, connected URL policy, settings, limits or mempool awareness changed.

Retained `scripts/tx_latency_endpoints.py` reproduces the diagnostic, using Python
requests, one persistent session per host, serial requests inside each host and
concurrent hosts. Three trials reverse endpoint order on the middle trial. The
first `/info` includes cold transport setup; subsequent requests use the session.
Timings cover request through full body receipt; response-header time and JSON
decode time are recorded separately. Timeout is 35 seconds. All final requests
returned 200 except kadia's unsupported `outputs_tree` route (404, empty body).
The public address/tree are the original report's sample. This is deliberately a
read-only endpoint comparison, **not a before/after application optimization**.

Final retained-script measurements, milliseconds in trial-number order:

| Control | kadia, three trials | eutxo, three trials | Median kadia / eutxo |
|---|---|---|---|
| info | 985.761 / 319.770 / 325.741 | 783.382 / 183.029 / 179.652 | 325.741 / 183.029 |
| unspent | 318.466 / 326.670 / 318.497 | 195.195 / 185.269 / 183.861 | 318.497 / 185.269 |
| tree100 | 321.312 / 321.035 / 321.696 | 2196.404 / 2189.119 / 2187.253 | 321.312 / 2189.119 |
| tree1 | 329.100 / 319.595 / 320.348 | 2190.698 / 2185.350 / 2190.947 | 320.348 / 2190.698 |
| other_tree | 323.584 / 319.455 / 317.872 | 2189.306 / 2185.949 / 2185.041 | 319.455 / 2185.949 |
| pool | 960.987 / 326.494 / 326.747 | 2930.989 / 2947.626 / 2921.824 | 326.747 / 2930.989 |
| pool1 | 323.903 / 321.625 / 321.635 | 2908.864 / 2941.622 / 2915.051 | 321.635 / 2915.051 |
| ids | 322.196 / 323.762 / 316.584 | 2183.892 / 2181.471 / 2184.328 | 322.196 / 2183.892 |
| outputs_tree | 318.006 / 320.557 / 317.174 | 2182.454 / 2185.203 / 2180.363 | 318.006 / 2182.454 |

Controls map directly to the script's `CASES`: `tree100` is Argus's exact POST
`/transactions/unconfirmed/byErgoTree?offset=0&limit=100`, with a JSON-string tree;
`tree1` changes only limit to 1; `other_tree` uses the valid generator-key P2PK tree.
`pool`/`pool1` GET `/transactions/unconfirmed` at limits 100/1; `ids` lists mempool
transaction IDs; `outputs_tree` queries unconfirmed outputs by tree. `unspent`
matches Argus's address POST with offset=0 and limit=500.

Eutxo's `tree100`, `tree1`, `other_tree` and `outputs_tree` bodies were each **3
bytes**, with median times **2189.119, 2190.698, 2185.949 and 2182.454 ms**. JSON
decoding took less than 0.2 ms and full-body time was within 1 ms of header time
for these empty responses. The 352-byte ID listing still took **2183.892 ms**.
Thus neither response download/JSON parsing nor the particular address nor the
requested result limit explains the main delay. Its 237282-byte full-mempool
response took **2930.989 ms**; limit=1 still returned a large 225104-byte transaction
and took **2915.051 ms**. Large responses add transfer time, but that is separate
from the two-second wait already present for empty/ID-only responses. By contrast,
confirmed unspent's 1786-byte response took **185.269 ms** median. A generally slow
connection to every endpoint is not supported by these controls.

The initial six-route probe and separate three-route controls independently
reproduced this pattern before the retained script was run. The initial empty-tree
medians were about 2.19 s eutxo / 0.319 s kadia, consistent with the investigation's
2.18 s / 0.34 s observation. Kadia returned two-byte empty arrays and a 404 for the
output-only control; do not interpret that 404 as an equivalent fast result.

Code findings: Argus requests no optional enrichment flag, makes only one mempool
request per address, and uses transaction input IDs plus owned outputs for spent
filtering and chaining. Dropping inputs or using only the output endpoint would
lose confirmed-spend awareness. Lowering the limit could omit relevant transactions.
No dispensable client request was established.

Eutxo reported `appVersion=6.0.4RC2-109-c3646640-SNAPSHOT`; kadia reported `0.7.0`.
They are not demonstrated identical server implementations or mempool snapshots.
Inspection of the [upstream transaction route at the reported eutxo revision](https://github.com/ergoplatform/ergo/blob/c3646640/src/main/scala/org/ergoplatform/http/api/TransactionsApiRoute.scala)
shows that by-tree examines pool outputs and state-resolved inputs before slicing
the matches; lowering the returned limit need not reduce that search. ID listing
only reads pool IDs, yet it has the same delay in these measurements. There is no
basis to attribute all of the delay specifically to input resolution. The reported
revision is source evidence, not verification of the operator's exact deployed
binary/proxy configuration. Server profiling is required for a root cause.

Reproduce (requires Python `requests`, as in the original method):

```bash
python3 scripts/tx_latency_endpoints.py > rust/target/endpoints.jsonl
```

Intended rank-2 diagnostic commit: `Record mempool endpoint latency controls`.

### Final verification and delivery status

`cargo test --workspace` passed: **825 passed, 0 failed, 15 ignored**, including
doc tests (baseline: 822 passed, 13 ignored). New deterministic checks cover the
two box-path equivalence proofs and the pinned-client capability mismatch. Both
retained local release benchmarks passed separately, including their byte-equality
assertions; the final lookup rerun also compares the production adaptive helper
against the old path for every N/K/position fixture. The earlier rank-1 local HTTP,
ordering, cancellation and ownership tests pass in the workspace suite.

`cd app && flutter analyze` and `cd app && flutter test` were attempted; both exit
before running because the installed SDK attempts to write
`/home/rkadias/coding/development/flutter/bin/cache/engine.stamp` on the read-only
filesystem. They are **blocked**, not passing. No `#[frb]` signature changed and
bindings were not regenerated. Rust native-library sources changed; tracked
`jniLibs/*.so` were deliberately not rebuilt, as allowed. `git diff --check` passes.

Staging rank 3 failed with:

```text
fatal: Unable to create '/home/rkadias/coding/arkadianet/Argus/.git/worktrees/safewins/index.lock': Read-only file system
```

Per the requested failure policy, **all changes remain uncommitted on
`perf/safe-wins`**. One commit per rank could not be created. The intended independent
commit subjects are recorded in each section; rank 3 owns the FFI helper/test,
rank 5 owns the net merge/helper test, rank 6 owns only its diagnostic test/module
registration, and rank 2 owns the endpoint script, each with its corresponding
report section. Nothing was pushed and no PR was opened.
