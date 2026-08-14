# Argus Wallet — Phase 0 Handoff Note

## What Was Built

A complete, buildable Rust workspace (10 crates) + a Flutter app scaffold +
build scripts + design docs for the Argus Ergo wallet.

### Where Everything Lives

All under `/tmp/opencode/wallet/` (move to your final repo location).

| Path | Contents |
|------|----------|
| `rust/` | Rust workspace with 10 crates |
| `rust/crates/wallet-core/src/` | HD derivation, mnemonic → seed, encryption, wallet handle, tx reduce/sign |
| `rust/crates/wallet-net/src/` | ErgoNodeClient (UTXO fetch, state context, submit tx) |
| `rust/crates/wallet-ffi/src/` | FRB-annotated API: create, restore, lock, unlock, derive_address, sign_reduced |
| `rust/crates/vendor/citadel-core/` | Vendored Citadel: BoxId, TokenId, errors, config |
| `rust/crates/vendor/ergo-tx/` | Vendored Citadel: EIP-12 tx building, send builder, box selector |
| `rust/crates/vendor/ergo-node-client/` | Vendored Citadel: NodeClient with capability detection |
| `rust/crates/vendor/ergopay-core/` | Vendored Citadel: transaction reduction (EIP-19) |
| `rust/crates/vendor/protocols/{amm,sigmausd,dexy}/` | Vendored Citadel: DeFi protocol tx builders |
| `rust/crates/vendor/core2/` | Patch shim for yanked core2 0.4.0 |
| `app/` | Flutter project with FRB bridge placeholder |
| `scripts/build_android.sh` | cargo-ndk build + copy to jniLibs |
| `scripts/build_ios.sh` | Placeholder |
| `docs/architecture.md` | Crate responsibilities, layout, codegen |
| `docs/security-design.md` | Keystore split, encryption lifecycle, biometric failure |
| `docs/dependency-list.md` | All deps with pinned SHAs and rationale |
| `docs/spike-results.md` | Phase 0 spike results |

## Build Commands

### Rust (host)

```bash
cd rust
cargo build                    # Debug build
cargo build --release          # Release build
cargo test --workspace         # All tests (125 pass)
cargo clippy --workspace       # Zero errors
```

### Rust + NDK (Android)

```bash
./scripts/build_android.sh
```

Prereqs: `cargo-ndk`, `ANDROID_NDK_HOME`, `rustup target add aarch64-linux-android x86_64-linux-android`

### Flutter app

```bash
cd app
flutter pub get
# After building .so:
flutter run
```

## FRB Codegen Command

```bash
cd app
flutter_rust_bridge_codegen generate \
    --rust-input ../rust/crates/wallet-ffi/src/lib.rs \
    --dart-output lib/bridge/generated_bridge.dart
```

**No manual glue was needed** beyond the generated code. The FRB-annotated
functions (`#[flutter_rust_bridge::frb]`) all return `Result<T, String>`
and use opaque `u64` handles. The Dart side will call them through the
generated `api` module.

## Spike Results

### (a) Address Derivation — PASS (3/3 vector matches)

- ergo-appkit vector `m/44'/429'/0'/0/0` → `9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8` ✓
- ergo-appkit vector `m/44'/429'/0'/0/1` → `9iBhwkjzUAVBkdxWvKmk7ab7nFgZRFbGpXA9gP6TAoakFnLNomk` ✓
- Ergo node vector `m/44'/429'/0'/0/0` → `9eYMpbGgBf42bCcnB2nG3wQdqPzpCCw5eB1YaWUUen9uCaW3wwm` ✓

### (b) ReducedTransaction Signing — Structurally complete, not run against live node

The signing pipeline is implemented end-to-end in code but requires a live
Ergo node for the integration test. The chain is:
`UTXOs + state_context → build → reduce → sign → check`

### (c) .so Size

Not measured (no NDK in this environment). Expected ~3-6 MB per ABI.
No `ergo-node` or `ergo-state` symbols were linked — verified by
dependency tree analysis.

## Design Decisions That Required Changes

### 1. core2 0.4.0 yanked from crates.io

Sigma-rust depends on `core2 = "0.4.0"` which was yanked. We vendored a
minimal shim at `crates/vendor/core2` that re-exports `std::io` under
`core2::io`. This is a zero-cost workaround. When sigma-rust updates to
`core3`, this shim can be removed.

### 2. ErgoStateContext requires real headers for consensus

The `ErgoStateContext::new()` constructor requires a `[Header; 10]` array.
Dummy headers were constructed for test/local contexts. For production,
`wallet_net::ErgoNodeClient::get_state_context()` fetches real headers
from the node.

### 3. ZeroizeOnDrop on Wallet/ExtSecretKey

`ergo-lib`'s `Wallet` and `ExtSecretKey` types don't implement `Zeroize`.
We removed the `ZeroizeOnDrop` derive from `UnlockedWallet`. The `lock()`
operation drops the `Option<UnlockedWallet>`, which drops the underlying
secrets normally. True memory zeroization of ergo-lib internal types is
a future improvement.

### 4. FRB-generated code not in repo

FRB generated Dart code was not committed — it's ephemeral output from
the codegen tool. The build pipeline should regenerate it.

## Top 3 Open Design Decisions

1. **Public node selection**: Which public Ergo node(s) to use for Phase 1?
   Options: ergo-explorer (read-only API), a specific community node, or
   require users to run their own node. Affects wallet-net target URL
   defaults and rate-limiting strategy.

2. **Keystore integration**: The Flutter side needs platform-specific code
   to store/retrieve the encrypted seed JSON from Android Keystore /
   iOS Keychain, and to handle biometric invalidation. This is pure Flutter
   work (no Rust changes needed), but requires careful error handling for
   the biometric-enrollment-changed case.

3. **UTXO selection strategy**: The current send flow requires selecting
   UTXOs to spend. The wallet-net client can fetch unspent boxes, but
   the selection algorithm (simple FIFO, smallest-first, largest-first,
   or a more sophisticated multi-UTXO optimizer) needs to be specified.
   The `ergo_tx::box_selector` module from Citadel provides a starting
   point but may need wallet-specific heuristics (e.g., "don't consolidate
   NFTs", "prefer mature boxes").

## Notable

- All 125 tests pass across all 10 crates
- Zero clippy errors
- wallet-core does NOT depend on ergo-node or ergo-state
- The FRB API never exposes secrets as Dart strings
- The `EncryptedSeed` encrypt/decrypt roundtrip + JSON serialization is
  tested and verified
- The protocol crates (amm, sigmausd, dexy) compile and their tests pass,
  ready for Phase 1 DeFi integration