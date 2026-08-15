# Security Layer Design

## Overview

Argus keeps signing keys in Rust. The Flutter shell stores an AES-GCM sealed
seed blob in Android Keystore (`EncryptedSharedPreferences`) or iOS Keychain.
That platform store is the confidentiality boundary.

The sealed blob includes a random AES-256-GCM wrap key next to the ciphertext.
Anyone who can read the JSON can decrypt the seed. Do not log or export the
blob. A later version can wrap that key with a user PIN.

No mnemonic is persisted. Create/restore require the user to enter or confirm
the BIP-39 phrase in the UI (Dart treats that string as secret: no logging,
controllers cleared on dispose).

## Lifecycle

1. **Create**: BIP-39 checksum is validated. PBKDF2 produces a 64-byte seed.
   The seed is sealed with a random AES key and returned as JSON for Keystore.
   EIP-3 children `m/44'/429'/0'/0/0..32` are loaded into the prover.
2. **Unlock**: Flutter loads the JSON from Keystore and calls `wallet_restore`.
   Rust decrypts with the key inside the blob and reloads EIP-3 children.
3. **Lock**: The handle is removed from the process map and secret keys are dropped.

## Signing

`ergo-lib::Wallet::from_mnemonic` only loads the BIP-32 master key. Argus does
**not** use that. It derives EIP-3 children and `add_secret`s them. Sends
verify the sender address belongs to the handle.

## What this is not

- Not a biometric wrap-vs-sign split. Keystore/Keychain encrypts the blob at rest.
- Not memory-safe against a compromised process. `ergo-lib` types are not zeroized.
- Not a substitute for the recovery phrase. If the device store is lost, the
  phrase is the only recovery path.
