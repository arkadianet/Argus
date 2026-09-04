# Stealth addresses in Argus: as built

Date: 2026-09-04
Status: implemented, not yet exercised on a device or against mainnet funds.
Supersedes section 1 of `2026-09-04-privacy-stealth-and-mixer-exploration.md`,
which is the exploration this implements.

## The scheme

A receiver holds a secret `x` and publishes `u = g^x`. A sender picks random
`r` and `y` and pays a one-time box guarded by

```
proveDHTuple(g^r, g^y, u^r, u^y)
```

Only the receiver can recognise the box (`gr^x == ur && gy^x == uy`) and only
the receiver can prove the tuple. Every payment lands on a different script,
so nothing on chain links two payments to the same receiver or to the
published key.

Reference implementation, matched byte for byte: ErgoMixer's
`mixer/app/stealth/StealthContract.scala` and `mixer/app/helpers/StealthUtils.scala`
in github.com/ergoMixer/ergoMixBack.

## Formats

**Published address.** `"stealth"` + Base58(`u` ‖ blake2b256(`u`)[..4]), with
`u` in compressed SEC-1 form (33 bytes), so the payload is 37 bytes and the
string is 57–58 characters. Identical to ErgoMixer, so its users can pay an
Argus stealth address and vice versa.

**Payment ErgoTree.** `1004 0e21<gr> 0e21<gy> 0e21<ur> 0e21<uy> ceee7300ee7301ee7302ee7303`
— header `10` (v0, constant segregation), constant count `04`, four
`Coll[Byte]` constants holding compressed points, then
`CreateProveDHTuple(DecodePoint(ph0), …, DecodePoint(ph3))`. A test asserts a
generated tree matches ErgoMixer's own regex
`(1004)((0e21)[a-fA-F0-9]{66}){4}(ceee7300ee7301ee7302ee7303)`.

The tree is handed to the existing send builders as a **P2S address**, so
stealth payments go through the ordinary single- and multi-send paths with no
special casing below the recipient list.

## Derivation

`m/44'/429'/0'/3'/0`.

The exploration proposed this path and asked whether sigma-rust could express
it. It can: `DerivationPath`'s `FromStr` accepts an arbitrary sequence of
hardened and normal indices, and `ExtSecretKey::derive` walks it from the
master key, so the path is used verbatim with no approximation. EIP-3 payment
keys live at `m/44'/429'/0'/0/i`, where the fourth element is the fixed normal
`change` index 0; putting a *hardened* `3'` in that position lands on a branch
no EIP-3 wallet ever walks, so `x` can never double as the signing key of an
address the wallet displays. A test asserts the stealth scalar differs from
the index-0 payment key.

The key is derived on demand from the unlocked wallet's root and dropped with
the value it produced. It is never cached, persisted, or logged; `Debug` on
`StealthSecret` prints `*****`. `r` and `y` are drawn inside
`build_payment_tree_hex` and never returned to any caller.

## Detection

`GET <explorer>/api/v1/boxes/unspent/byErgoTreeTemplateHash/<hash>?limit=500`
where `<hash>` is `sha256(ceee7300ee7301ee7302ee7303)` =
`210681f345e06655d54106373f6c401ebe35d17854ed7148bdcef50df24fd89b`
(asserted by a unit test). At the time of writing the endpoint returns 20
unspent boxes on mainnet.

Dart owns the HTTP call — it already holds the configured explorer and can
degrade gracefully — and hands the raw body to Rust, which parses the boxes
and tests each one against `x` locally. The explorer learns that someone asked
for the public list; it never learns which boxes are ours.

Degradation is deliberate and tested: an unreachable explorer leaves
`stealthBalanceUnknown` true and the previous figure on screen, and never
changes the wallet's `SyncPhase`. With the scan switched off in Settings the
explorer is not called at all and a zero stealth balance is honest.

## Spending

Stealth boxes are signed through the existing `sign_reduced` path with one
extra secret per input: `SecretKey::DhtSecretKey(DhTupleProverInput { w: x,
common_input: ProveDhTuple::new(gr, gy, ur, uy) })`.

`CachedPreparation` gained a `stealth_trees: Vec<String>` field holding the
ErgoTree hex of each stealth input — public data. At signing time
`sign_prepared_tx` re-derives `x` from the unlocked wallet, builds one DHT
prover input per tree, and signs with a throwaway `Wallet` carrying the
wallet's own keys plus those extras; the throwaway is dropped immediately.
When `stealth_trees` is empty the code path is byte-identical to before, and a
test asserts a normal P2PK send still signs.

`wallet-core` has a test that a stealth input **cannot** be signed by the
wallet's ordinary keys and **can** be signed once the DHT secret is supplied.

## What the app does

- **Receive**: a Stealth address section with the string, a QR, copy, a
  one-paragraph explainer (what it hides, what it does not, that detection
  needs the explorer), the current stealth balance or "unknown", and a
  *Sweep stealth funds* button when there is something to sweep.
- **Send**: `stealth…` strings are accepted as recipients (single and
  multi), a fresh one-time payment address is derived per payment at build
  time, and the confirm sheet shows a *Stealth payment* row naming the
  published string. Contacts can store stealth strings.
- **Sync**: every discover/refresh runs the scan alongside balances; owned
  ERG and tokens appear in the asset list, each token knowing how much of it
  sits in stealth boxes, and the token detail sheet says so. The restore
  flow lands in the same `_afterUnlock` path, so a restored wallet scans on
  its first refresh.
- **Settings → Security**: a *Scan for stealth payments* switch, default on,
  with a note that it queries the explorer.

## Decisions taken along the way

- **Stealth funds are not in ordinary coin selection.** They are shown in the
  asset list and in `totalNanoWithStealth`, but `spendableNano` — what the
  Send form validates against — stays the P2PK balance. Offering stealth
  amounts to a builder that cannot spend them would produce transactions that
  fail at signing. Sweeping first is the supported route.
- **The sweep accepts a single box.** Consolidation requires two inputs; one
  stealth receipt is the common case, so `build_sweep` is its own builder
  rather than a reuse of `build_consolidate_tx`.
- **No implementor fee.** ErgoMixer's stealth withdrawal pays its operator a
  percentage (`stealthImplementorFeePercent`). Argus's sweep pays only the
  miner fee and Argus's own flat app fee, like every other Argus transaction.
  This does not affect interoperability: the fee lives in ErgoMixer's
  withdrawal transaction, not in the address format or the script.
- **Dart owns the explorer call.** Keeping HTTP out of the Rust stealth path
  makes the degradation policy testable and reuses the configured explorer.

## Not done

- **Spent-box history.** Activity does not yet show stealth receipts or
  sweeps as stealth; they appear as ordinary transactions. The exploration's
  `byErgoTreeTemplateHash` + `spent` lookup is unimplemented.
- **Stealth boxes in general coin selection.** Only the sweep spends them.
- **Change to a fresh stealth box.** Change from a sweep goes to a normal
  wallet address, which links the swept amount to that address.
- **Multiple stealth identities per wallet.** One key per wallet, at index 0
  of the stealth branch. The path leaves room for more.
- **Testnet.** Payment addresses are encoded with the mainnet prefix.
- **Pagination.** The explorer query takes a single page of 500; the live set
  is tens of boxes, so this has not been exercised at the limit.
- **Device testing.** Nothing in this change has run on a phone or moved
  mainnet funds. The signing path is proven by a synthetic reduced
  transaction in `wallet-core`, not by a broadcast.
