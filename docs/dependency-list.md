# Dependency List

Pinned SHAs and version rationale for every dependency.

## Git dependencies

| Crate | Source | SHA / Ref | Rationale |
|-------|--------|-----------|-----------|
| `ergo-lib` | `github.com/ergoplatform/sigma-rust` | `eccb8eac97fecae3cd09b2240805ae112963a6c7` (develop, 2026-09-02) | Develop SHA, not a release; see below |
| `ergo-chain-types` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergotree-ir` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergotree-interpreter` | sigma-rust | same SHA | Pinned with ergo-lib |
| `sigma-ser` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-merkle-tree` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-nipopow` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-rest` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-node-interface` | `github.com/arkadianet/ergo-node-interface-rust` | `0264f6ffcb954da135960460d942f4c804ed65c9` | Rust Ergo node HTTP wrapper |

### Why sigma-rust stays a Git dependency

Checked on 2026-10-06. The newest crates.io release is still `ergo-lib` 0.28.0
(2024-08-09), 191 commits before the previous pin. It cannot replace the pin:

- its `ergo-chain-types` 0.15.0 requires `url ~2.2`, while reqwest needs
  `url ^2.4`, so the workspace does not resolve;
- with that requirement relaxed locally, Argus still fails to compile: it uses
  APIs added on develop after 0.28.0 (`ec_point::exponentiate_gen`,
  `Wscalar::{to_bytes, from_bytes}`, `EcPoint: Copy`,
  `ergotree_ir::chain::context_extension`).

The pin is the newest develop commit whose crates are still versioned 0.28.x
(merge of PR #916). Its library code differs from the previous pin
`7f927613` only by replacing the yanked `core2` with `core3 =0.1.2`, which let
the vendored `core2` shim go.

Later develop commits (head `1633e018`, 2026-09-15) bump the crates to 0.29.0
ahead of a release and fix signing-relevant issues: `ContextExtension`
serialization order for five or more entries (the node otherwise rejects the
signature), validation of reduced transactions before signing, and the
ErgoTree version used during reduction. `ergo-node-interface` requires
`ergo-lib = "0.28.0"`, and Cargo cannot patch a 0.29 crate into that
requirement, so moving past this pin first needs the fork to depend on 0.29.
A local trial with only that one-line change to the fork built the workspace
and passed the same tests as this pin. Once `ergo-lib` 0.29.0 is on crates.io
and the fork depends on it, switch to the release.

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
| `sha2` | 0.10 | SHA-256 (BIP-39 checksum) |
| `hmac` | 0.12 | HMAC for BIP-32 |
| `aes-gcm` | 0.10 | Seed blob sealing (AES-256-GCM, random wrap key) |
| `rand` | 0.8 | Random nonces and salts |
| `reqwest` | 0.12 (rustls-tls, json) | HTTP client for node queries |
| `flutter_rust_bridge` | 2.x | Dart-Rust FFI bridge |
| `once_cell` | 1 | Lazy statics |
| `indexmap` | 2 | Orrdered map |
| `num-bigint` / `num-traits` | 0.4 / 0.2 | Big integer math |

## Former patch: core2

sigma-rust used to depend on `core2 = "0.4.0"`, which was yanked from
crates.io, so Argus vendored a shim at `crates/vendor/core2` and patched it in.
The current sigma-rust pin depends on `core3` instead, so the shim and its
`[patch.crates-io]` entry were removed.