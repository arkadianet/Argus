# Architecture Design

## Directory Layout

```
wallet/
├── app/                          # Flutter project
│   ├── lib/
│   │   ├── main.dart             # App entry point
│   │   ├── bridge/               # FRB generated + manual glue
│   │   │   ├── bridge.dart       # Re-export of generated bindings
│   │   │   └── generated_bridge.dart  # FRB codegen output (gitignored)
│   │   └── ui/                   # Flutter screens (Phase 1+)
│   ├── android/
│   │   └── app/src/main/jniLibs/
│   │       ├── arm64-v8a/        # libwallet_ffi.so (aarch64)
│   │       └── x86_64/           # libwallet_ffi.so (x86_64 emulator)
│   └── pubspec.yaml
│
├── rust/                         # Rust workspace
│   ├── Cargo.toml                # Workspace root + patch section
│   ├── crates/
│   │   ├── wallet-core/          # Pure domain logic (no HTTP, no FFI)
│   │   ├── wallet-net/           # Node/explorer HTTP client
│   │   ├── wallet-ffi/           # FRB crate (cdylib/staticlib)
│   │   └── vendor/               # Vendored Citadel crates
│   │       ├── citadel-core/
│   │       ├── ergo-tx/
│   │       ├── ergo-node-client/
│   │       ├── ergopay-core/
│   │       ├── core2/            # Patch for yanked core2 0.4.0
│   │       └── protocols/
│   │           ├── amm/
│   │           ├── sigmausd/
│   │           └── dexy/
│   └── target/
│
├── scripts/
│   ├── build_android.sh          # cargo-ndk → jniLibs
│   └── build_ios.sh              # Placeholder
│
└── docs/
    ├── architecture.md           # This file
    ├── security-design.md        # Keystore split, encryption lifecycle
    └── dependency-list.md        # Pinned SHAs + rationale
```

## Crate Responsibilities

### wallet-core (pure domain, no HTTP, no FFI)

- Mnemonic → seed (PBKDF2 BIP-39)
- Encrypted seed (AES-256-GCM with a random wrap key; Keystore/Keychain is the wrap)
- HD derivation (BIP-44 / EIP-3: m/44'/429'/0'/0/index)
- ergo-lib Wallet creation from seed
- Transaction reduction (EIP-12 → ReducedTransaction)
- Transaction signing (ReducedTransaction → Transaction with proofs)
- **Must NOT** depend on `ergo-node`, `ergo-state`, or any networking crate

### wallet-net (HTTP, no secrets)

- Node connection via `ergo-node-interface` (NodeInterface wrapper)
- UTXO fetching (unspent boxes by address)
- State context fetching (headers for transaction reduction)
- Transaction submission (POST /transactions)
- Token info queries

### wallet-ffi (FRB bridge)

- `cdylib` + `staticlib` crate types
- FRB-annotated functions (`#[flutter_rust_bridge::frb]`)
- Opaque handle store (`static HANDLES: Lazy<Mutex<HashMap<u64, WalletHandle>>>`)
- All functions return `Result<T, String>` for Dart consumption
- Handles are u64; signed tx data is JSON. Create/restore still take a mnemonic
  String for the backup UI (Dart must treat it as secret).

### Vendored Citadel Crates

- `citadel-core`: Shared types (`BoxId`, `TokenId`, `TxId`), errors, config
- `ergo-tx`: EIP-12 unsigned tx structs, send tx builder, box selector, dev fee
- `ergopay-core`: Transaction reduction (EIP-12 → sigma-serialized bytes)
- `ergo-node-client`: Full node API client with capability detection
- `amm`, `sigmausd`, `dexy`: Protocol tx builders (vendored for Phase 1+)

## FRB Codegen Placement

FRB generated code lives in `app/lib/bridge/generated_bridge.dart`.
It is NOT committed to git (generated at build time). The codegen command:

```bash
cd app
flutter_rust_bridge_codegen generate \
    --rust-input ../rust/crates/wallet-ffi/src/lib.rs \
    --dart-output lib/bridge/generated_bridge.dart
```

## Connection between wallet-core and wallet-net

```
wallet-ffi (FRB)
    ├── wallet-core (pure domain)
    │       ├── seed, derivation, encryption, wallet
    │       └── transaction (build, reduce, sign)
    │
    └── wallet-net (HTTP)
            ├── ErgoNodeClient (UTXO fetch, state context, submit)
            └── fetch_state_context / make_state_context
```

wallet-core never imports wallet-net. The FFI crate wires them together:
- Transaction building needs UTXOs → wallet-net fetches them
- Transaction reduction needs state context → wallet-net provides it
- Signing happens in wallet-core using wallet-net's data