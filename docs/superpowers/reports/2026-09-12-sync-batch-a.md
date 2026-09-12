# Batch A sync work — 2026-09-12

**Superseded interim report.** Part 2 landed in `9665c61`; Part 1 was subsequently completed in `c839397` on `feat/sync-a`, as described in [the Part 1 completion report](2026-09-12-sync-batch-a-part1.md). Kadia is now the first default node and both Rust clients handle the exact already-known response. The blocked/default-node verdict and uncommitted-tree statements below describe the earlier checkpoint, not PR #113's final result.

The raw response and command-log directories were removed from the repository. This report retains historical summaries and excerpts only; those dumps are not included or linked. No transaction was broadcast during the work.

## Historical checkpoint (superseded)

The remaining sections record the initial Part 2 investigation before Part 1's compatibility fix.
## Default-node verdict and blocker

Do not make kadia preferred, or ship it as another default, yet. On a read-only preflight of the same existing network transaction, the endpoints disagreed:

Transaction: `6746fa2f2cb8c414bbace555d12d4554701889ed29f5f9be025dd1b53a73d5a4`.

```text
POST https://node.kadia.io/transactions/check
HTTP 400
{"error":400,"reason":"duplicate"}

POST https://ergo-node.eutxo.de/transactions/check
HTTP 200
"6746fa2f2cb8c414bbace555d12d4554701889ed29f5f9be025dd1b53a73d5a4"
```

The transaction was read from kadia's public mempool, then passed only to `/transactions/check`. Argus's `ergo-node-client::check_transaction` returns `Err` for kadia's response and `Ok(tx_id)` for eutxo's response. This is a concrete behavior and response-shape incompatibility for repeated preflight of an already-known transaction. It does not establish that a brand-new valid transaction would fail on kadia. The default-node gate nevertheless cannot pass. No compatibility workaround or weakened health check was added.

If parity is repaired, I would put kadia first for fresh automatic configuration: the measured mempool hot path saves about 1.8 seconds per call, while bulk discovery is occasional. That would remain subordinate to the existing selected-node, last-good-node and index-lag rules. List order is not an unconditional override for existing installations. Bulk performance is variable and should not be advertised as an advantage.

## Response parity

Queries used the original report's address `9hcvzUtMhsNnbfewYErk65mUxjWGn9DxQdiRVkMesg5fpZHwqF7` and its locally decoded ErgoTree. Listings used JSON-string POST bodies, matching Argus. The token sample was SigUSD (`03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04`); its issuance box came from `boxId`. Transaction and unspent-box IDs came from the address responses. Comparisons decoded JSON recursively, including nested field types and nulls, and also compared whole decoded values. Object key order and transport whitespace were ignored; array order was retained.

This is sampled endpoint evidence, not a claim to have proved every possible response. In particular, empty mempool listings do not prove nonempty-item parity. Work on defaulting stopped at the preflight blocker, as requested.

| Endpoint | Shape / nullability / pagination comparison | Result |
|---|---|---|
| `GET /info` | Same keys and types, including integer `fullHeight`, `headersHeight`, scores and parameters; string IDs/network/version; boolean flags. `isExplorer` is false on kadia, true on eutxo. | Required health data parses alike. Both sampled chain heights were 1,871,560. |
| `GET /blockchain/indexedHeight` | Both objects contain integer `indexedHeight` and `fullHeight`. Kadia adds string `status: "caughtUp"`. | Both heights equal chain height; no check weakened. |
| `POST /blockchain/balance` | Both have `confirmed`/`unconfirmed` objects containing integer `nanoErgs` and token arrays. Kadia token entries omit Scala's string `name` and integer `decimals`; both retain string `tokenId` and integer `amount`. | **Not identical.** Confirmed nanoERG also differs: 492,636,552,062 vs 494,720,040,911. Argus's current wallet balance/discovery paths sum UTXOs rather than consuming this endpoint's metadata. Cause of endpoint total discrepancy is unproven. |
| `POST /blockchain/box/unspent/byAddress?offset=0&limit=500` | Bare array, no `items`/`total`. Exact decoded equality. Boxes have string `boxId`, `ergoTree`, `transactionId`, `address`; integer `value`, `creationHeight`, `index`, `globalIndex`, `inclusionHeight`; asset arrays with string IDs/integer amounts; register object; nullable `spentTransactionId` and `spendingProof`. | Sample matches. Offset 1 / limit 1 also matches as empty arrays. |
| `POST /blockchain/box/unspent/byErgoTree?offset=0&limit=500` | Same bare-array box shape and exact decoded equality. Also tested offset 1 / limit 1 and the full Ergopad stake-tree 500-box page. | Samples match, including all 500 bulk boxes. |
| `POST /blockchain/transaction/byAddress?offset=0&limit=20` | Object `{items: array, total: integer}`. Exact equality of every decoded field/value, including enriched inputs/outputs, their assets/addresses/values, nullable box metadata, proofs/registers, `id`, `timestamp`, `inclusionHeight`, `numConfirmations`, `blockId`, `index`, `globalIndex`, `size`, and `dataInputs`. Offset 1 / limit 1 also exactly equal. | **120,686 vs 174,954 bytes is entirely whitespace.** Both compact to 120,686 bytes. No Argus-read history field is omitted. |
| `POST /transactions/unconfirmed/byErgoTree?offset=0&limit=100` | Bare arrays, both `[]`; 2 vs 3 bytes is whitespace. | Empty shape matches; nonempty shape remains unproven. |
| `GET /utxo/byId/{box}` | Object with core box fields, assets and registers; exact decoded equality, including field presence/types. | Sample matches. |
| `GET /blockchain/token/byId/{token}` | Object with string `id`, `boxId`, `name`, `description`; integer `emissionAmount`, `decimals`. | Exact decoded equality for SigUSD; absent/null optional metadata on other tokens not exhaustively sampled. |
| Issuance: `GET /blockchain/box/byId/{token.boxId}` | Enriched box object, including additional registers and spent metadata. | Exact decoded equality; issuance metadata sample matches. |
| `GET /blockchain/transaction/byId/{tx}` | Enriched transaction object with the same nested fields as history. | Exact decoded equality. |
| `POST /transactions/check`, malformed `{}` | Both HTTP 400 objects with integer `error`, string `reason`, string `detail`; wording differs. | Error parsing matches for malformed JSON transactions. |
| `POST /transactions/check`, existing network transaction | Kadia HTTP 400 object `{error: int, reason: string}`, with **no detail**; eutxo HTTP 200 JSON string transaction ID. | **Blocker: different Argus result.** |
| Submission: `POST /transactions`, malformed `{}` only | Both reject HTTP 400 with `{error: int, reason: string, detail: string}`; wording differs. | Error shape matches. Successful broadcast was deliberately not exercised; no transaction was submitted to mainnet. |
| `GET /blockchain/box/unspent/byTokenId/{token}?offset=0&limit=10` | Bare array of boxes. | Exact decoded equality; included because protocol/pricing paths call it. |
| `GET /blocks/lastHeaders/10`, `/blocks/{id}`, `/blocks/{id}/header`, `/blocks/{id}/transactions`, `/blocks/at/{height}` | Header arrays, full block/header/transaction objects, and string-ID array respectively. | Exact decoded equality for the same sampled block(s). |
| `GET /transactions/unconfirmed/byTransactionId/{confirmed-id}` | Both HTTP 404 `{error: int, reason: string, detail: ...}`; kadia detail is string, eutxo detail is null. | Error nullability differs; this was a missing-transaction sample. |
| `GET /transactions/unconfirmed?offset=0&limit=100` | Both bare arrays; different mempool contents. Used to obtain the preflight sample. | Whole-page shape differences are not parity evidence for the same transactions; no nonempty mempool compatibility claim. |

Kadia's `isExplorer: false` is not treated as proof that extraIndex is disabled. The **existing pinned** `ergo-node-interface-rust` revision `0264f6f` detects that capability by requesting `/blockchain/indexedHeight`; Argus's protocol client then compares index and chain heights. The sampled responses satisfy those existing checks. Neither Dart selection nor Rust capability logic changed.

The table records the observed shape differences. Dynamic register keys and different mempool contents are distinguished from comparisons of the same response. Raw samples are no longer included in the repository.

Bulk retest: kadia 3,406 ms, eutxo 5,107 ms, 500 exactly equal decoded boxes (1,053,052 vs 1,151,553 bytes). This reverses the user's 5,237 vs approximately 3,570 ms pair. These isolated HTTP measurements establish variability, not a reliable bulk-speed ranking. The original mempool measurement remains the reason to consider kadia first after compatibility is repaired.

## Implemented changes

- **Probe and configuration:** removed the pre-probe `apply()` and the discarded sequential Rust `/info` tour. A completed Dart probe applies the selected order once. The ordered URL list plus explorer URL is compared with the last successfully applied configuration, so an unchanged probe does not call the Rust setter or clear its 60-second client cache. Failed configuration calls remain retryable. Price refresh starts after this shorter path. Initial `load()` can still configure Rust before probing; that supports callers needing the network during startup.
- **Wallet correctness:** refresh sharing now requires the same wallet ID and generation. Reset invalidates pending work and clears its busy handle. Old completion cannot clear a newer operation. Discovery, cache hydration, balance/history publication, stealth hydration, metadata completion and snapshot writes reject obsolete contexts. No per-wallet in-memory retention or background cross-wallet refresh was added.
- **Honest sync state:** “Synced” requires the synced phase and evidence of a successful sync; online alone is insufficient. Partial history says “History incomplete.” Snapshots preserve `sync_phase` and `last_successful_sync_at` separately from the database write timestamp. Old snapshots without success evidence remain “Not synced” until a successful refresh. The status strip retains successful-sync age while refreshing.
- **Progressive pricing:** each existing branch updates the cumulative pricing inputs and publishes the prices currently resolvable. Oracle/ERG/major-token results can appear while pools are still pending. Source-generation checks prevent an obsolete source's branch from publishing. All original branches, source selection, requested IDs and currency requests remain unchanged.
- **Holdings and snapshots:** emission amount is serialized and hydrated so cached NFTs retain classification. Assets listens to the sync controller and reads live display tokens and total ERG, including stealth holdings; resetting the controller clears that view. It no longer freezes holdings at navigation time.

## Timing

For four healthy defaults, request count changes from **12 to 8**; the redundant four-request sequential tour disappears. The user's accepted prior replay was 5,143 ms versus 2,251 ms through the remaining first stage.

A new Python HTTP replay on this machine measured:

| Run | Old path | Remaining Dart probe stage | Removed tour |
|---|---:|---:|---:|
| 1 | 4,670 ms | 2,098 ms | 2,572 ms |
| 2 | 4,425 ms | 1,952 ms | 2,473 ms |
| 3 | 4,567 ms | 2,091 ms | 2,476 ms |

**Qualification:** sigmaspace `/info` returned HTTP 403 in every replay, so its indexed-height request was skipped: the actual replay was 11 versus 7 requests. The script's legacy JSON key labels say `12`/`8`; these are the healthy-path counts, not the observed counts. This is an HTTP replay, not a device/FFI trace; it does not measure cache-reuse gains, persistence or rendering.

## Regression verification and validation

New tests live in `app/test/batch_a_sync_test.dart`, `app/test/batch_a_network_test.dart`, plus the progressive-price test in `app/test/token_pricer_test.dart`.

Fourteen behavior tests were run against the actual HEAD implementations and failed:

1. Old wallet completion must not clear the newer refresh's busy handle or publish/cache its balance.
2. Changed wallet identity must not join an older refresh, even without reset.
3. Late discovery must not replace a new wallet's address.
4. Late cache hydration must not publish after a wallet change.
5. Late stealth scan must not contaminate a reset of the same wallet.
6. Cached NFT emission must survive hydration.
7. Database round trip must retain sync validity separately from save time.
8. Snapshot round trip must retain successful age, phase and emission.
9. Online alone must not imply successful wallet sync.
10. Repeated probes must apply unchanged configuration only once and publish prices.
11. Dart probing must not invoke the second native tour.
12. Oracle prices must publish while the pool branch is gated.
13. The rendered status strip must retain age during refresh.
14. The rendered Assets screen must follow live holdings and clear on reset.

The old-code run used the original implementation files from `git show HEAD:...`, with only test adapters retained: the injected network setter, a method exposing the **original dashboard status decision**, and a widget factory exposing the **original age suppression**. This allowed the new tests to compile against old behavior. It was not a test of missing symbols or a compiler failure. Production files were restored in a `finally` block. Result: **8 passed, 14 failed**, with expected assertion failures. The additional failed-configuration retry test also passes and protects unchanged behavior.

All tests then pass with the implementation restored: 692 passed, one existing skipped test, zero failures. Final result lines, verbatim:

```text
No issues found! (ran in 3.9s)
00:24 +692 ~1: All tests passed!
```

Only the final command excerpts above are retained; the full logs were removed.

Both use `TMPDIR=/home/rkadias/.cache/argus-tmp` and `/home/rkadias/coding/development/flutter/bin/flutter`. Rust clippy/tests are not required for this change because no Rust crate was touched. No native rebuild was performed. Formatting was limited to the nine changed Dart files, with unrelated formatter-only changes restored. `git diff --check` is clean.

## Limits and plan corrections

- Adding a fast new default before successful compatibility verification would be wrong. The explicit stop condition overrides adding kadia in this batch.
- The history-size concern is resolved: whitespace, not omitted fields.
- The `/blockchain/balance` response is not identical; its missing metadata and different total are recorded without attributing a cause. Current Argus wallet balances are derived from UTXO listings, which matched.
- Successful submission parity cannot be empirically established under the no-mainnet-submission constraint. Only malformed-request rejection was tested there.
- No Rust edit was necessary to stop unchanged configuration clearing clients on this Dart path. Single-flight Rust client construction from the broader original plan was not part of the explicit implementation bullets and remains unchanged.
- Pre-existing issues observed but not fixed: sigmaspace returned HTTP 403 from this environment; `NetworkController.setErgRate` assigns `usdPerErg = usdPerErg` rather than the field; changing price source during a pending refresh can leave the new source waiting for a later refresh. This batch retains existing source-change fetching behavior rather than adding more fetches.
- No Batch B work was started. Metadata hydration still precedes holdings publication; this batch makes the specifically requested price branches progressive and Assets live, without introducing the broader unknown-decimals/raw-holdings redesign.
