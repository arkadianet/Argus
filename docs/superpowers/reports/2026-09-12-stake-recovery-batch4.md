# Stake recovery batch 4 — implementation and evidence

Implemented on `feat/stake-recovery`, based on `216df1a`, without committing.
Proxy creation is **gated in the UI**. The UI ships independent refunds for
tracked proxies. Normal Paideia unstake remains disabled. This avoids asking
users to lock a key through Argus before batch 5 provides the execution flow.
The creation builder, handle boundary, preparation path, and durable commit
orchestration are implemented for that later entry point.

`proxy.rs` assembles creation/refund, validates by complete re-derivation,
checks ERG and token conservation, and requires exact reduced propositions at
the native preparation/signing boundary. Creation additionally reduces its
wallet inputs, the derived proxy's standalone refund, and a private execution
eligibility witness before returning. The witness is discarded: no executor
transaction is returned, cached, signed, or exposed through FFI.

R4 comes from the actual decoded state/stake full-unstake amount. R5 comes from
an address authenticated with `WalletHandle::owns_address`; the boundary has
no recipient-hex parameter. Exactly one key enters the proxy, and unrelated
funding tokens return in change. The accounting exception for execution allows
exactly one key burn and rejects all other token creation/burns.

Funding is derived as the maximum of:

- `0.100 + 0.002 + 0.002 + 0.001 ERG minimum payout - decoded StakeBox ERG`;
- `0.001 ERG refund fee + 0.001 ERG minimum refund output`.

The historical stake therefore needs **0.104 ERG**, not an exact 0.113 ERG.
The builder verifies the incentive hash against the proxy commitment and
reduces both future branches with that funding. Creation pays 0.0011 ERG to
Argus and 0.0011 ERG to the miner. Refund has exactly two outputs and deducts
only 0.001 ERG for the miner; it pays no Argus fee.

Refund construction takes only a canonical proxy and height. Preparation and
signing need normal node context and a current lookup of that proxy, never
state/stake discovery or executor construction. The actual R5 must belong to
the handle's wallet. Signing revalidates the immutable preparation's actual
inputs. Creation signing also revalidates state/stake and repeats preflight.

`stake_proxy_service.dart` derives tracking from the **signed** transaction via
Rust, checks its transaction/output identity against preparation, and awaits
`WalletDatabaseService.saveStakeProxies` **before** broadcast. Records contain
the creation transaction id, complete expected proxy box, key, recipient
address/tree, network and wallet association. The database follows the existing
wallet-scoped SharedPreferences/obfuscation precedent; it stores no secrets.
Submission errors never delete records. Restart loads records before chain
reconciliation. Positive chain evidence determines pending/confirmed/spent;
lookup errors retain the record and prior status. Spent records remain retained
and can become confirmed again after a reorg. Refund signing can proceed while
reconciliation is stalled; it does its own native proxy revalidation.

The screen shows tracked refunds independently of pool scans and explicitly
states the permanent key burn on successful unstake, refund asset return,
0.001 ERG deduction, and requirement that the proxy still be unspent.

Bindings were regenerated with automatic whole-project format/fix disabled,
then only generated files were formatted. Existing native additions were
formatted as appended fragments. `src/direct.rs` is unchanged. EGIO is unchanged.
No new dependency, native-library rebuild, `.so` edit, branch change, commit,
or transaction submission occurred. Chain access consisted only of GETs for
historical evidence. The existing contract-audit assertions remain intact.

No new contradiction was found in the amended spec. Execution eligibility is
necessarily a preflight against a particular state snapshot; another transaction
can move that state after creation. This is why the independent refund remains
necessary. Interpreting “preflight executor eligibility” as input accounting
alone would be weaker: this implementation also reduces the discarded witness.

Proven refusals and positive conservation evidence:

| Case | Evidence |
| --- | --- |
| Foreign address or caller hex at handle boundary | `owned_trees` tests; refund boundary test; signed-record test |
| Foreign actual R5 despite matching proxy tree/key | `refund_boundary_authenticates_actual_r5_and_needs_no_pool_boxes` |
| Edited recipient, reward amount, fees, output order/count, missing/extra output, key quantity, refund key burn | `output_edits_are_refused_by_rederivation`; unchanged audit tests |
| Wrong wallet key, multiple copies/key inputs, duplicate input | actual-input tests and refund re-derivation |
| Extra protocol assets or proxy assets; malformed register type/length; bad context extension; insufficient funds | proxy tests and existing validation suite |
| Stale checkpoint, insufficient totals/counts, reserve overflow, token sum overflow, out-of-range amounts, negative/future heights | actual-input/arithmetic tests and existing validation suite |
| Wrong incentive destination at unchanged pinned values | added contract audit asserts exact `TrivialProp(false)` |
| Any burn except the one execution key, or any token creation | explicit accounting exception unit test |
| Exactly one key into proxy; ten unrelated historical wallet assets returned | unmodified historical creation-input test |
| Refund returns exact key and 0.112 ERG from historical 0.113 ERG proxy, using no state/stake | standalone native-builder test asserts exact `TrivialProp(true)` |
| Signed record matches actual tx/output ids and recipient | native signed creation test with a locally generated wallet signature |
| Persistence precedes broadcast; survives crash/restart and uncertain creation/refund; wallet/network isolation | Dart lifecycle tests with the actual persistence service |
| Reconciliation pending/confirmed/spent, HTTP failure, incomplete/foreign response, old fork | real Dart lookup adapter under mocked HTTP |
| Slow reconciliation cannot block refund | held lookup future while refund signs/submits through the fake gateway |

The extra historical fixture, `paideia-creation.json`, is transaction
`f19388c137a8e39abf2cdd04e91c5fa1eca37057a4e61748aee9dbda17b75b53`.
It was captured read-only on 2026-09-12 and retains complete creation inputs,
signed transaction, inclusion header and ten parents. Tests combine its
unmodified wallet boxes with the historical unstake's state/stake context;
they prove reduction, not live unspentness of those historical boxes.

Verification completed with `CARGO_TARGET_DIR=/home/rkadias/.cache/cargo-target`:

| Command | Result |
| --- | --- |
| `cargo test --workspace` | 775 passed, 0 failed, 12 ignored, including doc tests |
| `cargo check --workspace` | exit 0 |
| `cargo clippy -p stake-recovery --all-targets --no-deps -- -D warnings` | exit 0 |
| `cargo fmt -p stake-recovery -- --check` | exit 0, no output |
| `flutter analyze --no-pub` | no issues |
| `flutter test --no-pub` | 645 passed, 1 skipped |
| scoped `dart format --output=none --set-exit-if-changed` | exit 0 |
| `git diff --check` | exit 0 |

Strict wallet-ffi Clippy was also run and still fails on the known **11 library /
13 test findings**, all outside the new code. They are the unused mix helper,
existing too-many-arguments/map-entry/useless-conversion findings in api.rs and
api_sigmausd_impl.rs, clone-on-copy in api_ergopay_impl.rs, existing test findings
in api_dexy_impl.rs/api_duckpools_impl.rs, and err-expect in the pre-existing API
tests. These were not modified. Cargo also prints the pre-existing unused
`ergo-rest` patch warning; workspace check prints the existing unused mix-helper
warning.

Full **verbatim** command outputs are available in the shared workspace:

- [cargo-test-workspace.log](/tmp/argus-stake-batch4-checks/cargo-test-workspace.log)
- [cargo-check-workspace.log](/tmp/argus-stake-batch4-checks/cargo-check-workspace.log)
- [clippy-stake-recovery.log](/tmp/argus-stake-batch4-checks/clippy-stake-recovery.log)
- [clippy-wallet-ffi.log](/tmp/argus-stake-batch4-checks/clippy-wallet-ffi.log)
- [flutter-test.log](/tmp/argus-stake-batch4-checks/flutter-test.log)
- [flutter-analyze.log](/tmp/argus-stake-batch4-checks/flutter-analyze.log)
- [cargo-fmt.log](/tmp/argus-stake-batch4-checks/cargo-fmt.log)
- [dart-format.log](/tmp/argus-stake-batch4-checks/dart-format.log)

Verbatim proxy test output from the final workspace run:

```text
     Running unittests src/lib.rs (/home/rkadias/.cache/cargo-target/debug/deps/stake_recovery-525f5f4fdaa83134)

running 1 test
test proxy::accounting_tests::only_execution_accounting_allows_exactly_one_key_burn ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s

     Running tests/proxy.rs (/home/rkadias/.cache/cargo-target/debug/deps/proxy-73494ffdd93129c3)

running 8 tests
test refund_with_only_proxy_and_context_returns_key_and_erg_exactly ... ok
test refund_refuses_extra_assets_malformed_registers_underfunding_and_context ... ok
test arithmetic_overflow_in_reserve_and_wallet_totals_is_refused ... ok
test creation_uses_unmodified_historical_wallet_inputs_with_every_other_token_preserved ... ok
test unrelated_funding_assets_survive_creation ... ok
test own_creation_reduces_exact_wallet_key_and_preflights_both_branches ... ok
test output_edits_are_refused_by_rederivation ... ok
test actual_inputs_refuse_foreign_recipients_wrong_keys_duplicates_assets_and_boundaries ... ok

test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.37s

     Running tests/proxy_contract_audit.rs (/home/rkadias/.cache/cargo-target/debug/deps/proxy_contract_audit-5b4a20b86f5a84c0)

running 8 tests
test larger_refund_deduction_is_rejected_even_with_only_two_outputs ... ok
test third_output_is_rejected_even_when_recipient_value_stays_exact ... ok
test independently_assembled_contract_refund_returns_key_and_exact_erg_and_reduces_true ... ok
test adding_standard_argus_fee_with_conservation_reduces_false ... ok
test refund_output_order_recipient_and_key_are_pinned_by_the_contract ... ok
test increased_proxy_funding_cannot_make_room_for_standard_argus_fee ... ok
test execution_rejects_a_foreign_incentive_destination_with_values_unchanged ... ok
test execution_also_rejects_an_added_app_fee_output ... ok

test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.03s
test api_stake_recovery_impl::proxy_tests::refund_boundary_authenticates_actual_r5_and_needs_no_pool_boxes ... ok
test api::paideia_tracking_tests::signed_creation_record_reconstructs_actual_proxy_and_authenticates_recipient ... ok
```

Verbatim Flutter results:

```text
00:15 +645 ~1: All tests passed!
Analyzing app...                                                
No issues found! (ran in 3.3s)
```

Still **UNPROVEN until a device test**:

- The regenerated Dart/native boundary in a newly built Android/iOS package.
  Bundled native libraries were deliberately not rebuilt, so this checkout's
  existing binaries do not yet contain the new entry points.
- Actual platform persistence across process kill, OS shutdown/reboot, disk
  failure and backup/restore. The automated crash tests recreate the service
  over mocked SharedPreferences; they do not prove device storage durability.
- PIN/confirmation, wallet switching and restarting the app with an actual
  tracked proxy, including a pool-discovery outage and interrupted submission.
- Real wallet signing, node mempool policy/cost checks, propagation and chain
  confirmation of an Argus-built creation/refund. No funds were spent to test
  these. Historical reduction uses the pinned interpreter/default parameters.
- End-to-end conflict/reorg handling against actual nodes, including another
  party executing or refunding a proxy during confirmation. Only an unspent
  proxy can be refunded; a successful unstake has already burned its key.

The production executor builder, orchestration, and its device test remain
batch 5 work. The discarded eligibility witness does not claim that flow is
implemented or device-proven.
