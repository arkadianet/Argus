//! Typed views over the four kinds of ErgoMixer box.
//!
//! Everything here takes an [`Eip12InputBox`] — the shape the rest of Argus
//! already uses for chain data — validates the ErgoTree against
//! [`crate::contracts`], and decodes the registers the contracts read. A box
//! that does not match is an error, never a silently-tolerated approximation:
//! the deployed contract is the authority.

use ergo_chain_types::EcPoint;
use ergo_tx::{Eip12Asset, Eip12InputBox};
use ergotree_ir::mir::constant::{Constant, TryExtractInto};
use ergotree_ir::serialization::SigmaSerializable;

use crate::contracts::{
    is_fee_emission_tree, is_full_mix_tree, is_half_mix_tree, is_token_emission_tree,
    HALF_MIX_SCRIPT_HASH_HEX, MIXING_TOKEN_ID,
};
use crate::error::ZeroJoinError;

// ---------------------------------------------------------------------------
// Register decoding
// ---------------------------------------------------------------------------

fn register_constant(b: &Eip12InputBox, name: &str) -> Result<Constant, ZeroJoinError> {
    let raw = b
        .additional_registers
        .get(name)
        .ok_or_else(|| ZeroJoinError::BadRegister {
            box_id: b.box_id.clone(),
            register: name.to_string(),
            expected: "present".to_string(),
        })?;
    let bytes = hex::decode(raw).map_err(|_| ZeroJoinError::BadRegister {
        box_id: b.box_id.clone(),
        register: name.to_string(),
        expected: "hex".to_string(),
    })?;
    Constant::sigma_parse_bytes(&bytes).map_err(|e| ZeroJoinError::BadRegister {
        box_id: b.box_id.clone(),
        register: name.to_string(),
        expected: format!("a constant ({e})"),
    })
}

fn bad_register(b: &Eip12InputBox, name: &str, expected: &str) -> ZeroJoinError {
    ZeroJoinError::BadRegister {
        box_id: b.box_id.clone(),
        register: name.to_string(),
        expected: expected.to_string(),
    }
}

fn group_element(b: &Eip12InputBox, name: &str) -> Result<EcPoint, ZeroJoinError> {
    register_constant(b, name)?
        .try_extract_into::<EcPoint>()
        .map_err(|_| bad_register(b, name, "GroupElement"))
}

fn coll_byte(b: &Eip12InputBox, name: &str) -> Result<Vec<u8>, ZeroJoinError> {
    let v = register_constant(b, name)?
        .try_extract_into::<Vec<i8>>()
        .map_err(|_| bad_register(b, name, "Coll[Byte]"))?;
    Ok(v.into_iter().map(|x| x as u8).collect())
}

fn long(b: &Eip12InputBox, name: &str) -> Result<i64, ZeroJoinError> {
    register_constant(b, name)?
        .try_extract_into::<i64>()
        .map_err(|_| bad_register(b, name, "Long"))
}

fn int(b: &Eip12InputBox, name: &str) -> Result<i32, ZeroJoinError> {
    register_constant(b, name)?
        .try_extract_into::<i32>()
        .map_err(|_| bad_register(b, name, "Int"))
}

/// Serialize a group element the way a register expects it (`07` + 33 bytes).
pub fn group_element_register(p: &EcPoint) -> Result<String, ZeroJoinError> {
    Constant::from(*p)
        .sigma_serialize_bytes()
        .map(hex::encode)
        .map_err(|e| ZeroJoinError::Serialization(e.to_string()))
}

/// Serialize a byte string the way a register expects it (`0e` + length + bytes).
pub fn coll_byte_register(bytes: &[u8]) -> Result<String, ZeroJoinError> {
    Constant::from(bytes.to_vec())
        .sigma_serialize_bytes()
        .map(hex::encode)
        .map_err(|e| ZeroJoinError::Serialization(e.to_string()))
}

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

fn parse_amount(a: &Eip12Asset) -> Result<i64, ZeroJoinError> {
    a.amount
        .parse::<i64>()
        .map_err(|_| ZeroJoinError::Serialization(format!("token amount {:?}", a.amount)))
}

fn value_of(b: &Eip12InputBox) -> Result<i64, ZeroJoinError> {
    b.value
        .parse::<i64>()
        .map_err(|_| ZeroJoinError::Serialization(format!("box value {:?}", b.value)))
}

/// The mixing token amount held at `tokens(0)`, plus whatever token sits at
/// `tokens(1)` for a token mix.
///
/// The contracts index tokens positionally, so this rejects a box whose first
/// token is not the mixing token instead of searching for it.
fn split_tokens(b: &Eip12InputBox) -> Result<(i64, Option<(String, i64)>), ZeroJoinError> {
    let first = b
        .assets
        .first()
        .ok_or_else(|| ZeroJoinError::MissingMixingToken {
            box_id: b.box_id.clone(),
        })?;
    if !first.token_id.eq_ignore_ascii_case(MIXING_TOKEN_ID) {
        return Err(ZeroJoinError::MissingMixingToken {
            box_id: b.box_id.clone(),
        });
    }
    let level = parse_amount(first)?;
    let mixing = match b.assets.get(1) {
        Some(a) => Some((a.token_id.clone(), parse_amount(a)?)),
        None => None,
    };
    Ok((level, mixing))
}

// ---------------------------------------------------------------------------
// Half-mix box
// ---------------------------------------------------------------------------

/// A half-mix box: Alice waiting for a counterpart.
///
/// `value` is the mix denomination — a ring only mixes boxes of exactly the
/// same value, which is why denominations must be *discovered* from the live
/// pool rather than chosen.
#[derive(Debug, Clone)]
pub struct HalfMixBox {
    pub input: Eip12InputBox,
    /// R4: `gX = g^x`, Alice's public commitment for this round.
    pub g_x: EcPoint,
    pub value: i64,
    /// Remaining mixing tokens: how many more rounds this box can pay for.
    pub mix_level: i64,
    /// `tokens(1)` for a token mix; `None` for an ERG mix.
    pub mixing_token: Option<(String, i64)>,
}

impl HalfMixBox {
    pub fn parse(input: &Eip12InputBox) -> Result<Self, ZeroJoinError> {
        if !is_half_mix_tree(&input.ergo_tree) {
            return Err(ZeroJoinError::WrongBoxKind {
                box_id: input.box_id.clone(),
                expected: "half-mix".to_string(),
            });
        }
        let (mix_level, mixing_token) = split_tokens(input)?;
        Ok(Self {
            g_x: group_element(input, "R4")?,
            value: value_of(input)?,
            mix_level,
            mixing_token,
            input: input.clone(),
        })
    }
}

// ---------------------------------------------------------------------------
// Full-mix box
// ---------------------------------------------------------------------------

/// A full-mix box: one of the two outputs of a mixing round.
///
/// It is spendable by `proveDlog(c2)` (the party that acted as Bob, holding
/// `y` with `c2 = g^y`) **or** by `proveDHTuple(g, c1, gX, c2)` (the party
/// that acted as Alice, holding `x` with `gX = g^x`). Exactly one of the two
/// full-mix boxes of a round is yours, and nobody else can tell which.
#[derive(Debug, Clone)]
pub struct FullMixBox {
    pub input: Eip12InputBox,
    /// R4.
    pub c1: EcPoint,
    /// R5.
    pub c2: EcPoint,
    /// R6: the `gX` of the half-mix box this round consumed.
    pub g_x: EcPoint,
    /// R7: `blake2b256` of the half-mix script — the contract's `delta`.
    pub delta: Vec<u8>,
    pub value: i64,
    pub mix_level: i64,
    pub mixing_token: Option<(String, i64)>,
}

impl FullMixBox {
    pub fn parse(input: &Eip12InputBox) -> Result<Self, ZeroJoinError> {
        if !is_full_mix_tree(&input.ergo_tree) {
            return Err(ZeroJoinError::WrongBoxKind {
                box_id: input.box_id.clone(),
                expected: "full-mix".to_string(),
            });
        }
        let delta = coll_byte(input, "R7")?;
        if hex::encode(&delta) != HALF_MIX_SCRIPT_HASH_HEX {
            return Err(ZeroJoinError::ContractMismatch {
                what: format!("full-mix box {} R7 (delta)", input.box_id),
                expected: HALF_MIX_SCRIPT_HASH_HEX.to_string(),
                found: hex::encode(&delta),
            });
        }
        let (mix_level, mixing_token) = split_tokens(input)?;
        Ok(Self {
            c1: group_element(input, "R4")?,
            c2: group_element(input, "R5")?,
            g_x: group_element(input, "R6")?,
            delta,
            value: value_of(input)?,
            mix_level,
            mixing_token,
            input: input.clone(),
        })
    }
}

// ---------------------------------------------------------------------------
// Emission boxes
// ---------------------------------------------------------------------------

/// The operator's fee emission box: it pays the miner fee of every mixing
/// transaction, so no spender contributes a linkable fee input.
#[derive(Debug, Clone)]
pub struct FeeEmissionBox {
    pub input: Eip12InputBox,
    /// R4: the largest fee one transaction may take from this box.
    pub max_fee: i64,
    pub value: i64,
}

impl FeeEmissionBox {
    pub fn parse(input: &Eip12InputBox) -> Result<Self, ZeroJoinError> {
        if !is_fee_emission_tree(&input.ergo_tree) {
            return Err(ZeroJoinError::WrongBoxKind {
                box_id: input.box_id.clone(),
                expected: "fee emission".to_string(),
            });
        }
        Ok(Self {
            max_fee: long(input, "R4")?,
            value: value_of(input)?,
            input: input.clone(),
        })
    }
}

/// The operator's token emission box: it sells mixing tokens in fixed batches.
///
/// `batches` is R4, a list of `(level, price)`; `rate` is R5, the divisor for
/// the proportional commission (`poolAmount / rate`).
#[derive(Debug, Clone)]
pub struct TokenEmissionBox {
    pub input: Eip12InputBox,
    pub batches: Vec<(i32, i64)>,
    pub rate: i32,
    pub value: i64,
    /// Mixing tokens still for sale.
    pub tokens_available: i64,
}

impl TokenEmissionBox {
    pub fn parse(input: &Eip12InputBox) -> Result<Self, ZeroJoinError> {
        if !is_token_emission_tree(&input.ergo_tree) {
            return Err(ZeroJoinError::WrongBoxKind {
                box_id: input.box_id.clone(),
                expected: "token emission".to_string(),
            });
        }
        let batches = register_constant(input, "R4")?
            .try_extract_into::<Vec<(i32, i64)>>()
            .map_err(|_| bad_register(input, "R4", "Coll[(Int, Long)]"))?;
        let (tokens_available, _) = split_tokens(input)?;
        Ok(Self {
            batches,
            rate: int(input, "R5")?,
            value: value_of(input)?,
            tokens_available,
            input: input.clone(),
        })
    }

    /// Price of a batch of exactly `level` mixing tokens.
    ///
    /// Only the levels the box actually offers can be bought — the contract
    /// checks `batchPrices.exists(...)`, so an invented level fails on chain.
    pub fn batch_price(&self, level: i32) -> Result<i64, ZeroJoinError> {
        self.batches
            .iter()
            .find(|(l, _)| *l == level)
            .map(|(_, p)| *p)
            .ok_or_else(|| ZeroJoinError::NoSuchBatch {
                requested: level,
                available: self.batches.iter().map(|(l, _)| *l).collect(),
            })
    }

    /// The mix levels on sale, cheapest first.
    ///
    /// Sorted by price, then level: the operator's list is not promised to
    /// be monotonic, and a caller taking the first entry means the cheapest.
    pub fn levels(&self) -> Vec<i32> {
        let mut b = self.batches.clone();
        b.sort_unstable_by_key(|(l, p)| (*p, *l));
        b.into_iter().map(|(l, _)| l).collect()
    }
}

// ---------------------------------------------------------------------------
// Explorer JSON
// ---------------------------------------------------------------------------

/// Parse explorer box JSON into the EIP-12 shape the rest of Argus uses.
///
/// Accepts either a paged response (`{"items": [...]}`) or a bare array, and
/// register values in either the explorer's object form
/// (`{"serializedValue": "07..."}`) or as a plain hex string, which is what a
/// node returns. Unknown fields are ignored.
pub fn parse_explorer_boxes(json: &str) -> Result<Vec<Eip12InputBox>, ZeroJoinError> {
    let root: serde_json::Value =
        serde_json::from_str(json).map_err(|e| ZeroJoinError::Serialization(e.to_string()))?;
    let items = match root.get("items") {
        Some(v) => v,
        None => &root,
    };
    let items = items.as_array().ok_or_else(|| {
        ZeroJoinError::Serialization(format!(
            "expected an array of boxes, got {}",
            json_shape(items)
        ))
    })?;
    items
        .iter()
        .enumerate()
        .map(|(i, it)| {
            explorer_box(it).map_err(|e| {
                // Say which item and what it looked like, never its whole
                // content: enough to see a wrong shape from a bug report.
                ZeroJoinError::Serialization(format!("item {i}: {e}; shape {}", json_shape(it)))
            })
        })
        .collect()
}

/// A one-line description of a JSON value's shape for error messages:
/// `object{boxId,value,…}`, `array[3]`, `string`, and so on.
fn json_shape(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Object(m) => {
            let mut keys: Vec<&str> = m.keys().map(String::as_str).collect();
            keys.sort_unstable();
            let shown: Vec<&str> = keys.iter().take(8).copied().collect();
            format!(
                "object{{{}{}}}",
                shown.join(","),
                if keys.len() > 8 { ",…" } else { "" }
            )
        }
        serde_json::Value::Array(a) => format!("array[{}]", a.len()),
        serde_json::Value::String(_) => "string".into(),
        serde_json::Value::Number(_) => "number".into(),
        serde_json::Value::Bool(_) => "bool".into(),
        serde_json::Value::Null => "null".into(),
    }
}

fn explorer_box(v: &serde_json::Value) -> Result<Eip12InputBox, ZeroJoinError> {
    let s = |k: &str| -> Result<String, ZeroJoinError> {
        v.get(k)
            .and_then(|x| x.as_str())
            .map(str::to_string)
            .ok_or_else(|| ZeroJoinError::Serialization(format!("box is missing {k}")))
    };
    let value = v
        .get("value")
        .and_then(|x| {
            x.as_i64()
                .map(|n| n.to_string())
                .or_else(|| x.as_str().map(str::to_string))
        })
        .ok_or_else(|| ZeroJoinError::Serialization("box is missing value".into()))?;
    let assets = v
        .get("assets")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .map(|t| {
                    let id = t
                        .get("tokenId")
                        .and_then(|x| x.as_str())
                        .unwrap_or_default()
                        .to_string();
                    let amount = t
                        .get("amount")
                        .and_then(|x| {
                            x.as_i64()
                                .map(|n| n.to_string())
                                .or_else(|| x.as_str().map(str::to_string))
                        })
                        .unwrap_or_else(|| "0".to_string());
                    Eip12Asset {
                        token_id: id,
                        amount,
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    let mut registers = std::collections::HashMap::new();
    if let Some(obj) = v.get("additionalRegisters").and_then(|r| r.as_object()) {
        for (name, raw) in obj {
            let hex = raw
                .as_str()
                .map(str::to_string)
                .or_else(|| {
                    raw.get("serializedValue")
                        .and_then(|x| x.as_str())
                        .map(str::to_string)
                })
                .ok_or_else(|| {
                    ZeroJoinError::Serialization(format!("register {name} has no serialized value"))
                })?;
            registers.insert(name.clone(), hex);
        }
    }
    // These identify the box on chain and go into the transaction as-is;
    // a default or a silently truncated value would build a transaction the
    // node rejects, or worse, one that spends the wrong box.
    let transaction_id = s("transactionId")?;
    if transaction_id.len() != 64 || !transaction_id.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(ZeroJoinError::Serialization(format!(
            "box transactionId {transaction_id:?} is not a 32-byte hex id"
        )));
    }
    let index = v
        .get("index")
        .and_then(|x| x.as_u64())
        .ok_or_else(|| ZeroJoinError::Serialization("box is missing index".into()))?;
    let index = u16::try_from(index)
        .map_err(|_| ZeroJoinError::Serialization(format!("box index {index} exceeds u16")))?;
    let creation_height = v
        .get("creationHeight")
        .and_then(|x| x.as_i64())
        .ok_or_else(|| ZeroJoinError::Serialization("box is missing creationHeight".into()))?;
    let creation_height = i32::try_from(creation_height)
        .ok()
        .filter(|h| *h >= 0)
        .ok_or_else(|| {
            ZeroJoinError::Serialization(format!(
                "box creationHeight {creation_height} is out of range"
            ))
        })?;
    Ok(Eip12InputBox {
        box_id: s("boxId")?,
        transaction_id,
        index,
        value,
        ergo_tree: s("ergoTree")?,
        assets,
        creation_height,
        additional_registers: registers,
        extension: std::collections::HashMap::new(),
    })
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// The denominations the live pool actually has half-mix boxes for.
///
/// A ring is a `(value, mixing token)` pair: ERG mixes have `None`. Returned
/// sorted by value with a count of waiting boxes, so a caller can offer only
/// denominations that have a counterpart today. Boxes that do not parse are
/// skipped rather than failing the scan — the pool is other people's data.
pub fn discover_rings(boxes: &[Eip12InputBox]) -> Vec<Ring> {
    let mut rings: Vec<Ring> = Vec::new();
    for b in boxes.iter().filter(|b| is_half_mix_tree(&b.ergo_tree)) {
        let Ok(half) = HalfMixBox::parse(b) else {
            continue;
        };
        let token_id = half.mixing_token.as_ref().map(|(id, _)| id.clone());
        let token_amount = half.mixing_token.as_ref().map(|(_, a)| *a);
        match rings.iter_mut().find(|r| {
            r.value == half.value && r.token_id == token_id && r.token_amount == token_amount
        }) {
            Some(r) => {
                r.waiting += 1;
                r.max_mix_level = r.max_mix_level.max(half.mix_level);
            }
            None => rings.push(Ring {
                value: half.value,
                token_id,
                token_amount,
                waiting: 1,
                max_mix_level: half.mix_level,
            }),
        }
    }
    rings.sort_by_key(|r| (r.value, r.token_id.clone(), r.token_amount));
    rings
}

/// One mixing denomination, as observed on chain.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Ring {
    /// nanoERG per box in this ring.
    pub value: i64,
    /// `tokens(1)` for a token mix; `None` for an ERG mix.
    pub token_id: Option<String>,
    /// Token units per box, for a token mix.
    pub token_amount: Option<i64>,
    /// Half-mix boxes currently waiting in this ring.
    pub waiting: usize,
    /// Highest mix level among them.
    pub max_mix_level: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{fixture_boxes, FULL_MIX_FIXTURE, HALF_MIX_FIXTURE};

    #[test]
    fn levels_are_cheapest_first_even_when_the_operator_lists_them_oddly() {
        let b = TokenEmissionBox {
            batches: vec![(30, 3_000_000), (10, 5_000_000), (20, 1_000_000)],
            ..crate::testing::fixture_token_box()
        };
        assert_eq!(b.levels(), vec![20, 30, 10], "price order, not level order");
    }

    #[test]
    fn explorer_boxes_with_missing_or_absurd_identity_are_rejected() {
        let good = serde_json::json!({
            "boxId": "ab", "value": 1, "ergoTree": "00", "assets": [],
            "transactionId": "0".repeat(64), "index": 0, "creationHeight": 1000000,
        });
        assert!(explorer_box(&good).is_ok());
        let mut m = good.clone();
        m.as_object_mut().unwrap().remove("transactionId");
        assert!(explorer_box(&m).is_err(), "no transaction id");
        let mut m = good.clone();
        m["transactionId"] = serde_json::json!("abc");
        assert!(explorer_box(&m).is_err(), "short transaction id");
        let mut m = good.clone();
        m["index"] = serde_json::json!(70000);
        assert!(
            explorer_box(&m).is_err(),
            "index past u16 must not be truncated"
        );
        let mut m = good.clone();
        m["creationHeight"] = serde_json::json!(-5);
        assert!(explorer_box(&m).is_err(), "negative height");
        let mut m = good.clone();
        m["creationHeight"] = serde_json::json!(5_000_000_000i64);
        assert!(
            explorer_box(&m).is_err(),
            "height past i32 must not be truncated"
        );
        let mut m = good.clone();
        m.as_object_mut().unwrap().remove("index");
        assert!(explorer_box(&m).is_err(), "no index");
    }

    #[test]
    fn a_bad_item_is_reported_with_its_position_and_shape() {
        let json = r#"[{"boxId":"a","value":1,"ergoTree":"00","assets":[],"transactionId":"0000000000000000000000000000000000000000000000000000000000000000","index":0,"creationHeight":1}, "not a box"]"#;
        let err = parse_explorer_boxes(json).unwrap_err().to_string();
        assert!(err.contains("item 1"), "{err}");
        assert!(err.contains("shape string"), "{err}");
        let err = parse_explorer_boxes(r#"[{"boxId":"a","assets":[]}]"#)
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("missing value") && err.contains("object{assets,boxId}"),
            "{err}"
        );
        let err = parse_explorer_boxes(r#"{"error":404,"reason":"no index"}"#)
            .unwrap_err()
            .to_string();
        assert!(err.contains("object{error,reason}"), "{err}");
        let err = parse_explorer_boxes(r#"{"items":"not an array"}"#)
            .unwrap_err()
            .to_string();
        assert!(err.contains("got string"), "{err}");
    }

    #[test]
    fn half_mix_fixtures_parse() {
        let boxes = fixture_boxes(HALF_MIX_FIXTURE);
        assert!(!boxes.is_empty());
        for b in &boxes {
            let h = HalfMixBox::parse(b).expect("half-mix parses");
            assert!(h.value > 0);
            assert!(h.mix_level > 0);
        }
    }

    #[test]
    fn full_mix_fixtures_parse_and_pin_the_half_mix_hash() {
        let boxes = fixture_boxes(FULL_MIX_FIXTURE);
        assert!(!boxes.is_empty());
        for b in &boxes {
            let f = FullMixBox::parse(b).expect("full-mix parses");
            assert_eq!(hex::encode(&f.delta), HALF_MIX_SCRIPT_HASH_HEX);
            assert_ne!(f.c1, f.c2);
        }
    }

    #[test]
    fn a_half_mix_box_is_not_a_full_mix_box() {
        let half = &fixture_boxes(HALF_MIX_FIXTURE)[0];
        assert!(matches!(
            FullMixBox::parse(half),
            Err(ZeroJoinError::WrongBoxKind { .. })
        ));
        let full = &fixture_boxes(FULL_MIX_FIXTURE)[0];
        assert!(matches!(
            HalfMixBox::parse(full),
            Err(ZeroJoinError::WrongBoxKind { .. })
        ));
    }

    #[test]
    fn rings_are_discovered_not_invented() {
        let boxes = fixture_boxes(HALF_MIX_FIXTURE);
        let rings = discover_rings(&boxes);
        assert!(!rings.is_empty());
        assert_eq!(rings.iter().map(|r| r.waiting).sum::<usize>(), boxes.len());
        // Discovery must never report a ring with no box behind it.
        assert!(rings.iter().all(|r| r.waiting > 0 && r.value > 0));
    }
}
