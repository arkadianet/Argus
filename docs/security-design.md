# Security Layer Design

## Overview

Argus keeps signing keys in Rust. The Flutter shell stores an AES-GCM sealed
seed blob in Android Keystore (`EncryptedSharedPreferences`) or iOS Keychain.
That platform store is the confidentiality boundary.

The sealed blob is AES-256-GCM ciphertext plus nonce (`v: 2`). The wrap key is
never stored in plaintext after setup. A device PIN derives an Argon2id KEK
(19 MiB, t=2, p=1) that AES-GCM-wraps the wrap key (`pin_wrap` in
Keystore/Keychain). Optional biometrics keep a convenience copy of the wrap
key after a PIN unwrap. v1 blobs that still embed `k` are accepted on restore
for migration. Do not log or export the wrap key, PIN, or mnemonic.

No mnemonic is persisted. Create/restore require the user to enter or confirm
the BIP-39 phrase in the UI (Dart treats that string as secret: no logging,
controllers cleared on dispose). Phrase screens set `FLAG_SECURE` / hide
captured content. The wallet locks when the app backgrounds.

## Lifecycle

1. **Create**: BIP-39 checksum is validated. PBKDF2 produces a 64-byte seed.
   The seed is sealed with a random AES key. Ciphertext and the PIN-wrapped
   key go to Keystore. EIP-3 children `m/44'/429'/0'/0/0..32` are loaded
   into the prover.
2. **Unlock**: Flutter unwraps the wrap key with the PIN (or a biometric copy)
   and calls `wallet_restore`. Rust decrypts and reloads EIP-3 children.
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
