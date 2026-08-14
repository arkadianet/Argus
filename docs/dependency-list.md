# Dependency List

Pinned SHAs and version rationale for every dependency.

## Git dependencies

| Crate | Source | SHA / Ref | Rationale |
|-------|--------|-----------|-----------|
| `ergo-lib` | `github.com/ergoplatform/sigma-rust` | `7f927613c5a72bf6ea93b95cf9987129a03dd4ba` (develop) | Pinned develop SHA matching Citadel's approach |
| `ergo-chain-types` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergotree-ir` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergotree-interpreter` | sigma-rust | same SHA | Pinned with ergo-lib |
| `sigma-ser` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-merkle-tree` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-nipopow` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-rest` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-node-interface` | `github.com/arkadianet/ergo-node-interface-rust` | `0264f6ff...` (HEAD) | Rust Ergo node HTTP wrapper |

## Vendored Citadel crates (path deps)

All vendored from `github.com/arkadianet/citadel` commit `f533f15`.

| Crate | Vendored path | Notes |
|-------|---------------|-------|
| `citadel-core` | `crates/vendor/citadel-core` | Types, errors, config |
| `ergo-tx` | `crates/vendor/ergo-tx` | EIP-12 tx building |
| `ergopay-core` | `crates/vendor/ergopay-core` | Transaction reduction (EIP-19) |
| `ergo-node-client` | `crates/vendor/ergo-node-client` | Node API client |
| `amm` | `crates/vendor/protocols/amm` | Spectrum DEX (vendored for future use) |
| `sigmausd` | `crates/vendor/protocols/sigmausd` | AgeUSD stablecoin (vendored for future use) |
| `dexy` | `crates/vendor/protocols/dexy` | Dexy (vendored for future use) |

## Crates.io dependencies

| Crate | Version | Purpose |
|-------|---------|---------|
| `tokio` | 1.40 (rt-multi-thread, macros, sync) | Async runtime |
| `serde` / `serde_json` | 1.0 | Serialization |
| `thiserror` | 1 | Error handling |
| `anyhow` | 1 | Error handling |
| `tracing` | 0.1 | Logging |
| `tracing-subscriber` | 0.3 | Logging |
| `hex` | 0.4 | Hex encoding |
| `base16` | 0.2 | Base16 encoding |
| `zeroize` | 1.8 (zeroize_derive) | Secret zeroing |
| `sha2`| 0.0.10 | SHA-256 hashing |
| `hmac` | 0.12 | HMAC for BIP-32 |
| `argon2` | 0.5 | Key derivation (seed encryption) |
| `aes-gcm` | 0.10 | Seed blob encryption (AES-256-GCM) |
| `rand` | 0.8 | Random nonces and salts |
| `reqwest` | 0.12 (rustls-tls, json) | HTTP client for node queries |
| `flutter_rust_bridge` | 2.x | Dart-Rust FFI bridge |
| `once_cell` | 1 | Lazy statics |
| `indexmap` | 2 | Orrdered map |
| `num-bigint` / `num-traits` | 0.4 / 0.2 | Big integer math |
| `core2` | 0.4.0 (patched, vendored) | Shim for sigma-rust no_std io (original yanked) |

## Patch: core2

The `core2 = "0.4.0"` crate was yanked from crates.io. We vendor a minimal shim
at `crates/vendor/core2` that re-exports `std::io` under the `core2::io` module,
sufficient for sigma-rust when built with `std` (our default target).
This is a zero-cost workaround; the shim will be removed when sigma-rust
updates to `core3` or drops the dependency.