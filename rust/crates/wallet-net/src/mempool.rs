//! Mempool parsing and filtering. Pure functions over node JSON — no I/O, so
//! every rule here is unit-testable without a node.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
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
}
