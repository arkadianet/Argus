# Privacy in Argus: stealth addresses and a native mixer

Date: 2026-09-04
Status: exploration, no code. Written from primary sources: ErgoMixer's
`ergoMixBack` (contracts and stealth implementation), sigma-rust 0.28
(prover support), and live checks against the explorer and a node.

Both features are published, open-source Ergo protocols with users on
mainnet today. Nothing here needs new cryptography; Argus would
implement existing schemes with the primitives sigma-rust already
ships. The interesting decisions are interoperability, key derivation,
scanning, and what a phone can realistically run.

## 1. Stealth addresses

### The scheme (as deployed by ErgoMixer)

A receiver holds a secret `x` and publishes `u = g^x`. A sender picks
random `r` and `y` and builds a one-time box script

```
proveDHTuple(g^r, g^y, u^r, u^y)
```

whose ErgoTree is literally `1004 0e21<gr> 0e21<gy> 0e21<ur> 0e21<uy>
ceee7300ee7301ee7302ee7303`. Only someone who knows `x` can produce the
DH-tuple proof (`ur = gr^x` and `uy = gy^x`), and only the receiver can
tell the box is theirs, by checking those two equalities. Every payment
lands on a different script, so nothing on chain links payments to the
same receiver or to the published key.

The published form is a string: `stealth` + Base58(`u` ‖ first 4 bytes
of blake2b256(`u`)). Anyone with an ErgoMixer install can already pay
such an address, and can be paid at one.

### What Argus would add

**Receiving.** A per-wallet stealth key derived from the seed, so it
survives restore. Use a dedicated hardened branch (for example
`m/44'/429'/0'/3'/0` under the EIP-3 root; no other wallet uses `3'`)
rather than reusing a payment key, so the stealth secret never doubles
as a signing key. Show the `stealth…` string on the Receive tab as a
second option with a QR.

**Detecting payments.** ErgoMixer scans every block. A phone should not.
The explorer exposes `boxes/unspent/byErgoTreeTemplateHash/<sha256 of
template>`, verified today: 20 unspent stealth boxes on mainnet. Argus
fetches that list on each sync, tests each box against `x` (two point
multiplications per box), and adds matches to the wallet's box set. A
node does not offer template lookups, so the explorer is the source for
this feature; the query reveals only that some wallet is interested in
stealth boxes in general, never which ones are ours. Spent-box history
comes from the explorer's `byErgoTreeTemplateHash` with `spent` when
building activity.

**Spending.** sigma-rust's `SecretKey::DhtSecretKey(DhTupleProverInput)`
already proves DH tuples, so signing is the same `sign_reduced` path
with an extra secret per stealth input. Coin selection treats stealth
boxes like any other owned box; change goes to the normal change
address (or a fresh stealth box to oneself, which keeps the amount
unlinkable at the cost of another scan).

**Sending.** The Send screen accepts `stealth…` strings, validates the
checksum, derives a one-time payment script per recipient, and shows
"stealth payment" on the confirm sheet instead of an address. The
recipient's `u` is never written to chain.

### Caveats

- Amounts and timing are still visible; stealth hides the receiver's
  identity, not the payment.
- Detection depends on an indexed source. Offline, Argus cannot learn
  about new stealth receipts.
- A wallet that has been restored must rescan the template set once to
  recover stealth funds; make that a visible step in restore.

### Effort

Two to three days: Rust helpers for derivation, detection and the
DHT secret; Dart for Receive, Send parsing, sync integration and
restore rescan; tests against fixtures captured from the 20 live boxes.

## 2. Native mixer (ZeroJoin, as deployed by ErgoMixer)

### The protocol

ZeroJoin is a non-custodial, non-interactive mix between two parties
per round, with no coordinator and no trusted party.

1. **Alice** locks a fixed-denomination box (a *half-mix box*) whose
   script holds `gX = g^x` in R4.
2. **Bob** spends it together with his own input of the same amount and
   creates two *full-mix boxes*, each holding a pair `(c1, c2)` that is
   either `(g^y, gX^y)` or the swap, in random order. He proves with
   `proveDHTuple` that one of the two orderings is honest without
   revealing which. Each output now belongs to one of them, and an
   observer cannot tell which.
3. A full-mix box is spent either by its owner as **the next Bob** (with
   `proveDlog(c2)`) or by the other party re-entering as **the next
   Alice** (with `proveDHTuple(g, c1, gX, c2)`). Rounds repeat; each
   doubles the anonymity set.

Fees are the subtle part. A spender's own fee input would link rounds,
so ErgoMixer's contracts add a **fee emission box** that pays the miner
fee of every mixing transaction, funded by a **mixing token** (id
`1a6a8c16…2b98`) bought from a **token emission box** whose price goes
to the ErgoMixer operator's income address. Every mixing box carries
some of that token and burns one or two units per round. The operator
holds `mixerOwner` rights over the emission boxes only, never over
anyone's funds.

### Two ways to build it

**A. Interoperate with the live pool.** Reproduce the four contracts
byte-for-byte with the same constants, so Argus's half-mix and full-mix
boxes are indistinguishable from ErgoMixer's and share its anonymity
set. This is the only version worth shipping: a mixer with just Argus
users would have an anonymity set of a handful of boxes. It means
buying mixing tokens through the same emission box and paying the same
operator fees. The script hashes must be verified against boxes on
chain, the way the Dexy pool constants now are.

**B. Argus's own contracts.** Free of the operator fee, but empty pool,
and the fee-emission design would have to be re-solved. Not
recommended.

### What a phone can run

ErgoMixer is a server that watches the chain continuously and acts
whenever a counterpart appears. A mobile wallet cannot promise that.
Realistic shape:

- Mixing runs while the app is open, plus a periodic background task
  (WorkManager, every 15 minutes at best on Android) that checks for
  counterparts and advances one round. A mix of several rounds takes
  hours to days.
- Every secret (`x` per half-mix, `y` per full-mix) is derived from
  the seed and a round counter, never random, so a restored wallet can
  recover boxes stuck mid-mix. ErgoMixer stores these in a database;
  losing it loses the funds. Argus must not have that failure mode.
- State machine per mix (idle → half → full → … → withdrawn) with
  persistence and a visible "in mix" balance separate from spendable.

### Pieces

- `zerojoin` crate in `rust/crates/vendor/protocols`: contract
  compilation with constants, half/full/fee/token box discovery by
  script hash (node `byErgoTree` works for exact trees), Alice and Bob
  transaction builders, DH-tuple proving through the existing
  `sign_reduced` path.
- Discovery of counterparts: unspent half-mix boxes of the chosen
  denomination and token level.
- Withdraw flow to a fresh address or a stealth address.
- UI: a Mix tab under Swap or a Tools entry: choose amount from the
  supported denominations, rounds, watch progress.

### Risks

- **Complexity.** Four interacting contracts, fee-token accounting, and
  a long-running state machine. Bugs strand funds in mix boxes.
- **Operator dependency.** Token and fee emission boxes are the
  operator's; if they are not refilled, mixing stops. The funds in mix
  boxes remain spendable by their owners.
- **Distribution.** A wallet with a built-in mixer may be refused by
  Google Play. Ship it behind an opt-in flag and, if needed, only in
  the GitHub and F-Droid builds.
- **Time on a phone.** Users must understand a mix is not instant.

### Effort

Three to five weeks for the interoperable version, including a
testnet-style dry run against the live contracts with small amounts.

## 3. Recommendation

Stealth addresses first. They are small, they compose with everything
else (mixer withdrawals, Send, Receive), they interoperate with
ErgoMixer users today, and they give Argus a privacy feature no other
mobile Ergo wallet has. The explorer template lookup removes the main
obstacle for a light client.

The mixer second, as an opt-in experiment interoperating with the live
ZeroJoin pool, once the on-chain attestation and beta work are done.
Its value depends entirely on sharing ErgoMixer's anonymity set, and
its cost is dominated by the state machine and background execution.

## 4. Questions before starting

1. Stealth key derivation: a new hardened branch as proposed, or the
   wallet's index-0 key (simpler, but ties stealth to a signing key)?
2. Is an explorer dependency acceptable for stealth detection, with a
   node-only fallback that scans recent blocks?
3. For the mixer, is paying ErgoMixer's operator fees acceptable in
   exchange for its anonymity set?
4. Play Store: does Argus plan to be listed there, or GitHub only?
