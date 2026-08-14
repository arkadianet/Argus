# Security Layer Design

## Overview

Argus uses a split-security model: Android Keystore / iOS Keychain holds the
encrypted seed blob; Rust is the only component that ever sees the mnemonic or
produces signatures. No secret (mnemonic phrase, seed bytes, private key)
crosses the Flutter-Rust bridge as a Dart-visible value.

## Keystore / Keychain Wrap-vs-Sign Split

```
┌─────────────────────────────────────────────────────┐
│                  Flutter Shell                       │
│  (Dart) — no ssecrets beyond a function call)        │
│                                                      │
│  • Stores EncryptedSeed JSON blob in Keystore        │
│  • Passes blob to Rust on unlock                     │
│  • Receives opaque u64 handle ID                     │
│  • Receives base58 address strings                   │
│  • Receives serialized transaction bytes             │
│  • NEVER sees mnemonic or seed as String/Uint8List   │
└──────────────────────┬──────────────────────────────┘
                       │ FRB (opaque handles + bytes)
┌──────────────────────▼──────────────────────────────┐
│                    Rust Core                         │
│                                                      │
│  • Derives encryption key from seed (Argon2id)       │
│  • Decrypts seed blob → reconstructs wallet          │
│  • Derives addresses                                 │
│  • Builds & reduces transactions                     │
│  • Signs (produces proofs)                           │
│  • Encrypts seed for re-storage                      │
│  • Zeroizes secrets on lock                          │
└─────────────────────────────────────────────────────┘
```

## In-Rust Encryption / Wipe Lifecycle

1. **Wallet creation**: mnemonic → PBKDF2 (BIP-39) → 64-byte seed.
   The seed is immediately encrypted via `AES-256-GCM` using a key derived
   with `Argon2id(password=seed[..32], salt=random)`.
   The `EncryptedSeed {nonce, ciphertext, salt}` is serialized to JSON and
   returned to Flutter for storage in Keystore/Keychain.
   The mnemonic and seed are dropped (Rust `drop()`).

2. **Unlock**: Flutter fetches the encrypted seed JSON from Keystore, passes
   it to Rust via FRB (`wallet_restore`). Rust re-derives the decryption key
   (from the 64-byte seed, which it reconstructs via the stored encrypted
   data). The wallet is reconstituted as a `WalletHandle` with an opaque u64
   ID returned to Flutter.

3. **Lock**: Flutter calls `wallet_lock(handle_id)`. Rust sets the
   `Option<UnlockedWallet>` to `None`, dropping `Wallet` and `ExtSecretKey`
   from memory.

## Opaque Handle Design

- The Dart side stores a `Map<int, int>` mapping local identifiers to Rust
  handle IDs.
- Rust maintains `HANDLES: Mutex<HashMap<u64, WalletHandle>>`.
- On create/restore, a new handle ID is allocated; the `WalletHandle` is
  inserted into the map.
- All operations take `handle_id: u64` and look up the handle on the Rust
  side.
- `wallet_lock` consumes the handle (removes from map + drops secrets).

## Biometric Enrollment Change — Failure Mode

If the user's biometric enrollment changes (add/remove fingerprint, face,
etc.), Android Keystore may invalidate the key that wraps the encrypted seed
blob. When this happens:

1. Flutter attempts to load the encrypted seed from Keystore.
2. Keystore throws `KeyPermanentlyInvalidatedException`.
3. Flutter catches this and prompts the user to re-enter their 12/24-word
   mnemonic phrase.
4. The phrase is passed directly to Rust via `wallet_create` (never stored
   in Dart).
5. Rust re-generates the encrypted seed blob (with fresh Argon2 salt + AES
   nonce).
6. The new encrypted blob is stored in Keystore under a newly generated key.

**The mnemonic phrase is the ultimate recovery mechanism.** Without it, the
wallet cannot be restored if Keystore invalidates the wrapping key.

## Security Properties

- **No secret in Dart heap**: The mnemonic enters Rust `String`, is converted
  to seed via `Mnemonic::to_seed`, and the `String` is dropped. Dart only
  sees opaque handle IDs and derived public data (addresses, tx bytes).
- **AES-256-GCM with random nonce**: Every encryption produces a unique
  ciphertext even for identical seeds.
- **Argon2id key derivation**: Memory-hard KDF protects against offline
  attacks on the stored ciphertext.
- **Encrypted at rest, decrypted only in Rust**: The seed blob is useless
  without the Argon2-derived key, which requires the original seed bytes
  (themselves derived from the mnemonic).
- **Lock drops keys**: `WalletHandle::lock()` sets `inner=None`, dropping
  the `Wallet` (secret keys) and `ExtSecretKey` from process memory.