# Stake Recovery — design

**Status:** agreed 2026-09-11 (Claude + Codex consensus, granted after one round).
**Feature:** permissionless recovery of stranded v1 Paideia-template staking positions
(Ergopad, Paideia, EGIO) for holders of an abandoned Stake Key NFT, as an Argus **Tool**.

## What this is

Three v1 staking pools built on the Paideia staking template were abandoned by their
operators. Anyone still holding the `Stake Key` NFT for a position can redeem the
underlying reward tokens **without any action from the (defunct) operator**, because the
contracts gate redemption structurally rather than on a signature.

Two mechanisms:

- **Direct** (Ergopad, EGIO) — one transaction spends `StakeStateBox`, `StakeBox` and the
  user's key box. The state script checks the key-token membership against `INPUTS(2)`, so
  **input ordering is load-bearing**. The key's UTXO is consumed and the token recreated in
  change — it returns to the user's wallet.
- **PaideiaProxy** (Paideia) — two steps. The key is spent into a single-use proxy box
  (`101b`) naming a payout recipient in R5; the proxy is then consumed with the state box
  and stake box to pay out, **burning the key**. A permissionless refund path returns the
  key and ERG if the unstake cannot run.

Reference implementation: `citadel/crates/protocols/stake_recovery` (ergo-defi). It is
**reference only** — see D1.

## Audit findings that shape this design

A Codex audit of the reference crate (2026-09-11) found:

1. **Two of three `stake_box_ergo_tree` constants are malformed.** Decoding the registered
   P2S addresses yields different, valid trees. Ergopad: stored 918 hex chars vs 856
   derived, type error on parse. Paideia: 1010 vs 1022, `InvalidTypeCode(216)`. The
   reference gets away with it only because discovery queries by *address* and builders
   copy input trees.
2. **The validators are near-empty.** `validate_stake_box`/`validate_state_box` check asset
   count and the first two token ids. Nothing binds trees, registers, box ids, key ids,
   quantities or wallet ownership.
3. **Proxy R5 recipient is unchecked** — any nonempty hex is accepted as the payout
   destination. A wrong recipient defeats both payout and refund.
4. **Refund is gated behind executor construction** in the reference service layer, so an
   executor failure can block the refund path entirely.
5. **The reference's 10 tests prove serialization, not execution.** Eight are
   serialization, two check reconstructed fields, the helper fabricates box ids. Nothing
   reduces a script or hits mainnet.

Live chain facts measured 2026-09-11:

| Pool | Unspent boxes at StakeBox P2S | Notes |
|---|---:|---|
| Ergopad | unknown | public explorer `byAddress` returns 503 reproducibly (4 retries, 90s) |
| EGIO | 0 | nothing left to recover |
| Paideia | 332 | fits one 500-box page today |

Node-first discovery **is verified working** for Ergopad: `POST
/blockchain/box/unspent/byErgoTree` with the full address-derived tree as a JSON string
returned HTTP 200 and 500 exact tree matches in 3.57s from both `ergo-node.eutxo.de` and
`ergo-node.zoomout.io` — nodes already in `network_controller.dart`. The node indexes on a
hash of **full tree bytes**, so address-derived bytes are exactly what it wants (not the
template).

Mainnet precedent exists: Ergopad recovery `0e1f269f…`, Paideia unstake `fccb0c49…`,
Paideia refund `72e33dd7…`. All three have null proofs on the protocol inputs.

## Decisions

### D1 — Native crate, no vendoring
New crate `rust/crates/vendor/protocols/stake-recovery`, registered in `rust/Cargo.toml`
members and `workspace.dependencies`. **No Citadel code is copied.** This follows the
standing 2026-09-06 decision that Citadel is reference material only, and matches the five
native reimplementations already living there (sigmafi, zerojoin, duckpools, rosen,
stealth). The `vendor/` directory name is a known wart; renaming the tree is out of scope.

### D2 — Scope
Ship **Ergopad** and **Paideia**. **EGIO** stays as an inactive constants entry excluded
from automatic discovery — zero requests attributable to it — since it currently has no
recoverable positions.

### D3 — Discovery
- **Paideia:** page the StakeBox P2S. Implement bounded pagination; do not encode
  "one page" as an invariant.
- **Ergopad:** node-first `byErgoTree` with the full address-derived tree, bounded paging,
  explorer fallback. Require a **caught-up extraIndex** — a reachable, chain-synced node can
  still have a lagging or absent index.
- **State box:** discover the singleton via **state-NFT lookup**, not paging.
- **Cache** `stake_key_id → stake_box_id`, scoped by network/protocol/key (and results by
  wallet). Revalidation is one unspent lookup per cached box, re-checking tree, assets and
  R5. Spent/missing → rediscover; timeout/503 → error, not absence. Scan once per pool for
  all unresolved keys.
- **Rejected:** R5 lineage walking. The key lives in the wallet, not the StakeBox assets, so
  `track_singleton_lineage` does not apply; compounding advances the checkpoint per cycle
  (a sampled position moved 341 → 790, 449 hops) against a 200-hop cap. Pool-token paging
  was measured and offers no advantage (500 results/3.70s, 499 matches vs 500/500 for tree).
- **Capped or interrupted scans report incomplete results, never authoritative absence.**
- Explorer failure wording: *"Ergopad scan failed on the configured explorer. Connect an
  indexed node or retry."* — repeated failures establish current availability, not
  permanent incapability.

### D4 — Rust/Dart split
Pure Rust: constants, decoding, validation, builders. Dart: all HTTP, paging, orchestration,
persistence. JSON-in/JSON-out FFI following `api_sigmafi_impl.rs`. No `NodeClient` inside
the protocol crate. **Wallet-ownership checks belong at the wallet-integration boundary** —
a pure parser cannot establish ownership from caller-supplied box JSON.

### D5 — Contracts derived, never hardcoded
Derive trees from P2S addresses via `ergo_tx::address_to_ergo_tree`. Assert in tests that
derived trees equal the historical mainnet input trees, and that Ergopad/EGIO StakeBox
**templates** are byte-identical. Runtime binding compares **full trees**, since identical
templates omit the differing pool constants. Cover state, proxy and incentive contracts;
verify the incentive tree's hash against the proxy's commitment.

### D6 — Validation (non-negotiable)
Every builder, from the **actual decoded inputs**:
- Reconstruct canonical boxes; verify supplied box ids against contents; reject duplicate
  inputs; derive snapshots internally rather than trusting callers.
- Validate exact register types/lengths, 32-byte key ids, token positions where scripts
  index them, and singleton quantities.
- Enforce checkpoint compatibility, positive payout, sufficient state totals/counts, and
  proxy amount equal to the actual full-unstake amount.
- Enforce transaction-wide conservation: Direct returns the key; proxy creation transfers
  exactly one; execution burns exactly that one; refund preserves all proxy assets. Reject
  unexpected protocol assets while preserving unrelated wallet funding assets.
- Pin input/output ordering, counts, fees, incentive destination, minimum box values.
  Wallet-control checks cover Direct payout/change and the executor tip.
- Revalidate current inputs before commitment; reduce the assembled transaction. Preflight
  executor eligibility and refund funding **before proxy creation**.
- Reject ambiguous matching positions rather than taking the first.
- Checked arithmetic throughout; no `unwrap_or(0)`.
- Tree plus matching R5 alone is **not** sufficient authentication.

### D7 — Refund independence
The Paideia refund must be constructible and submittable from the **proxy box alone** plus
ordinary context (height) — no state discovery, no StakeBox discovery, no executor
construction. Persist the creation tx id, expected proxy box, key, recipient, network and
wallet association **before broadcast** (saving after submission leaves a crash window).
Reconcile pending/confirmed/spent on restart; retain tracking through uncertain submission.

### D8 — Tests
Real mainnet fixtures for the three historical transactions, with complete input creation
metadata, context extensions and data inputs. Argus already pins the interpreter and calls
`reduce_tx` (`wallet-core/src/transaction.rs:11`), so **script reduction tests are practical
and required**. Test both the historical transactions and native-builder output against
those inputs. Do **not** assert only `reduce_tx(..).is_ok()` — inspect reduced propositions:
permissionless inputs must reduce to true, the Ergopad wallet input must retain its
signature requirement. Keep contract-rejection tests separate from wallet-policy tests (a
wrong recipient in R5 can be contract-valid; Argus must reject it independently). Adversarial
cases: wrong recipient, foreign box at the P2S with matching R5, extra assets, stale
checkpoint, malformed registers, duplicate inputs, singleton quantities, integer boundaries,
unintended burns, reordered outputs.

### D9 — UI
`DiscoverFeature.stakes` in the Tools group (`discover_screen.dart:40`) plus an explainer;
a screen following the SigmaFi/Duckpools shape; the existing confirm-transaction sheet for
signing. Per-pool incomplete/unavailable status — an Ergopad failure must not hide Paideia
results or refunds. Persistent access to pending proxies and refunds. Confirmation
explicitly displays the Paideia key burn and the costs.

### D10 — No dev fee
Argus takes **no** dev fee on stake recovery. It recovers stranded funds; a percentage cut
reads badly. Contract-mandated costs remain and are not an Argus fee: Paideia's fixed
executor layout requires a 0.1 ERG incentive output, 0.002 ERG executor output and 0.002 ERG
miner fee. The freely selectable executor destination routes to the user's own wallet when
Argus executes.

## Batches (stacked PRs)

1. **Contract foundations** — crate registration, address registry, decoded models, strict
   validators, historical fixtures, reduction harness.
2. **Discovery vertical slice** — parsing FFI/bindings, Dart node/explorer paging, state-NFT
   lookup, cache and error semantics, Tools entry, read-only screen.
   **First device-testable batch** (discovery, fallback, cache, wallet switching).
3. **Ergopad recovery** — Direct builder, conservation/reduction/adversarial tests,
   confirm/sign/submit, stale-input handling. **First device-testable recovery transaction.**
4. **Paideia proxy + refund** — both builders and tests, durable pre-broadcast tracking,
   restart reconciliation, independent refund submission. Normal unstake entry stays
   disabled.
5. **Paideia execution** — executor builder and tests, eligibility preflight, full unstake
   flow, conflict reconciliation, final cost/burn presentation. Paideia enabled only once
   refund is operational.
