# Extended-key watch-only accounts

Implemented on `feat/watch-xpub`; compare against `feat/token-send-flow`.
Single addresses and compressed-key imports retain their existing behavior.
Extended keys use a distinct account entry and preference collection.

## Format evidence and correction to the brief

Confidence is high from primary implementation sources; no physical Ergo Wallet
App device round trip was performed.

- [Ergo Wallet App ErgoFacade.kt](https://github.com/ergoplatform/ergo-wallet-app/blob/540e5edbe0e337e78474e6ce6759c482f3d66cd7/common-jvm/src/main/java/org/ergoplatform/ErgoFacade.kt)
  calls Appkit `serializeExtendedPublicKeyToHex` when exporting and
  `parseExtendedPublicKeyFromHex` on import.
- [Appkit Bip32Serialization.java](https://github.com/ergoplatform/ergo-appkit/blob/2142620416b516b728726c14eb62ab4c19730b6c/common/src/main/java/org/ergoplatform/appkit/Bip32Serialization.java)
  writes the EIP-3 **external-chain parent**, not the account key: 78 bytes
  rendered as 156 hex characters, with no checksum or Base58 encoding.
- [Appkit Address.java](https://github.com/ergoplatform/ergo-appkit/blob/2142620416b516b728726c14eb62ab4c19730b6c/common/src/main/java/org/ergoplatform/appkit/Address.java)
  derives the last EIP-3 index from this public key.
- [Appkit MnemonicSpec.scala](https://github.com/ergoplatform/ergo-appkit/blob/2142620416b516b728726c14eb62ab4c19730b6c/appkit/src/test/scala/org/ergoplatform/appkit/MnemonicSpec.scala)
  provides the literal export and seed phrase used below.

The payload is version (4 bytes), depth (1), parent fingerprint (4), child
number (4, big endian), chain code (32), compressed public key (33).
Argus accepts mainnet version `0488b21e` with either:

- depth 4, child 0: external chain `m/44'/429'/0'/0`; append only `/i`;
- depth 3, child `80000000`: account `m/44'/429'/0'`; append `/0/i`.

The latter accepts the brief's account-level key in the same raw payload
format. Base58 `xpub...`, testnet, private versions, unsupported depths/children,
wrong lengths and invalid curve points are rejected with the expected format.
Whitespace around the input and either hex case are accepted.
`ExtPubKey` has no string codec for this payload; the small parser extracts the
fields and delegates point validation and all derivation to ergo-lib.

A BIP32 payload does not prove its complete ancestor path: the fingerprint is
not verifiable without the parent. Argus interprets the supported headers as
EIP-3, as the exporting app does, while validating depth and child more strictly
than Appkit's parser. There is no checksum to detect a typo that happens to
produce another valid key. The import UI therefore asks users to verify the
first derived address against their source wallet. Do not advertise arbitrary
BIP32 imports or infer an extra `/0` from the word “account.”

## Pinned derivation vector

Upstream phrase, empty passphrase:

`lens stadium egg cage hollow noble gate belt impulse vicious middle endless angry buzz crack`

Upstream literal hex export:

`0488b21e04220c2217000000009216e49a70865823eff5381d6fd33ac96743af1f3051dc4cc8edd66a29a740860326cfc301b0c8d4d815ac721e0551304417e6133c2c9137f9f22c33895a3e1650`

Pinned public addresses at indices 0, 1, 2:

- `9hQ352ipFLWNA96FjCXPFidQrwp8gF4i9JUkrnxw6b4buVBFjVg`
- `9fzV11eLdVS1Mxzz59V7ewoar5FTLx7Eqfwh9XDfbL68DYTyfTv`
- `9etyztcGrJwrAbCg4d4fG9JisJLY73n69SVfpnWwuJUjy5vdbWC`

These address literals were computed with Argus/ergo-lib, not copied from
Appkit. The independent upstream export pins the public key and chain code;
tests also compare the parsed key to the phrase's secret-side chain key, all
20 public addresses to existing secret-side EIP-3 derivation, and account-level
and external-chain imports to each other. No address vector is regenerated at
test runtime to serve as its own expected value.

## Discovery and shared data paths

Import validates by deriving the first 20 addresses. Refresh derives batches
of 20, starting at index zero, and stops after 20 consecutive addresses without
history or funds beyond the persisted highest-used index. An address with spent
history still resets the gap. The first index after the highest used index is
Receive, matching a wallet that advances after payment rather than reserving a
new address on every screen opening. Receive runs a fresh scan before opening.

This is the payment-address case, unlike the stealth spec's “Persistence, not
gap-scan”: spent payments leave queryable transaction history. It does not prove
that no payment exists after an arbitrarily large gap. The account UI states
that limitation. Previously discovered indices are retained across launches,
so a later scan never stops before the known frontier. Unfunded addresses
published by other devices are not discoverable or reservable through an xpub.

A refresh uses the existing wallet service balance and history APIs. It sums
ERG and token integer amounts across every scanned address and deduplicates
transaction IDs. History opens the existing paginated TransactionsScreen over
the derived set; watched history does not merge the active wallet's local,
stealth or mixing transactions. No wallet handle or secret is introduced.

Any balance/history/derivation error fails the refresh and disables Receive by
clearing the snapshot, rather than returning a partial/zero balance. A node
change during refresh also invalidates it. A 10,000-address cap reports an
incomplete scan, never success. Refresh is single-flight per account and runs
on import, overview refresh and Receive. No background monitoring guarantee is
made. Snapshots are in memory; key and highest-used index are persisted.

## Privacy, scope and cold signing

The paste dialog explains that anyone holding the key can link all public
payment addresses forever. The dialog, account card and account Receive state
that the balance excludes stealth funds and the entry cannot spend. The
hardened stealth branch `m/44'/429'/0'/3'/i` is intentionally unreachable; an
external-chain export cannot even ascend to the account parent.

This supplies the public discovery half of the cold-signing design. A future
public preparation context should retain this key, its depth/path, and ordered
address indices for input and change ownership, using the existing transaction
builders without an unlocked handle. Account aggregation is not authority to
spend. No cold transaction building, signing, QR transport or broadcasting was
implemented. EIP-19's optional sender address does not identify the complete
account or convey every input derivation path: verify real multi-address
signing with the offline wallet before promising it. The cold-signing spec is
amended to distinguish this implemented discovery from future preparation.

## Verification and delivery

Commands from this worktree (the local Flutter copy avoids read-only SDK
stamps; analytics is disabled to avoid writes to the home directory):

```sh
# Repository root
PATH="$PWD/app/build/tooling/flutter/bin:$PATH" FLUTTER_SUPPRESS_ANALYTICS=true CARGO_TARGET_DIR="$PWD/rust/target" flutter_rust_bridge_codegen generate
# rust/
CARGO_TARGET_DIR="$PWD/target" cargo test --workspace
# app/
FLUTTER_SUPPRESS_ANALYTICS=true build/tooling/flutter/bin/flutter analyze
FLUTTER_SUPPRESS_ANALYTICS=true build/tooling/flutter/bin/flutter test
```

Bridge generation completed successfully and generated Dart/Rust files are
included. Workspace tests passed (808 passed, 12 ignored across unit/doc suites), analysis reported no issues, and Flutter
reported 814 passing tests and one skipped. Additional regressions cover
persisted frontier restoration without bridge validation and account Receive's
stealth exclusion. `git diff --check` passed. Build products, logs and research
checkouts remain in already-ignored build directories; no ignore rules changed.

The requested first commit (`Derive payment chains from extended public keys`)
was attempted but `git add` failed creating
`/home/rkadias/coding/arkadianet/Argus/.git/worktrees/xpub/index.lock` because
that directory is read-only in the sandbox. All pieces are left uncommitted;
no push or PR was attempted. Suggested subsequent coherent pieces are
`Watch balances and receive across public address chains` and
`Document extended-key exports and cold signing integration`.

After the final overview wording adjustment (accounts are counted separately
from individual addresses), analysis passed again and
`FLUTTER_SUPPRESS_ANALYTICS=true build/tooling/flutter/bin/flutter test test/overview_summary_test.dart test/watch_receive_test.dart`
passed all four tests from `app/`.
