# Dependency List

Pinned SHAs and version rationale for every dependency.

## Git dependencies

| Crate | Source | SHA / Ref | Rationale |
|-------|--------|-----------|-----------|
| `ergo-lib` | `github.com/ergoplatform/sigma-rust` | `1633e01835d48e4d4b127f7478e602e129e80110` (develop head, 2026-09-15) | Unreleased 0.29.0; see below |
| `ergo-chain-types` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergotree-ir` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergotree-interpreter` | sigma-rust | same SHA | Pinned with ergo-lib |
| `sigma-ser` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-merkle-tree` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-nipopow` | sigma-rust | same SHA | Pinned with ergo-lib |
| `ergo-rest` | sigma-rust | same SHA | Pinned with ergo-lib |

The `[patch.crates-io]` entries for the same SHA no longer change anything:
nothing from crates.io depends on sigma-rust since `ergo-node-interface` went
(below). They stay so that any future crates.io dependent resolves to the pin
instead of compiling a second sigma-rust.

### Why sigma-rust stays a Git dependency

Checked on 2026-10-06. The newest crates.io release is still `ergo-lib` 0.28.0
(2024-08-09), 191 commits before `7f927613`, the pin Argus started from. It
cannot be used:

- its `ergo-chain-types` 0.15.0 requires `url ~2.2`, while reqwest needs
  `url ^2.4`, so the workspace does not resolve;
- with that requirement relaxed locally, Argus still fails to compile: it uses
  APIs added on develop after 0.28.0 (`ec_point::exponentiate_gen`,
  `Wscalar::{to_bytes, from_bytes}`, `EcPoint: Copy`,
  `ergotree_ir::chain::context_extension`).

The pin is develop head, whose crates are versioned 0.29.0 ahead of a release.
Compared with `eccb8eac`, the pin before it, it carries these fixes; the first
three affect what Argus signs:

- `ContextExtension` entries are serialized in the node's (Scala 2.12 HashMap)
  order when an input has five or more of them; before, the bytes to sign
  differed from the node's and it rejected the signature
  (`wallet-core/tests/context_extension_order.rs` pins this through Argus's
  EIP-12 conversion);
- reduced transactions are validated (input counts, extensions) before JSON
  acceptance, serialization, signing and deterministic commitments, and
  deterministic signing refuses unsupported reductions instead of falling back
  to random proofs;
- reduction evaluates with the ErgoTree's own version, so version-3 trees
  (protocol 6.0, active on mainnet: block version 4) reduce like the node;
- header PoW checks reject a zero difficulty, and checked 256-bit unsigned
  arithmetic is fixed.

`eccb8eac` was the newest commit still versioned 0.28.x, which
`ergo-node-interface` required. That dependency is gone (next section), so the
pin follows develop. Switch to the crates.io release once 0.29.0 is published.

### Node interface (formerly `ergo-node-interface`)

Argus used the `arkadianet/ergo-node-interface-rust` fork (Git, `0264f6f`) for
node REST calls. The part Argus uses is now `wallet_net::node_interface`, a
port of that code onto `wallet_net::http`, so every node request uses the same
rustls/ring/webpki-roots stack and there is a single reqwest version. The port
keeps the fork's behaviour: endpoints, request headers, `Url::join`
resolution, the 30 s timeout, the extraIndex probe and guard, parsing
responses whatever their status, and its error messages. Before the fork was
removed, every ported call was run through both implementations against the
same responses (recorded mainnet headers, error bodies, unreachable nodes,
probing) and against the four default mainnet nodes, with identical results.
`wallet-net/src/node_interface_tests.rs` keeps those expectations, including
state contexts built from recorded `/blocks/lastHeaders/10` responses in
`wallet-net/tests/fixtures/`.

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

Locked versions as of 2026-10-06, each the newest stable release unless noted.
The toolchain is Rust 1.99.0 (`rust/rust-toolchain.toml`).

| Crate | Requirement | Locked | Purpose |
|-------|-------------|--------|---------|
| `tokio` | 1.53 (rt-multi-thread, macros, sync) | 1.53.2 | Async runtime |
| `futures` | 0.3 | 0.3.34 | Async utilities |
| `serde` / `serde_json` | 1.0 | 1.0.229 / 1.0.151 | Serialization |
| `thiserror` | 2 | 2.0.21 | Error handling |
| `anyhow` | 1 | 1.0.104 | Error handling |
| `tracing` | 0.1 | 0.1.44 | Logging |
| `tracing-subscriber` | 0.3 | not used by any crate | Logging |
| `hex` | 0.4 | 0.4.3 | Hex encoding |
| `base16` | 0.2 | 0.2.1 | Base16 encoding |
| `base64` | 0.23 (wallet-core) | 0.23.1 | Cold-signing transport |
| `bs58` | 0.5 (rosen, stealth) | 0.5.1 | Base58 addresses |
| `zeroize` | 1.9 (zeroize_derive) | 1.9.0 | Secret zeroing |
| `sha2` | 0.11 | 0.11.0 | SHA-256 (BIP-39 checksum, stealth, Rosen) |
| `hmac` | 0.13 | not used by any crate | HMAC |
| `argon2` | 0.6 | 0.6.0 | PIN key derivation (Argon2id) |
| `aes-gcm` | 0.11 | 0.11.1 | Seed blob sealing (AES-256-GCM, random wrap key) |
| `rand` | 0.10 | 0.10.3 | Keys, nonces, salts, handle ids (`SysRng`) |
| `reqwest` | 0.13 (rustls-no-provider, json) | 0.13.5 | HTTP client for node queries |
| `rustls` / `webpki-roots` | 0.23 (ring, std, tls12) / 1 | 0.23.45 / 1.0.9 | TLS config for reqwest, see below |
| `flutter_rust_bridge` | =2.13.0 | 2.13.0 | Dart-Rust FFI bridge (see `flutter-toolchain.md`) |
| `once_cell` | 1 | 1.21.4 | Lazy statics |
| `indexmap` | 2 | 2.14.2 | Ordered map |
| `num-bigint` / `num-traits` | 0.5 / 0.2 | 0.5.1 / 0.2.19 | Big integer math (amm) |

Versions held back on purpose, because the value crosses into sigma-rust's API:

- `stealth` depends on `rand = "0.8"` (0.8.8): it passes `OsRng` to
  `random_scalar_in_group_range`, which takes a rand_core 0.6 RNG.
- `wallet-core` and `wallet-net` depend on `num-bigint = "0.4"` (0.4.8): they
  build `AutolykosSolution`, whose `pow_distance` is a num-bigint 0.4 `BigUint`.

reqwest 0.13 no longer offers rustls with bundled roots, and its remaining
rustls features use the platform verifier, which needs JNI setup on Android.
`wallet_net::http` therefore hands every client a rustls config with the ring
provider and webpki-roots, the configuration reqwest 0.12's `rustls-tls` built.
Create clients with `wallet_net::http::client_builder()` or `client()`, not
`reqwest::Client::builder()`/`new()`, which panic without a crypto provider.
reqwest 0.13.5 is the only reqwest in `Cargo.lock`.

## Former patch: core2

sigma-rust used to depend on `core2 = "0.4.0"`, which was yanked from
crates.io, so Argus vendored a shim at `crates/vendor/core2` and patched it in.
The current sigma-rust pin depends on `core3` instead, so the shim and its
`[patch.crates-io]` entry were removed.