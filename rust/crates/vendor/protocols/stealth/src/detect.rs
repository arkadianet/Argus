//! Detection: which of the explorer's stealth boxes belong to us.
//!
//! The explorer's `boxes/unspent/byErgoTreeTemplateHash/{hash}` endpoint
//! returns every unspent box whose script matches the stealth template. That
//! list is public and identical for everyone, so fetching it says only that
//! *some* wallet is interested in stealth boxes — never which ones are ours.
//! The test that narrows it down (`gr^x == ur && gy^x == uy`) runs locally.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::error::StealthError;
use crate::secret::StealthSecret;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StealthAsset {
    pub token_id: String,
    /// Kept as a string so large token amounts survive the FFI boundary.
    pub amount: String,
}

/// One box from the explorer, normalised into the fields a transaction
/// builder needs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StealthBox {
    pub box_id: String,
    pub transaction_id: String,
    pub index: u16,
    pub value: i64,
    pub ergo_tree: String,
    pub creation_height: i32,
    pub assets: Vec<StealthAsset>,
    pub additional_registers: BTreeMap<String, String>,
}

impl StealthBox {
    /// Node-shaped JSON, which is what `ErgoBox`'s deserializer expects.
    pub fn to_node_json(&self) -> serde_json::Value {
        serde_json::json!({
            "boxId": self.box_id,
            "transactionId": self.transaction_id,
            "index": self.index,
            "value": self.value,
            "ergoTree": self.ergo_tree,
            "creationHeight": self.creation_height,
            "assets": self.assets.iter().map(|a| serde_json::json!({
                "tokenId": a.token_id,
                "amount": a.amount.parse::<u64>().unwrap_or(0),
            })).collect::<Vec<_>>(),
            "additionalRegisters": self.additional_registers,
        })
    }
}

fn parse_one(item: &serde_json::Value) -> Option<StealthBox> {
    let assets = item["assets"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|a| {
                    Some(StealthAsset {
                        token_id: a["tokenId"].as_str()?.to_string(),
                        amount: match &a["amount"] {
                            serde_json::Value::Number(n) => n.to_string(),
                            serde_json::Value::String(s) => s.clone(),
                            _ => return None,
                        },
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    // Registers arrive either as plain hex or as
    // `{serializedValue, sigmaType, renderedValue}` depending on endpoint.
    let additional_registers = item["additionalRegisters"]
        .as_object()
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| {
                    let hex = match v.as_str() {
                        Some(s) => s.to_string(),
                        None => v["serializedValue"].as_str()?.to_string(),
                    };
                    Some((k.clone(), hex))
                })
                .collect()
        })
        .unwrap_or_default();

    Some(StealthBox {
        box_id: item["boxId"].as_str()?.to_string(),
        transaction_id: item["transactionId"].as_str()?.to_string(),
        index: item["index"].as_u64()? as u16,
        value: item["value"].as_i64()?,
        ergo_tree: item["ergoTree"].as_str()?.to_string(),
        creation_height: item["creationHeight"].as_i64()? as i32,
        assets,
        additional_registers,
    })
}

/// Parse an explorer response: either `{"items": [...]}` or a bare array.
///
/// Boxes that do not carry a stealth script are dropped rather than failing
/// the parse, so an endpoint change cannot break a wallet sync.
pub fn parse_explorer_boxes(json: &str) -> Result<Vec<StealthBox>, StealthError> {
    let value: serde_json::Value =
        serde_json::from_str(json).map_err(|e| StealthError::Serialization(e.to_string()))?;
    let items = match value.get("items") {
        Some(serde_json::Value::Array(a)) => a.clone(),
        _ => match value {
            serde_json::Value::Array(a) => a,
            _ => {
                return Err(StealthError::Serialization(
                    "expected an array or an object with `items`".into(),
                ))
            }
        },
    };
    Ok(items
        .iter()
        .filter_map(parse_one)
        .filter(|b| crate::tree::is_stealth_tree(&b.ergo_tree))
        .collect())
}

/// Keep only the boxes this secret can spend.
pub fn detect_owned(secret: &StealthSecret, boxes: &[StealthBox]) -> Vec<StealthBox> {
    boxes
        .iter()
        .filter(|b| secret.owns_tree(&b.ergo_tree))
        .cloned()
        .collect()
}

/// Totals across a set of stealth boxes: nanoERG plus per-token amounts.
pub fn totals(boxes: &[StealthBox]) -> (i64, BTreeMap<String, u128>) {
    let mut erg: i64 = 0;
    let mut tokens: BTreeMap<String, u128> = BTreeMap::new();
    for b in boxes {
        erg = erg.saturating_add(b.value);
        for a in &b.assets {
            let amount = a.amount.parse::<u128>().unwrap_or(0);
            *tokens.entry(a.token_id.clone()).or_insert(0) += amount;
        }
    }
    (erg, tokens)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secret::build_payment_tree_hex;
    use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
    use ergo_lib::wallet::mnemonic::Mnemonic;

    const FIXTURE: &str = include_str!("../test/fixtures/unspent_stealth_boxes.json");

    fn secret() -> StealthSecret {
        let seed = Mnemonic::to_seed(
            "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet",
            "",
        );
        StealthSecret::derive(&ExtSecretKey::derive_master(seed).unwrap()).unwrap()
    }

    #[test]
    fn parses_real_explorer_boxes() {
        let boxes = parse_explorer_boxes(FIXTURE).unwrap();
        assert_eq!(boxes.len(), 3, "fixture holds three live mainnet boxes");
        for b in &boxes {
            assert_eq!(b.box_id.len(), 64);
            assert!(crate::tree::is_stealth_tree(&b.ergo_tree));
            assert!(b.value > 0);
            // Every one parses into four group elements.
            crate::tree::parse_stealth_tree(&b.ergo_tree).unwrap();
        }
        let with_tokens = boxes.iter().filter(|b| !b.assets.is_empty()).count();
        assert!(with_tokens >= 1, "fixture covers the token-carrying case");
    }

    #[test]
    fn real_boxes_belong_to_other_people() {
        let boxes = parse_explorer_boxes(FIXTURE).unwrap();
        assert!(detect_owned(&secret(), &boxes).is_empty());
    }

    #[test]
    fn our_own_payment_is_found_among_strangers() {
        let me = secret();
        let mut boxes = parse_explorer_boxes(FIXTURE).unwrap();
        let mine = StealthBox {
            box_id: "a".repeat(64),
            transaction_id: "b".repeat(64),
            index: 0,
            value: 1_000_000,
            ergo_tree: build_payment_tree_hex(me.public_key()).unwrap(),
            creation_height: 1_000_000,
            assets: vec![StealthAsset {
                token_id: "c".repeat(64),
                amount: "5".into(),
            }],
            additional_registers: BTreeMap::new(),
        };
        boxes.push(mine.clone());

        let owned = detect_owned(&me, &boxes);
        assert_eq!(owned, vec![mine]);
        let (erg, tokens) = totals(&owned);
        assert_eq!(erg, 1_000_000);
        assert_eq!(tokens.get(&"c".repeat(64)), Some(&5u128));
    }

    #[test]
    fn non_stealth_boxes_are_dropped_not_fatal() {
        let json = serde_json::json!({"items": [
            {"boxId": "x", "transactionId": "y", "index": 0, "value": 1,
             "ergoTree": "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
             "creationHeight": 1, "assets": [], "additionalRegisters": {}}
        ]})
        .to_string();
        assert!(parse_explorer_boxes(&json).unwrap().is_empty());
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_explorer_boxes("not json").is_err());
        assert!(parse_explorer_boxes("{\"error\":\"nope\"}").is_err());
    }

    #[test]
    fn node_json_keeps_the_box_id() {
        let boxes = parse_explorer_boxes(FIXTURE).unwrap();
        let json = boxes[0].to_node_json();
        assert_eq!(json["boxId"], boxes[0].box_id);
        assert_eq!(json["ergoTree"], boxes[0].ergo_tree);
    }
}
