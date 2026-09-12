# Batch C: warm cross-wallet public snapshots

Work remains uncommitted on `feat/sync-b`, above Batch B `5e007f2`. No branch change, dependency change, Rust change, native-library rebuild, or transaction submission.

## Change

`PublicWalletSync` replaces the dashboard's ERG-only cross-wallet requests with one shared scheduler. It reads the union of persisted frontier addresses, used addresses, primary address and recorded display address, deduplicated. It aggregates ERG and tokens, fetches up to 20 confirmed history rows per address, deduplicates transactions, and retains the five newest rows. An address balance or history failure retains the entire prior wallet snapshot and its timestamp; it never writes an incomplete sum as zero.

The public result is written to the existing per-wallet database, so `lastKnownBalance` supplies the dashboard, portfolio, and overview with the same ERG and token amounts. The overview has no separate wallet balance request fallback. It paints cached balances without waiting for network work and listens for completed public refreshes; that listener reloads wallet snapshots without refreshing watch-only addresses.

The controller remembers warmed public holdings/activity under their wallet ID. Activation applies them synchronously, before hydration or network awaits. Batch B's existing remembered routing, stealth state, and ownership boundary remain in place. A public result never updates the active controller view directly. Tokens use the existing global `walletService.tokenMeta` cache: the live mock proves that two wallets holding the same previously unseen token require exactly one metadata call, then reuse its name and decimals. Newly learned metadata is also flushed through the existing global persistent cache, so warming does not make it session-only.

## Phone policy

- Minimum five minutes between global attempts, including failed attempts. The dashboard checks the shared scheduler on its existing five-second timer; there is no second independent throttle. Busy active syncs can delay a check. Active polling remains 20 seconds normally and five seconds with pending activity.
- Foreground only, and only during an unlocked session. Lifecycle states other than resumed pause this work. Before the first unlock, and after security lock, screens use persisted public summaries. No unlock is initiated to refresh another wallet.
- Skip each wallet whose public refresh or successful active sync is less than five minutes old. A fresh disk snapshot can still seed the session's warm view without network requests.
- One global job, one inactive wallet at a time, one address at a time. Balance, history, and missing token metadata requests are sequential. Added concurrency is at most one public API operation, regardless of wallet/address count. Existing active-wallet request concurrency is unchanged.
- Lifecycle changes invalidate even a job whose app backgrounds and resumes before its request completes. Switch, deletion, and security lock likewise invalidate jobs. Checks occur between awaited operations and before persistence/admission. An already-started native operation cannot be cancelled here; it can finish its internal HTTP work, but no subsequent public operation or late snapshot publication is permitted.

Five minutes is 15 times less frequent than ordinary active polling and 60 times less frequent than pending polling. Serial work sacrifices background completion speed to avoid request bursts. This is bounded concurrency, not constant request volume: many recorded addresses still cost proportionally more. No undiscovered addresses are queried. A long job remains single-flight; a switch can cancel its remaining wallets until the next eligible attempt.

## Ownership and security

`PublicWalletGateway` exposes only public balance/history/metadata reads and scoped cache access. It has no derivation, discovery, stealth scanning, secret access, or unlocking capability. Production calls supply public address strings, never a wallet handle.

The controller's separate public-session generation advances on deactivate/switch, reset, and deletion. Ordinary active refreshes do not advance it, so a slow warm job is not starved by active polling. Admission rejects the active wallet, mismatched payload IDs, locked sessions and revoked generations. The database checks ownership and the job's validity after obtaining preferences, immediately before writing its wallet-specific key.

Reviewed `session_lock.dart` and `WalletService._lock`: security lock synchronously calls controller reset before awaiting the native lock. Reset clears both Batch B remembered views and the new warm map. Switching retains public views; security lock does not. Existing persisted public summaries and metadata remain available under the existing public-cache policy. No secret is added to these caches and no grace/suppression/secure-storage behavior changes. This fits the existing auto-lock model.

## Honest presentation

Inactive dashboard and overview rows say:

> Last-known public data · known addresses only; undiscovered funds may be missing

Dashboard rows retain an “as of” age even after a successful public refresh. Existing dated stealth annotations retain their original scan time; public refreshes do not scan stealth or advance discovery/stealth timestamps. The activated warm view says “Last-known public data · known addresses only” until a successful active sync replaces it. `public_only` survives persistence and unsuccessful active refreshes; a public refresh does not claim a successful full-wallet sync.

Recent public history is confirmed address history, not a stealth scan or a separately fetched pending-transaction history. Balances retain the existing public balance API's mempool adjustment. Undiscovered funds, new stealth receipts, and later chain changes require the active wallet's normal sync.

## Three-wallet measurement and added cost

Controlled test: one active wallet (unchanged), two inactive wallets with one known address each, cached metadata, and 20 ms simulated latency per public API operation. The baseline reproduces Batch B's `Future.wait` ERG-only path; the new path runs the actual scheduler against the measured fake gateway. This measures orchestration, not real-node latency or phone battery consumption.

| Cross-wallet work | Batch B | Batch C |
| --- | ---: | ---: |
| Balance API calls per eligible pass | 2 | 2 |
| History API calls per eligible pass | 0 | 2 |
| Peak simultaneous public operations | 2 | 1 |
| Controlled wall time, representative run | 21 ms | 83 ms |
| Extra calls on an ordinary active poll | 0 | 0 |
| Recurring calls per five-minute eligible pass | 0 | 4 |
| Network calls needed to show already-warmed tokens on activation | No cross-wallet token warming | 0, synchronous |

The Rust public balance API already fetches unspent boxes and address mempool data. With fewer than 500 UTXOs per address, no retries/fallbacks, and cached metadata, the two old balance calls represent **four HTTP requests**. Two balances plus two histories represent **six HTTP requests** after this change. Thus initial eligible work adds two HTTP requests, and the added recurring cost is plainly **six HTTP requests per five minutes, approximately 72 per foreground hour**, excluding the unchanged active wallet. With two addresses in each inactive wallet, the recurring figure doubles to 12 requests/pass or approximately 144/hour. Fresh wallets reduce these counts, possibly to zero.

Each newly seen token adds metadata work once when retrieval succeeds; the live bridge test observes one metadata call across both wallets. Further UTXO pages add requests: existing page size is 500 and the existing cap is 10,000 boxes/address. General steady-state cost is `sum(UTXO pages + 1 mempool + 1 history)` over stale inactive known addresses, plus uncached metadata. Actual bytes, battery drain, endpoint retries and real-network wall time were not measured; the synthetic numbers must not be represented as a phone performance claim.

## Tests and mutation checks

16 new tests cover public native API usage without a handle, shared metadata, immediate owned activation, reset eviction, recorded-frontier union/deduplication, token aggregation, five-row history, freshness/throttling, foreground gating, single-flight, delayed switch/lock/delete/background results, failure preservation, overview snapshot reads without independent requests, persisted incompleteness, admission checks, completion notifications, active-poll coexistence, and the three-wallet measurement.

19 deliberate mutations were killed by assertion failures: omit warm memory; publish into the active view; omit persistence; omit history; omit frontier; retry after one second; ignore freshness; ignore session revocation; ignore lifecycle revocation; omit the public label; omit overview notification; remove database ownership/validity guards; retain warm memory on lock; bypass global metadata cache; inject locked discovery; inject locked stealth scanning; parallelize addresses; parallelize wallets; omit metadata persistence. Original sources were restored after every mutation. The locked discovery/stealth mutations use the real public gateway and fail the handle-free live test; the mock native API rejects every capability outside the public read allowlist.

A separate cache-contract test uses only APIs that already exist in Batch B. Running it with the actual `5e007f2` controller/database fails behaviorally with `Expected: true / Actual: <null>` for the public-only flag. With Batch C it passes. The scheduler's newly introduced API cannot itself be invoked on unmodified Batch B; the removal mutations establish the missing warming behavior without presenting a compilation failure as behavioral evidence.

Formatting was run only on changed Dart files; untouched surrounding formatting was restored to keep the diff focused. No repository-wide formatter was run. Working logs and mutation scripts stay outside the repository in the requested cache directory.

## Validation output

Commands ran from `app/`, using `/home/rkadias/coding/development/flutter/bin/flutter` and `TMPDIR=/home/rkadias/.cache/argus-tmp`. Final commands and their complete captured output follow; the failures-only test reporter avoids dumping every passing test. The JSON reporter was retained outside the repository for counts.

`flutter analyze --no-pub` — exit 0:

```text
Waiting for another flutter command to release the startup lock...
Analyzing app...                                                
No issues found! (ran in 5.6s)
```

`flutter test --no-pub --reporter failures-only --file-reporter json:/home/rkadias/.cache/argus-tmp/c-tests.json` — exit 0:

```text
+11: /home/rkadias/coding/arkadianet/Argus/app/test/widget_test.dart: App renders dashboard
argus: notifications unavailable: LateInitializationError: Field '_instance@1532271368' has not been initialized.
+721 ~1: /home/rkadias/coding/arkadianet/Argus/app/test/batch_b_timing_test.dart: BATCH B timing: synthetic controller switch, cold launch, refresh
SYNTHETIC controller microseconds: return=[914, 100, 96] coldCache=[69941, 63523, 62774] coldFresh=[116530, 105743, 103990] refresh=[68349, 40722, 41303]
+727 ~1: /home/rkadias/coding/arkadianet/Argus/app/test/batch_c_sync_test.dart: C: three-wallet controlled latency measurement
C BENCH: before=2 calls/21ms; after=4 calls/83ms; ordinary poll=0; five-minute poll=4 calls
+730 ~1: 1 skipped test.
+730 ~1: All other tests passed!
```

Result: 730 passed, one existing opt-in test skipped. JSON reporter success: `true`; full-suite elapsed time: 29.393 seconds. `git diff --check` also passed.


## Existing findings and limits

The test suite's app-render test logs a notification-plugin initialization warning. The existing real-mainnet stake-recovery test is opt-in and skipped without its executable/evidence environment variables. Neither was changed.

Existing public balance reads can degrade mempool errors to confirmed-only data, and the native UTXO listing caps at 10,000 boxes/address; Batch C does not claim stronger completeness than that API. Existing overview/portfolio stealth-total conventions differ from the active wallet's full total; they were not broadened here. No unrelated finding was fixed and no implementation blocker remains.
