# Argus go-to wallet roadmap

Date: 2026-08-15
Status: roadmap (no implementation plan yet)
Branch context: `feat/v1-runnable-wallet`, Alpha 0 (`v1.0.0-alpha.0`)

This is the product sequence for making Argus the wallet people recommend on Ergo. It is not a sprint plan. Each layer is a separate spec → plan → ship cycle. Do not start layer N+1 until the layer below can be used with real (small) funds without surprise.

## What exists today

Alpha 0 is a single-wallet mainnet client:

- Create / restore 24-word EIP-3 wallet, PIN wrap (Argon2id), optional biometrics, auto-lock, screenshot block on phrase screens
- Discover used addresses (gap 20, max index 256), receive = next unused, send change = that unused address
- Balance, tokens, NFTs, recent activity
- Send ERG or one token / NFT from **one** sender address (the used address with the most ERG)
- Watchful / Ledger themes, Settings for palette only
- Debug-signed Android APK

It is not a daily driver. It is a working proof that the path exists.

## How nodes work today

Argus is a **light client**. It does not run a node and it does not gossip. It talks HTTP to explorer-compatible public APIs.

Hardcoded in `wallet-net`:

| Role | URL | Used for |
|---|---|---|
| Default nodes | `https://ergo-node.eutxo.de`, `https://ergo-node.zoomout.io`, `https://ergo1.oette.info`, `https://node.sigmaspace.io` | UTXOs, height, history, broadcast (HTTPS + extraIndex) |
| User-added | `https://host` or `http://ip:port` | Same, if the operator adds one in Settings |
| Explorer | `https://api.sigmaspace.io` | Token name / decimals, and Open in explorer |

`ErgoNodeClient::connect(preferred)` tries preferred (if any), then the two candidates, and keeps the first that answers `current_height()`. The Flutter UI never passes a preferred URL, so every call is `connect(None)`.

There is **no** node list in Settings, **no** add/remove, **no** display of which host won, **no** persisted last-good node, **no** testnet, **no** peer discovery. "Discovery" in this repo means HD address gap scan, not finding nodes.

That is the correct architecture for a phone wallet. Bitcoin-style P2P peer finding is the wrong model here. Public Ergo wallets use a short list of known HTTP APIs plus a user override. Layer 1 makes that list visible and editable. It does not invent a new discovery protocol.

## What "go-to" means

Nautilus is the incumbent (extension + dApps). A go-to Argus is the app someone opens when they get paid, when they pay, and when a dApp says "connect wallet" on a phone.

That requires, in order:

1. Money always works (this layer)
2. dApps open Argus (ErgoPay)
3. The app feels inevitable (craft)
4. Ergo-native actions live in the same place (DeFi)

UI polish and Spectrum on a wallet that cannot spend from address #2, or that silently depends on one public host, will not displace anyone.

## Layer 1 — Daily driver

Goal: a careful person can hold and move ERG/tokens without fighting the app or the network.

### Nodes

- Persist a node list. Ship the two current public hosts as defaults. User can add, disable, reorder, or remove (cannot remove the last enabled host).
- On launch and on pull-to-refresh, probe enabled hosts (`/info` height). Use the first healthy one. Remember last-good for the next cold start.
- Show the active host and height in Settings, and a small status on the ledger (height or "offline").
- Optional custom explorer URL for token metadata (default is `api.sigmaspace.io`).
- Mainnet only in this layer. Testnet is a later toggle, not a second product.

Out of scope: running a local node, DNS seeder, automatic scrape of random IPs.

### Spend

- `prepare_send` selects UTXOs across **all owned used addresses**, not one sender. Change still goes to the current unused receive address.
- If funds are split, the user should not have to know which address holds them.
- Keep the existing prepare → confirm → `send_erg(preparation_id)` consume path.
- Miner fee stays the protocol default in this layer. A fee picker is layer 3.

### Send / receive completeness

- Send: scan a QR (address or `ergo:` URI), paste, MAX, show fee and change on confirm.
- Receive: keep unused-address QR; add share sheet.
- Activity: one tx screen with id, height, timestamp, net ERG, tokens, copy, open in explorer.
- Distinguish confirmed (has height) from not-yet-in-a-block. No fake "pending" if the API did not say so.
- Settings: show recovery phrase after PIN; enable/disable biometrics (already partly there); lock.

### Trust ops

- Release-sign the next APK (`ARGUS_KEYSTORE` via local `.env`, never committed). Alpha 0 is debug-signed; a store key will not update over it.
- Keep the unaudited-prototype strip until an external review exists.

### Done when

A wallet that received on two addresses can send the combined ERG in one tx. Settings shows the live node and height. A phone can scan a receive QR and pay it. Activity opens a real tx. The next published APK is release-signed.

## Layer 2 — dApp wallet

Goal: Spectrum, auction houses, and other Ergo apps open Argus instead of "use Nautilus".

- Implement ErgoPay / EIP-12: receive an unsigned tx (deeplink / QR / HTTPS), show human summary, PIN to sign, return or broadcast.
- ErgoAuth if the dApp needs identity, not only a tx.
- Multiple wallets on one device (separate PIN-wrapped seeds). Layer 1 stays one wallet.
- Address book (label + address) used by send and ErgoPay.

Out of scope: WalletConnect-on-EVM, browser extension. Phone first.

### Done when

A real ErgoPay request from a public dApp can be signed in Argus and the dApp accepts the result.

## Layer 3 — Craft

Goal: the same flows feel like a product someone keeps, not an alpha with a theme.

Some honesty UI is already in layer 1 (node, height, tx detail). Layer 3 is feel:

- Amount entry: large Newsreader, keypad, fiat toggle (ERG/USD or ERG/EUR from a quoted source, display-only).
- Confirm send / ErgoPay: one screen you can read in two seconds (to, amount, fee, node).
- Empty states that say what to do, not "No transactions found".
- Activity grouping by day; copy that is product language, not `Unlocked (discovery unavailable)`.
- Haptics on unlock / broadcast; keep fade routes, no bounce.
- Fiat is never consensus. If the quote feed is down, hide it.

World-class here is restraint: one accent, two palettes, money as the only loud number. Do not add a second visual system.

### Done when

A new user can create, back up, receive, and send without reading a status string, and the confirmation is unambiguous.

## Layer 4 — DeFi

Goal: Ergo-native actions without leaving Argus.

Vendored builders already exist (`amm`, `sigmausd`, `dexy`). They stay unused until layers 1–2 are real.

Order inside this layer:

1. Token / NFT detail (explorer metadata, send, open in explorer) — small, useful, no AMM
2. Spectrum swap via ErgoPay or in-app builder, user-visible price impact and fees
3. SigmaUSD redeem/mint
4. Dexy only if 2–3 are used

Every DeFi action uses the same prepare/confirm/PIN path as send. No hidden Citadel fee (`DevFeeConfig::disabled()` stays unless we add an explicit, disclosed Argus fee later).

### Done when

A user can swap on Spectrum from Argus without a browser wallet, and can explain the fee line on the confirm screen.

## Explicitly not now

- Browser extension
- Mixing / stealth addresses
- Multi-sig
- Hardware keys
- iOS TestFlight (needs a Mac and Apple account; keep the xcframework script)
- Wiping the wallet on PIN lockout
- Automatic public-node crawlers
- Replacing the user's `.env`

## Suggested alphas

| Tag | Meaning |
|---|---|
| `v1.0.0-alpha.0` | Shipped. Proof the path exists. Debug-signed. |
| `v1.0.0-alpha.1` | Layer 1. Release-signed. Daily driver. |
| `v1.0.0-alpha.2` | Layer 2. ErgoPay. |
| `v1.0.0-beta.1` | Layer 3 craft on top of 1–2. |
| `v1.0.0` | External review + store listing. DeFi can land in 1.1. |

## Risks that already exist

- Public nodes rate-limit and drift. A visible list is the mitigation, not a hidden retry.
- One-address spend will look like a "missing balance" bug the first time someone restores a used wallet. Fix that in layer 1 before any UI craft sprint.
- Alpha 0's debug signature trains testers to install a key we must abandon. Say so on every debug build; switch at alpha.1.
- ErgoPay is how you win mobile. Spectrum-in-app without ErgoPay still loses desktop users.

## Next document

When this roadmap is accepted, the next file is a **layer 1 only** implementation spec (nodes, multi-address select, send/receive completeness, release signing). Not ErgoPay. Not DeFi. Not a visual rewrite.
