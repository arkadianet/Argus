# Spectrum AMM Direct Swaps — Design

Date: 2026-08-23
Branch: `feat/alpha-12`
Status: approved, pending implementation plan

## Goal

Let Argus users swap ERG and tokens directly against Spectrum AMM pools, by
spending the pool box in a single signed transaction. No proxy contracts, no
off-chain execution bots.

The vendored `amm` crate (`rust/crates/vendor/protocols/amm`, from
`arkadianet/citadel` commit `f533f15`) already implements the transaction
builders. This work wraps it in the same layers Dexy and AgeUSD use, and adds a
Swap screen.

## Scope

In scope:

- Single-hop swaps through one pool per transaction
- N2T pools (ERG ↔ token) and T2T pools (token ↔ token)
- Full pool discovery with a cached pool set
- A dedicated Swap screen

Out of scope, deliberately:

- Multi-hop routing (`router/graph.rs`, `arb_chain.rs`)
- LP deposit / redeem / pool setup / refund
- Pending-order handling (`find_pending_orders`, `find_mempool_swaps`)
- Reusing the swap engine for the Send screen's "buy & send" auto-buy

The last item is deferred, not discarded. The FFI takes a pool identifier rather
than reading Swap-screen state, so the Send screen can call the same quote and
build functions later without a rewrite.

## Architecture

```
amm crate (vendored, unchanged)
  └─ wallet-ffi/src/api_amm_impl.rs        new — thin wrapper
       └─ api.rs: amm_pools / amm_quote / amm_build_swap
            └─ frb codegen → app/lib/bridge/api.dart
                 └─ services/amm_service.dart    new
                      └─ ui/swap_screen.dart     new
```

This mirrors `api_dexy_impl.rs` and `api_sigmausd_impl.rs` exactly. The vendored
crate is not modified, so re-vendoring from citadel stays a clean copy.

### FFI surface

Three calls, matching the existing `state` / `preview` / `build` shape:

| Function | Returns |
|---|---|
| `amm_pools(node_url, force_refresh)` | Discovered pools + token metadata + `truncated` flag |
| `amm_quote(from_token, to_token, amount, slippage_pct, node_url)` | `output_amount`, `min_output`, `price_impact_pct`, `pool_id`, `box_id` |
| `amm_build_swap(...)` | Cached preparation, returns `preparation_id` |

`amm_build_swap` returns a preparation id, so signing and broadcast reuse
`walletService.signPreparation` / `sendErg` and `showConfirmTransactionSheet`.
No new signing path is introduced; swaps get the same guard rails as every other
send in Argus.

### Caching

Both caches live in Rust (`once_cell` + `RwLock`), not Dart:

- **Pool set** — TTL 60s. Refreshed on expiry or `force_refresh`.
- **Token metadata** — keyed by token id, no TTL. Token ids are immutable, so
  this only grows.

Rust-side placement keeps the token-info lookups next to the pool data, and
means the deferred Send-screen reuse inherits the cache instead of
re-implementing it in a second Dart service.

Token metadata matters more than it first appears: pools carry only token **ids**.
A usable picker needs name and decimals per token via `get_token_info`, which
across a full pool set is hundreds of lookups. These are fetched lazily for
tokens actually displayed, then cached.

## Data flow

1. Swap screen opens → `amm_pools` → cached pool set (+ truncation flag)
2. User picks from/to token and enters an amount
3. `amm_quote` → output, min output at 0.5% slippage, price impact, pool box id
4. Review → `amm_build_swap` → preparation id
5. `showConfirmTransactionSheet` → `sendErg(preparationId:)`

## Error handling

Four cases, each surfaced explicitly rather than as a generic failure:

**Node lacks the extra index.** Pool discovery calls
`unspent_boxes_by_ergo_tree`, which requires it. `NodeCapabilities.has_extra_index
== Some(false)` short-circuits with a distinct error code; the screen renders
"Your node doesn't support pool discovery" and points at node settings. Argus is
node-only for data — the explorer is used solely to build web links
(`network_controller.dart:114`) — so there is no fallback data source.

**Pool list truncated.** `discover_n2t_pools` / `discover_t2t_pools` cap at 1000
boxes each and only `tracing::warn` on overflow. The FFI returns a `truncated:
bool` so the UI can say a pool may be missing, instead of a token silently not
existing.

**Pool contention.** Direct swaps spend the pool box, so a competing swap in the
same block invalidates the transaction. Each quote carries the `box_id` it was
built from. On broadcast failure the service refetches and re-quotes once, then
surfaces "pool moved — re-quote" rather than retrying blind.

**Slippage.** `min_output` derives from a 0.5% default, matching the existing
convention in `dexy_service.dart:453`, with an override field following the
custom-miner-fee pattern already in the Send screen.

## Dev fee

Argus levies no dev fee. `api.rs:21-26` sets `CITADEL_DEV_FEE_ENABLED=false` in
`#[frb(init)] init_app()`, before any builder resolves the config, and
`load_from_env_or_default` honours that flag by returning
`DevFeeConfig::disabled()`. No work is required to keep AMM swaps fee-free.

The protection is nonetheless untested and quietly fragile. It depends on
`init_app()` running before the first builder call and on a process-global
`OnceLock` cached for the process lifetime. If init ordering changes, or frb
alters when `#[frb(init)]` fires, the fee silently re-enables and every swap
sends 0.011 ERG to `9eoLQ6FFKJPqZXeBFvd3CKu7DRfXavKo7n9PFkVypSmXgD6ActU` with
nothing in the UI to show it.

This work therefore adds a regression test asserting that **no output pays
`DEFAULT_DEV_FEE_ERGO_TREE`** (`0008cd0224f3a8…`), covering both the new AMM
builder and the existing Dexy swap builder.

The assertion deliberately pins Citadel's address rather than "no third-party
output". An Argus dev fee is planned (0.0011 ERG on any Argus transaction,
pending a P2PK). A "no extra output" test would fail the day that lands, and the
quickest fix would be deleting it — losing the Citadel guard too. Pinning the
address keeps the guard green when an Argus fee output appears beside it.

## Testing

**Rust** (`api_amm_impl.rs` wrapper):

- Quote arithmetic against known reserves
- Capability gate returns the distinct error when `has_extra_index == Some(false)`
- `truncated` flag set at the 1000-box cap
- No output pays `DEFAULT_DEV_FEE_ERGO_TREE` (AMM + Dexy builders)

Uses the crate's existing `with_test_dev_fee` harness. The vendored crate has 87
passing tests of its own; none are modified.

**Dart** (`amm_service`):

- Pool and quote JSON parsing
- Slippage → `min_output` arithmetic
- Label helpers, following `test/dexy_service_test.dart`

## Build

This is the first change in this branch that requires regenerating bindings and
rebuilding the native library:

```
flutter_rust_bridge_codegen generate
scripts/build_android.sh
```

Toolchain is present (`cargo-ndk`, `flutter_rust_bridge_codegen`, NDK
28.2.13676358). The committed
`app/android/app/src/main/jniLibs/*/libwallet_ffi.so` binaries change as part of
this work.

## Future work

Adding the planned Argus dev fee is **not** a matter of re-enabling the citadel
mechanism. `append_dev_fee_output` fires only inside allowlisted protocol
builders, so it does not cover plain sends. "Any transaction via Argus" is a
wallet-ffi-level concern and needs its own vehicle.
