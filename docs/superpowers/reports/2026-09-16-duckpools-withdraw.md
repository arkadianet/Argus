# Duckpools withdrawal input selection and diagnostics

## Fix and safety

`wallet_core::spend::is_spendable` now accepts a token-bearing box when it contains the requested token (`any`, previously `all`). Co-located tokens no longer hide public receipts. No device box JSON was supplied, so this is a reproduced selector defect, not proof of the reporting device's exact holdings.

Both send builders aggregate every input token, subtract only the sent amounts, and return all remaining tokens to the change address. Neither discards extras. Reviewed the same accounting in Duckpools order/adjustment and Rosen lock builders; each preserves extras and requires minimum ERG for token-bearing change.

`wallet-core/tests/token_containment.rs` exercises selection followed by both single-send and multi-recipient builders:

- One and three unrelated tokens in the receipt box.
- One box and receipts spread across two boxes, only one carrying extras.
- Exact amount (100) and excess holdings (100 held, 80 sent).
- No-change baseline, zero remainder, minimum minus one nanoERG, and exactly minimum change funding, with zero, one and three extra tokens.
- Every successful transaction asserts per-token totals across **all inputs and all outputs including change**, full return of extras to the wallet, exact recipient amounts, ERG conservation, and minimum value for token-bearing outputs.
- Insufficient change funding must fail explicitly, producing no transaction. Single-send now returns `TokenChangeInsufficientErg`, explaining that more ERG is needed to preserve unsent tokens, rather than a generic balance shortfall. Multi-send already has that specific error.

A Duckpools FFI regression withdraws the real fixture receipt in base units with an extra token. The receipt box funds exactly proxy plus fee; token change forces a retry selecting a second ERG box. The regression asserts per-token conservation and that the extra token returns in a minimum-value change box.

The `send_token: None` filter remains unchanged: token-bearing boxes are ineligible there. Also unchanged is `select_for_send`'s pre-existing fallback to token-bearing boxes when plain ERG is insufficient. Changing either ERG-send policy is outside this token-containment fix.

## Diagnostics and recovery retained

The original public-input, mixed-ID and reservation snapshots remain. Duckpools reports the required amount, automatically selectable amount and public-address total separately. It names mixed-box privacy exclusions, pending-mix ERG reservations, and stealth holdings absent from protocol funding. The Flutter lend/withdraw preflight uses Assets pocket metadata and offers Open Send with the token and public receive address prefilled; it does not select boxes or broadcast. Wallet identity checks and privacy explanations remain.

The obsolete co-location explanation is replaced with the actual remaining token-containment restriction: during a token order, ERG in boxes holding only unrelated tokens is still excluded. A regression checks that wording. A receipt co-located with other tokens now selects successfully. Mixed-box privacy exclusions remain based on tracked box IDs, not token co-location. Reservation matching requires a token-free box and cannot reserve receipts. Stealth signing is still unsupported by this public protocol path.

## Caller audit

| Path | Effect of this fix |
| --- | --- |
| Ordinary single-token Send via `select_preferring_one_pocket` | Fixed in each offered pocket; pocket preference and ownership checks unchanged. |
| Duckpools orders via `build_order` | Fixed whenever `Quote::token_needed` supplies a token: withdrawal receipts, token-pool lending, token collateral for borrowing, and token repayment/partial repayment. |
| Duckpools collateral adjustment | Fixed when adding token collateral through `wallet_needs`; ERG-only adjustments unchanged. |
| Rosen transfers | Fixed for token transfers; ERG transfers unchanged. |
| Multi-recipient Send | Separate `select_for_multi_send` already accepts co-located tokens; conservation covered by the new tests. |
| Explicit coin control | `select_exact` already accepts selected boxes; unchanged. |
| Mint and burn fee top-up | Call the shared selector with `None`; unchanged. Burn chooses its token inputs separately. |
| SigmaFi, stake recovery, Dexy, SigmaUSD, AMM | Do not use this token filter; their separate selectors and public/mixed/stealth restrictions are unchanged. |

This fix does not grant any protocol access to stealth or privacy-protected mixed boxes.

## Verification before the watched-address-send rebase

The table below records the original token-containment work before rebasing onto the watched-address-send work: 842 passing Cargo tests and 891 passing Flutter tests. PR #123 subsequently recorded 844 and 893 for the combined branch. Those are measurements of different scopes; the original results are retained here rather than replaced. The current review verification is recorded separately below.

The pinned Flutter SDK is used from the existing worktree-local `logs/flutter` copy because the installed SDK cache is read-only. The Flutter pin and both lockfiles are unchanged. No `#[frb]` signature changed; bindings need no regeneration.

Commands run from the indicated directory (paths relative to that directory):

| Directory | Exact command | Result |
| --- | --- | --- |
| root | `CARGO_TARGET_DIR="$PWD/rust/target" TMPDIR="$PWD/logs/tmp" cargo test --manifest-path rust/Cargo.toml --workspace` | Passed: 842 tests, 0 failed, 15 ignored, including doc tests. Equivalent workspace invocation to `cd rust && cargo test --workspace`. |
| app | `FLUTTER_SUPPRESS_ANALYTICS=true TMPDIR="$PWD/../logs/tmp" ../logs/flutter/bin/flutter analyze` | Passed: no issues. |
| app | `FLUTTER_SUPPRESS_ANALYTICS=true TMPDIR="$PWD/../logs/tmp" ../logs/flutter/bin/flutter test` | Passed: 891 tests, 1 skipped. |
| root | `CARGO_TARGET_DIR="$PWD/rust/target" TMPDIR="$PWD/logs/tmp" scripts/build_android.sh` | Passed: rebuilt both tracked Android libraries. |
| root | `CARGO_TARGET_DIR="$PWD/rust/target" TMPDIR="$PWD/logs/tmp" scripts/release_check.sh libs` | Passed: both tracked ABIs match a fresh build byte-for-byte. |
| root | `git diff --check` | Passed. |

Logs: `logs/containment-workspace.log`, `logs/containment-analyze.log`, `logs/containment-flutter-test.log`, `logs/containment-android.log`, and `logs/containment-release-libs.log`.

## Original commit status before the rebase

On `fix/duckpools-withdraw`, staging the original diagnostics separately failed:

```
fatal: Unable to create '/home/rkadias/coding/arkadianet/Argus/.git/worktrees/duck/index.lock': Read-only file system
```

Per instruction, all work remains uncommitted. The original diagnostics binary patch and report were saved separately under `logs/diagnostics-before-containment.patch` and `logs/diagnostics-before-containment.md` (ignored local artifacts), preserving the starting state for splitting commits later. Intended plain commit messages: `Explain Duckpools funding exclusions and offer Send recovery` and `Allow token sends from boxes with co-located tokens`. Nothing was pushed and no PR was opened.


## Review verification on the combined branch

Measured on 2026-09-16 in `fix/duckpools-withdraw`, based on `f8c6746` with the review fixes in the working tree. This scope includes the watched-address-send rebase and two new Flutter regression tests for the minimum stealth transfer and exact public coverage. Current totals are **844 Cargo tests passed, 0 failed, 15 ignored**, including doc tests, and **895 Flutter tests passed, 0 failed, 1 skipped**. The Flutter total is two higher than the PR's earlier combined-branch total of 893 because of these regression tests.

The diagnostic now computes `required - (total - stealth)` and formats every amount with the pool decimals, using the same formatter as the order screen. With two decimals, 3,000 public base units, 8,000 stealth base units, and a 10,000-base-unit order display as 30 public, 80 stealth, and an order of 100: the minimum transfer is 70 (7,000 base units). Exact public coverage returns no message; a one-base-unit shortfall displays as 0.01.

Commands run from the indicated directory:

| Directory | Exact command | Result |
| --- | --- | --- |
| rust | `cargo test --workspace` | Could not start tests: the configured shared target cache is read-only (`/home/rkadias/.cache/cargo-target/debug/.cargo-lock`). Retried below with a writable local target. |
| rust | `CARGO_TARGET_DIR="$PWD/target" TMPDIR="$PWD/../logs/tmp" cargo test --workspace` | Passed: 844 tests, 0 failed, 15 ignored, summed across 42 result groups including doc tests. |
| app | `FLUTTER_SUPPRESS_ANALYTICS=true TMPDIR="$PWD/../logs/tmp" ../logs/flutter/bin/flutter analyze` | Passed: no issues. |
| app | `FLUTTER_SUPPRESS_ANALYTICS=true TMPDIR="$PWD/../logs/tmp" ../logs/flutter/bin/flutter test` | Passed: 895 tests, 0 failed, 1 skipped. |
| root | `git diff --check` | Passed. |

Logs: `logs/review-workspace.log` (successful retry), `logs/review-analyze.log`, and `logs/review-flutter-test.log`.

The local SDK is Flutter 3.41.2 / Dart 3.11.0. The Flutter pin, lockfiles, bindings, native Rust, and tracked libraries are unchanged. No native rebuild or library release check is needed for these Dart and documentation changes.

### Review commit status

Staging the first finding failed because Git could not create `/home/rkadias/coding/arkadianet/Argus/.git/worktrees/duck/index.lock` on the read-only filesystem. As requested, both findings remain uncommitted. Intended separate plain commit messages:

- `Show the minimum Duckpools stealth funding shortfall`
- `Record Duckpools verification totals by branch scope`

Nothing was pushed and no PR was opened.
