//! Mempool parsing and filtering. Pure functions over node JSON — no I/O, so
//! every rule here is unit-testable without a node.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;

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
            TxId::from_str("2222222222222222222222222222222222222222222222222222222222222222")
                .unwrap(),
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
