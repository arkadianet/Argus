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

/// A detected box together with the identity that owns it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedStealthBox {
    pub identity: u32,
    pub owned: StealthBox,
}

/// Which secret, if any, owns `tree_hex`.
///
/// The tree is parsed once and then tested against each identity, rather than
/// re-parsing per identity: parsing dominates the cheap identities and the
/// two exponentiations dominate the rest.
pub fn identity_for_tree<'a>(
    secrets: &'a [StealthSecret],
    tree_hex: &str,
) -> Option<&'a StealthSecret> {
    let tuple = crate::tree::parse_stealth_tree(tree_hex).ok()?;
    secrets.iter().find(|s| s.owns_tuple(&tuple))
}

/// Keep the boxes any of these identities can spend, each tagged with its
/// owner.
///
/// A box is claimed by the first identity that owns it. Two identities
/// deriving to the same scalar is not reachable from one seed, so the order
/// only matters for a caller that passed duplicates.
pub fn detect_owned_multi(secrets: &[StealthSecret], boxes: &[StealthBox]) -> Vec<OwnedStealthBox> {
    if secrets.is_empty() {
        return Vec::new();
    }
    boxes
        .iter()
        .filter_map(|b| {
            identity_for_tree(secrets, &b.ergo_tree).map(|s| OwnedStealthBox {
                identity: s.index(),
                owned: b.clone(),
            })
        })
        .collect()
}

/// Restore-time discovery: which of `secrets` actually hold funds.
///
/// A stealth identity has no on-chain footprint until it is paid, so "N empty
/// in a row, stop" would permanently miss a published-but-unpaid identity.
/// This deliberately answers a narrower question — *which identities own a
/// box in this set* — and the caller turns that into a frontier. An identity
/// that was funded and then swept clean has nothing left to find, which is
/// the accepted loss: it holds no funds either.
pub fn discover_funded_identities(secrets: &[StealthSecret], boxes: &[StealthBox]) -> Vec<u32> {
    let mut found: Vec<u32> = detect_owned_multi(secrets, boxes)
        .into_iter()
        .map(|o| o.identity)
        .collect();
    found.sort_unstable();
    found.dedup();
    found
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

    fn root() -> ExtSecretKey {
        let seed = Mnemonic::to_seed(
            "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet",
            "",
        );
        ExtSecretKey::derive_master(seed).unwrap()
    }

    fn box_paid_to(secret: &StealthSecret, id: u8) -> StealthBox {
        StealthBox {
            box_id: format!("{id:02x}").repeat(32),
            transaction_id: "b".repeat(64),
            index: 0,
            value: 1_000_000,
            ergo_tree: build_payment_tree_hex(secret.public_key()).unwrap(),
            creation_height: 1_000_000,
            assets: vec![],
            additional_registers: BTreeMap::new(),
        }
    }

    #[test]
    fn each_box_is_attributed_to_the_identity_that_owns_it() {
        let ids = StealthSecret::derive_range(&root(), 4).unwrap();
        let mut boxes = parse_explorer_boxes(FIXTURE).unwrap();
        boxes.push(box_paid_to(&ids[2], 0xa1));
        boxes.push(box_paid_to(&ids[0], 0xa2));
        boxes.push(box_paid_to(&ids[3], 0xa3));

        let owned = detect_owned_multi(&ids, &boxes);
        assert_eq!(owned.len(), 3);
        let mut pairs: Vec<(u32, &str)> = owned
            .iter()
            .map(|o| (o.identity, o.owned.box_id.as_str()))
            .collect();
        pairs.sort();
        assert_eq!(
            pairs,
            vec![
                (0, "a2".repeat(32).as_str()),
                (2, "a1".repeat(32).as_str()),
                (3, "a3".repeat(32).as_str()),
            ]
        );
    }

    /// A wallet that only knows identities 0..2 must not claim — or try to
    /// spend — a box paid to identity 3.
    #[test]
    fn a_box_beyond_the_known_frontier_is_not_ours() {
        let all = StealthSecret::derive_range(&root(), 4).unwrap();
        let known = &all[..2];
        let boxes = vec![box_paid_to(&all[3], 0xb1)];
        assert!(detect_owned_multi(known, &boxes).is_empty());
        assert!(identity_for_tree(known, &boxes[0].ergo_tree).is_none());
        assert_eq!(
            identity_for_tree(&all, &boxes[0].ergo_tree).map(|s| s.index()),
            Some(3)
        );
    }

    #[test]
    fn multi_detection_agrees_with_single_detection_for_identity_zero() {
        let ids = StealthSecret::derive_range(&root(), 3).unwrap();
        let mut boxes = parse_explorer_boxes(FIXTURE).unwrap();
        boxes.push(box_paid_to(&ids[0], 0xc1));

        let single = detect_owned(&ids[0], &boxes);
        let multi: Vec<StealthBox> = detect_owned_multi(&ids, &boxes)
            .into_iter()
            .filter(|o| o.identity == 0)
            .map(|o| o.owned)
            .collect();
        assert_eq!(single, multi);
    }

    #[test]
    fn no_identities_claims_nothing() {
        let boxes = parse_explorer_boxes(FIXTURE).unwrap();
        assert!(detect_owned_multi(&[], &boxes).is_empty());
        assert!(discover_funded_identities(&[], &boxes).is_empty());
    }

    /// Restore: only funded identities can be found, and each is reported
    /// once however many boxes it holds.
    #[test]
    fn discovery_reports_funded_identities_once_each() {
        let ids = StealthSecret::derive_range(&root(), 8).unwrap();
        let boxes = vec![
            box_paid_to(&ids[5], 0xd1),
            box_paid_to(&ids[5], 0xd2),
            box_paid_to(&ids[1], 0xd3),
        ];
        assert_eq!(discover_funded_identities(&ids, &boxes), vec![1, 5]);
        // An unfunded identity leaves no trace to discover — the reason the
        // frontier is persisted rather than gap-scanned.
        assert!(!discover_funded_identities(&ids, &boxes).contains(&2));
    }

    #[test]
    fn strangers_boxes_are_claimed_by_no_identity() {
        let ids = StealthSecret::derive_range(&root(), 16).unwrap();
        let boxes = parse_explorer_boxes(FIXTURE).unwrap();
        assert!(detect_owned_multi(&ids, &boxes).is_empty());
        assert!(discover_funded_identities(&ids, &boxes).is_empty());
    }

    #[test]
    fn node_json_keeps_the_box_id() {
        let boxes = parse_explorer_boxes(FIXTURE).unwrap();
        let json = boxes[0].to_node_json();
        assert_eq!(json["boxId"], boxes[0].box_id);
        assert_eq!(json["ergoTree"], boxes[0].ergo_tree);
    }
}
