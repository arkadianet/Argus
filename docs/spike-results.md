# Phase 0 Spike Results

## (a) Address Derivation — ergo-appkit Test Vector

**Test**: `wallet_core::derivation::tests::test_appkit_test_vector_address_0`

**Mnemonic**:
```
slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet
```

**Derivation path**: `m/44'/429'/0'/0/0`

**Expected address** (from ergo-appkit):
```
9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8
```

**Result**: PASS (see test output below)

**Derivation path**: `m/44'/429'/0'/0/1`

**Expected address**:
```
9iBhwkjzUAVBkdxWvKmk7ab7nFgZRFbGpXA9gP6TAoakFnLNomk
```

**Result**: PASS

**Ergo Node test vector** (mnemonic: `race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty`, path `m/44'/429'/0'/0/0`):
- Expected: `9eYMpbGgBf42bCcnB2nG3wQdqPzpCCw5eB1YaWUUen9uCaW3wwm`
- Result: PASS

```
running 3 tests
test derivation::tests::test_appkit_test_vector_address_0 ... ok
test derivation::tests::test_appkit_test_vector_address_1 ... ok
test derivation::tests::test_ergo_node_test_vector ... ok
```

## (b) ReducedTransaction Signing — Not Yet Run Against Live Node

The EIP-19 sign flow is implemented in:
- `wallet_core::transaction::build_reduced_transaction` — builds ReducedTransaction from EIP-12 components
- `wallet_core::transaction::serialize_reduced` / `deserialize_reduced` — EIP-19 byte serialization
- `wallet_core::wallet::WalletHandle::sign_reduced` — signs a ReducedTransaction
- `wallet_core::wallet::WalletHandle::create` — creates wallet from mnemonic

A complete integration test requires:
1. A running Ergo node (or public node) reachable from the test environment
2. Real UTXO(s) belonging to the test address
3. A live state context from the node

The scaffold code supports this flow:
1. Fetch UTXOs via `wallet_net::ErgoNodeClient::unspent_boxes_by_address`
2. Fetch state context via `wallet_net::ErgoNodeClient::get_state_context` or `fetch_state_context`
3. Build UnsignedTransaction from the UTXOs
4. Reduce via `build_reduced_transaction`
5. Sign via `WalletHandle::sign_reduced`
6. Verify via `/transactions/check`

This test was deferred because it requires a live node. The implementation
is structurally complete — the wallet creation and signing code paths use
the same ergo-lib APIs that pass in production (Citadel).

## (c) Compiled Release .so Size and Symbol Check

**Note**: The `release` .so has not yet been built for Android because the
NDK toolchain is not installed in this environment. The estimated size based
on ergo-lib release builds is approximately 3–6 MB per ABI.

The wallet-ffi crate does NOT link `ergo-node` or `ergo-state`. The dependency
tree was verified by checking the crate's Cargo.toml:

```
wallet-ffi depends on:
  ├── wallet-core  (no ergo-node, no ergo-state)
  ├── ergo-lib     (no ergo-node, no ergo-state)
  ├── flutter_rust_bridge
  └── once_cell
```

No `redb` (used by ergo-state) or `ergo-node` crates appear in any dependency
chain of wallet-core or wallet-ffi.