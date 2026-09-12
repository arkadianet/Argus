# Batch A Part 1 — 2026-09-12

Completed in `c839397` on `feat/sync-a`, following Part 2 (`9665c61`). This report supersedes the initial report’s blocked Part 1 verdict. No branch changes, new dependencies, native-library rebuilds, or `jniLibs/**/*.so` changes. No transaction submitted to mainnet. **A native rebuild is required for these Rust changes to reach a device.**

## Result and remaining limits

The already-known compatibility issue is repaired, and `https://node.kadia.io` is first in `NetworkController.defaultNodes`. Exact duplicate errors now pass both check and submit in both Rust clients. Genuine rejection responses still fail closed.

This is **Argus response compatibility for the tested cases, not complete node behavioral parity**. I cannot honestly confirm that nothing else diverges: kadia applies mempool admission policy during preflight, and returned `double_spend_loser` where Scala returned 200 for a transaction in its own pool. Fee-policy order differs too. Those failures remain failures. The nodes had different mempool contents. Successful submission shape is verified from the versions' source, not by a live broadcast; neither valid-new submission nor controlled valid-new preflight was established on both nodes. A new valid transaction can in principle be checked without spending, but this run did not construct a controlled one with satisfiable live scripts. I do not infer that result from the duplicate case.

## Verbatim live responses

The response and command-log directories were removed from the repository. Only the summaries and verbatim excerpts in this report remain; request JSON and raw logs are not included. Selected cases:

### Already known

```text
kadia: HTTP 400
{"error":400,"reason":"duplicate"}
```

```text
eutxo: HTTP 200
"acd2ddb65cd2eb744ad7cde9b0e070d4a1a5edd0b97a00e5cfa4d12b4dbe6734"
```

### Spent input

```text
kadia: HTTP 400
{"error":400,"reason":"unresolved_input"}
```

```text
eutxo: HTTP 400
{
  "error" : 400,
  "reason" : "bad.request",
  "detail" : "Malformed transaction: Every input of the transaction should be in UTXO. 3713a3a6a5b1bd79bd12130a55567de61a761c501a9eedaa1c5bfdb5f91a7f1f: 0 == 1. Missing inputs: 0"
}
```

### Broken proof with correct miner fee

```text
kadia: HTTP 400
{"error":400,"reason":"script_failed"}
```

```text
eutxo: HTTP 400
{
  "error" : 400,
  "reason" : "bad.request",
  "detail" : "Malformed transaction: Scripts of all transaction inputs should pass verification. 58595727df605de84f3896c8ef4c1a8e9455d59a4c9f777deaaaf4bad71fd3f9: #0 => Success((false,403))"
}
```

### Malformed JSON

```text
kadia: HTTP 400
{"error":400,"reason":"deserialize","detail":"invalid JSON body: EOF while parsing an object at line 1 column 1"}
```

```text
eutxo: HTTP 400
{
  "error" : 400,
  "reason" : "bad.request",
  "detail" : "The request content was malformed:\nexhausted input"
}
```

## Changes and rejection boundary

- `rust/crates/vendor/ergo-node-client/src/lib.rs`: both transaction methods use the same response normalization. The additional success branch requires HTTP **400** and decoded JSON **exactly equal** to `{"error":400,"reason":"duplicate"}`. Object order/whitespace are irrelevant; additional keys, different status/error values, `duplicate input`, arbitrary detail strings, missing fields, malformed JSON and all other rejection reasons fail. Existing HTTP-success behavior is preserved.
- `rust/crates/wallet-net/src/client.rs`: identical handling for its separate recovery preflight and submission path. This second client is called from `wallet-ffi/src/api.rs`; fixing only the vendor client would have left a real route broken. Both clients already depend on sigma-rust; no dependency was added to share code across otherwise separate clients.
- Both submission methods also normalize the exact duplicate envelope because kadia uses the same mapping for submission. Otherwise a retry could pass check and then falsely report submission failure. No POST-to-submit transaction was used to establish this; see source evidence below.
- On duplicate, the return ID is computed with sigma-rust `Transaction::new_from_vec` from inputs, data inputs and output candidates. A caller-supplied ID is not trusted or required. A malformed local transaction cannot manufacture a successful return simply by supplying an ID.
- No script, UTXO, fee, conflict or malformed rejection is reclassified. This is an acknowledgement of the node's already-known verdict, not a local proof verifier. As before, Argus trusts the node's success verdict. Ergo IDs exclude proofs, so a known-ID response is not proof that every alternative proof encoding was freshly validated; the mutated-proof probes are explicitly recorded, not presented as valid-new evidence.
- `app/lib/services/network_controller.dart`: only the default list entry changed. Selected/preferred node, last-good order and indexed-height/lag decisions are unchanged. Existing stored node lists replace the defaults during `load()`, and existing stored preferences are respected: **list order does not override an existing installation's stored preference** (nor automatically add kadia to its saved list).
- Two existing clippy findings in the touched `wallet-net` crate were fixed: copy a Copy token ID without `.clone()`, and use `max_hops.clamp(1, 200)`. No other formatting cleanup was made. Only new Rust test files and the new helper text were passed through rustfmt; no whole-repository formatter ran.

## Balance and token metadata verification

Both fresh UTXO listings contain one box totaling **492,636,552,062 nanoERG**. Kadia's balance endpoint equals that sum. Scala's endpoint reports **494,720,040,911**, overstating its own listed UTXOs by **2,083,488,849 nanoERG**. The previous report's balance concern is resolved in kadia's favor.

Repository call-site search found no call to the pinned interface's `nano_ergs_balance`, its only `/blockchain/balance` method. That method itself reads only confirmed nanoERG. Neither Argus client consumes the endpoint or its token `name`/`decimals`. The vendor client's `get_address_balances` sums fetched boxes, as does `wallet-net`; metadata has separate token/issuance lookup paths. Thus the missing balance-token metadata has no Argus consumer.

## Updated parity table

The earlier report's equal history, UTXO, token/issuance and block samples remain historical evidence; they are not claimed to have all been rerun here.

| Path | Follow-up evidence | Verdict |
|---|---|---|
| `/info`, `/blockchain/indexedHeight` | Both report mainnet UTXO mode. Both indexes reached 1,871,589; kadia adds `status`. | Existing health/capability checks pass. |
| `/blockchain/balance`, address UTXOs | One identical-value box on both; kadia balance matches sum; Scala overstates. | No Argus effect; metadata unused. |
| `/transactions/check`: known | Kadia exact duplicate 400, Scala JSON ID 200. | Both now pass. |
| `/transactions/check`: spent / broken proof / malformed | Both 400; kadia structured reason without detail for consensus failures; Scala `bad.request` with detail. | Both fail. |
| `/transactions/check`: fee/conflict policy | Kadia checked fee before proof; a Scala-pool transaction received kadia `double_spend_loser` / Scala 200. | Policy/state difference remains; not normalized. |
| `/transactions/check`: valid new | Not established in a controlled same-state case. | Unknown, not inferred. |
| Nonempty `/transactions/unconfirmed/byTransactionId/{id}` and `/byErgoTree` | Found four IDs common to refreshed pools; compared `6f22ea073f76e353d78a710f1b42f94c98fc8cec77921d1c0db58d09d5cd83b5` on both routes. Core inputs/proofs/dataInputs/outputs match; Scala enriches inputs with value/tree/assets/context that kadia omits. | Argus uses input `boxId`, resolves value/assets from confirmed boxes, and consumes matching output fields. Different pool contents are expected. |
| Missing unconfirmed ID | Kadia detail string, Scala detail null, both 404. | Existing failure paths remain failures. |
| `/transactions`: malformed JSON | Live 400 on both; verbatim in response appendix. | Parser failures compatible. |
| `/transactions`: accepted | Kadia v0.7.0 route returns HTTP 200 JSON string; Scala advertised revision returns accepted ID with HTTP 200. HTTP client tests exercise that shape. | Source-backed and locally tested, **not live broadcast verified**. |
| `/transactions`: rejected / already known | Source shows structured error mapping, including kadia duplicate with no detail; Scala reports admission errors through BadRequest. Exact duplicate is normalized; every other error fails. | No known remaining response-parser mismatch in the sampled check/submit cases. Full admission parity is not claimed. |

## Submission source evidence

The live nodes advertised kadia `0.7.0` and Scala `6.0.4RC2-109-c3646640-SNAPSHOT`. Source inspection used the matching [kadia v0.7.0 transaction handlers](https://github.com/arkadianet/ergo/blob/v0.7.0/ergo-api/src/compat/transactions.rs), [kadia rejection mapping](https://github.com/arkadianet/ergo/blob/v0.7.0/ergo-node/src/node/admission.rs), and [Scala c3646640 base route](https://github.com/ergoplatform/ergo/blob/c3646640/src/main/scala/org/ergoplatform/http/api/ErgoBaseApiRoute.scala). Kadia's annotated tag resolves to `7670c3be8a5ed57d6c50ee84f9477b026cdcc581`. An advertised version is not proof that the deployed binary has no local modifications.

Kadia check/submit differ by CheckOnly/Broadcast mode, with a shared JSON response handler. Accepted ID becomes `StatusCode::OK, Json(tx_id)`; rejection uses the common mapper. Scala accepted processing returns the ID; invalid/declined/double-spend outcomes become BadRequest. These support the success/error **shape** comparison without broadcasting. Upstream route tests were inspected, not executed or passed off as live results.

## Regression and validation evidence

Before production edits, each client's actual HTTP `check_transaction` was exercised against a local TCP server: **duplicate-as-pass failed by assertion**, while **Scala success and invalid-fails-closed passed**. These were behavioral failures, not compile failures.

The final tests cover both clients' check and submit methods: exact duplicate, Scala success, spent input, failed script, similar duplicate wording, extra detail, inconsistent/missing error code, wrong status and malformed responses. They also check that malformed transaction data cannot produce an already-known ID. Submit tests verify a computed hex ID rather than the deliberately forged caller ID. All run locally; none contact mainnet.

Commands:

```sh
CARGO_TARGET_DIR=/home/rkadias/.cache/cargo-target cargo test --manifest-path rust/Cargo.toml --workspace
CARGO_TARGET_DIR=/home/rkadias/.cache/cargo-target cargo clippy --manifest-path rust/Cargo.toml -p ergo-node-client -p wallet-net --all-targets --no-deps -- -D warnings
# Working directory: app
TMPDIR=/home/rkadias/.cache/argus-tmp /home/rkadias/coding/development/flutter/bin/flutter analyze
TMPDIR=/home/rkadias/.cache/argus-tmp /home/rkadias/coding/development/flutter/bin/flutter test
```

The full command logs were removed; final excerpts remain below. Cargo retains its pre-existing unused `ergo-rest` patch warning; there are no clippy diagnostics with warnings denied.

Flutter final lines, verbatim:

```text
No issues found! (ran in 3.8s)
00:25 +692 ~1: All tests passed!
```

Rust workspace results and final tree checks are recorded after the final run below.

Final Rust workspace run: **785 passed, 0 failed, 12 ignored**, including doc tests across 39 result groups. All 10 new tests passed. Relevant output verbatim:

```text
test check_tests::duplicate_requires_parseable_transaction_and_derives_id ... ok
test check_tests::scala_preflight_passes ... ok
test check_tests::duplicate_preflight_passes ... ok
test check_tests::submit_success_duplicate_and_rejection ... ok
test check_tests::invalid_preflight_fails_closed ... ok
test client::check_tests::duplicate_requires_parseable_transaction_and_derives_id ... ok
test client::check_tests::duplicate_preflight_passes ... ok
test client::check_tests::scala_preflight_passes ... ok
test client::check_tests::submit_success_duplicate_and_rejection ... ok
test client::check_tests::invalid_preflight_fails_closed ... ok
```

`git diff --check` passed. The completed work is recorded in `c839397` on `feat/sync-a`. No lockfiles or native binaries changed.

Nonempty-tree pagination follow-up (`offset=1&limit=1`): both HTTP 200 bare arrays, lengths 1 / 0. Returned IDs: kadia ['3072ef1eb1d9e1debbb8ecb1151a06306286d6df1a61605b7d78104e12e6ff7f'], Scala []. Pool ordering/contents remain node-local; this verifies the pagination response shape, not identical pool snapshots. Raw pagination bodies are no longer included.
