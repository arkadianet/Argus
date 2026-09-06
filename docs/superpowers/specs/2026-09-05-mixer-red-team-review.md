# Mixer red-team review

Date: 2026-09-05
Scope: the ZeroJoin mixer as shipped in alpha.37: `zerojoin` crate,
`api_mix_impl` and the mix FFI, `MixService`, `MixBackground`, the mix key
storage, the Mix screen and settings. Read as an attacker: what can take
funds, what can strand them, what can grief a user for free, what can
deanonymise. Each finding names the code, the attack, the impact, and the
fix. Findings are ordered by what I would fix first.

Not in scope: the ErgoMixer contracts themselves (reproduced byte for
byte and verified against mainnet in stage 1), the node, the explorer.

## Summary

No finding lets an attacker take a user's funds. The proofs are the
contracts' proofs, secrets never leave the process except as an opt-in
per-mix key in the hardware-backed store, and every spend goes through
the contract. Three findings let an attacker or bad luck **strand a
mix's record** so it stops moving until the user recovers from seed, and
two of those cost the attacker only a transaction fee. Two findings are
privacy leaks to whoever runs the node or explorer the app talks to. The
rest are hygiene.

| # | Finding | Severity | Cost to attacker |
|---|---|---|---|
| 1 | A fake full-mix box with our `gX` captures our record | High (griefing) | one transaction |
| 2 | A failed or replaced broadcast leaves the record pointing at a box that never appears | High (robustness) | none, or a counterpart's reclaim |
| 3 | A fee emission box with a tiny `maxFee` is chosen and every move fails | Medium (griefing) | one transaction |
| 4 | Own-box lookups by id tell the node or explorer exactly which boxes are ours | Medium (privacy) | run a public node or explorer |
| 5 | A token emission box with absurd prices is chosen for entry | Low (griefing) | one transaction |
| 6 | Mix records, including the withdrawal destination, are stored in plain preferences | Low (privacy, local) | physical access |
| 7 | Notifications print the amount on the lock screen | Low (privacy) | look at the phone |
| 8 | The mix key crosses to Dart as a `String` | Low (hygiene) | memory access |

## 1. A fake full-mix box with our `gX` captures our record

**Where.** `zerojoin::mix::observe`. When our half box is no longer
unspent, it takes the first full-mix box whose R6 equals our `gX` and the
ring matches, and moves the record to "full owned as Alice".

**Attack.** Our `gX` is public: it is R4 of our half box. Anyone can
create a box under the full-mix script with any registers, because a
contract only constrains spending, not creation. An attacker posts a box
under the full-mix script with R6 = our `gX`, the right value and token,
R7 = the half-script hash, and `c1`, `c2` of their own choosing. If our
snapshot lists it before the genuine box (the legitimate Bob's spend of
our half box also produces one), the record attaches to the fake. Every
later move tries to prove `c2 == c1^x`, fails, and the mix shows "Last
move failed" forever while the genuine box sits unused.

**Impact.** No loss: recovery from seed uses `role_for`, which checks
`c2 == c1^x`, and finds the genuine box. But the user sees a stuck mix,
and the fix is a recovery scan they have to know to run. An attacker can
do this to every half box in the pool for a fee each.

**Fix.** `observe` must verify ownership, not just `gX`. Give it the
secret (the FFI has it, in both the handle and the key path) and select
with `owns_as_alice`. The engine test that builds a fake box with the
right `gX` and wrong pair must leave the record waiting.

## 2. A broadcast that never confirms strands the record

**Where.** `MixState::after` moves the phase to the new box as soon as a
move is broadcast. If that transaction never confirms, the new box never
exists, the old box is still ours and unspent, and the record points at
nothing.

**How it happens.** A counterpart reclaims their half box while our
remix-as-Bob spending it is in the mempool: ours is dropped. A node
accepts our transaction and then loses it. A fee box copy is spent by
someone else first. None of these are exotic. The record then says "box
not seen" on every tick, forever. Recovery from seed finds the old box,
but as a fresh record with no destination and, worse, the old record is
not reconciled because reconciliation only covers pending records.

**Fix.** Keep the previous box id on the state through a transition.
When the current box has not been seen for a grace period (say thirty
minutes or fifteen blocks, long enough for a mempool transaction to
confirm or drop) and the previous box is still unspent in the snapshot,
roll the record back one step and let the next tick rebuild the move.
The grace matters: immediately after a broadcast the previous box is
still unspent on chain, and rolling back then would double-spend our own
box. Also let recovery reconcile a record whose box is not on chain but
whose previous round's box is.

## 3. A fee emission box with a tiny `maxFee` stalls every remix

**Where.** `ChainView::fee_box` picks the fee emission box with the
largest value. `fee_emission_copy` then refuses if our miner fee exceeds
that box's R4 `maxFee`.

**Attack.** Anyone can create a box under the fee emission script with a
large value and R4 = 1. It becomes "the" fee box for every Argus user,
and every remix and withdrawal fails at build time, on every tick, for as
long as the box exists. The attacker loses nothing: the fee contract
lets its box be spent as a copy, so they can take the ERG back later.

**Fix.** Choose the fee box among those whose `maxFee` covers our fee,
and among those prefer the largest value. Same discipline as finding 5
for the token box. Test with a decoy fee box.

## 4. Box lookups by id are a fingerprint

**Where.** `MixService.snapshot` resolves each of our boxes with
`box/byId` and then `transaction/byId` on the spending transaction, and
`_confirmFinished` looks up the withdrawal by id.

**Attack.** Whoever runs the node or explorer the phone talks to sees one
client fetch exactly these ids in sequence: the entry box, then each
round's box, then the withdrawal transaction whose output is the
destination. That is the whole chain the mix exists to hide, linked to
one IP, before any chain analysis. The half-box list is fetched whole,
so the *pool* reads are not a fingerprint; the own-box reads are.

**Mitigation.** (a) State plainly, in the Mix screen and the notes, that
the node the app uses learns which boxes are yours, and that a mix is
only as private as that node; recommend the user's own node. (b) Replace
per-id lookups with whole-list reads where affordable: the unspent
full-mix list is a few hundred boxes and already used by recovery, and a
spent own box can be found by scanning the full list for our `gX` and
`c2` rather than by asking about the box. (c) Never look up the
withdrawal transaction by id; learn the height from the destination's
own balance refresh, which the wallet does anyway.

## 5. A token emission box with absurd prices

**Where.** `ChainView::token_box` picks the box with the most tokens for
sale. Its R4 batch prices and R5 rate are whatever the box says.

**Attack.** Post a box under the token emission script with many tokens
and a batch price of 1,000 ERG. Argus offers it. The confirm sheet shows
the fee, so a reading user declines, and the income goes to the operator
script baked into the contract, so the attacker earns nothing. Pure
nuisance, but it makes the Start sheet unusable while the box exists.

**Fix.** Prefer the token box with the lowest price for the chosen level
among those with enough tokens; cap the offered fee at a sanity bound
(say 5% of the denomination plus 1 ERG) and refuse above it with a clear
message.

## 6. Mix records are plain text on the device

**Where.** `argus_mixes_v1_<wallet>` in shared preferences holds every
box id, transaction id, round, and the destination script. `allowBackup`
is off and the extraction rules exclude backups, so this does not leave
the device by Android's own means.

**Impact.** Anyone who can read the app's data (a rooted phone, a
forensic image) links the entire mix to the destination, the very thing
the mix hid on chain. The seed is not there and no funds are at risk.

**Fix.** Store the records through the same encrypted preferences the
keys use (the Kotlin handler already wraps `EncryptedSharedPreferences`).
It is a small change with no user-visible effect. Until then the current
state is defensible for an alpha, and should be stated.

## 7. Notifications name the amount

**Where.** `mixProgress`: "Mix finished · 1 ERG delivered", "Mix round 2
of 3 done · 1 ERG is still mixing".

**Fix.** Leave amounts out of notifications (the app has them): "A mix
finished", "A mix round completed". Same rule the incoming-payment
notification should follow, which is out of scope here.

## 8. The exported mix key is a Dart string

**Where.** `mix_export_key` returns hex; Dart passes it to the keystore
and, in the background job, back to `mix_advance_with_key`. Dart strings
are immutable and cannot be zeroised; the Rust side zeroises its copy.

**Impact.** The key lingers in the Dart heap until collected. It can
spend only that mix's boxes, and someone who can read process memory
could read the keystore-decrypted value anyway. Hygiene, not a hole.

**Mitigation.** Keep the key inside Rust: let the FFI read and write the
keystore through a platform call, or pass bytes through a `Uint8List`
the Dart side clears. Low priority.

## What was checked and found sound

- Secrets: derived per round from the seed, never stored, `Debug` hides
  scalars, decoded copies zeroised. The mix key derives only its own mix.
- Pair order from OS randomness, not from anything public.
- Every spend is proven with the contract's own proposition; the wallet's
  own keys are only used for the funding self-send.
- Funding box bound by the funding transaction's output ids; an unrelated
  box of the same size is never taken.
- Every broadcast is preceded by a persisted record and followed by a
  commit; a staged entry is reconciled before it is sent again.
- One driver at a time across the foreground and the background job, with
  a lease and merge-by-mix-id behind it.
- Mix indices never reused after a removal.
- Fees are validated before building; the contract shapes make an extra
  output impossible, so the app fee cannot be smuggled in.
- Snapshot parsing is capped and tolerant of stray items; error bodies are
  no longer boxes.
- Keys are deleted when a mix ends, the switch turns off, or the wallet is
  deleted; a failed deletion is an error.

## Bugs, found on the same pass

These are not attacks; they are ways the mixer stops doing what it says
under ordinary use. Verified in the code, not guessed.

| # | Bug | Effect |
|---|---|---|
| B1 | Locking the wallet cancels the background job | Background mixing silently stops after auto-lock |
| B2 | A pending mix's funding box is an ordinary wallet box | Send or the UTXO tools can spend it before the entry |
| B3 | A failed funding broadcast leaves a pending mix that says "waiting for the box" | Twelve-minute wait for a box that was never sent |
| B4 | A staged entry is committed whenever the funding box is gone | The wrong conclusion if something else spent the funding box |
| B5 | Finished mixes only learn their height while another mix is active | The last withdrawal stays "not yet in a block" forever |
| B6 | A stuck mix has no way out but "Withdraw now" | A half box nobody joins waits forever unless the user notices |

**B1. Locking cancels the job.** `MixService.reset()` runs on lock and
clears the in-memory records. The next lifecycle change calls
`_reschedule()`, which asks whether any *in-memory* mix is active, finds
none, and cancels the WorkManager job. The usual sequence is: enter a
mix, close the app, auto-lock fires within the grace period, the job is
cancelled, nothing moves until the app is opened again. This defeats the
feature for exactly the user who turned it on. Fix: decide whether the
job is wanted from what is stored (records on disk, or keys in the
store), not from the in-memory list, and never let a lock cancel it.

**B2. The funding box is spendable by anything.** After the self-send
and before the entry, the funding box is a plain box on the wallet's
address. Send, buy-and-send, the UTXO tools and even a second mix's
funding all select from the same UTXOs and will happily take it, and
then the entry fails to find its box and the record sits pending. Fix:
the wallet's coin selection must exclude the funding boxes of pending
mixes (the record knows their ids), the way stealth boxes are handled by
pocket.

**B3. A failed funding broadcast.** `MixStartFlow.start` creates the
record before broadcasting, which is right, but if the broadcast throws
the record stays pending with no funding transaction. "Continue" then
waits twelve minutes for a box that was never sent and reports it as
"not confirmed yet". Fix: on a broadcast failure with no transaction id,
remove the record and surface the broadcast error.

**B4. Resuming a staged entry trusts the wrong signal.** On resume with
a staged entry, the flow checks whether the funding box is still there;
gone means "the entry went out". But the funding box can be gone because
B2 happened. Fix: the staged state carries the box the entry would
create; check for *that* box on chain. Seen: commit. Not seen and the
funding box present: build again. Neither: the funding box was spent by
something else; say so and clear the attempt.

**B5. Finished mixes and the height.** `_confirmFinished` runs inside
`tick`, after the `active.isEmpty` early return, so a wallet whose only
mix just finished never looks up its withdrawal and the row stays
unconfirmed. Fix: run the finished check before that return.

**B6. No exit for a half box nobody joins.** By design the pool is thin;
a half box can wait days. The card offers "Reclaim" but nothing nudges
the user, and background mixing will wait indefinitely. Fix: a waiting
time on the card ("waiting 2 days"), and an optional per-mix limit after
which the strip suggests reclaiming; never an automatic reclaim, since
that costs the tokens.

## Recommended order

1. B1 now: it makes background mixing not work.
2. Findings 1 and 3, B3, B5: small engine and service changes, tests with
   decoy boxes.
3. Finding 2 and B4 together: both are "the box I expect is not there";
   one rollback design with a grace period covers both.
4. B2: coin selection excludes reserved funding boxes.
5. Finding 4: the wording now; the whole-list reads when the full-box
   list is measured on device.
6. Findings 5, 6, 7 and B6 as a hygiene batch.
