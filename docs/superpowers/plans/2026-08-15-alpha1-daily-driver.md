# Alpha 1 Daily Driver Implementation Plan

> **For agentic workers:** Execute inline in this session. User already ordered: implement, commit, publish.

**Goal:** Ship `v1.0.0-alpha.1` — a wallet that can spend across all owned addresses, shows and edits its nodes, scan-to-send, real tx detail, and a polished ledger. Still alpha. Not ErgoPay. Not DeFi.

**Architecture:** Keep secrets in Rust. Persist node list in Dart (`shared_preferences`). `prepare_send` gathers UTXOs from every owned spend address. Network list is process state set from Dart before any node call. Phrase is not stored; Settings says paper is the only copy.

**Tech Stack:** Rust `wallet-core` / `wallet-net` / `wallet-ffi`, FRB 2.11.1, Flutter, `mobile_scanner`, `share_plus`, `url_launcher`.

## Global Constraints

- Author arkadianet only. Never Co-Authored-By.
- Never replace `.env`. Use `example.env` if a new var is needed.
- Do not persist the mnemonic.
- `DevFeeConfig::disabled()` stays.
- Mainnet only.
- Keep unaudited-prototype strip.
- Rebuild `libwallet_ffi.so` before the APK.
- `flutter analyze` and `flutter test` and `cargo test -p wallet-core -p wallet-net -p wallet-ffi --lib` must pass.

## Files

- Modify: `rust/crates/wallet-net/src/client.rs` — network list, probe, connect uses list
- Modify: `rust/crates/wallet-ffi/src/api.rs` — `set_network`, `probe_network`, `prepare` multi-address
- Modify: `app/lib/services/wallet_service.dart` — spend addresses, network, parse URI
- Create: `app/lib/services/network_controller.dart`
- Create: `app/lib/format.dart` helpers — `parseErgoUri`, `formatHeight`, `formatTxTime`
- Modify: dashboard, send, receive, settings, transactions
- Create: `app/lib/ui/scan_screen.dart`, `app/lib/ui/transaction_detail_screen.dart`
- Modify: `app/pubspec.yaml` — deps + version `1.0.0-alpha.1+2`
- Modify: Android manifest camera permission
- Rebuild: `app/android/app/src/main/jniLibs/**/libwallet_ffi.so`

### Task 1: Network list + probe (Rust)

- [ ] Tests for `set_network` / `node_urls` using a custom list
- [ ] `set_network`, `network_snapshot`, `probe_url`
- [ ] `connect` tries preferred then the configured list
- [ ] FFI `set_network` + `probe_network`

### Task 2: Multi-address UTXO gather (Rust)

- [ ] `prepare` takes `spend_addresses: Vec<String>`
- [ ] Every address must be owned; UTXOs merged by box id
- [ ] Empty list falls back to `sender_address`
- [ ] FRB codegen

### Task 3: Dart network + URI + spend wiring

- [ ] `NetworkController` persist/load/probe
- [ ] `parseErgoUri` tests
- [ ] `prepareSend` passes history addresses
- [ ] Fiat quote optional (CoinGecko), hide on failure

### Task 4: UI polish

- [ ] Settings: nodes, explorer, height, paper-backup copy
- [ ] Ledger: height/offline, cleaner copy, day-grouped activity
- [ ] Send: scan, MAX, confirm sheet with to/amount/fee/node
- [ ] Receive: share
- [ ] Tx detail: id, height or unconfirmed, time, copy, explorer

### Task 5: Verify, commit, publish

- [ ] Tests + analyze
- [ ] Rebuild Android `.so`
- [ ] Commit as arkadianet
- [ ] Build APKs, `gh release create v1.0.0-alpha.1 --prerelease`
