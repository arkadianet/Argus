# ZeroJoin mixer, stage 1: the Rust core

Date: 2026-09-05
Status: implemented in `rust/crates/vendor/protocols/zerojoin`; no UI, no
state machine, nothing in the app calls it yet. Follows section 2 of
`2026-09-04-privacy-stealth-and-mixer-exploration.md`.

## Decision: interoperate with the live ErgoMixer pool

Argus does not deploy its own mixing contracts. It reproduces ErgoMixer's
four contracts byte for byte, so an Argus half-mix or full-mix box is
indistinguishable from an ErgoMixer one and both wallets draw on the same
anonymity set. A pool containing only Argus users would hide nothing.

Where this crate's model and the deployed contract disagree, the contract
wins. Every claim below about what a contract requires was checked by
building a real transaction against live pool boxes and reducing every
input offline (`tests/live_round.rs`), not by reading the ErgoScript.

## What was verified against mainnet

The four ErgoTrees were lifted verbatim from mainnet transactions, not
compiled locally:

| Contract | Source transaction on mainnet |
|---|---|
| half mix, full mix, fee emission | `2828df5af82ba172a06476d9265cb672faf95be83e488a68fdf1bdab3a6ae32f` (a remix as Bob) |
| token emission, income script | `b8d6a127ea0152ad2d16ec7d6ab46910a74f2e92001b9c10ce8c6f34ad41b206` (an Alice entry) |

They form a closed hash chain that a substitution cannot satisfy: the token
emission contract embeds `blake2b256(half mix)`, the half-mix contract
embeds `blake2b256(full mix)`, the full-mix contract embeds
`blake2b256(fee emission)`, and every full-mix box carries
`blake2b256(half mix)` in R7. `contracts::verify_contract_wiring` asserts
the whole chain, and `zerojoin_live_contracts_match_mainnet` asserts the
pinned trees equal the scripts on unspent boxes right now.

Identities, from ErgoMixer's `TokenErgoMix.scala` and confirmed by the
hashes the contracts embed:

- mixing token `1a6a8c16e4b1cc9d73d03183565cfb8e79dd84198cb66beeed7d3463e0da2b98`
- operator income `9f4bRuh6yjhz4wWuz75ihSJwXHrtGXsZiQWUaHSDRf3Da16dMuf`
- operator key `03b038b0…848e`, which can spend the fee and token emission
  boxes and nothing else. It has no rights over any half- or full-mix box.

### The six moves, all reduced to true against live boxes

| Move | Inputs | Outputs | Proof the wallet supplies |
|---|---|---|---|
| Enter as Alice | funding, token emission | half mix, income, token emission copy, miner fee | `proveDlog` on the funding box |
| Enter as Bob | half mix, funding, token emission | full, full, income, token emission copy, miner fee | `proveDHTuple(g, gX, gY, gXY)` |
| Remix as Bob | half mix, own full mix, fee emission | full, full, fee copy, miner fee | DH tuple on the half box, `proveDlog(c2)` on the full |
| Remix as Alice | own full mix, fee emission | half mix, fee copy, miner fee | `proveDlog(c2)` or `proveDHTuple(g, c1, gX, c2)` |
| Withdraw | own full mix, fee emission | destination, fee copy, miner fee | as above |
| Reclaim half mix | own half mix | destination, miner fee | `proveDlog(gX)` |

`zerojoin_live_round_reduces` builds each of these against live pool boxes
and asserts no input reduces to `false`. This is the same technique that
found two real bugs in the Dexy work, and it is the acceptance evidence
for this stage. Nothing is signed or broadcast.

### Token and fee accounting, matched to `ErgoMixBase.scala`

- Remix as Bob pools both boxes' mixing tokens, gives each output
  `(total − 1) / 2`, and burns the remainder, which the fee contract
  requires to be exactly 1 or 2.
- Remix as Alice burns exactly one token.
- Enter as Bob pays its own miner fee from the funding box; the fee
  emission box is not involved, because its Bob branch requires both
  spent inputs to carry mixing tokens and a fresh deposit has none.
- Withdrawal burns every mixing token in the box; the full-mix contract
  allows a spend only into another round or into outputs holding none.
- Reclaiming a half-mix box that never found a counterpart pays its own
  miner fee: the operator's fee box only funds transactions that mix.
- The fee box copy keeps the same script and R4 and loses at most
  `maxFee` (its R4), as `isCopy` demands. The token emission copy keeps
  R4 (batch prices) and R5 (rate), and the income output pays
  `batchPrice + poolAmount / rate`, both read from the live box rather
  than assumed.

### The Argus app fee is deliberately absent

Every other transaction Argus builds carries a 0.0011 ERG app fee. Mixing
transactions cannot. The fee emission contract pins the output count
(`OUTPUTS.size == 3` for Alice or withdraw, `4` for Bob), the token
emission contract pins it at 4 and 5, and the half-mix contract inspects
outputs by index. An extra output fails validation. This is the same
constraint ErgoPay has, for the same reason: the contract, not the wallet,
fixes the transaction shape.

## Secrets: derived from the seed, never stored

ErgoMixer keeps every mix secret in a SQL database, and losing that
database loses the funds in every half- and full-mix box, because nothing
else can produce the proofs their contracts demand. Argus must not inherit
that.

A mix secret is a pure function of `(seed, mix id, round)` on the path
`m/44'/429'/0'/4'/<mix id>/<round>`. The hardened `4'` is the next free
branch after stealth's `3'`, so a mix secret can never double as a
payment or stealth key. One secret serves a round whichever role the wallet
plays: as Alice it is `x` with `gX = g^x` in the half box, as Bob it is `y`
with `c2 = g^y` in the wallet's full box. That is ErgoMixer's own
one-secret-plus-`isAlice` model.

Recovery therefore needs the seed alone. A restored wallet re-derives
`(mix, round)` pairs, computes `g^secret`, and finds its boxes by matching
R4 (half) or R4/R5 (full) on chain. Bob never needs to remember which
`(c1, c2)` order he chose: his box is the one whose `c2` equals his `g^y`.

Tests: the same seed and round reproduce the same secret; a different round
or mix does not; the path is off the payment and stealth branches; `Debug`
never prints the scalar; indices past the soft range are rejected rather
than wrapped.

## The live pool, measured on 2026-09-05

`zerojoin_live_rings` discovers denominations from boxes rather than
hard-coding them. Today's unspent half-mix boxes:

| Ring | Waiting half boxes | Highest mix level |
|---|---|---|
| 1 ERG | 1 | 21 |
| 100 ERG | 2 | 2 |
| 0.001 ERG carrying 200 Paideia | 2 | 90 |
| 0.001 ERG carrying a token (`0cd8c9…`), 100 000 or 1 000 000 units | 1 each | 90 / 178 |
| 0.001 ERG carrying a token (`fbbaac…`), 1 000 or 10 000 units | 100 / 10 | 30 / 18 |

Token rings mix a token amount with a nominal ERG carrier; the two token
ids above are not on Argus's verified list and are not named here.

The pool is thin. A wallet entering the 1 ERG ring today pairs with one
possible counterpart. This does not change the design, since anonymity
grows with rounds and with other users, but the UI must not imply
otherwise, and the state machine must expect long waits for a counterpart.

## The operator dependency

The fee emission and token emission boxes are ErgoMixer's operator's. If
they are not refilled, no new round can be built: entries need tokens to
buy and remixes need a fee box to pay from. Funds already in half- and
full-mix boxes stay spendable by their owners regardless, through the
reclaim and withdraw moves, which is why both exist and why reclaim pays
its own fee.

Entering costs the operator's token price, read from the live emission box.
That is the price of sharing ErgoMixer's anonymity set, and the reason
option B in the exploration (Argus's own contracts) was rejected.

## Not in this stage

- **FFI.** Nothing in `wallet-ffi` exposes the crate. The signer already
  accepts extra DH-tuple secrets (`sign_reduced_with_secrets`, added for
  stealth); a mix needs the same plus `proveDlog` secrets for `y`.
- **The state machine.** Per mix: `idle → half posted → full (as Bob) →
  … → withdrawn`, persisted, advanced while the app is open and on a
  periodic background task, and re-derivable from the seed after restore.
  A round can take hours; the UI must say so.
- **Counterpart discovery and polling.** Finding a half box of the right
  ring to join, or noticing that our half box was joined.
- **A Mix screen.** Choose ring and rounds, watch progress, cancel.
  Outcomes land in the pocket model as Mixed and In mix.
- **Withdrawal to a stealth address** of the user's own, which is the
  natural end of a mix and already buildable.
- **Distribution.** A built-in mixer may be refused by Google Play; ship
  behind an opt-in flag and, if needed, only in GitHub builds.
