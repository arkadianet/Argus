# Sync batch B — 2026-09-13

Implemented on `feat/sync-b`, starting at `v1.0.0-alpha.49`. The tree is intentionally uncommitted. The original investigation from session `01a09583` was re-read, including priorities 6/7 and the request dependency graph.

**Part 1 — retain the wallet just left.**

[WalletSyncController](../../../app/lib/services/wallet_sync_controller.dart) keeps a wallet-ID-keyed, session-local view: balances, full token metadata, ordinary and stealth activity, used/frontier addresses, receive/change/sender routing, UTXO count, successful-sync time, discovery metadata, stealth box IDs, and broadcast bookkeeping. Returning restores the view synchronously, before derivation, preferences reads, or HTTP. A retained in-flight phase becomes idle rather than falsely claiming a completed refresh.

`deactivate()` is the wallet-switch operation; `reset()` remains a complete security purge. [WalletService](../../../app/lib/services/wallet_service.dart) uses `lockForSwitch()` to discard the outgoing private-key handle while retaining public view data. It still requires the existing biometric/PIN authentication before opening another wallet. There is no retained key or authentication bypass.

The safety boundary is explicit:

1. The service clears the outgoing visible view and invalidates its generation before publishing the new identity. It clears the outgoing mix/stealth overlays too.
2. Activation can restore only the entry indexed by the target wallet ID. An unseen wallet is empty. The old wallet's addresses cannot become the new wallet's refresh inputs.
3. Batch A's generation **and** active-wallet-ID checks still reject late hydration, discovery, balances, history and stealth results. An old operation cannot clear the new operation's busy flag or save its result as the new wallet.
4. [WalletViewBoundary](../../../app/lib/ui/widgets/wallet_view_boundary.dart), used by the dashboard, requires the displayed wallet ID, controller owner and service identity to agree. Both update orders are tested: label first and service first. There is no outgoing-view fade; a wallet-specific subtree key also prevents reuse of the previous wallet's embedded screen state.
5. Stealth box IDs are owned by the remembered view, rather than borrowed from the global service's most recent scan. Dashboard ancillary state is reset before immediately rendering the restored view.

**Lock/deletion policy.** `SessionLock` still invokes `walletService.lock()` after its configured grace (default two seconds; overlay suppression unchanged). That path drops **all** retained controller references synchronously, before awaiting native key locking. Explicit lock does the same. Deleting a wallet evicts its entry before storage work, including when that wallet is inactive. Tests cover a pending native lock, subsequent re-authentication, and deletion of an inactive wallet without erasing the active wallet's view. The existing public-chain disk snapshots and locked-wallet overview policy remain; this work does not claim physical zeroization of garbage-collected Dart memory. No private key is stored in the view.

**Part 2 — known addresses first; persistent discovery.**

A refresh reads remembered addresses before discovery. Routine launch/return checks discovery age; foreground quiet polls check it too. A successful discovery is fresh for **15 minutes**. First restore/import and older snapshots without discovery metadata require discovery. Pull-to-refresh/manual rescan always forces it. Hydration detects changed pin/unused-change settings and expires discovery. A future-dated timestamp is also treated as expired.

Fifteen minutes avoids repeatedly scanning the gap when switching wallets within a minute, while bounding ordinary foreground discovery staleness when another client uses new addresses. It is not a promise to discover arbitrary external use immediately; manual rescan is the immediate override. Only the active unlocked wallet participates.

The address frontier, discovery timestamp/configuration and receive/change routing survive restart through [WalletDatabaseService](../../../app/lib/services/wallet_database_service.dart). A successful discovery persists even if subsequent balance reads fail; a never-known balance remains null and is not exposed as a zero-valued last-known balance. Old snapshots remain readable and force discovery because they lack the new metadata.

Discovery runs after the known-address pass. When it finds a changed address set, a second pass reads the expanded set; when unchanged, there is no second holdings/history/count read. This deliberately preserves complete wallet-wide pending valuation. Discovery's own existence/balance probes are separate from the refresh input-sharing described below. Thus a rescan that expands the address set can perform two refresh passes; the request reduction is per pass, not a claim that the entire rescan makes only three requests per address.

**Departure from the proposed parallel frontier loop:** the premise that these FFI derivations can execute independently is false in the current interface. `derive_address()` executes the complete derivation inside `with_handle()`, which holds the global `HANDLES` mutex. Concurrent Dart calls would queue behind that same lock. The frontier loop therefore remains serial. I did not weaken key-locking/lifetime semantics or claim a speedup from `Future.wait`. Actual parallel BIP32 execution would require a different native batching/handle design. The existing 64-entry frontier cap is unchanged.

**Part 3 — share refresh inputs.**

The new Rust `get_sync_inputs` in [api.rs](../../../rust/crates/wallet-ffi/src/api.rs) owns one UTXO listing and one mempool result per unique address. Addresses run concurrently; the UTXO and mempool branches use `tokio::join!`. Balance/token deltas, wallet-wide deduplicated pending activity, and unique confirmed UTXO count all consume those inputs. Confirmed history starts concurrently in Dart. No TTL/global response cache was added: another explicit refresh reads the node again.

Failed address listings remain missing balance results, and an incomplete count retains the previous count. Mempool failure retains the existing confirmed-only fallback. The existing standalone APIs remain available for other callers; the live sync gateway uses the shared path. Generated Dart/Rust bridge sources are included.

For warm client/metadata caches and one UTXO page per address, with stealth/discovery excluded: **6N → 3N HTTP requests** (UTXO listings 3N → N; mempool 2N → N; confirmed history N). With pagination the new count is `Σ UTXO pages at 500 + 2N`. Metadata, stealth, node setup/probes and discovery are additional work.

**Part 3 requires a native library rebuild before app/device validation or release.** No native libraries were rebuilt, and no `jniLibs/**/*.so` was modified. Cargo checks/tests built test/check artifacts only. No dependencies were added and no transaction was submitted to mainnet. Cross-wallet background holdings/history refresh (batch C) was not implemented; the existing other-wallet reader was not extended.

**Measurements.**

The committed [timing harness](../../../app/test/batch_b_timing_test.dart) ran against both the actual alpha.49 sources extracted into the cache directory and this implementation. Its compatibility adapter uses alpha.49's `reset()`/full-refresh calls only when the new switch/freshness APIs are unavailable. These are **synthetic controller timings**, not an Android/iOS cold-start trace: pinned-index read, derivation and cache read each wait 20 ms; discovery waits 200 ms; balance reads wait 40 ms. The cold-launch case has a persisted snapshot/frontier. Three trials; medians in milliseconds:

| Scenario | Before | After |
|---|---:|---:|
| Return to previously viewed wallet: first remembered figures | 62.896 | 0.074 |
| Cold controller launch: cached figures | 62.801 | 62.782 |
| Cold controller launch: first fresh holdings | 326.049 | 103.973 |
| Ordinary refresh through the fake gateway | 41.261 | 41.355 |

The fake refresh does not execute Rust, so its unchanged time is expected. Cold cached rendering still pays the same disk/local work. Return timing after the change measures the synchronous publication, not completion of the later pin check. Verbatim timing output (microseconds):

```text
SYNTHETIC controller microseconds: return=[62896, 62917, 62744] coldCache=[67111, 62280, 62801] coldFresh=[336778, 325542, 326049] refresh=[41249, 41265, 41261]
SYNTHETIC controller microseconds: return=[713, 74, 51] coldCache=[68692, 62387, 62782] coldFresh=[113830, 103579, 103973] refresh=[41382, 41355, 41344]
```

Separately, a Python/aiohttp **live HTTP dependency replay** used public address `9hcvzUtMhsNnbfewYErk65mUxjWGn9DxQdiRVkMesg5fpZHwqF7`, a reused connection pool, and only read endpoints. It replayed the old three branches and the new shared-input graph, three alternating before/after trials per node. All measured responses were HTTP 200. These numbers exclude Flutter, FFI, address discovery, token hydration, stealth, persistence, and authentication.

| Node / completion point | Before, ms (three trials) | After, ms (three trials) |
|---|---|---|
| kadia balance inputs | 641 / 661 / 643 | 342 / 350 / 356 |
| kadia full replay | 1382 / 693 / 689 | 656 / 660 / 653 |
| eutxo balance inputs | 2423 / 2479 / 2409 | 2200 / 2185 / 2203 |
| eutxo full replay | 2734 / 2479 / 2409 | 2200 / 2185 / 2203 |

Median balance completion: **643 → 350 ms** on kadia; **2423 → 2200 ms** on eutxo. Median complete replay: **693 → 656 ms**, **2479 → 2200 ms** respectively. Eliminating duplicate concurrent calls halves request volume; it does not imply a 2× wall-time improvement. No measured device/app launch number is available without rebuilding and running the native bridge.

**Regression and mutation evidence.**

[Baseline-compatible regressions](../../../app/test/batch_b_baseline_regression_test.dart) ran unchanged against actual alpha.49 code. All three failed with assertion failures, not compilation failures:

```text
Return: expected 11; actual null.
Known balance before releasing discovery: expected 42; actual null.
Cold persisted frontier: expected ['addr0', 'addr1', 'addr2']; actual ['addr0'].
```

[Batch B tests](../../../app/test/batch_b_sync_test.dart) additionally cover every switch notification, stale completion/retained-state poisoning, revocation, native-lock latency, deletion, service publication, dashboard frames, discovery freshness/manual override/foreground expiry, disk round-trip, changed pin/routing, failed-balance discovery persistence, stealth ownership and live shared-read wiring/concurrent history. Existing batch A tests remain and were adjusted only where they expected B to reuse A's addresses or assumed discovery preceded the known-address read.

[Native HTTP replay tests](../../../rust/crates/wallet-ffi/src/sync_tests.rs) assert exact UTXO/mempool request counts, concurrent arrivals (a condition-variable rendezvous detects serialization), no reuse on a subsequent refresh, deduplication, balance/pending valuation and failure behavior. They use a local HTTP server and an existing fixture, not mainnet transactions.

All **24 mutations** below produced assertion failures and nonzero test exits; every source mutation was restored. Mutations changing newly introduced APIs test the removed behavior without treating a missing symbol/compile failure as evidence.

| Removed or broken behavior | Mutation result |
|---|---|
| Remembered entry restoration | Assertion failed; exit 1 |
| Clear outgoing figures before identity publication | Assertion failed; exit 1 |
| Generation/wallet-ID stale-result guard | Assertion failed; exit 1 |
| Inactive-entry revocation | Assertion failed; exit 1 |
| Security-lock purge before awaiting native lock | Assertion failed; exit 1 |
| Known-address read before discovery | Assertion failed; exit 1 |
| Persist the frontier | Assertion failed; exit 1 |
| Honor discovery freshness/manual override | Assertion failed; exit 1 |
| Use the shared live read | Assertion failed; exit 1 |
| Wallet-owned stealth box IDs | Assertion failed; exit 1 |
| Clear outgoing global stealth overlay | Assertion failed; exit 1 |
| Delete-wallet eviction hook | Assertion failed; exit 1 |
| Restore discovered receive routing | Assertion failed; exit 1 |
| Invalidate discovery after pin change | Assertion failed; exit 1 |
| Controller ownership predicate | Assertion failed; exit 1 |
| Dashboard ownership gate | Assertion failed; exit 1 |
| Remove outgoing ledger without a fade | Assertion failed; exit 1 |
| Persist successful discovery despite failed balances | Assertion failed; exit 1 |
| Keep unknown balance null | Assertion failed; exit 1 |
| Restore the alpha.49 independent balance/pending/count read graph | Assertion failed; exit 101; actual requests `(3, 2)`, expected `(1, 1)` |
| Reject duplicate UTXO fetch | Assertion failed; exit 101 |
| Reject serial UTXO/mempool reads | Assertion failed; exit 101 |
| Do not publish zero count for a failed listing | Assertion failed; exit 101 |
| Retain pending valuation from shared inputs | Assertion failed; exit 101 |

The original regressions are red against alpha.49 and green here. The native legacy-graph mutation ran the retained standalone APIs in alpha.49’s original arrangement; the request-count assertion failed with three UTXO and two mempool reads instead of one each. The broader tests also protect unchanged fallback behavior; those preservation tests are not presented as pre-existing bugs.

**Validation and existing findings.**

Final commands (Flutter run from `app`; Cargo run from repository root), all exit **0**:

```sh
TMPDIR=/home/rkadias/.cache/argus-tmp /home/rkadias/coding/development/flutter/bin/flutter analyze --no-pub
TMPDIR=/home/rkadias/.cache/argus-tmp /home/rkadias/coding/development/flutter/bin/flutter test --no-pub --reporter expanded
CARGO_TARGET_DIR=/home/rkadias/.cache/cargo-target cargo clippy -p wallet-ffi --no-deps --manifest-path rust/Cargo.toml
CARGO_TARGET_DIR=/home/rkadias/.cache/cargo-target cargo test --workspace --manifest-path rust/Cargo.toml
```

Verbatim terminal result excerpts follow; raw working logs remain outside the repository. Flutter: **714 passed, one skipped**. Rust, summed across the emitted result lines: **788 passed, 12 ignored, zero failed**.

```text
Analyzing app...                                                
No issues found! (ran in 5.2s)
00:25 +714 ~1: All tests passed!
warning: `wallet-ffi` (lib) generated 13 warnings (run `cargo clippy --fix --lib -p wallet-ffi -- --no-deps` to apply 6 suggestions)
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 1.53s
```

<details>
<summary>All Cargo test-result lines, verbatim</summary>

```text
test result: ok. 141 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 97 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 35 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.18s
test result: ok. 0 passed; 0 failed; 2 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
test result: ok. 144 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
test result: ok. 25 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 26 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.09s
test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.62s
test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.38s
test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.03s
test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.03s
test result: ok. 15 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.11s
test result: ok. 26 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.20s
test result: ok. 42 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.97s
test result: ok. 80 passed; 0 failed; 4 ignored; 0 measured; 0 filtered out; finished in 1.58s
test result: ok. 26 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
test result: ok. 64 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 19.66s
test result: ok. 0 passed; 0 failed; 4 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

</details>

Clippy completed with **13 existing wallet-ffi warnings**: unused `funding_requirement`, map-entry suggestions, Copy-type clones, an unnecessary `into_iter`, and argument-count warnings. The copied balance helper retains its pre-existing Copy-clone findings. Cargo also reports the pre-existing unused `ergo-rest` patch. These were not cleaned up.

A pre-existing node-client behavior observed during failure testing remains: some read paths parse a valid-looking JSON payload even with HTTP 500. The failure fixtures therefore return malformed error bodies so they actually exercise failed inputs. Mempool page limits and the pre-existing discovery cap remain unchanged.

Only changed Dart files were passed to formatting; unrelated formatter churn in existing files was removed. Only the new/changed Rust helper text, test file and generated bridge were formatted. No repository-wide formatter ran. `git diff --check` passes. The only report artifact added is this markdown file; it contains no links to uncommitted working logs or external evidence dumps.
