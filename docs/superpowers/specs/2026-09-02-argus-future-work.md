# Argus future work

Date: 2026-09-02 (updated the same day after Phases B–E landed)
Status: plan; Phases B, C, D and E.3 shipped in alpha.19, Phase A deferred by
decision, E.1 and E.2 deferred for the reasons under "Deferred"
Build context: `v1.0.0-alpha.19` (versionCode 4020), debug-signed

This follows the 2026-08-15 go-to-wallet roadmap. That document set four
layers: money always works, dApps open Argus, craft, DeFi. As of alpha.18
layers 1, 3 and most of 4 exist; layer 2 (ErgoPay) does not. This plan
orders what comes next and says why.

## Where alpha.18 stands

Shipped in alpha.18 (PRs #26–#29):

- Wallet sync lives in `WalletSyncController` with an enum phase and 17
  unit tests. Polling no longer rescans addresses or probes every node.
- Send uses the shared confirm sheet, validates recipients in a pure
  function, and can sign without broadcasting.
- Home has real tabs (Wallet, Activity, Swap, Settings), capped assets,
  persisted hide-balances, token icons, sync age.
- Tokens open a detail sheet with copy, explorer and send-this-token.
- Test count 120 → 172. `flutter analyze` is clean.

Still true, and the biggest gaps:

| Gap | Why it matters |
|---|---|
| No ErgoPay / EIP-12 / ErgoAuth | dApps still say "use Nautilus". This was layer 2 in the roadmap and has been skipped in favour of DeFi screens. |
| Every alpha is debug-signed | A store or release key cannot update over the installed base. The longer this runs, the more testers must wipe and restore. |
| Nothing is device-tested before release | Each release note says "still not tested on a device". Alpha.18 is the same. |
| `send_screen`, `dexy_screen`, `utxo_management_screen` are 1200–1450 line state classes | Same shape the dashboard had before #26; UI work in them is slow and untested. |
| No iOS build | Roadmap deferred it; still deferred. |

## Ordering principle

Ship what makes the wallet usable by someone else before what makes it
nicer for us. Every item below has a done-criterion a tester can check on
a phone.

## Phase A — Trust and verification (next, small)

1. **On-device smoke test before every release.** Add
   `docs/release-checklist.md` with the flows the last four PR
   descriptions listed (unlock, pull-to-refresh, wallet switch, delete
   last wallet, tab back button, ERG send, token send, two-recipient
   send, Sign only, token sheet → Send). A release is not tagged until
   the checklist is run on one physical device. This costs an hour per
   alpha and stops shipping regressions we cannot see.
2. **Release signing.** Create the Argus release keystore, keep it out
   of git (`.env` already gitignored), sign `alpha.19` with it, and
   announce in the release note that alpha.19 requires uninstall +
   restore from phrase. Do it once, early, while the tester count is
   small. The build.gradle already supports it.
3. **Widget smoke test of the home shell.** `DashboardScreen` is not
   widget-tested because it initialises Rust in `initState`. Give it a
   `WalletSyncGateway`-style seam for `walletService.init` so a test can
   render the gate, unlock into tabs, and switch tabs.

Done when: alpha.19 is release-signed, the checklist exists and was run,
and a widget test renders the tab shell.

## Phase B — ErgoPay (the missing layer)

This is the roadmap's layer 2 and the single largest product gap.

1. **Deep link intake.** `ergopay://` and `https://` app links in the
   Android manifest; a QR path from the existing scanner. Parse the
   EIP-20 request (`reducedTx`, `address`, `message`, `replyTo`).
2. **Reduce and summarise.** `ergopay-core` already reduces; add the
   human summary the confirm sheet needs: to, amount, tokens, fee, and
   the dApp's message. Reuse `ConfirmTransactionSheet`.
3. **Sign and respond.** PIN or biometric → sign → POST to `replyTo` or
   broadcast, with the same "broadcast may have failed" guard as send.
4. **ErgoAuth** after ErgoPay works, because some dApps need identity
   before a transaction.
5. **Address selection.** ErgoPay requests can name an address; map it
   to the wallet's derived indices and refuse with a clear message when
   it is not ours.

Done when: a real request from a public dApp (Spectrum or an auction
house) is signed in Argus and the dApp accepts it. Tests: request
parser, summary builder, reply encoder, all pure.

## Phase C — Code health for velocity

Do these as the first step of whichever feature touches the file, the
way #26 preceded the home redesign.

1. **Send screen controller.** Move quote debounce, recipient drafts,
   spend-address selection and the prepare/confirm/broadcast state
   machine out of `_SendScreenState` into a tested `SendController`.
   `buildRecipients` already exists as the seed.
2. **UTXO management and Dexy screens.** Same split. Each has three
   prepare/confirm flows that duplicate the sheet-building code.
3. **Route arguments.** `WalletRouteArgs` is passed as a snapshot to
   every pushed route, so a pushed screen never sees a balance update.
   Now that `WalletArgsScope` exists, wrap the `MaterialApp` navigator
   in it (fed by the sync controller) and stop passing snapshots.
4. **Theme tokens.** Fifteen call sites compute `muted` and `dark` by
   hand. Add a `ThemeExtension` with `muted`, `cardBorder`,
   `surfaceInset` so tiles stop re-deriving them.
5. **Dependency refresh.** `flutter_rust_bridge` 2.11 → 2.13 (regenerate
   the bridge), `share_plus` 11 → 13, `mobile_scanner`, `qr_flutter`.
   Do this on a device-testable branch after Phase A.1 exists.

Done when: no `lib/ui` file exceeds ~600 lines and each screen's state
machine has unit tests.

## Phase D — Craft, round two

Items from the 2026-09-02 audit not yet done, in order of user impact:

1. **Receive screen.** QR card is hard-coded light in dark mode; the
   amount field duplicates the parser (`parseErgToNano` exists); the
   used-addresses list should use `AssetTile`-style rows with labels
   and a copy affordance.
2. **Activity detail.** History JSON has no fee or counterparty. Extend
   the Rust history builder to return `fee_nano_erg` and the primary
   counterparty address so the detail screen can show "To 9abc… · fee
   0.0011", and show token amounts sent, not only received.
3. **Empty and error states.** Home "No activity yet" and Activity
   "Could not load activity" are plain text. Give them an icon, a
   sentence, and an action (Receive / Retry / Check nodes).
4. **Amount entry.** The roadmap's layer-3 keypad with fiat toggle was
   never built; the send form still uses a plain text field. Worth it
   once ErgoPay exists, because both flows share the confirm sheet.
5. **Discover cards.** Static three cards. Show the user's own
   positions (Dexy LP, SigmaUSD holdings) when non-zero, otherwise the
   marketing card.

## Phase E — Platform reach

1. **iOS.** `build_ios.sh` is a placeholder and `SecureStorageHandler.
   swift` exists. Needs a Mac; TestFlight once ErgoPay works, because
   ErgoPay is the reason a phone wallet gets recommended.
2. **Testnet toggle** in Settings → Network, so dApp developers can test
   ErgoPay against Argus without real funds.
3. **Watch-only wallets as first-class entries** in the wallet list
   (today they are a summed balance on the gate only).

## Status after alpha.19

| Phase | State |
|---|---|
| A trust | Deferred by decision. Still the first thing to do before wider testing. |
| B ErgoPay | Shipped (#30). ErgoAuth and `#MULTIPLE_ADDRESSES#` not built. |
| C code health | Shipped (#31). `flutter_rust_bridge` still 2.11 (needs a matching codegen install and native rebuild) and `share_plus` still 11 (13.3.0 fails to compile its Android sources in this Gradle setup). |
| D craft | Shipped (#32). |
| E.1 iOS | Deferred: needs a Mac. |
| E.2 testnet | Deferred: see below. |
| E.3 watch-only entries | Shipped (#33). |

### Deferred: testnet toggle

A network toggle is not a Settings switch. The mainnet prefix is baked
into address derivation (`wallet-core/derivation.rs`), address parsing
(`wallet-net/client.rs`), the ErgoPay summariser, the Dart address regex,
and the per-wallet address cache inside the unlocked handle; every stored
`address0` and cache snapshot is mainnet; and the Dexy, AgeUSD and AMM
contract constants exist only on mainnet, so those screens would have to
be hidden. Landing that without a device to test address correctness on
is the wrong trade. Do it as its own spec after Phase A, with the
protocol screens gated off on testnet.

## Explicitly not now

Unchanged from the roadmap: browser extension, mixing, multi-sig,
hardware keys, PIN-lockout wipe, node crawlers. Add: a second visual
system, a Dexy/AMM feature before ErgoPay exists.

## Suggested alphas

| Tag | Contents |
|---|---|
| `alpha.18` | Shipped. Sync controller, send flow, tabs, token sheets. Debug-signed. |
| `alpha.19` | Phase A: release-signed, checklist run on device, home shell widget test. Requires reinstall. |
| `alpha.20` | Phase B.1–B.3: ErgoPay sign and reply. |
| `alpha.21` | Phase B.4–B.5 + Phase C.1 (send controller). |
| `beta.1` | Phase C complete, Phase D.1–D.3, dependency refresh. |
| `1.0.0` | External review, store listing, iOS TestFlight. |

## Next document

A Phase B design spec: ErgoPay request model, address resolution, reply
transport, and the confirm summary. Not a UI redesign.
