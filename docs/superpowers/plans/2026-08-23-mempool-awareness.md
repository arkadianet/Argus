# Mempool Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the wallet aware of unconfirmed transactions — shown in activity, reflected in balances, excluded from spendable inputs once spent, and usable as inputs while still unconfirmed.

**Architecture:** One mempool read per wallet address via `/transactions/unconfirmed/byErgoTree`, added to the first-party `wallet-net` crate beside `get_unspent`. A new `get_effective_unspent` returns the same `(Vec<ErgoBox>, Vec<Eip12InputBox>)` tuple, making it a drop-in at the single call site in `gather_unspent`. Balance and activity read the same mempool data through new FFI calls. Every mempool query degrades to confirmed-only on failure.

**Tech Stack:** Rust 2021, flutter_rust_bridge 2.11.1, reqwest, Flutter/Dart, `cargo-ndk`.

**Spec:** `docs/superpowers/specs/2026-08-23-mempool-awareness-design.md`

## Global Constraints

- **Do not modify `rust/crates/vendor/`.** `wallet-net`, `wallet-core` and `wallet-ffi` are first-party; everything here lands in those. `get_effective_utxos` in the vendored `ergo-node-client` is deliberately left alone — it returns the wrong type and is superseded by Task 3.
- **Every mempool query degrades to confirmed-only.** A mempool failure must never fail a send, blank a balance, or empty an activity list. It logs and falls back.
- **Never abort a whole UTXO set for one bad box.** A mempool output that will not parse is skipped; the rest stand.
- `/transactions/unconfirmed/byErgoTree` needs **no `extraIndex`** — do not add a capability gate.
- `get_unconfirmed_by_ergo_tree` in the vendored crate hardcodes `limit=100`. The new `wallet-net` version takes the same cap; log when it is hit rather than truncating silently.
- Dart package is `argus_wallet`. Test imports use `package:argus_wallet/...`.
- Branch `feat/mempool-awareness`, worktree `/home/rkadias/coding/arkadianet/Argus-wt-shortfall`.

---

## File Structure

| File | Responsibility |
|---|---|
| `rust/crates/wallet-net/src/mempool.rs` | **Create.** Pure parsing/filtering: output→`ErgoBox`, spent-set, deltas |
| `rust/crates/wallet-net/src/client.rs` | Mempool fetch + `get_effective_unspent` |
| `rust/crates/wallet-net/src/lib.rs` | Register the module |
| `rust/crates/wallet-ffi/src/api.rs` | Wire `gather_unspent`; mempool-aware `get_balance`; new `get_pending_transactions` |
| `app/lib/services/wallet_service.dart` | Fetch + merge pending, dedup by tx id |
| `app/lib/ui/dashboard_screen.dart` | Poll while mounted, pause when backgrounded |
| `app/test/mempool_test.dart` | **Create.** Dart-side dedup and merge tests |

---

## Task 1: Turn a mempool output into an ErgoBox

The spec's step one. Everything downstream depends on whether a mempool output deserialises as-is, and `json_output_to_eip12` (`ergo-node-client/src/lib.rs:996`) suggests it will not: it reads `boxId` from the output but takes `tx_id` and `index` as **parameters** from the enclosing transaction.

**Files:**
- Create: `rust/crates/wallet-net/src/mempool.rs`
- Modify: `rust/crates/wallet-net/src/lib.rs`

**Interfaces:**
- Produces: `pub fn output_to_ergo_box(output: &serde_json::Value, tx_id: &str, index: u16) -> Option<ErgoBox>`

- [ ] **Step 1: Write the failing test**

Create `rust/crates/wallet-net/src/mempool.rs`:

```rust
//! Mempool parsing and filtering. Pure functions over node JSON — no I/O, so
//! every rule here is unit-testable without a node.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;

#[cfg(test)]
mod tests {
    use super::*;

    /// Shape of one output inside a `/transactions/unconfirmed` transaction.
    /// Note there is no `transactionId` or `index` — the enclosing transaction
    /// carries those, which is why they are parameters.
    fn mempool_output() -> serde_json::Value {
        serde_json::json!({
            "boxId": "1111111111111111111111111111111111111111111111111111111111111111",
            "value": 1000000000u64,
            "ergoTree": "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            "assets": [],
            "creationHeight": 100000,
            "additionalRegisters": {}
        })
    }

    #[test]
    fn a_mempool_output_becomes_a_spendable_box() {
        let tx_id = "2222222222222222222222222222222222222222222222222222222222222222";
        let b = output_to_ergo_box(&mempool_output(), tx_id, 0)
            .expect("mempool output must convert to an ErgoBox");

        assert_eq!(b.value.as_u64(), &1_000_000_000u64);
        assert_eq!(b.creation_height, 100_000);
    }

    #[test]
    fn a_malformed_output_is_skipped_not_fatal() {
        let junk = serde_json::json!({"boxId": "abc"});
        assert!(output_to_ergo_box(&junk, "tx", 0).is_none());
    }
}
```

Register in `rust/crates/wallet-net/src/lib.rs`:

```rust
pub mod mempool;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test -p wallet-net a_mempool_output_becomes`

Expected: FAIL — `cannot find function 'output_to_ergo_box'`.

- [ ] **Step 3: Write the implementation**

```rust
/// Build an `ErgoBox` from one output of an unconfirmed transaction.
///
/// `ErgoBox`'s JSON form expects `transactionId` and `index`, which a mempool
/// output does not carry — the enclosing transaction does. Inject them before
/// deserialising, mirroring how `json_output_to_eip12` receives them.
///
/// Returns `None` for anything that will not parse: one bad box must never
/// abort a whole UTXO set.
pub fn output_to_ergo_box(
    output: &serde_json::Value,
    tx_id: &str,
    index: u16,
) -> Option<ErgoBox> {
    let mut enriched = output.clone();
    let obj = enriched.as_object_mut()?;
    obj.entry("transactionId")
        .or_insert_with(|| serde_json::Value::String(tx_id.to_string()));
    obj.entry("index")
        .or_insert_with(|| serde_json::Value::from(index));

    match serde_json::from_value::<ErgoBox>(enriched) {
        Ok(b) => Some(b),
        Err(e) => {
            tracing::warn!("Skipping unparsable mempool output: {}", e);
            None
        }
    }
}
```

If the test still fails, the assumption is wrong in a different way — read the serde error, adjust the injected fields to match `ErgoBox`'s JSON representation, and **do not** move on until this passes. Every later task builds on it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust && cargo test -p wallet-net mempool`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rust/crates/wallet-net/src/mempool.rs rust/crates/wallet-net/src/lib.rs
git commit -m "feat: convert an unconfirmed transaction output into an ErgoBox"
```

---

## Task 2: Spent-set and ownership filtering

**Files:**
- Modify: `rust/crates/wallet-net/src/mempool.rs`

**Interfaces:**
- Produces: `pub fn spent_box_ids(txs: &[serde_json::Value]) -> HashSet<String>`, `pub fn owned_outputs(txs: &[serde_json::Value], ergo_tree: &str) -> Vec<ErgoBox>`

- [ ] **Step 1: Write the failing test**

```rust
    fn tx(id: &str, spends: &[&str], outputs: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "inputs": spends.iter().map(|b| serde_json::json!({"boxId": b})).collect::<Vec<_>>(),
            "outputs": outputs,
        })
    }

    #[test]
    fn every_input_box_counts_as_spent() {
        let txs = vec![tx("t1", &["boxA", "boxB"], vec![]), tx("t2", &["boxC"], vec![])];
        let spent = spent_box_ids(&txs);
        assert!(spent.contains("boxA") && spent.contains("boxB") && spent.contains("boxC"));
        assert!(!spent.contains("boxD"));
    }

    #[test]
    fn only_outputs_paying_this_tree_are_owned() {
        const MINE: &str =
            "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let mut theirs = mempool_output();
        theirs["ergoTree"] = serde_json::json!("0008cd03aaaa");
        theirs["boxId"] =
            serde_json::json!("3333333333333333333333333333333333333333333333333333333333333333");

        let txs = vec![tx("t1", &[], vec![mempool_output(), theirs])];
        let owned = owned_outputs(&txs, MINE);

        assert_eq!(owned.len(), 1, "only the output paying our tree is ours");
        assert_eq!(owned[0].value.as_u64(), &1_000_000_000u64);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test -p wallet-net -- every_input_box only_outputs_paying`

Expected: FAIL — `cannot find function 'spent_box_ids'` / `'owned_outputs'`.

- [ ] **Step 3: Write the implementation**

```rust
use std::collections::HashSet;

/// Every box id consumed by these transactions. A confirmed UTXO whose id is
/// in this set is already spent and must not be offered again.
pub fn spent_box_ids(txs: &[serde_json::Value]) -> HashSet<String> {
    let mut spent = HashSet::new();
    for tx in txs {
        if let Some(inputs) = tx["inputs"].as_array() {
            for input in inputs {
                if let Some(id) = input["boxId"].as_str() {
                    spent.insert(id.to_string());
                }
            }
        }
    }
    spent
}

/// Outputs of these transactions that pay `ergo_tree`, as spendable boxes.
/// Unparsable outputs are skipped rather than failing the batch.
pub fn owned_outputs(txs: &[serde_json::Value], ergo_tree: &str) -> Vec<ErgoBox> {
    let mut owned = Vec::new();
    for tx in txs {
        let tx_id = match tx["id"].as_str() {
            Some(id) => id,
            None => continue,
        };
        let outputs = match tx["outputs"].as_array() {
            Some(o) => o,
            None => continue,
        };
        for (idx, output) in outputs.iter().enumerate() {
            if output["ergoTree"].as_str() != Some(ergo_tree) {
                continue;
            }
            if let Some(b) = output_to_ergo_box(output, tx_id, idx as u16) {
                owned.push(b);
            }
        }
    }
    owned
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust && cargo test -p wallet-net mempool`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add rust/crates/wallet-net/src/mempool.rs
git commit -m "feat: derive mempool spent-set and owned outputs"
```

---

## Task 3: `get_effective_unspent` in wallet-net

**Files:**
- Modify: `rust/crates/wallet-net/src/client.rs`

**Interfaces:**
- Consumes: `spent_box_ids`, `owned_outputs` (Task 2); `address_to_ergo_tree` (`wallet-net/src/client.rs`); `get_unspent(address) -> (Vec<ErgoBox>, Vec<Eip12InputBox>)` (`client.rs:358`)
- Produces: `pub async fn mempool_txs_for(&self, ergo_tree: &str) -> Result<Vec<serde_json::Value>, String>`, `pub async fn get_effective_unspent(&self, address: &str) -> Result<(Vec<ErgoBox>, Vec<Eip12InputBox>), String>`

- [ ] **Step 1: Add the mempool fetch**

Mirror the POST idiom of `unspent_boxes_by_address` (`client.rs:237-260`):

```rust
/// Unconfirmed transactions touching `ergo_tree`. Mempool is in-memory on the
/// node, so this needs no extra index and works against any node.
pub async fn mempool_txs_for(&self, ergo_tree: &str) -> Result<Vec<serde_json::Value>, String> {
    const MEMPOOL_LIMIT: usize = 100;
    let endpoint = format!(
        "/transactions/unconfirmed/byErgoTree?offset=0&limit={}",
        MEMPOOL_LIMIT
    );
    let body = serde_json::to_string(ergo_tree).map_err(|e| format!("JSON serialize: {}", e))?;
    let response = self
        .inner
        .send_post_req(&endpoint, body)
        .await
        .map_err(|e| format!("Node request: {}", e))?;
    let text = response.text().await.map_err(|e| format!("Read: {}", e))?;
    if text.is_empty() {
        return Ok(Vec::new());
    }
    let value: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("Parse: {}", e))?;
    let items = match value {
        serde_json::Value::Array(arr) => arr,
        serde_json::Value::Object(ref map) => map
            .get("items")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default(),
        _ => Vec::new(),
    };
    if items.len() >= MEMPOOL_LIMIT {
        tracing::warn!("Mempool page limit hit; some unconfirmed transactions not seen");
    }
    Ok(items)
}
```

- [ ] **Step 2: Add the effective-unspent wrapper**

```rust
/// Mempool-aware UTXOs: confirmed, minus boxes already spent in mempool, plus
/// this address's unconfirmed outputs. Enables 0-conf chaining.
///
/// Returns the same tuple as [`get_unspent`], so it is a drop-in for callers.
/// Any mempool failure degrades to exactly the confirmed set.
pub async fn get_effective_unspent(
    &self,
    address: &str,
) -> Result<(Vec<ErgoBox>, Vec<ergo_tx::Eip12InputBox>), String> {
    let (confirmed, _) = self.get_unspent(address).await?;

    let tree = match address_to_ergo_tree(address) {
        Some(t) => t,
        None => return self.get_unspent(address).await,
    };
    let txs = match self.mempool_txs_for(&tree).await {
        Ok(t) if !t.is_empty() => t,
        Ok(_) => return self.get_unspent(address).await,
        Err(e) => {
            tracing::warn!("Mempool query failed, using confirmed UTXOs only: {}", e);
            return self.get_unspent(address).await;
        }
    };

    let spent = crate::mempool::spent_box_ids(&txs);
    let mut boxes: Vec<ErgoBox> = confirmed
        .into_iter()
        .filter(|b| !spent.contains(&b.box_id().to_string()))
        .collect();

    // Chained spends: an unconfirmed output may itself already be spent by a
    // later mempool transaction, so filter the additions by the same set.
    for b in crate::mempool::owned_outputs(&txs, &tree) {
        if !spent.contains(&b.box_id().to_string()) {
            boxes.push(b);
        }
    }

    let eip12 = boxes
        .iter()
        .map(|b| ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index))
        .collect();
    Ok((boxes, eip12))
}
```

- [ ] **Step 3: Verify it compiles and the suite is green**

Run: `cd rust && cargo test -p wallet-net && cargo build -p wallet-net`

Expected: PASS. If `b.transaction_id` / `b.index` are not public fields on `ErgoBox`, copy whatever `get_unspent` (`client.rs:358-369`) already uses — it does exactly this mapping.

- [ ] **Step 4: Commit**

```bash
git add rust/crates/wallet-net/src/client.rs
git commit -m "feat: add mempool-aware effective unspent to wallet-net"
```

---

## Task 4: Spend from the effective set

**Files:**
- Modify: `rust/crates/wallet-ffi/src/api.rs`

**Interfaces:**
- Consumes: `get_effective_unspent` (Task 3)

- [ ] **Step 1: Switch the call site**

In `gather_unspent` (`api.rs:528`), replace the single `client.get_unspent(addr)` call:

```rust
        let (b, e) = client
            .get_effective_unspent(addr)
            .await
            .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
```

This is the whole change — `gather_unspent` already dedupes by box id via its `seen` set, which now also protects against an unconfirmed output arriving twice across addresses.

- [ ] **Step 2: Verify the workspace**

Run: `cd rust && cargo test --workspace`

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add rust/crates/wallet-ffi/src/api.rs
git commit -m "feat: build transactions from mempool-aware UTXOs"
```

---

## Task 5: Mempool-aware balance

**Files:**
- Modify: `rust/crates/wallet-net/src/mempool.rs`
- Modify: `rust/crates/wallet-ffi/src/api.rs`

**Interfaces:**
- Produces: `pub fn balance_delta(txs: &[serde_json::Value], ergo_tree: &str, confirmed_box_ids: &HashSet<String>) -> i64`

The spec's one-pass rule matters here: resolve every transaction for the address before applying deltas, so a chained transaction's input — which references an unconfirmed output rather than a confirmed one — is still recognised as ours.

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn a_chained_spend_nets_out_across_one_pass() {
        const MINE: &str =
            "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let confirmed: HashSet<String> = ["boxA".to_string()].into_iter().collect();

        // t1 spends confirmed boxA (1 ERG), pays us back 0.6 as boxB.
        let mut b_out = mempool_output();
        b_out["boxId"] = serde_json::json!("boxB");
        b_out["value"] = serde_json::json!(600_000_000u64);
        let t1 = tx("t1", &["boxA"], vec![b_out.clone()]);

        // t2 chains: spends the still-unconfirmed boxB, pays us 0.4 back.
        let mut c_out = mempool_output();
        c_out["boxId"] = serde_json::json!("boxC");
        c_out["value"] = serde_json::json!(400_000_000u64);
        let t2 = tx("t2", &["boxB"], vec![c_out]);

        // Net: -1 ERG confirmed in, +0.4 ERG still ours. boxB must not be
        // counted as an asset while also being spent by t2.
        let delta = balance_delta(&[t1, t2], MINE, &confirmed);
        assert_eq!(delta, -600_000_000, "expected -1.0 spent + 0.4 returned");
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust && cargo test -p wallet-net a_chained_spend_nets_out`

Expected: FAIL — `cannot find function 'balance_delta'`.

- [ ] **Step 3: Write the implementation**

```rust
/// Net nanoERG change from unconfirmed transactions for `ergo_tree`.
///
/// Single pass: collect every owned output first, then subtract the ones that
/// are spent again within the same mempool set. Applying deltas transaction by
/// transaction gets chained spends wrong, because a child's input references an
/// output that is in no confirmed UTXO set.
pub fn balance_delta(
    txs: &[serde_json::Value],
    ergo_tree: &str,
    confirmed_box_ids: &HashSet<String>,
) -> i64 {
    let spent = spent_box_ids(txs);

    // Confirmed boxes of ours consumed by mempool: leaving.
    let mut delta: i64 = 0;
    for tx in txs {
        if let Some(inputs) = tx["inputs"].as_array() {
            for input in inputs {
                if let Some(id) = input["boxId"].as_str() {
                    if confirmed_box_ids.contains(id) {
                        // Value comes from the confirmed set, resolved by the caller.
                        delta -= input["value"].as_i64().unwrap_or(0);
                    }
                }
            }
        }
    }

    // Our unconfirmed outputs that are not themselves already spent: arriving.
    for tx in txs {
        let outputs = match tx["outputs"].as_array() {
            Some(o) => o,
            None => continue,
        };
        for output in outputs {
            if output["ergoTree"].as_str() != Some(ergo_tree) {
                continue;
            }
            let id = output["boxId"].as_str().unwrap_or_default();
            if spent.contains(id) {
                continue;
            }
            delta += output["value"].as_i64().unwrap_or(0);
        }
    }
    delta
}
```

Mempool inputs may not carry `value`. If the test shows they do not, the caller must resolve each spent box id against the confirmed set it already has; pass a `&HashMap<String, i64>` of confirmed box values instead of a `HashSet` and look the value up. Decide from the actual JSON, not from this note.

- [ ] **Step 4: Run tests, then wire `get_balance`**

Run: `cd rust && cargo test -p wallet-net mempool` — expect PASS.

Then in `api.rs:325`, fetch the address's mempool transactions and its confirmed UTXO ids, apply `balance_delta`, and report the adjusted figure. Keep the existing shape of the response JSON so Dart needs no change:

```rust
    let delta = /* balance_delta(...) or 0 on any mempool failure */;
    "balance_nano_erg": (nano as i64 + delta).max(0),
```

- [ ] **Step 5: Verify and commit**

```bash
cd rust && cargo test --workspace
git add rust/crates/wallet-net/src/mempool.rs rust/crates/wallet-ffi/src/api.rs
git commit -m "feat: reflect unconfirmed transactions in the balance"
```

---

## Task 6: Pending transactions in the activity list

**Files:**
- Modify: `rust/crates/wallet-ffi/src/api.rs`
- Modify: `app/lib/services/wallet_service.dart`
- Create: `app/test/mempool_test.dart`

**Interfaces:**
- Produces: `pub async fn get_pending_transactions(addresses: Vec<String>, node_url: Option<String>) -> Result<String, String>`; Dart `List<Map<String, dynamic>> mergePending(List pending, List confirmed)`

- [ ] **Step 1: Add the FFI call**

Query each address's mempool concurrently with `tokio::task::JoinSet`, following `discover_addresses` (`api.rs:395`). Return a JSON array of transactions, each carrying at least `id`, `inputs`, `outputs`, and `confirmed: false`. Deduplicate by `id` in Rust as well — the same transaction comes back once per matching address.

- [ ] **Step 2: Write the failing Dart test**

Create `app/test/mempool_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_wallet/services/wallet_service.dart';

void main() {
  group('mergePending', () {
    test('a transaction seen on two addresses appears once', () {
      // Spending from address A with change to address B returns the same
      // transaction from both mempool queries.
      final pending = [
        {'id': 'tx1', 'confirmed': false},
        {'id': 'tx1', 'confirmed': false},
      ];

      final merged = mergePending(pending, []);

      expect(merged, hasLength(1));
      expect(merged.single['id'], 'tx1');
    });

    test('pending entries sort above confirmed ones', () {
      final merged = mergePending(
        [{'id': 'tx1', 'confirmed': false}],
        [{'id': 'tx0', 'confirmed': true, 'timestamp': 1}],
      );

      expect(merged.map((e) => e['id']), ['tx1', 'tx0']);
    });

    test('a transaction that has confirmed is not also shown as pending', () {
      final merged = mergePending(
        [{'id': 'tx1', 'confirmed': false}],
        [{'id': 'tx1', 'confirmed': true, 'timestamp': 1}],
      );

      expect(merged, hasLength(1));
      expect(merged.single['confirmed'], true);
    });
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd app && flutter test test/mempool_test.dart`

Expected: FAIL — `Method not found: 'mergePending'`.

- [ ] **Step 4: Write the implementation**

```dart
/// Pending transactions ahead of confirmed history, deduplicated by id.
///
/// The mempool is queried once per wallet address, so a transaction touching
/// two of our addresses — spending from one, change to another — arrives twice.
/// A transaction that has since confirmed wins over its pending copy.
List<Map<String, dynamic>> mergePending(
  List<dynamic> pending,
  List<dynamic> confirmed,
) {
  final confirmedIds = <String>{
    for (final c in confirmed) (c as Map)['id'] as String? ?? '',
  };
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];

  for (final p in pending) {
    final m = (p as Map).cast<String, dynamic>();
    final id = m['id'] as String? ?? '';
    if (id.isEmpty || confirmedIds.contains(id) || !seen.add(id)) continue;
    out.add(m);
  }
  for (final c in confirmed) {
    out.add((c as Map).cast<String, dynamic>());
  }
  return out;
}
```

Then call `getPendingTransactions` alongside the existing history fetch and pass both through `mergePending`.

- [ ] **Step 5: Verify and commit**

```bash
cd app && flutter test && flutter analyze lib test
git add rust/crates/wallet-ffi/src/api.rs app/lib/services/wallet_service.dart app/test/mempool_test.dart
git commit -m "feat: show unconfirmed transactions in activity"
```

---

## Task 7: Poll while the dashboard is open

**Files:**
- Modify: `app/lib/ui/dashboard_screen.dart`

- [ ] **Step 1: Add the timer**

`Timer.periodic` started in `initState`, calling the existing `_refresh()` (`dashboard_screen.dart:522`), cancelled in `dispose`. Guard against overlap: skip a tick if a refresh is already in flight.

Pause while backgrounded using a `WidgetsBindingObserver` on `AppLifecycleState.paused` / `.hidden` — the same states `SessionLock.onLifecycle` reacts to. **Do not** try to subscribe to `SessionLock`: it exposes `onLock` (a callback it invokes), `suppress`/`release`, `run`, `onLifecycle` and `grace`, and its `_backgrounded` flag is private. There is nothing to listen to.

Interval is not fixed by the spec — 20s is a reasonable default.

- [ ] **Step 2: Verify and commit**

```bash
cd app && flutter test && flutter analyze lib test
git add app/lib/ui/dashboard_screen.dart
git commit -m "feat: poll for mempool changes while the dashboard is open"
```

---

## Task 8: Build and verify

- [ ] **Step 1: Rebuild and run everything**

```bash
export ANDROID_NDK_HOME="$(ls -d ~/Android/Sdk/ndk/* | tail -1)"
./scripts/build_android.sh
cd rust && cargo test --workspace
cd ../app && flutter test && flutter analyze lib test
```

- [ ] **Step 2: On-device verification**

No unit test covers node behaviour. Check, in order:

1. Send ERG — the entry appears immediately marked Pending, and the balance drops
2. Send again before it confirms — the second transaction builds and broadcasts rather than being rejected as a double-spend
3. Spend unconfirmed change — the chained transaction is accepted
4. Wait for a block — entries flip to Confirmed without a manual refresh
5. A transaction spending from one address with change to another appears **once**, not twice
6. Point at a node with an empty mempool — nothing regresses

Step 2 is the original bug; step 5 is the dedup; step 6 is the degradation path.

- [ ] **Step 3: Commit**

```bash
git add app/android/app/src/main/jniLibs
git commit -m "build: rebuild libwallet_ffi.so with mempool awareness"
```

---

## Notes for the implementer

- **Task 1 gates everything.** If a mempool output will not become an `ErgoBox`, Tasks 3–5 have no foundation. Do not paper over a failure there.
- **Degradation is not optional.** Four separate consumers read mempool data; each must fall back to confirmed-only. A wallet that cannot show a balance because the mempool endpoint hiccuped is worse than one that shows a slightly stale balance.
- **One pass, then apply.** The chained-spend test in Task 5 exists because transaction-by-transaction iteration silently mis-nets a grandchild. If you refactor, keep that test.
- **`gather_unspent` already dedupes by box id** via its `seen` set — do not add a second layer.
- The vendored `get_effective_utxos` stays unused and untouched. Deleting it is out of scope; it belongs to `ergo-node-client`, which other consumers may use.
