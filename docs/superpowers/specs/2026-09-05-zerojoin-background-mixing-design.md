# ZeroJoin mixer, stage 2 batch D: mixing while the app is closed

Date: 2026-09-05
Status: in review. Follows `2026-09-05-zerojoin-mixer-stage2-design.md`
(batches A–C, shipped in alpha.33 and alpha.34).

## The problem

A mix takes hours or days, and today it only moves while Argus is in the
foreground, plus the ten-minute grace window, and only while the wallet
is unlocked: every remix is signed with a secret derived from the seed
inside the unlocked handle. Auto-lock ends it. A phone in a pocket does
no mixing.

## The decision: a background job with per-mix keys, opt in

Android can run periodic work with the app closed, but that work cannot
ask for a PIN, and the seed must never be readable without one. So the
job gets a smaller key.

The mix derivation path is `m/44'/429'/0'/4'/<mix>/<round>`, and both
trailing indices are soft. The extended private key one level up, at
`m/44'/429'/0'/4'/<mix>`, derives every round of that one mix and
nothing else: not another mix, not a payment key, not the stealth key.
That key is what the background job holds.

- **When** a mix enters the pool and background mixing is on, the app
  exports the mix's key from the unlocked handle into the app's
  Keystore-backed encrypted preferences, under the wallet and mix id.
  Turning the switch on exports keys for every mix already in the pool;
  turning it off deletes them all. A finished or removed mix deletes its
  key.
- **A periodic job** (WorkManager, fifteen minutes at best, network
  required) starts a headless Dart isolate, brings up the native
  library, reads each wallet's mix records, builds the chain snapshot
  exactly as the foreground does, and for each mix with a stored key
  asks the engine to observe and advance using that key. Remix and
  withdraw transactions spend only mix boxes and the operator's fee box,
  so they need no wallet key: the signer is built from the mix's round
  secrets alone. The seed is never touched.
- **What the user is told**, on the switch itself: with this on, someone
  with full access to this unlocked phone could spend the money of mixes
  in progress, and nothing else; a lost or wiped phone loses nothing,
  because every mix is recoverable from the seed. That is the trade, and
  it is off by default.
- **Withdrawal** at the end of the rounds happens in the background too,
  to the destination fixed at entry. Leaving early stays a foreground
  action.

## Why not the alternatives

A foreground service would keep the seed in memory for hours and Android
14 caps how long such services run. Storing per-round secrets instead of
the mix key would need the foreground app to top them up every round,
which defeats the purpose. ErgoMixer keeps every secret in a database;
this keeps only the keys of mixes in flight, encrypted by the hardware
keystore, deleted when they are done.

## Pieces

| Layer | Change |
|---|---|
| zerojoin | `MixKey`: the mix-level extended key. `derive(root, mix)`, `round_secret(round)`, `to_bytes` / `from_bytes` (64 bytes: secret, chain code), zeroised. Test: `MixKey::derive(root, m).round_secret(r)` equals `MixSecret::derive(root, m, r)`. |
| wallet-core | `WalletHandle::mix_key(mix_id)`. |
| wallet-ffi | `mix_export_key(handle, mix)` → hex. `mix_observe_with_key`, `mix_advance_with_key`: the same engine calls with the secret provider being the key, signing with the round secrets only, no handle. |
| Kotlin / `SecureStorageService` | `saveMixKey`, `loadMixKey`, `deleteMixKey`, `listMixKeys` in the encrypted preferences. |
| `MixService` | `backgroundEnabled` (app-wide, off). Key export on entering the pool and on switch-on; deletion on finish, remove, and switch-off. `tickHeadless()`: every wallet with stored keys, no unlock required, keyed gateway calls. |
| `MixBackground` | Registers or cancels the periodic job as the switch and the active-mix count change; the `@pragma('vm:entry-point')` dispatcher that initialises the native library, preferences and notifications, then calls `tickHeadless`. |
| Settings, Mix screen | The switch under Mixing with the exposure statement; the screen says whether a mix will move in the background. |

## Not in this batch

iOS stays foreground-only: background refresh there is not dependable.
No change to the contracts, fees or the state machine.
