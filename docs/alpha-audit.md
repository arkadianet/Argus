# Argus Alpha Audit

**Scope:** first-party Rust (`wallet-core`, `wallet-net`, `wallet-ffi`), Flutter shell, Android/iOS secure storage, and the Citadel send/fee path the wallet actually calls. Vendored AMM/SigmaUSD/Dexy crates were reviewed only where they affect the live send path.

**Verdict:** this is a Phase 0/1 scaffold with a working address-derivation core. It is **not a spendable wallet**. The published security model is internally contradictory, restore cannot unlock a stored seed, signing uses the BIP-32 master key instead of EIP-3 children, and the send UI claims a broadcast that never happens. Do not put real funds on this build.

---

## What is solid

- EIP-3 address derivation matches the ergo-appkit and Ergo node test vectors (`m/44'/429'/0'/0/{0,1}`).
- Crate split (core / net / ffi) is the right shape, even if `wallet-core` already pulls `tokio`, `ergo-tx`, and `ergopay-core`.
- FFI handle IDs are opaque `u64`s; the *intent* of keeping secrets out of Dart is correct.
- Android `EncryptedSharedPreferences` + iOS Keychain is a reasonable at-rest layer (the Rust AES layer on top of it is not).
- `ArgusError` JSON codes are a good Dart contract.
- `reqwest` uses rustls, not native-tls.

These do not offset the P0 issues below.

---

## P0 — funds, keys, or the product claim

### 1. Seed “encryption” is circular and restore is impossible

`SeedBox::from_mnemonic` and `create_encrypted_seed` encrypt the 64-byte seed with a key derived from **the first 32 bytes of that same seed**:

```36:38:rust/crates/wallet-core/src/seed.rs
        let encrypted =
            super::EncryptedSeed::encrypt(&seed, &seed[..32])
                .map_err(|e| CoreError::Encryption(e.to_string()))?;
```

Decrypt requires that same 32-byte prefix. Anyone who can decrypt already has the seed. Anyone who only has the ciphertext (Keystore/Keychain) cannot decrypt.

The Flutter unlock path then passes an empty key and a comment that is false:

```86:88:app/lib/ui/dashboard_screen.dart
      // keyMaterial is derived inside Rust from the stored blob.
      // For now, use a placeholder that triggers Rust-side key derivation.
      await walletService.restoreWallet(json, []);
```

`wallet_restore` will fail AES-GCM. After process death, the wallet cannot be unlocked. The security design (`docs/security-design.md` §Unlock) claims Rust “reconstructs the 64-byte seed via the stored encrypted data.” That is cryptographically impossible.

**Correct model:** Keystore/Keychain *is* the wrap. Either store the raw seed blob there, or encrypt with a user PIN / random wrap key that is itself Keystore-held. Never derive the AES key from the plaintext you are encrypting.

### 2. Signing uses the master key, not EIP-3 children

Addresses are derived at `m/44'/429'/0'/0/index`. The `Wallet` prover is loaded with only the BIP-32 **master** secret:

```29:36:rust/crates/wallet-core/src/wallet.rs
    pub fn create(mnemonic: MnemonicPhrase, passphrase: &str) -> Result<Self, CoreError> {
        let wallet = Wallet::from_mnemonic(mnemonic.as_str(), passphrase)
            .map_err(|e| CoreError::Mnemonic(e.to_string()))?;
        // ...
        let ext_secret_key =
            ExtSecretKey::derive_master(seed).map_err(|e| CoreError::Derivation(e.to_string()))?;
```

Pinned `ergo-lib` (`7f927613`) implements `from_mnemonic` as `Wallet::from_secrets(vec![ext_sk.secret_key()])` — master only. `restore_from_seed` does the same. P2PK boxes at the displayed address cannot be signed. Every send will fail at `sign_reduced_transaction`.

**Fix:** for each used index, `ext_sk.derive(eip3_path(index))` and `wallet.add_secret(child.secret_key())`. Do this on create, restore, and after discovery.

### 3. Quick-create never shows the mnemonic

`_quickCreate` generates a 12-word phrase, creates the wallet, encrypts it, and drops the phrase. There is no backup screen, no confirmation re-entry, no export. Combined with (1), a killed process means the seed is gone and the user never saw it.

### 4. Empty-wallet UI advertises a public test address

When no seed is stored, the dashboard calls `test_derive_display()` and shows the well-known appkit vector address `9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8` as “Your Address”. Receive / QR / copy all use that string. Anyone who funds it sends to a published test mnemonic.

`test_derive_display` should not exist in the production FFI surface.

### 5. Send never broadcasts, but the UI says it did

`send_erg` builds, reduces, signs, and returns JSON. `ErgoNodeClient::submit_transaction` is never called from FFI. `SendScreen` then:

```78:78:app/lib/ui/send_screen.dart
                    Text('Transaction submitted', style: theme.textTheme.titleLarge),
```

The user is told the tx is on-chain. It is not. There is also no preview of outputs, miner fee, or change before the sign call.

### 6. Release APK has no `INTERNET` permission

`INTERNET` is only in `debug` / `profile` manifests. The main manifest has none. A release build cannot reach a node. `build.gradle.kts` also signs release with the **debug** keystore.

### 7. Every send spends every UTXO and strips NFT registers

`build_send_tx` is called with the full 500-box fetch. `ergo_tx::box_selector` exists and is unused. Change outputs are built with `additional_registers: HashMap::new()`. Any EIP-4 NFT / royalty / artwork box that is swept loses R4–R9 and is destroyed as an NFT.

`get_eip12_utxos` also fabricates `transaction_id = 0x00..00` and `index = 0` for every box, and drops registers. Reduction happens to use the second, real `ErgoBox` fetch for input box IDs, so the fake txId is currently unused — until someone wires EIP-12 signing that trusts those fields.

### 8. Two independent UTXO fetches can disagree

`send_erg` fetches EIP-12 boxes, builds outputs from those totals, then fetches `unspent_boxes_by_address` again for reduction. `reduce_transaction_with_context` zips the two lists and silently drops the tail if lengths differ. A box arriving or disappearing between calls produces an unsigned tx whose inputs do not match the output accounting. That is an invalid-tx or value-mismatch bug, not a theoretical race.

---

## P1 — security model, fees, discovery

### 9. Secrets cross the Dart heap on every create

`generate_mnemonic` returns a `String` to Dart. `wallet_create` / `create_encrypted_seed` take that `String` back. `docs/security-design.md` (“No secret in Dart heap”) is false for the only create path that exists. FRB will copy the phrase into a Dart `String` regardless of comments on the Rust side.

If the goal is “mnemonic never in Dart”, generation and confirmation must stay in Rust (or a platform view that never assigns the phrase to a Dart variable). If the goal is a normal backup UI, drop the claim and treat Dart as a secret-handling surface (no logs, no screenshots, zeroize controllers).

### 10. Undisclosed Citadel developer fee on every Argus send

Production `resolved_config()` enables a **0.011 ERG** output to `9eoLQ6FFKJPqZXeBFvd3CKu7DRfXavKo7n9PFkVypSmXgD6ActU` unless `CITADEL_DEV_FEE_ENABLED=false`. A Flutter app will not have that env var. The send UI never mentions it. Unit tests disable the fee (`#[cfg(test)]` → disabled), so CI will not catch this.

Argus should default the fee **off**, or show it as a first-class line item with an explicit opt-in.

### 11. Sender / change address is trusted from Dart

`send_erg(handle_id, sender_address, ...)` does not check that `sender_address` was derived from `handle_id`. Change is paid to `sender_tree`. A bug or compromised shell can redirect change. Derive the change address from the handle (or verify membership in the discovered set) on the Rust side.

### 12. Address discovery is not BIP-44

- Pre-derives **1000** addresses while holding the handle lock, then always reports `scanned_up_to: 999`.
- `next_unused_index = 1000 - consecutive_empty` (e.g. 980 after a gap of 20). Wrong.
- “Used” means “has UTXOs now.” An address that received and spent everything looks empty. `gap_limit` consecutive spent-empty addresses hide later funded indices. Discovery must use transaction history, not current UTXOs.

### 13. Keystore / Keychain does not match the design

| Claim | Reality |
|---|---|
| Biometric wrap | Android `MasterKey` has no `setUserAuthenticationRequired`. iOS uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with no `SecAccessControl` biometry. |
| `KEY_INVALIDATED` on enrollment change | Android maps any exception whose message contains `"KeyStore"`. iOS never emits `KEY_INVALIDATED`. |
| Hardware Keystore wrap-vs-sign split | `EncryptedSharedPreferences` (Tink, `security-crypto:1.1.0-alpha06`). Fine for at-rest, not the described biometric key. |

`apply()` is async; a kill immediately after save can drop the blob (the only copy, given (1) and (3)).

### 14. iOS secure-storage plugin is registered incorrectly

```11:11:app/ios/Runner/AppDelegate.swift
    SecureStorageHandler.register(with: self)
```

`register(with:)` wants `FlutterPluginRegistrar`. `AppDelegate` is a `FlutterPluginRegistry`. This should not compile. Scene-based lifecycle (`SceneDelegate: FlutterSceneDelegate`) may also mean the channel is never attached even after a signature fix. Use `registrar(forPlugin:)`.

### 15. FRB bindings are gitignored; clean checkout cannot build the app

`.gitignore` excludes `app/lib/bridge/frb_generated*.dart` and `rust/crates/wallet-ffi/src/frb_generated.rs`. `wallet_service.dart` imports them. `wallet-ffi/src/lib.rs` has `mod frb_generated;`. There is no codegen step in the Android/iOS scripts. Handoff claims “complete, buildable” Flutter + Rust.

### 16. No mnemonic checksum; strength is not a BIP-39 value

`MnemonicPhrase::new` accepts any string. `Mnemonic::to_seed` PBKDF2s it without validating the checksum. A typo creates a wallet no other EIP-3 wallet will restore.

`generate_mnemonic` clamps strength to `[128, 256]` but does not snap to `{128,160,192,224,256}`. `MnemonicGenerator::new(..., 200)` fails.

### 17. `wallet_lock` does not consume the handle

Design: “removes from map + drops secrets.” Code: sets `inner = None` and leaves the entry. The id cannot be unlocked in place; restore allocates a new id. Locked handles leak until process exit. Dart `lock()` also fires the FRB future and ignores it.

### 18. State context uses `Parameters::default()`, not the node’s parameters

`get_state_context` pads missing headers by cloning `headers[0]` and always uses default parameters. Reduction / script evaluation can disagree with what the network will accept after parameter votes.

---

## P2 — correctness, hygiene, ops

| # | Issue | Where |
|---|---|---|
| 19 | `EncryptedSeed::from_json` `copy_from_slice` panics if nonce/salt hex is the wrong length | `encryption.rs` |
| 20 | `ZeroizeOnDrop` on `EncryptedSeed` zeroizes ciphertext, not seed. Comment is wrong. `MnemonicPhrase` is not zeroized. `seed_arr` in restore is not zeroized. | `encryption.rs`, `seed.rs`, `wallet.rs` |
| 21 | Handle IDs are sequential from 1. Predictable; fine only while the process is trusted. | `api.rs` |
| 22 | Almost every FFI path `.unwrap()`s a `Mutex`. Poison = panic across the isolate. | `api.rs`, `wallet.rs` |
| 23 | History “value” is `outputs[0].value`, not net vs self. Balance is never fetched (`_balance` stays null). Amounts are nanoERG in the UI. | `client.rs`, `dashboard_screen.dart`, `send_screen.dart` |
| 24 | Bottom nav can open Send/Receive while locked, using a stale or test address. | `dashboard_screen.dart` |
| 25 | `TransactionsScreen._load` reads `ModalRoute.of(context)` from `initState` with no post-frame callback. | `transactions_screen.dart` |
| 26 | `wallet-core` depends on `tokio` and never uses it. `transaction.rs` imports a pile of unused types; its only test is an empty stub. | `Cargo.toml`, `transaction.rs` |
| 27 | `ergo-node-interface` is an unpinned git dep. Docs claim a SHA; `Cargo.toml` has none. | `rust/Cargo.toml` |
| 28 | Default node `https://ergo-explorer-01.ergonode.net` is an explorer-shaped hostname with no fallback, pinning, or user setting. | `wallet-net/src/client.rs` |
| 29 | iOS script builds device `aarch64` only, copies a raw `.a`, and leaves Xcode linking as a note. No xcframework / sim. | `scripts/build_ios.sh` |
| 30 | Android ABI filter is `arm64-v8a` + `x86_64` only (no 32-bit, no physical x86). | `build.gradle.kts` |
| 31 | Widget test pumps `ArgusApp` and expects “Argus” without initializing FRB; will fail or hang once `init()` is forced. | `app/test/widget_test.dart` |
| 32 | Docs drift: `sha2 0.0.10`, “125 tests / zero clippy”, “FRB never exposes secrets”, “Keystore wrap-vs-sign”. | `docs/*` |

---

## Design doc vs code

`docs/security-design.md` describes a product that was not built:

1. Encrypted blob is not decryptable from the blob alone.
2. Mnemonics are Dart `String`s.
3. Lock does not remove handles.
4. Biometric invalidation is not implemented.
5. `ergo-lib` types are not zeroized (handoff already admits this; the security doc still implies wipe).

Treat those docs as a target spec, not as documentation of the current tree.

---

## Recommended order

Do not add DeFi, tokens, or polish until the wallet can create, backup, restore, sign, and broadcast one ERG payment on mainnet against a known vector.

1. **Kill the circular KDF.** Store seed under platform wrap only, or wrap with a user secret. Delete `keyMaterial` from the Dart restore API.
2. **Load EIP-3 child keys into `Wallet`** on create/restore/discover. Add a sign test against a fixture reduced tx (no live node required).
3. **Mnemonic backup UI** before the seed is persisted. Validate BIP-39 checksum. Remove `test_derive_display` from the app.
4. **One UTXO fetch → select (not sweep) → reduce → sign → submit.** Preview fee + change. Verify change address in Rust. Default Citadel fee off or disclose it.
5. **Preserve registers** on change; never select NFT boxes unless the user is sending that token.
6. **Discovery via tx history + real gap index.**
7. **Commit FRB output or generate it in the build scripts.** Add `INTERNET` to the main manifest. Stop signing release with debug keys.
8. Rewrite `docs/security-design.md` to match the implementation you actually ship.

Until 1–4 are done, this should stay labeled **non-custodial prototype / do not fund**.
