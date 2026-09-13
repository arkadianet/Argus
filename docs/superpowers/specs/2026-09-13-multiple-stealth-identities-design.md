# Multiple stealth identities: as built

Date: 2026-09-13
Status: implemented, not yet exercised on a device or against mainnet funds.
Extends `2026-09-04-stealth-addresses-design.md`, which stays accurate for
everything about the scheme itself — encoding, template, detection test,
signing path. Only the *number* of identities changes here.

## The problem

Argus had one stealth identity per wallet, pinned at `m/44'/429'/0'/3'/0`.
Payments to it are unlinkable one-time scripts, but the published string is
not: hand the same `stealth…` string to a donation page and to a client, and
those two contexts are linked by the string itself, whatever the chain shows.

ErgoMixer let a user mint several named stealth addresses. It did so with a
server holding plaintext secrets in Postgres. The requirement here is the same
capability with Argus's property intact: everything regenerates from the
recovery phrase, and nothing but the phrase is needed to find the funds.

## Derivation

Identity `i` lives at `m/44'/429'/0'/3'/i`, with a uniformly non-hardened
final index.

Identity 0 walks the historical path byte for byte —
`stealth_derivation_path(0)` returns the `STEALTH_DERIVATION_PATH` constant
itself rather than formatting it — so a string already published by a wallet
that only ever knew one identity does not move. The regression guard is
`wallet.rs`'s `stealth_identity_is_stable_and_locked_with_the_wallet`, which
was not touched by this change and still passes.

The hardened `3'` above the index does the security work, as before: no EIP-3
wallet walks that branch, no account-level xpub can descend into it, and a
test asserts no identity `0..8` collides with a payment key `m/44'/429'/0'/0/i`.
`MAX_STEALTH_IDENTITY` is 255 — not a protocol limit, a guard so a corrupted
frontier cannot ask for millions of derivations.

## Persistence, not gap-scan

This is the one place where the obvious design is wrong.

A stealth identity has **no on-chain footprint until it is funded**. There is
no address to look up, no first transaction, nothing. So the usual BIP-44 rule
— "N consecutive empty, stop" — does not terminate correctly: a donation
address published last week and not yet paid is indistinguishable from an
index nobody ever used, and a gap scan would drop it permanently.

So the identity list is persisted, and the frontier is `max(index) + 1`:

- `StealthIdentityStore` keeps `{index, label, published_at}` per wallet.
- Publishing appends at the next index. Indices are never reused and never
  chosen by hand — a reused index hands out a string that may already be
  published under a different name.
- On unlock, `StealthService.loadIdentities` reads the list and calls
  `stealth_use_identity`, which raises the handle's frontier. `scan()` checks
  a `_identitiesLoaded` flag and loads first if a caller got there early, so
  the guarantee does not depend on call ordering at the unlock site.
- `WalletHandle::ensure_stealth_identity` only ever *raises* the frontier. A
  stale caller must not be able to shrink the set and strand funds.

**Restore** has no list to read, so it uses bounded discovery instead:
`stealth_discover_identities` derives `0..STEALTH_DISCOVERY_SPAN` (32) and
reports which of them own a box in the template set. Funded identities are
always rediscovered — their boxes are the evidence. An identity that was
published but never paid is not, and that is the accepted loss: re-adding at
index `i` regenerates its exact string for free, and it held no money anyway.
An identity that was funded and then swept clean is likewise not rediscovered,
for the same reason. Discovery refuses to run on a truncated box list, since
an absent identity there is not evidence of an unfunded one.

## Storage, and what that means for labels

There is no SQL database in Argus. Identity records are plaintext
SharedPreferences under `argus_stealth_identities_v1_<walletId>`, matching
`AddressLabelService` and `ContactsService` — the two nearest neighbours, both
of which store user-authored labels attached to addresses the same way.

They deliberately do *not* go through `WalletDatabaseService`'s XOR helper.
That helper's own header calls itself "NOT encryption … only deters casual
greps", so routing through it would buy no real protection while making this
the odd one out among the label stores. (A review flagged the opposite, on the
strength of an earlier draft of this file's own comment claiming the helper was
used. The comment was wrong; the code was consistent with its neighbours.)

An index and a label are not secrets in the key sense — an index buys an
attacker nothing they could not get by scanning, and the published strings are
published on purpose. But a **label is user metadata**, readable by anyone with
file access, and on iOS it rides along in device backups. The Settings note
says labels live on the device only; nothing that must actually stay private
should go in one.

### Mutations are serialized per wallet

`add`, `rename` and `merge` each load the whole list, change it, and save the
whole list back, so interleaved they lose each other's writes. The reachable
case is not exotic: discovery is a network round trip started from Settings,
and the user can add an identity on Receive while it is in flight — discovery's
save then drops the new row, *after* its string was shown and possibly
published. Two concurrent `add`s can likewise pick the same index for two
labels.

`StealthIdentityStore._locked` chains one future per wallet id around each
complete read-modify-write. `merge` re-reads inside the lock for exactly this
reason. Tests cover all three pairings and were confirmed to fail with the lock
removed.

## Cost

Detection is `2` exponentiations per box per identity, with a first-match
exit. The live mainnet template set is tens of boxes and the cap is 5000, so a
worst case is bounded and the realistic case is a handful of identities over a
few dozen boxes. No cross-scan cache was added: it would need process-local
state keyed by the identity set, and there is no measured cost to justify it.

The `published_at` height floor from the original proposal was **dropped**.
`published_at` is wall-clock and boxes carry `creationHeight`; comparing them
needs the chain height recorded at publish time, which is more moving parts
than the saving is worth at this box count.

## Spending, and the trap avoided

Detection finding a box is worthless if signing cannot produce its key. Three
call sites derived identity 0's secret only, and each would have detected a
box on a later identity and then failed to sign it:

- `api_stealth_impl::dht_secrets_for` — now resolves each tree against every
  identity in use via `identity_for_tree`, and errors loudly if a tree belongs
  to none of them.
- `api::wallet_can_spend_change` — stealth change may sit on any identity's
  one-time script.
- `api::prepare`'s send path — stealth inputs are detected with
  `detect_owned_multi`.

`prepare_stealth_sweep` gained `only_identity`. The Receive screen passes the
shown identity: sweeping everything into one output would spend two identities
in one transaction and link on chain exactly the contexts the user separated.
Passing `None` still sweeps everything, which is what a single-identity wallet
has always done.

Stealth change stays pinned to identity 0. It is internal plumbing, never
surfaces in the picker, and never advances the frontier.

## What the app does

- **Receive**: with one identity, unchanged. With several, a label-keyed
  picker above the QR; the string, balance and sweep all follow the choice,
  and the balance line says "on this address" so one pocket is not read as
  the whole stealth balance. "Add stealth address" asks for a label and
  appends at the next index.
- **Settings → Security**: one row per identity showing its shortened string
  and its own balance, tap to rename; a "Find stealth addresses with funds"
  action for the restore case; a note that labels are device-local and that
  an unpaid address comes back unnamed.

## Decisions taken along the way

- **Labels, not indices, in the UI.** The index is plumbing. Exposing it as
  the primary control invites index-hopping, which is how a user strands a
  published string on a path they will not derive again.
- **No manual secret import.** Accepting a raw `x` would break the property
  that the phrase alone restores everything — the reason this design exists.
- **Append-only, no delete.** A freed index would be handed out again under a
  new label while the old string is still published. Test:
  `indices are never reused`.
- **A scan result with no per-identity rows credits identity 0.** Such a
  result came from a single-identity scan, so its wallet-wide total *is*
  identity 0's. Reading it as zero would hide real funds and remove the sweep
  button; `StealthScanResult.balanceOf` handles it explicitly.
- **The frontier lives on the handle, not in every FFI signature.** It mirrors
  the existing `max_index`/`ensure_index` idiom, and gives one place where the
  identity set is decided rather than five call sites that could each forget.
  It resets to 1 on lock, which is the safe direction: a session that never
  raises it behaves exactly as a single-identity wallet.
- **A failed frontier push does not count as "identities loaded".**
  `_syncFrontier` returns whether the handle accepted the frontier, and
  `_identitiesLoaded` is set from that. Scanning narrow is the safe failure,
  but remembering the failure as success would make it permanent for the
  session — funds on later identities would stay hidden until the next unlock.
  A missing *address string* does not block the flag: the frontier is already
  in, so detection still works; only the QR is unavailable.
- **Discovery is three-valued, not a list.** "Searched and found nothing" and
  "could not search" must not collapse into one answer. `StealthDiscovery`
  distinguishes found / failed / superseded, because this runs at the moment a
  user is asking whether a restore recovered their money, and reporting an
  unreachable explorer as "no funds found" is the worst available lie. The
  truncated-list case is a failure too: an identity absent from partial data is
  not evidence of an unfunded identity.
