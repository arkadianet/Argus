//! The EIP-12 dApp connector behind the FFI: an unsigned transaction a
//! page hands over, checked and summarised into a preparation the
//! ordinary confirm-and-sign flow signs.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_tx::{Eip12DataInputBox, Eip12InputBox, Eip12UnsignedTx};

use crate::error::ArgusError;

fn ser_err(e: impl std::fmt::Display) -> String {
    ArgusError::SerializationError(e.to_string()).to_json_string()
}

/// Parse the EIP-12 transaction a page sent. Fleet emits an input's
/// context extension as `{"0": "..."}`; the EIP-12 type definitions show
/// `{"values": {...}}`; both are accepted, and a missing `dataInputs`
/// means none.
pub fn parse_unsigned(tx_json: &str) -> Result<Eip12UnsignedTx, String> {
    let mut v: serde_json::Value = serde_json::from_str(tx_json).map_err(ser_err)?;
    let obj = v
        .as_object_mut()
        .ok_or_else(|| ser_err("the transaction is not a JSON object"))?;
    obj.entry("dataInputs").or_insert_with(|| serde_json::json!([]));
    if let Some(inputs) = obj.get_mut("inputs").and_then(|i| i.as_array_mut()) {
        for input in inputs {
            let Some(ext) = input.get("extension") else { continue };
            let unwrapped = match ext {
                serde_json::Value::Object(m) if m.contains_key("values") => m["values"].clone(),
                serde_json::Value::Null => serde_json::json!({}),
                other => other.clone(),
            };
            input["extension"] = unwrapped;
        }
    }
    let tx: Eip12UnsignedTx =
        serde_json::from_value(v).map_err(|e| ser_err(format!("unsigned transaction: {e}")))?;
    // Fail closed on a context extension the reducer would silently drop:
    // a transaction signed without it would differ from the one the page
    // built and computed its id from.
    for input in &tx.inputs {
        for (key, value) in &input.extension {
            let bad = |why: &str| {
                ArgusError::TxBuildFailed(format!(
                    "input {} context extension {key:?} {why}",
                    input.box_id
                ))
                .to_json_string()
            };
            if key.parse::<u8>().is_err() {
                return Err(bad("is not a variable index (0-255)"));
            }
            let bytes = hex::decode(value).map_err(|_| bad("is not hex"))?;
            use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
            ergo_lib::ergotree_ir::mir::constant::Constant::sigma_parse_bytes(&bytes)
                .map_err(|_| bad("is not a serialized constant"))?;
        }
    }
    Ok(tx)
}

/// A data input as the reducer needs it, checked to hash back to its id.
pub fn data_input_to_ergo_box(b: &Eip12DataInputBox) -> Result<ErgoBox, String> {
    let input = Eip12InputBox {
        box_id: b.box_id.clone(),
        transaction_id: b.transaction_id.clone(),
        index: b.index,
        value: b.value.clone(),
        ergo_tree: b.ergo_tree.clone(),
        assets: b.assets.clone(),
        creation_height: b.creation_height,
        additional_registers: b.additional_registers.clone(),
        extension: Default::default(),
    };
    crate::api_mix_impl::to_ergo_box(&input)
}

/// Node-shaped JSON of a box, for the summary's input lines.
pub fn node_json(b: &ErgoBox) -> Option<serde_json::Value> {
    serde_json::to_value(b).ok()
}

/// A wallet box in the shape `ergo.get_utxos()` returns. `confirmed` is
/// false for an output of a transaction still in the mempool, which the
/// wallet's box gathering includes for 0-conf chaining.
pub fn utxo_json(b: &Eip12InputBox, confirmed: bool) -> serde_json::Value {
    serde_json::json!({
        "boxId": b.box_id,
        "transactionId": b.transaction_id,
        "index": b.index,
        "ergoTree": b.ergo_tree,
        "creationHeight": b.creation_height,
        "value": b.value,
        "assets": b.assets.iter().map(|a| serde_json::json!({
            "tokenId": a.token_id,
            "amount": a.amount,
        })).collect::<Vec<_>>(),
        "additionalRegisters": b.additional_registers,
        "confirmed": confirmed,
    })
}

/// The miner fee an unsigned transaction pays.
pub fn miner_fee_of(tx: &Eip12UnsignedTx) -> i64 {
    tx.outputs
        .iter()
        .filter(|o| o.ergo_tree == citadel_core::constants::MINER_FEE_ERGO_TREE)
        .filter_map(|o| o.value.parse::<i64>().ok())
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TX: &str = r#"{
      "inputs": [{
        "boxId": "e56847ed19b3dc6b72828fcfb992fdf7310828cf291221269b7ffc72fd66706e",
        "transactionId": "9148408c04c2e38a6402a7950d6157730fa7d49e9ab3b9cadec481d7769918e9",
        "index": 1,
        "ergoTree": "0008cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a02",
        "creationHeight": 1000000,
        "value": "1000000000",
        "assets": [],
        "additionalRegisters": {},
        "extension": {"values": {"0": "0400"}}
      }],
      "outputs": [{
        "value": "998900000",
        "ergoTree": "0008cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a02",
        "creationHeight": 1000000,
        "assets": [],
        "additionalRegisters": {}
      }, {
        "value": "1100000",
        "ergoTree": "1005040004000e36100204a00b08cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798ea02d192a39a8cc7a701730073011001020402d19683030193a38cc7b2a57300000193c2b2a57301007473027303830108cdeeac93b1a57304",
        "creationHeight": 1000000,
        "assets": [],
        "additionalRegisters": {}
      }]
    }"#;

    #[test]
    fn parses_fleet_style_and_typed_extensions_and_missing_data_inputs() {
        let tx = parse_unsigned(TX).unwrap();
        assert_eq!(tx.inputs[0].extension["0"], "0400");
        assert!(tx.data_inputs.is_empty());
        assert_eq!(miner_fee_of(&tx), 1_100_000);
        let flat = TX.replace(r#"{"values": {"0": "0400"}}"#, r#"{"0": "0400"}"#);
        assert_eq!(parse_unsigned(&flat).unwrap().inputs[0].extension["0"], "0400");
        let none = TX.replace(r#""extension": {"values": {"0": "0400"}}"#, r#""extension": null"#);
        assert!(parse_unsigned(&none).unwrap().inputs[0].extension.is_empty());
        // Fail closed: a page's extension the reducer could not encode.
        for bad in [r#"{"1": "zz"}"#, r#"{"x": "0400"}"#, r#"{"300": "0400"}"#, r#"{"0": "ff"}"#] {
            let tx = TX.replace(r#"{"values": {"0": "0400"}}"#, bad);
            assert!(parse_unsigned(&tx).is_err(), "{bad}");
        }
        assert!(parse_unsigned("[]").is_err());
        assert!(parse_unsigned(r#"{"inputs": [{"boxId": 1}], "outputs": []}"#).is_err());
    }

    #[test]
    fn utxo_json_is_the_connector_shape() {
        let tx = parse_unsigned(TX).unwrap();
        let j = utxo_json(&tx.inputs[0], true);
        assert_eq!(j["boxId"], tx.inputs[0].box_id);
        assert_eq!(j["value"], "1000000000");
        assert_eq!(j["confirmed"], true);
        assert_eq!(utxo_json(&tx.inputs[0], false)["confirmed"], false);
        assert!(j.get("extension").is_none());
    }
}
