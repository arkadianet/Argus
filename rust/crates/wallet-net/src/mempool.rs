//! Mempool parsing and filtering. Pure functions over node JSON — no I/O, so
//! every rule here is unit-testable without a node.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use std::collections::{HashMap, HashSet};

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

/// Net nanoERG change from unconfirmed transactions for `ergo_tree`.
///
/// Mempool inputs carry no value — only a `boxId` and a spending proof — so
/// the leaving amounts are resolved against `confirmed_values`, the map of the
/// caller's confirmed box ids to their nanoERG values.
///
/// Single pass over all transactions: collect every spent id first, then apply
/// deltas. Applying them transaction by transaction mis-nets a chained spend,
/// whose input references an unconfirmed output that is in no confirmed set.
pub fn balance_delta(
    txs: &[serde_json::Value],
    ergo_tree: &str,
    confirmed_values: &HashMap<String, i64>,
) -> i64 {
    let spent = spent_box_ids(txs);

    // Confirmed boxes of ours consumed by mempool: leaving.
    let mut delta: i64 = 0;
    for id in &spent {
        if let Some(v) = confirmed_values.get(id) {
            delta -= v;
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

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
    use ergo_lib::ergotree_ir::chain::ergo_box::NonMandatoryRegisters;
    use ergo_lib::ergotree_ir::chain::tx_id::TxId;
    use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
    use std::str::FromStr;

    const OWN_TREE: &str =
        "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    /// A real-shaped transaction id (32 bytes hex): the box id is recomputed
    /// from contents *including* the injected transactionId, so the wrapping
    /// transaction in tests must carry exactly this id or conversion fails.
    const TX_ID: &str = "abababababababababababababababababababababababababababababababab";

    /// Shape of one output inside a `/transactions/unconfirmed` transaction:
    /// no `transactionId` and no `index` — the enclosing transaction carries
    /// those. The box id must be self-consistent with the contents, because
    /// deserialisation recomputes and verifies it, so the fixture is derived
    /// from a real `ErgoBox` rather than hand-written.
    fn mempool_output() -> serde_json::Value {
        let tree = ErgoTree::sigma_parse_bytes(&base16::decode(OWN_TREE).unwrap()).unwrap();
        let b = ErgoBox::new(
            BoxValue::try_from(1_000_000_000u64).unwrap(),
            tree,
            None,
            NonMandatoryRegisters::empty(),
            100_000,
            TxId::from_str(TX_ID).unwrap(),
            0,
        )
        .unwrap();
        let mut v = serde_json::to_value(&b).unwrap();
        let obj = v.as_object_mut().unwrap();
        obj.remove("transactionId");
        obj.remove("index");
        v
    }

    #[test]
    fn a_mempool_output_becomes_a_spendable_box() {
        let b = output_to_ergo_box(&mempool_output(), TX_ID, 0)
            .expect("mempool output must convert to an ErgoBox");

        assert_eq!(b.value.as_u64(), &1_000_000_000u64);
        assert_eq!(b.creation_height, 100_000);
    }

    #[test]
    fn a_malformed_output_is_skipped_not_fatal() {
        let junk = serde_json::json!({"boxId": "abc"});
        assert!(output_to_ergo_box(&junk, "tx", 0).is_none());
    }

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
        let mut theirs = mempool_output();
        theirs["ergoTree"] = serde_json::json!("0008cd03aaaa");
        theirs["boxId"] =
            serde_json::json!("3333333333333333333333333333333333333333333333333333333333333333");

        // The wrapping tx must carry the same id the fixture's box was built
        // with — the recomputed box id depends on it.
        let txs = vec![tx(TX_ID, &[], vec![mempool_output(), theirs])];
        let owned = owned_outputs(&txs, OWN_TREE);

        assert_eq!(owned.len(), 1, "only the output paying our tree is ours");
        assert_eq!(owned[0].value.as_u64(), &1_000_000_000u64);
    }

    #[test]
    fn a_chained_spend_nets_out_across_one_pass() {
        let mut confirmed = std::collections::HashMap::new();
        confirmed.insert("boxA".to_string(), 1_000_000_000i64);

        // t1 spends confirmed boxA (1 ERG), pays us back 0.6 as boxB.
        let mut b_out = mempool_output();
        b_out["boxId"] = serde_json::json!("boxB");
        b_out["value"] = serde_json::json!(600_000_000u64);
        let t1 = tx("t1", &["boxA"], vec![b_out]);

        // t2 chains: spends the still-unconfirmed boxB, pays us 0.4 back.
        let mut c_out = mempool_output();
        c_out["boxId"] = serde_json::json!("boxC");
        c_out["value"] = serde_json::json!(400_000_000u64);
        let t2 = tx("t2", &["boxB"], vec![c_out]);

        // Net: -1 ERG confirmed in, +0.4 ERG still ours. boxB must not be
        // counted as an asset while also being spent by t2.
        let delta = balance_delta(&[t1, t2], OWN_TREE, &confirmed);
        assert_eq!(delta, -600_000_000, "expected -1.0 spent + 0.4 returned");
    }
}
