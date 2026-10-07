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
   Only the user's action unlocks: the app opens on the wallet overview with
   nothing unlocked, opening a seed wallet asks for its key once, and a
   cancelled prompt waits for an explicit Unlock or the PIN. Nothing prompts
   on launch or on resume; a biometric sheet itself pauses and resumes the
   activity, so a prompt on resume reopens the sheet it just closed.
3. **Lock**: The handle is removed from the process map and secret keys are dropped.

## Signing

`ergo-lib::Wallet::from_mnemonic` only loads the BIP-32 master key. Argus does
**not** use that. It derives EIP-3 children and `add_secret`s them. Sends
verify the sender address belongs to the handle.

## Phrase entry on restore

The restore screen checks the phrase as it is typed through one sync FFI call,
`check_mnemonic`, into the same Rust validator `MnemonicPhrase::parse` uses
(`wallet-core/src/bip39.rs`), so the screen and the wallet cannot disagree.

- **Normalisation** (`bip39::normalize_words`): zero-width and other invisible
  format characters (ZWSP, ZWJ/ZWNJ, BOM, soft hyphen, direction marks) are
  dropped; NFKD folds NBSP, ideographic and other Unicode spaces to a space and
  full-width letters to ASCII; anything not a letter or combining mark (digits,
  commas, full stops, brackets) separates words, so a pasted `1. abandon 2)
  ability,` list works; everything is lower-cased. A clean English phrase is
  unchanged byte for byte, so no phrase that restored before derives a
  different seed now.
- **Per word**: each word not in the list is reported by 1-based position with
  up to three suggestions: the list word sharing its first four letters (unique
  in BIP-39), then words within two edits (insert, delete, substitute, swap).
  The word still being typed is not flagged. Tapping a suggestion rewrites the
  field with the normalised words.
- **Continue** checks count and checksum and says which failed; a checksum
  failure is explained as one wrong word or a wrong order.
- **Languages**: all ten official BIP-39 lists are embedded (from
  bitcoin/bips, sha256 of the English list 2f5eed53…). The phrase is checked
  against the list holding most of its words; English wins a tie. Non-English
  phrases are accepted on restore — the BIP-39 seed is PBKDF2 over the NFKD
  words joined by spaces whatever the list (NFKD turns the Japanese ideographic
  space into a space, so the bip32JP vectors hold), and the Ergo node lets its
  operator choose the phrase language — but only when every word is in that one
  list and its checksum holds. Argus itself only creates English phrases.
- The phrase field uses a password keyboard (`visiblePassword`), no
  suggestions, autocorrect, smart punctuation or IME learning. Words cross the
  bridge only in memory; nothing logs or stores them. The BIP-39 passphrase
  field explains that it is not a wallet password, can be shown, and warns
  when it starts or ends with a space (spaces are significant).

## Legacy (pre-1627) derivation

Early Scala Ergo wallets — the ergo node wallet and everything built on
ergo-appkit / sigma-state's `ExtendedSecretKey` before ergoplatform/ergo#1627
— did not follow BIP-32 exactly. In `ExtendedSecretKey.deriveChildSecretKey`
the child key was stored as `BigIntegers.asUnsignedByteArray(childKey)`, which
drops leading zero bytes, and a **hardened** child derivation hashes
`HMAC-SHA512(chainCode, 0x00 || parent.keyBytes || ser32(i))` with those short
bytes, where BIP-32 uses the 32-byte `ser256(k)`. The fix pads to 32 bytes
(`asUnsignedByteArray(32, childKey)`); old wallets keep the bug behind
`usePre1627KeyDerivation = true` (node secret file, appkit
`withMnemonic(..., usePre1627KeyDerivation)`). The master key is never trimmed
(`deriveMasterKey` keeps the raw HMAC slice), and non-hardened steps hash the
public key, so on the EIP-3 path `m/44'/429'/0'/0/i` only two keys matter:
`m/44'` and `m/44'/429'`. If either starts with a zero byte the whole account
(every address) differs; otherwise the modes agree. Probability ≈ 1 − (255/256)²
≈ 0.78%, about 1 seed in 128.

Argus implements it in `wallet-core::derivation` as `DerivationMode::Pre1627`:
`account_key` derives `m/44'/429'/0'` with the legacy hardened steps (own
HMAC-SHA512, checked against RFC 4231 and against sigma-rust in standard mode),
and every address, discovery step and signing key comes from that account key.
Tests pin the ergo node vector (`race relax … pretty` → `9ewv8sx…` legacy,
`9eYMpbG…` standard), the sigma-state 6.0.6 intermediate keys (depth 2 is the
31-byte key), the leading-zero-master vector (modes agree), and a legacy spend
that verifies. Stealth identities and mix keys still derive from the standard
master in both modes: they are Argus-only constructions, and restoring the same
phrase in the other mode then keeps them.

- **Persisted with the seed.** The sealed blob gains `"d": "pre1627"` and the
  mode is bound into the AES-GCM tag as associated data
  (`argus-seed-derivation:pre1627`). Removing, adding or changing `d` makes the
  blob fail to open instead of deriving another wallet's addresses; an unknown
  `d` is refused. Standard blobs carry no `d` and no associated data, exactly as
  before. Wallet metadata also records `derivation: pre1627` for display, and
  the wallet's settings tell the user to turn on "legacy / pre-1627" when
  restoring the phrase elsewhere.
- **Detected on restore.** After the phrase step, `probe_restore_derivation`
  derives the first 5 addresses under both modes. If they are the same (≈127 in
  128 phrases) it answers without any network call. Otherwise it asks the
  user's node whether either set has transactions (the node only sees the
  user's own addresses) and restores legacy only when legacy alone has history;
  both, neither, or an unreachable node mean standard, with a notice saying how
  to force legacy. Advanced → "Legacy (pre-1627) derivation" forces it without
  asking the node.

## What this is not

- Not a biometric wrap-vs-sign split. Keystore/Keychain encrypts the blob at rest.
- Not memory-safe against a compromised process. `ergo-lib` types are not zeroized.
- Not a substitute for the recovery phrase. If the device store is lost, the
  phrase is the only recovery path.
