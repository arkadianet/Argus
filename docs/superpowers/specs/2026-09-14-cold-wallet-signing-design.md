# Watch-only transactions and EIP-19 cold signing

Date: 2026-09-14
Status: Argus hot/cold application flow implemented for the bounded mainnet P2PK policy; real-device interoperability pending
Base for this completion: `perf/safe-wins`, not `main`

## Current implementation

The same build now supports both roles. A watched xpub account can prepare an
ERG payment with an optional token transfer, display CSR QR pages, collect CSTX,
verify the exact payment and all signatures, and explicitly broadcast through
the retained node. Settings → Offline signing collects CSR, reviews the actual
outputs using local key ownership, signs only after confirmation, and displays
CSTX pages. No secrets or unlocked handle are used by public preparation.

The supported policy is deliberately narrow: mainnet, external EIP-3 indices
0–512, 1–256 P2PK spending inputs, 1–256 outputs, canonical P2PK output trees
and the standard mainnet miner-fee tree (delay 720). Ordinary token quantities
and change are supported. Registers, context extensions, data inputs, other
scripts and other miner-fee policies are refused before general binary parsing.
This is an application policy, not a modified EIP-19 format.

See **Implementation record — application completion** below for review,
recovery, verification, validation results and remaining release checks.
The earlier records describe the historical stopping point and are superseded
by that record where they say there is no application flow.

## Original staged decision (historical)

Support the hot side of EIP-19 first: build a simple P2PK payment in Argus,
show its request as QR pages, scan the signed transaction from Ergo Wallet
App, verify that it signs the exact prepared payment, and broadcast it.
Keep keys exclusively on the cold device. Reuse the existing transaction
builders, reducer and node submission path; introduce a public preparation
context instead of inventing an unlocked wallet handle for watched addresses.

Compatibility is supported by the primary sources at the JSON, paging and
binary-format levels. Confidence is high in the protocol identification, but
cross-wallet interoperability is **not yet tested**. Shipping a compatibility
claim requires sigma-rust/Appkit fixture round trips and an actual offline
Ergo Wallet App signing round trip, including multiple pages in both directions.
The implementation record below describes the completed Rust foundation; no
application cold-signing flow is available yet.

## Evidence and precise transport

The sources inspected are:

- [EIP-19 at 5cb6788](https://github.com/ergoplatform/eips/blob/5cb67888f59683b1d4f3a382fa3dabe208088105/eip-0019.md), the cold-wallet envelope and interaction protocol.
- [EIP-43 at the same revision](https://github.com/ergoplatform/eips/blob/5cb67888f59683b1d4f3a382fa3dabe208088105/eip-0043.md), the reduced-transaction binary format. Both EIPs have status Proposed.
- [ColdWalletUtils.kt](https://github.com/ergoplatform/ergo-wallet-app/blob/beeecb1009e26c6ea9b506d5fca3a4efb3f79f9e/common-jvm/src/main/java/org/ergoplatform/transactions/ColdWalletUtils.kt), the actual JSON codec, chunker and collector.
- [ErgoFacade.kt](https://github.com/ergoplatform/ergo-wallet-app/blob/beeecb1009e26c6ea9b506d5fca3a4efb3f79f9e/common-jvm/src/main/java/org/ergoplatform/ErgoFacade.kt), the Appkit reduction, box serialization, signing and submission calls.
- [Base64Coder.java](https://github.com/ergoplatform/ergo-wallet-app/blob/beeecb1009e26c6ea9b506d5fca3a4efb3f79f9e/common-jvm/src/main/java/org/ergoplatform/utils/Base64Coder.java), which defaults to regular padded Base64 (`+`, `/`, `=`), not ErgoPay's URL-safe alphabet.
- [ColdWalletSigningUiLogic.kt](https://github.com/ergoplatform/ergo-wallet-app/blob/beeecb1009e26c6ea9b506d5fca3a4efb3f79f9e/common-jvm/src/main/java/org/ergoplatform/uilogic/transactions/ColdWalletSigningUiLogic.kt), which collects the request, builds transaction information, asks for confirmation and signs offline.
- [ColdWalletUtilsKtTest.kt](https://github.com/ergoplatform/ergo-wallet-app/blob/beeecb1009e26c6ea9b506d5fca3a4efb3f79f9e/common-jvm/src/test/java/org/ergoplatform/transactions/ColdWalletUtilsKtTest.kt), including real serialized transaction/box fixtures.

The wallet revision above was the repository's `master` head when inspected.
These are implementation observations, not assumptions based on a wallet with
a similar name or on EIP-20.

The inner request is compact JSON:

```json
{"reducedTx":"<regular padded Base64>","sender":"<P2PK address>","inputs":["<regular padded Base64 box>"]}
```

`reducedTx` and `inputs` are mandatory in EIP-19; `sender` is optional. Argus
will always supply sender and all spending input boxes in transaction order.
The reference parser tolerates absent inputs, but that is not a reason to omit
them. Its transaction-information builder uses the boxes to explain the spend.

The reduced bytes are EIP-43: a VLQ unsigned message length, the unsigned
transaction's message-to-sign bytes, then one SigmaBoolean and VLQ unsigned
64-bit reduction cost per input, then a VLQ unsigned transaction cost. Input
IDs and context extensions are in the unsigned message. This is neither
EIP-12 JSON nor an unsigned transaction with full blockchain headers attached.
The implementation calls Appkit `reduce(unsigned, ERG_BASE_COST).toBytes()`;
input entries are full `ErgoBox.bytes()` serialization, including their
transaction reference and output index, not just box candidates or IDs.

The cold response is compact JSON containing `signedTx`, whose value is
regular padded Base64 of the **entire signed transaction**. Ergo Wallet App
calls `prover.signReduced(...).toBytes()` and the hot side calls
`ctx.parseSignedTransaction(...)`. It does not return a separate proof array.

The actual QR content wraps a string slice of the inner JSON:

```json
{"CSR":"{\"reducedTx\":\"...\",\"sender\":\"9...\",\"inputs\":[\"...\"]}"}
{"CSTX":"<slice of response JSON>","n":3,"p":1}
```

There is no URI prefix, compression, fountain encoding or Base64 of the whole
envelope. `CSR` identifies requests; `CSTX` identifies responses. `p` is
one-based; `n` is total pages. For a single page they may be absent (the
reference defaults each to 1). Slice the inner JSON first, then JSON-escape
each slice into its envelope. After parsing the outer JSON, sort slices by
index and concatenate before parsing the inner JSON. A slice need not be
valid JSON in isolation. Scan order is unrestricted.

The reference constants are 2,000 characters normally and 400 in low-resolution
mode. `buildQrChunks` subtracts `30 + prefix.length` before slicing, giving
1,967/367 characters for CSR and 1,966/366 for CSTX. This is a heuristic reserve,
not a strict post-escaping QR byte bound: JSON quotes and backslashes expand
when wrapped. EIP-19 itself specifies no maximum page count or payload size;
neither the reference chunker nor collector imposes a total bound. Physical
QR capacity depends on encoding and error correction, so a claimed universal
4 KB QR limit should not become an Argus constant.

Argus should retain those interoperable density presets, while checking the
actual encoded envelope size and shrinking a slice if needed. Receivers do
not require exactly the reference chunk boundaries. An initial Argus resource
policy of at most 512 pages, 2 MiB accumulated inner JSON and 4 KiB per scanned
envelope is proposed, with explicit rejection before expensive allocation or
binary parsing. These are local defensive limits, not EIP requirements.

The reference collector keys pages by index, rejects different page counts,
and replaces duplicates. Its joiner sorts and checks that the declared count
equals the collection size. It does not establish a transaction/session ID or
validate the complete index range. Argus should require integer `1 <= p <= n`,
a consistent direction and total, every index exactly once, and byte-identical
duplicates. A conflicting duplicate should stop collection and offer restart,
not silently replace data. There is no authentic way to identify mixed sessions
from the envelope alone when counts match; complete transaction validation is
still necessary.

## Offline context and realistic size

A reduced transaction contains the result of evaluating scripts, not all the
information needed to evaluate them again. The cold signer can generate proofs
without input boxes, headers or data-input box bodies. The **EIP-19 request**
still carries spending input boxes so that the user can inspect amounts, tokens
and scripts and so the cold wallet can check their IDs against the transaction.
Data-input bodies are not a field in this protocol. The online reducer needs
the full input/data-input boxes and current state context.

Measured by decoding the upstream test fixtures and compacting their inner
JSON (standard Base64, without Gson's optional `\u003d` escaping):

| Upstream fixture | Reduced bytes | Spending box bytes | Request characters | Normal / low-resolution pages |
| --- | ---: | --- | ---: | --- |
| One input, three outputs | 284 | 80 | 582 | 1 / 2 |
| Three inputs, three outputs, tokens/registers | 578 | 79 + 79 + 226 | 1,392 | 1 / 4 |

These are fixture measurements, not camera benchmarks or claims about all
transactions. For any request the Base64 contribution is
`4*ceil(reducedBytes/3) + sum(4*ceil(boxBytes/3))`, plus JSON, sender and outer
escaping. Plain P2PK input boxes in those examples are about 80 bytes each;
token/register-heavy boxes are substantially larger. A rough ten-input plain
payment is likely around 2–3 KB of inner JSON (about two normal pages), but
actual serialized sizes should drive the UI. Large token holdings, arbitrary
registers and many inputs dominate; never hide input boxes to achieve a
one-code marketing claim. Returned signed transactions omit those box bodies,
although each signed input now carries its proof.

## Existing Argus and sigma-rust seams

The workspace pins `ergo-lib` 0.28.0 to sigma-rust revision
`7f927613c5a72bf6ea93b95cf9987129a03dd4ba` (corrected during implementation). Its
[reduced.rs](https://github.com/ergoplatform/sigma-rust/blob/7f927613c5a72bf6ea93b95cf9987129a03dd4ba/ergo-lib/src/chain/transaction/reduced.rs)
implements `ergo_lib::chain::transaction::reduced::{ReducedTransaction,
ReducedInput, reduce_tx}`. Reduction takes
`wallet::tx_context::TransactionContext<UnsignedTransaction>` and
`chain::ergo_state_context::ErgoStateContext`; constructing that context uses
`TransactionContext::new(unsigned, input_boxes, data_input_boxes)`.

`ergotree_ir::serialization::SigmaSerializable::{sigma_serialize_bytes,
sigma_parse_bytes}` is implemented for `ReducedTransaction`, `ErgoBox` and
`chain::transaction::Transaction`. `wallet::Wallet::sign_reduced_transaction`
returns a `Transaction`. The
[transaction implementation](https://github.com/ergoplatform/sigma-rust/blob/7f927613c5a72bf6ea93b95cf9987129a03dd4ba/ergo-lib/src/chain/transaction.rs)
also offers `Transaction::bytes_to_sign`, `verify_p2pk_input` and
`from_unsigned_tx`. The last can attach proofs in other protocols but is not
needed to reconstruct an EIP-19 response: that response already is a signed
transaction. Full parsing must reject trailing bytes and unbounded declared
lengths; do not assume a convenience parser enforces those transport policies.

Already in this repository:

- `wallet-core/src/transaction.rs`: `build_reduced_transaction`,
  `serialize_reduced`, `deserialize_reduced` already wrap the above APIs.
- `vendor/ergopay-core/src/reduce.rs`: `reduce_transaction` fetches context;
  `reduce_transaction_with_context` converts an `Eip12UnsignedTx` and full
  boxes into serialized reduced bytes, without secret keys.
- `wallet-ffi/src/api.rs`: `sign_reduced_transaction` accepts bytes and an
  unlocked handle, returns signed **node JSON**; `submit_signed_transaction`
  broadcasts node JSON without a handle. EIP-19 needs a binary-transaction to
  node-JSON boundary and a match/verification gate before this submit call.
- `api_ergopay_impl.rs`: `summarize_reduced` delegates to `summarize_unsigned`,
  which accepts an ownership predicate and supplied box JSON. The public
  `describe_reduced_transaction` currently requires a handle and fetches boxes
  best effort. Reuse the pure summary with a watched-address predicate, not
  the handle-bound wrapper or its permissive missing-input behavior offline.
- `prepare_send`, `prepare_send_multi` and `CachedPreparation` retain the
  unsigned transaction and real input/data-input boxes. `sign_prepared_tx`
  currently fetches context, reduces and immediately signs under a handle.
  Splitting reduction/export from signing is the important seam. Preserve
  existing fees, token change, coin selection and preparation checks.
- `api_dapp_impl::parse_unsigned` and `dapp_prepare_sign` accept a dApp's
  EIP-12 transaction, summarize it and cache a preparation; the latter performs
  ownership checks under a handle. The connector does not provide a complete
  public build/export/returned-signature session today. The dApp supplies the
  unsigned transaction; Argus is its signer. Public building primitives exist
  below the handle-bound API, but this is not merely a QR widget addition.

A P2PK address already contains its compressed public key. The item-2 imports
normalize keys to addresses, so no new redundant public-key storage is needed
for single-address P2PK building. Arbitrary P2S/P2SH addresses remain watchable
and receivable, but do not imply knowledge of signing keys or spending scripts.
First cold signing should explicitly support P2PK spending inputs only. Extended-key watch accounts now provide public discovery separately from
single-address imports; see [the xpub implementation report](2026-09-14-watch-xpub-implementation.md).
Ergo Wallet App exports a raw hex depth-4 external-chain key, not a depth-3
account key. Preserve the supported key depth and address indices in a future
public preparation context: append only `/i` to that export, and `/0/i` to an
account key. The point alone is insufficient to derive sibling addresses.
Discovery does not yet implement public transaction preparation or cold signing.
The account key cannot derive the hardened stealth branch. Keep stealth funds
out of public preparation. Test offline signing of inputs across several
indices; EIP-19's sender field alone does not describe that ownership set.

## Compatible, and better

Yes: preserve EIP-19 exactly at the transport boundary and improve the local
experience and validation. Display “3 of 7 scanned” with a missing-page map;
accept out-of-order scans and harmless duplicates; offer manual next/previous,
pause and repeat alongside optional animation. Keep partially collected pages
when the scanner is temporarily covered or navigation is interrupted. Persist
a bounded draft with explicit resume/discard and expiry if cross-launch recovery
is offered. Treat the draft as private financial data even though it has no keys.
Keep one scan session active; explain restart on conflicts.

Fewer input boxes, compact JSON, avoiding gratuitous escaping, and choosing a
readable higher-density preset reduce pages compatibly. Coin selection must
still preserve fees, token change, dust constraints and privacy; spending
unrelated inputs together just to consolidate may be a privacy regression.
The reference already uses compact JSON, so do not promise dramatic encoding
savings over it. Check actual QR capacity instead of its fixed reserve heuristic.

Better cold review is also wire-compatible: derive recipient/change ownership
from local keys, match serialized box IDs, show every output, fee, token change,
and burns, and reject incomplete data. However, Argus acting only as the hot
wallet cannot improve another app's cold-screen behavior. Those improvements
need upstream changes or a future Argus cold role. Supply the data the existing
cold screen expects and test its presentation.

Compression, binary envelopes, Base45, fountain/UR frames, omitting required
boxes, proof-only responses and authenticated session hashes are protocol
extensions, not transparent optimizations. Unknown optional JSON fields may
be tolerated, but the other wallet will not enforce their semantics. Never
claim a new session digest protects users of an unchanged reference wallet.
Any extension needs explicit negotiation or a separately selected transport,
with legacy EIP-19 retained as the default.

## Preparation, return and release boundary

A public preparation should bind network/node choice, watched sender/change,
selected box IDs, exact unsigned message bytes, serialized boxes and reduced
bytes, review summary and expiry to one local session. It must not depend on
an unlocked handle or borrow another wallet's stealth identities. A watched
wallet's Send action should explain the offline signer requirement.

After collecting CSTX, decode Base64 and parse the full `Transaction`. Compare
its `bytes_to_sign()` against the stored unsigned message, covering ordered
inputs, extensions, data inputs and every output. For the initial P2PK scope,
verify each proof against its matched input box/public key. Reject another
payment even if its signatures are valid. Recheck spendability and node
acceptance, display the matched result and submit through the existing node
path. Handle an already-broadcast transaction idempotently; retain the signed
transaction and ID through uncertain network failures. A stale or changed
preparation requires rebuilding and new signatures, never editing a signed tx.

The smallest useful release is a single watched P2PK address sending ERG with
ordinary change and both QR directions, including multi-page support. Before
that release, establish fixture parity for reduced transactions, boxes and signed
transactions with Appkit, plus mismatched/duplicate/missing/oversized-page and
wrong-transaction rejection. The architecture can then extend to token sends,
multiple watched P2PK inputs and richer draft recovery. An Argus cold-device
role, extended-key account transaction preparation and dApp cold signing follow only after that narrow
path works with a real Ergo Wallet App device. This ordering keeps the initial
security boundary understandable without replacing the existing builders.

## Security contract

An air gap protects keys from direct network access; it does not make a hostile
transaction safe. The cold device must show network, full destination addresses,
ERG amounts, every token ID and integer quantity, fees including application
fees, locally verified change, and any token burn/mint or unusual scripts and
registers before explicit signing approval. Token names and hot-wallet labels
are untrusted. Never call an output “change” merely because the hot device says
so. Unknown or missing input data must block the initial P2PK flow rather than
produce a deceptively complete balance summary.

The cold device must recompute box IDs from supplied serialized boxes and match
them to transaction inputs. For P2PK it can check the input script and reduced
proposition against its own public key without network context. For arbitrary
contracts, supplied reductions do not prove that the actual script evaluates
that way at the current chain state. General cold signing needs an explicit
policy for this trust boundary; showing an attractive summary is insufficient.

A compromised hot device can substitute destinations, select unwanted inputs,
mislabel assets, lie about network state, supply misleading reductions, replay
pages and withhold or prematurely broadcast an approved transaction. It cannot
extract the private key through correct signing, change transaction contents
after valid signatures, or sign a different payment without another approval
or a vulnerability in the cold signer. The user must independently verify the
recipient on the cold screen. Malformed QR/binary data still attacks a parser;
use bounds, complete-consumption checks and a narrow first signing scope.
Neither the air gap nor EIP-19 prevents a compromised cold application from
leaking secrets via output QR data or malicious signing randomness.

## Related watch-only corrections

`watch_only_service.load()` ran before bridge initialization in `main()`. Rust
address validation is deterministic local parsing: there is no discovered
transient network-driven false result. Accessing the bridge too early throws
on the Dart side; the old guard preserved an initially empty list and later
saves could erase the stored collection. Independently, a false result silently
filtered entries. Loading now restores persisted strings without revalidation;
add validates and normalizes, and explicit remove deletes. A false-validator
regression checks load and persistence after removing an unrelated entry.

`IncomingPaymentWatcher` is an in-memory set, not a persisted derived list;
it accumulates observed IDs and only resets explicitly. Watch-balance maps are
also transient caches. Contacts, address labels and stealth identity preferences
perform structural decoding/filtering, not fallible bridge validation. They
have separate malformed-storage behavior, but no clearly identical
validation/rebuild bug was found, so no unrelated changes were made.

## Implementation record — transport layer

`wallet-core::cold_transport` implements compact CSR/CSTX JSON, standard padded
Base64, required request input boxes, optional sender, both density presets,
and slicing before escaping with an actual envelope byte cap. The stateful
collector retains partial scans in memory, reports missing pages, accepts
out-of-order pages and identical duplicates, and latches conflicts until reset.
It enforces the proposed local limits without adding wire fields. It has no
UI, persistence, signing authority or network calls. Decoded request bytes are
explicitly untrusted; this is not an offline binary parser or signer.

Pinned upstream Appkit request fixtures cover one and three inputs; the latter
occupies four low-density pages. Tests cover codec bytes, JSON escaping, Unicode
slicing, invalid indices, conflicts, duplicate fields and resource limits.
`cargo test -p wallet-core cold_transport`: 4 passed. Interoperability remains
untested against a real device. No compression, fountain codes or proof-only
response was needed or added.

## Implementation record — return verification and stopping point

`wallet-core::cold_signing::PreparedColdTransaction` binds a **locally built**
reduced transaction to all spending boxes, in order, and its exact unsigned
message bytes. It rejects missing/duplicate/mismatched boxes, non-P2PK input
scripts and reductions inconsistent with those scripts or extensions. It
exports the request through the transport codec without an unlocked handle.
This type is a lower-level immutable transaction binding, not the proposed
public watch-wallet preparation/session API. It must never be constructed by
parsing untrusted QR bytes using the existing convenience parser.

The returned full signed transaction passes a gate before node JSON becomes
available: compare every non-proof byte to the preparation, allowing only the
canonical 56-byte P2PK Schnorr proofs to differ. This preflight uses the trusted
input IDs and serialized extensions, then compares the entire remaining
transaction suffix. Consequently, an attacker cannot introduce new output
scripts or binary length declarations into the general parser. Then parse,
require byte-identical reserialization, compare `bytes_to_sign()` and verify
every input proof against its matched P2PK box. This covers ordered inputs,
context extensions, data inputs, token dictionaries, all output values,
recipients, scripts, heights, tokens and registers. Trailing bytes and
noncanonical encodings are rejected. `VerifiedColdTransaction` exposes the
unchanged signed bytes, transaction ID and node JSON only after these checks.
There is no broadcast integration; node acceptance and spendability still
belong to the future application session.

Tests include the full local prepare → request pages → decode → sign → response
pages → decode → verify sequence, retaining byte identity at each serialization
boundary and signing inputs at indices 0, 3 and 20. Separately signed changes
to recipients, token quantities, registers, extensions, input order and data
inputs are rejected. Corrupt proofs, every single-byte mutation of the local
signed fixture, every truncation and trailing bytes are rejected. The locked
wallet still refuses signing. Both pinned Appkit requests preserve their
reduced-transaction and full-box bytes exactly in sigma-rust. These are tests
of request fixtures and local signing, **not signed Appkit fixture parity or
verified real-device interoperability**. Interoperability is untested against
a real device.

What the design got wrong or left incomplete:

- The sigma-rust revision cited in the original research was stale; the actual
  workspace Git pin is corrected above.
- A bounded QR payload does not bound allocations inside a binary parser.
  In particular, `ReducedTransaction::sigma_parse` allocates from its declared
  message length before checking available bytes, and general ErgoTree parsing
  also has supplied lengths. Production request decoding therefore stops at
  bounded Base64 bytes. Only trusted fixtures use the convenience binary parser
  in tests. A cold role needs an audited bounded parser before UI work; no
  production offline signing entry point has been added.
- Exact canonical signed bytes can be compared to local preparation before
  general binary parsing, narrowing the returned-transaction attack surface
  beyond the original parse-then-compare design. The gate is intentionally P2PK.

Left for subsequent layers: public watch-wallet preparation with retained
network/node, sender/change, expiry and ownership metadata; depth-3 account
versus depth-4 external-chain xpub identity and each selected address index;
FFI bindings; QR rendering/scanning UI; persistent resume/expiry; spendability
rechecks and broadcast/retry handling; and the Argus cold-device role. The
multi-index cryptographic test does not implement extended-key preparation.
No derivation metadata is flattened into the optional sender field.

**There is no cold review screen and no user-facing cold signing yet.** Before
adding it, implement safe request parsing, recomputed box-ID checks and locally
verified ownership, then show network, full recipients, ERG amounts, every token
ID/quantity, fees, locally verified change, burns/mints and unusual scripts or
registers before explicit approval. No opaque-blob signing shortcut is exposed.
The ordinary hot-wallet send path and watch-only signing restrictions are
unchanged. No FRB signature changed, so no binding regeneration is required;
tracked JNI libraries were not rebuilt.

Stopping here follows the requested lower-half-first scope: the transport and
return gate are complete and independently testable, while safely parsing and
reviewing arbitrary cold requests and implementing preparation/UI sessions
would be a separate substantial layer. No EIP-19 extensions were needed.

Validation uses a worktree-local Cargo target and a writable copy of the
installed Flutter SDK under `rust/target/tools/flutter`, because the default
Cargo target and installed Flutter cache are outside the writable sandbox.
No build output or scratch logs were placed in `/tmp`, and no ignore rules
were added. Exact successful commands from the worktree root:

```sh
(cd rust && CARGO_TARGET_DIR="$PWD/target" cargo test --workspace)
(cd app && CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true ../rust/target/tools/flutter/bin/flutter analyze)
(cd app && CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true ../rust/target/tools/flutter/bin/flutter test)
```

Rust workspace: 822 passed, 0 failed, 13 ignored, including 8 cold-signing tests.
Flutter analysis: no issues. Flutter tests: 814 passed, 1 skipped.
The initial unmodified commands failed due to read-only external Cargo/Flutter
caches, before checks ran. The worktree-local commands address that limitation.

The intended layer commits are `Add EIP-19 cold signing transport and page
collection` and `Verify EIP-19 returns against prepared P2PK transactions`.
The first staging attempt failed creating the shared Git worktree's
`index.lock` on a read-only filesystem; all changes remain uncommitted, per the
requested fallback. Nothing was pushed and no PR was opened.


## Implementation record — application completion

### Public watch preparation and key metadata

`WatchContext` retains depth 3 (account key) versus depth 4 (external-chain key),
each public address index and its full `m/44'/429'/0'/0/i` path. The native session
retains selected input ownership in transaction order, the watched context,
exact request/binding, node URL and creation time. Both xpub depths derive the
same payment paths; an external-chain export gets only `/i` appended. No metadata
is added to CSR or flattened into `sender`. The cold wallet independently finds
and loads the matching local EIP-3 keys, bounded to indices 0–512. A sender hint
never establishes ownership. Stealth branches remain excluded.

The watched-account action uses the existing multi-send selector, fee budget,
builder and reducer. Change is derived from the watched key at the first unused
index confirmed by discovery. Inputs are gathered without a wallet handle;
selected input bodies and ownership must match. The cold parsing/review policy
is applied before export, so unsupported transactions are refused on the hot
side as well. This separate API does not alter `prepare_send`, ordinary local
signing, or the ordinary send screen. Mainnet P2PK ERG payments and one optional
token transfer are exposed; unrelated input tokens return as change.

### Defensive request boundary and cold review

`cold_request::parse_request` adds a complete preflight grammar before the
pinned library's general binary parser. A slice cursor checks canonical VLQs,
overflow, actual remaining bytes, bounded counts and complete consumption.
Input proofs/extensions, data inputs and registers must be empty. Every tree is
a fixed-length canonical P2PK tree or byte-identical to the locally serialized
standard miner-fee tree; reductions must be fixed P2PK propositions. Only then
are reduced transactions and boxes parsed, and their canonical reserialization
must reproduce every byte. The existing preparation checks recompute input box
IDs, require their exact order and uniqueness, and match reductions to scripts.
No panic-catching substitute is used for length or grammar validation.

The review requires every spending input to belong to the selected unlocked
seed wallet. It checks ERG conservation and exactly one nonzero miner fee with
no tokens, and computes token burns/creation from complete input/output totals.
Unsupported or incomplete requests never reach a partial review. Signing
rechecks ownership/unlocked state and verifies its own resulting proofs.

Before signing, the cold device displays:

- The explicit mainnet policy and every output, including miner and application
  fee outputs; full destination addresses and exact ERG values to nine decimals.
- Every token's full ID and integer base-unit quantity, without trusting names,
  labels or decimal metadata supplied by the online wallet.
- Locally verified “Your address” ownership, described as change or self-payment,
  rather than asserting an output is change based on the sender hint.
- Miner fee, the locally recognized Argus application-fee destination, and every
  token burn or creation (or “None”).

The user must check the review acknowledgement and explicitly choose “Confirm
and sign offline.” The cold endpoints make no network calls. Locking or changing
the selected wallet prevents signing with the previous review handle. Existing
watch-only accounts still have no local signing capability.

### Flutter QR, recovery and broadcast

Settings → Offline signing is available in the same build as watched-account
“Send with offline signer.” Receive's `qr_flutter` renderer and the existing
`ScanScreen`/`mobile_scanner` camera are reused; no dependency was added.
The camera scans one code per visit. The collection screen shows received/total
and exact missing page numbers. QR display has code/total, previous, next,
auto-repeat and pause. The hot side can redisplay the original request without
losing response collection progress.

A retained native collector accepts out-of-order pages and identical duplicates;
conflicts latch until reset. Malformed envelopes, hostile binaries and failed
verification show a refusal and require an explicit scan reset in the UI.
A missing page disables review/verification. Closing the scanner or navigating
back retains collection; returning to the action resumes it. There is one cold
signer draft and one draft per watched account in Flutter, with a native limit
of eight sessions. Unsigned sessions expire after 30 minutes. Drafts are memory
only: closing the app discards them. Verified hot returns are retained beyond
unsigned expiry for retry, until explicit discard or process exit.

The hot session's `cold_verify` calls the existing `verify_response`. Only its
`VerifiedColdTransaction` can provide bytes/JSON to `cold_broadcast`; that API
accepts a session ID, never scanned transaction JSON. A failed check clears the
verified capability and there is no fallback to raw scanned data. Broadcast
uses the retained node, checks the live UTXO set via `/transactions/check`, then
submits the unchanged verified transaction. On check/submission errors it looks
up the same transaction ID to handle an already-known/confirmed transaction;
otherwise it preserves the verified return and ID for retry. An unexpected node
ID is refused. The broadcast action appears only after successful verification.

### Compatibility and remaining scope

CSR/CSTX JSON, padded standard Base64, EIP-43 reduced bytes, full input boxes,
full signed responses and legacy paging are unchanged. No compression, fountain
codes, proof-only returns, derivation fields or new envelope fields were added.
The two pinned Appkit request fixtures still round-trip byte-identically through
sigma-rust in the existing trusted-fixture parity tests.

Those fixtures are **not evidence that the production cold policy accepts every
Appkit request**: fixture 1 uses a non-default miner delay of 72, and fixture 2
also carries registers. Production cold parsing explicitly refuses them under
the narrow policy above. Locally generated standard-mainnet requests exercise
the complete safe parse/review/sign path, including multiple input indices and
token transfers/burns. No signed Appkit fixture or actual ergo-wallet-app device
round trip has been performed. Compatibility at the wire format is maintained;
end-to-end interoperability with ergo-wallet-app remains unverified.

Remaining: real phones in both roles (camera readability and lifecycle), an
actual offline ergo-wallet-app round trip, signed Appkit response fixture parity,
and live node broadcast/uncertain-retry acceptance. Tests cover native sessions
and mocked Flutter actions, not a real financial broadcast. Extended script and
register support needs a separately bounded parser/review policy. Other networks,
indices above 512, dApp cold signing, durable cross-launch drafts, and exporting
an Argus seed wallet's xpub are not part of this completion. An existing watched
xpub and its matching seed wallet are the setup prerequisites.

FRB bindings were regenerated from the repository root. Tracked JNI `.so` files
were not rebuilt, as permitted; an installed build needs the updated native
library to use these APIs. All tooling/build outputs/logs stay under `rust/target`
or Flutter's existing build directories. `/tmp` was not used and no ignore rules
were added.

Final validation (commands run from the worktree root; `TMPDIR` is worktree-local):

```sh
(cd rust && CARGO_TARGET_DIR="$PWD/target" TMPDIR="$PWD/target/tmp" cargo test --workspace)
(cd app && CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true TMPDIR="$PWD/../rust/target/tmp" ../rust/target/tools/flutter/bin/flutter analyze)
(cd app && CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true TMPDIR="$PWD/../rust/target/tmp" ../rust/target/tools/flutter/bin/flutter test)
PATH="$PWD/rust/target/tools/flutter/bin:$PATH" CARGO_TARGET_DIR="$PWD/rust/target" TMPDIR="$PWD/rust/target/tmp" CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true flutter_rust_bridge_codegen generate
```

Results: Rust workspace **828 passed, 0 failed, 13 ignored**. Flutter analysis:
**no issues**. Flutter tests: **824 passed, 1 skipped** (including ten new cold
widget tests). A second root binding generation produced byte-identical files,
checked with SHA-256. `git diff --check` passed.

The new native integration test uses the production public builder/reducer and
session path with locally supplied boxes/context, across indices 0, 3 and 20,
then CSR collection, offline review/sign, CSTX collection and return verification.
Native tests also exercise expiry, missing pages, duplicates, conflicts, no
signing before review and no broadcast without a verified capability. Core tests
cover every truncation and single-byte input-box mutation, reduced-byte mutation,
oversized/overflowing lengths, a deterministic malformed corpus, token quantities,
burns, foreign recipients and locked/foreign wallets. Widget tests exercise both
directions' progress, missing/duplicate/conflicting/hostile scans, navigation
resume, explicit review approval, QR controls and verification failure refusing
to broadcast.

Failures found and corrected during validation: the disclosure test's obsolete
“Cannot spend” assertion; scroll targeting in a new widget test; and a new native
test resolving the global fee configuration before the existing init test. The
native test now uses the existing thread-local fee override. The attempted
production acceptance assertion for Appkit fixture 1 was replaced by an explicit
refusal regression for its non-default miner-fee policy; trusted binary parity
coverage remains unchanged.

The first layer staging attempt failed creating
`/home/rkadias/coding/arkadianet/Argus/.git/worktrees/coldui/index.lock` because the
shared Git directory is read-only. Per the requested fallback, all completion
changes remain uncommitted. Intended coherent layers: “Parse and review bounded
cold signing requests”, “Prepare watched payments and gate cold session
broadcasts”, and “Complete both cold signing QR flows”. Nothing was pushed and no
PR was opened. Comparison is against `perf/safe-wins`; newer base-only commits
are not part of this worktree's changes.
