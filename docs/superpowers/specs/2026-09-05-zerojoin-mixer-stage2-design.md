# ZeroJoin mixer, stage 2: engine, wallet and screen

Date: 2026-09-05
Status: batch A merged (#64); batch B in review; batch C next. Follows `2026-09-05-zerojoin-mixer-design.md`
(stage 1, merged as #63), which built the contracts, secrets and the six
transaction builders and verified them against live pool boxes.

## What a mix looks like from the wallet

A mix is one denomination's worth of ERG (or one token ring's worth of a
token) moving through `rounds_target` rounds and landing at a destination
the user chose when they started it. The wallet drives it; nothing else
does. Its life:

```text
Pending ──entry tx──► HalfPosted ──someone Bobs it──► FullOwned(Alice)
                  └──► FullOwned(Bob)                       │
                                                            ▼
      FullOwned ──remix as Bob──► FullOwned(Bob)     rounds_done += 1
      FullOwned ──remix as Alice──► HalfPosted ──…──► FullOwned(Alice)
      FullOwned, rounds_done ≥ target ──withdraw──► Withdrawn
      HalfPosted, user gives up ──reclaim──► Reclaimed
```

Every transition is a function of the persisted state and a snapshot of
the chain, so the whole machine is pure, unit-tested, and re-runnable
from a restored seed.

## Decisions

**Entry is confirmed; everything after runs itself.** Entering a mix
spends the user's money and pays the operator, so it goes through the
same prepare, PIN, confirm path every send uses. Remixes cost nothing
new: the mixing tokens were bought at entry and the fee box pays the
miner. They run whenever the app is open and the wallet unlocked, and in
the existing ten-minute background poll window. Withdrawal is decided at
entry too: the destination is fixed then, so finishing needs no one at
the phone. A user who wants out early reclaims or withdraws from the Mix
screen, which is a confirmed action.

**One box per mix, one secret per box.** Mix `m`, round `r` uses the
secret at `m/44'/429'/0'/4'/m/r`. The entry box uses round 0 and every
box the mix creates afterwards increments the round. Recovery derives
`(m, r)` pairs and matches `g^secret` against R4 of half boxes and
R4/R5 of full boxes; a mix is found if any of its boxes is unspent.

**Funding is a plain self-send first.** The contracts pin the entry to
exactly one funding input with nothing on it the transaction cannot
place (stage 1 enforces this). So starting a mix is two transactions:
an ordinary send to the wallet's own address for exactly
`denomination + operator fee + miner fee` (carrying the usual Argus fee),
then the entry spending that box. ErgoMixer's deposit address is the
same idea.

**Enter as Bob when a half box is waiting.** That completes a round
immediately instead of waiting for a counterpart. The wallet never Bobs
its own half boxes: pairing with yourself hides nothing.

**The pair order is random.** Which of the two full-mix outputs is Bob's
must not be derivable from anything public, so it comes from OS
randomness, not the secret. Recovery does not need it: Bob's box is the
one whose `c2` is his `g^y`.

**Withdraw to a stealth address by default.** The natural end of a mix is
a box nothing links to the wallet's addresses. The Mix screen offers the
wallet's own stealth self-change script (already buildable) as the
default destination, with a fresh public address as the alternative.

**Chain reads happen in Dart, decisions in Rust.** As with stealth: Dart
fetches explorer pages (unspent half boxes of the ring, the fee and
token emission boxes, and the spend status of the mix's own box) into
one JSON snapshot; Rust parses, decides, builds, signs and broadcasts.
Unit tests drive the machine with synthetic boxes and no network.

**Behind a switch.** Mixing is off until the user turns it on in
Settings → Privacy. A store build may need it compiled out entirely;
that is a build flag decision for the release, not for this stage.

## Batches

| Batch | Contents | Done when |
|---|---|---|
| A (#64) | `zerojoin::mix`: `MixState`, `ChainView`, `observe`, `plan`, `recover`, transitions. Wallet-core `mix_secret`. FFI: `mix_rings`, `mix_funding_requirement`, `mix_prepare_entry` (through the prepare/confirm cache, secrets re-derived at sign time), `mix_advance` (build, reduce, sign, broadcast one move), `mix_recover`, `mix_plan`. | Unit tests for every transition; a live ignored test that enters, remixes and withdraws a 1 ERG mix reduces every input to true. |
| B (this PR) | Dart `MixService`: persisted mix list per wallet, snapshot fetcher, advancement on sync and in the background window, notifications on round completion. Pockets: `inMix` and `mixed` fed from mix states. | A mix survives app restart and a seed restore; balances show in the pockets. |
| C | Mix screen: start (ring, level, rounds, destination), progress, reclaim, withdraw now. Settings switch. Release notes. | Device-tested 1 ERG mix end to end. |

## Not in stage 2

- Token rings in the UI (the engine supports them; the screen starts
  with ERG rings).
- Multiple boxes per mix, or mixing an arbitrary amount by splitting it
  across rings.
- Any change to the contracts, fees or operator identities.
