//! Storage rent: when a box can be charged, how much a miner may take, and
//! how much ERG keeps a box (and the tokens in it) from being collected.
//!
//! The rules, as the reference node enforces them (Scala
//! `ErgoInterpreter.verify` / `checkExpiredBox`; mirrored with consensus
//! parity by arkadianet/ergo in `ergo-validation/src/tx/script/
//! storage_rent_check.rs` and `storage_rent.rs`):
//!
//! - A box may be spent without its script by the block whose height is at
//!   least `creationHeight + StoragePeriod` (`height - creationHeight >=
//!   1_051_200`, inclusive). Mempool validation uses the next block's
//!   height, so a box due at `D` can be collected once block `D - 1` is the
//!   tip.
//! - The fee is `storageFeeFactor * box.bytes.length`, an `Int * Int` product
//!   that wraps on overflow (ergoplatform/ergo#2251). At the launch factor
//!   that happens above 1,717 bytes: the fee turns negative and collecting
//!   the box would mean *adding* ERG to it, so nobody does. Above 3,435 bytes
//!   it wraps positive again and is charged.
//! - When `value - fee <= 0` the whole box may be taken, tokens included.
//!   Otherwise it must be recreated with the same script, tokens and
//!   registers, at least `value - fee`, and the collecting block's height as
//!   its creation height, which starts its next period.
//! - `box.bytes` is the whole serialized box the node hashes for the box id:
//!   the candidate with inline token ids, then the 32-byte transaction id and
//!   the VLQ output index.

use std::str::FromStr;

use ergo_lib::ergo_chain_types::Digest32;
use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
use ergo_lib::ergotree_ir::chain::ergo_box::{
    BoxTokens, ErgoBox, ErgoBoxCandidate, NonMandatoryRegisters,
};
use ergo_lib::ergotree_ir::chain::token::{Token, TokenAmount, TokenId};
use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use serde::Serialize;

use crate::CoreError;

/// Blocks a box may sit untouched before rent can be charged
/// (`Constants.StoragePeriod`, 4 × 365 × 24 × 30: four years of 2-minute
/// blocks). Fixed by the protocol, not voted.
pub const STORAGE_PERIOD: u32 = 1_051_200;

/// `storageFeeFactor` as set at launch: nanoERG per byte per period. Miners
/// may vote it anywhere in `0..=2_500_000`, so callers read the current value
/// from the node's `/info` and use this only when the node did not report
/// it, saying so wherever the figure is shown.
pub const FALLBACK_STORAGE_FEE_FACTOR: i32 = 1_250_000;

/// Target block interval, for turning block counts into approximate dates.
pub const TARGET_BLOCK_SECS: u64 = 120;

/// Rent suggestions round up to whole hundredths of an ERG, so a suggested
/// amount reads as a plain number rather than a fee calculation.
pub const SUGGESTION_STEP_NANO: u64 = 10_000_000;

/// Bytes the node adds to a candidate once a transaction creates it: the
/// 32-byte transaction id, then the output index as a VLQ, which is one byte
/// below 128 outputs.
const TX_ID_BYTES: usize = 32;

/// The fee the node computes for a box of `box_bytes` at
/// `storage_fee_factor`, including the 32-bit wrap it applies. Zero or
/// negative means the protocol cannot charge this box.
pub fn storage_fee(box_bytes: usize, storage_fee_factor: i32) -> i64 {
    // Boxes are capped at 4,096 bytes, far inside i32; saturate rather than
    // truncate if a caller passes nonsense.
    let bytes = i32::try_from(box_bytes).unwrap_or(i32::MAX);
    i64::from(storage_fee_factor.wrapping_mul(bytes))
}

/// The first block that may collect rent on a box created at
/// `creation_height`.
pub fn due_height(creation_height: u32) -> u64 {
    u64::from(creation_height) + u64::from(STORAGE_PERIOD)
}

/// What a collector may do with a box once it is due.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RentCharge {
    /// The fee is taken and the box is recreated with the rest: same
    /// script, tokens and registers, and a fresh four-year period.
    Fee,
    /// The box holds no more than the fee, so all of it may be taken,
    /// tokens included.
    WholeBox,
    /// The wrapped fee is zero or negative: collecting would cost the
    /// collector ERG, so in practice the box is never collected.
    None,
}

/// What a box would lose to rent, and when, judged at `tip_height`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BoxRent {
    pub size_bytes: usize,
    /// The node's fee for this box. May be zero or negative; see
    /// [`RentCharge::None`].
    pub fee_nano: i64,
    pub charge: RentCharge,
    /// nanoERG a collector takes: the fee, the whole value, or nothing.
    pub charge_nano: u64,
    pub due_height: u64,
    /// `due_height - tip_height`: at most 1 means the next block may collect
    /// it, and below that it has been collectable for a while.
    pub blocks_until_due: i64,
    /// True once the next block may collect it.
    pub collectable_now: bool,
}

/// [`RentCharge`] for a box of `value` against a node fee of `fee`, and the
/// nanoERG that charge takes. Mirrors `storageFeeNotCovered = value - fee <=
/// 0`, evaluated in 64 bits as the node does.
pub fn charge_for(value: u64, fee: i64) -> (RentCharge, u64) {
    if fee <= 0 {
        return (RentCharge::None, 0);
    }
    if i128::from(value) - i128::from(fee) <= 0 {
        (RentCharge::WholeBox, value)
    } else {
        (RentCharge::Fee, fee as u64)
    }
}

/// Rent position of a box of `value` and `size_bytes`, created at
/// `creation_height`, with the chain at `tip_height`.
pub fn assess(
    value: u64,
    size_bytes: usize,
    creation_height: u32,
    storage_fee_factor: i32,
    tip_height: u32,
) -> BoxRent {
    let fee_nano = storage_fee(size_bytes, storage_fee_factor);
    let (charge, charge_nano) = charge_for(value, fee_nano);
    let due = due_height(creation_height);
    let blocks_until_due = due as i64 - i64::from(tip_height);
    BoxRent {
        size_bytes,
        fee_nano,
        charge,
        charge_nano,
        due_height: due,
        blocks_until_due,
        collectable_now: u64::from(tip_height) + 1 >= due,
    }
}

/// Serialized size of an existing box, exactly as the node measures it.
///
/// For a box parsed from node JSON this is exact: ergo-lib refuses JSON
/// whose `boxId` differs from the hash of these bytes.
pub fn box_size(ergo_box: &ErgoBox) -> Result<usize, CoreError> {
    ergo_box
        .sigma_serialize_bytes()
        .map(|bytes| bytes.len())
        .map_err(|e| CoreError::Serialization(e.to_string()))
}

/// Serialized size a box will have once a transaction creates it from
/// `candidate`, assuming it is one of the first 128 outputs.
pub fn candidate_size(candidate: &ErgoBoxCandidate) -> Result<usize, CoreError> {
    let body = candidate
        .sigma_serialize_bytes()
        .map_err(|e| CoreError::Serialization(e.to_string()))?;
    Ok(body.len() + TX_ID_BYTES + 1)
}

/// A register-free output candidate: what wallet sends and consolidations
/// create. Built without ergo-lib's builder so a value below the dust floor
/// can still be measured.
pub fn output_candidate(
    value: u64,
    ergo_tree_hex: &str,
    tokens: &[(String, u64)],
    creation_height: u32,
) -> Result<ErgoBoxCandidate, CoreError> {
    let value = BoxValue::try_from(value).map_err(|e| CoreError::Transaction(e.to_string()))?;
    let tree_bytes =
        hex::decode(ergo_tree_hex).map_err(|e| CoreError::InvalidAddress(e.to_string()))?;
    let ergo_tree = ErgoTree::sigma_parse_bytes(&tree_bytes)
        .map_err(|e| CoreError::InvalidAddress(e.to_string()))?;
    let mut parsed = Vec::with_capacity(tokens.len());
    for (id, amount) in tokens {
        let digest =
            Digest32::from_str(id).map_err(|e| CoreError::Transaction(format!("token id: {e}")))?;
        let amount = TokenAmount::try_from(*amount)
            .map_err(|e| CoreError::Transaction(format!("token amount: {e}")))?;
        parsed.push(Token {
            token_id: TokenId::from(digest),
            amount,
        });
    }
    let tokens = if parsed.is_empty() {
        None
    } else {
        Some(BoxTokens::from_vec(parsed).map_err(|e| CoreError::Transaction(e.to_string()))?)
    };
    Ok(ErgoBoxCandidate {
        value,
        ergo_tree,
        tokens,
        additional_registers: NonMandatoryRegisters::empty(),
        creation_height,
    })
}

/// The least ERG, in whole [`SUGGESTION_STEP_NANO`]s, that pays one rent
/// charge and still leaves `keep_nano` in the recreated box, for a box
/// whose size at a given value is `size_at` (the value's VLQ width changes
/// the size by a byte or two). `None` when the protocol cannot charge the
/// box at all.
pub fn suggested_value(
    size_at: impl Fn(u64) -> Result<usize, CoreError>,
    storage_fee_factor: i32,
    keep_nano: u64,
) -> Result<Option<u64>, CoreError> {
    let mut value = keep_nano.max(1);
    // Each round can only grow the value's VLQ, which settles within a few.
    for _ in 0..8 {
        let fee = storage_fee(size_at(value)?, storage_fee_factor);
        if fee <= 0 {
            return Ok(None);
        }
        let needed = (fee as u64).saturating_add(keep_nano);
        let target = needed.div_ceil(SUGGESTION_STEP_NANO) * SUGGESTION_STEP_NANO;
        if target <= value {
            return Ok(Some(value));
        }
        value = target;
    }
    Ok(Some(value))
}

/// One output box of a recipient's layout and its rent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OutputRent {
    pub value_nano: u64,
    pub token_count: usize,
    #[serde(flatten)]
    pub rent: BoxRent,
}

/// Rent for everything one recipient receives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RecipientRent {
    /// The ERG the send will actually carry: what was asked for, raised to
    /// the size floor exactly as the send builders raise it.
    pub value_nano: u64,
    /// The boxes the send builders will create, in order. Only the first
    /// carries the value above the floors; any others carry their floor.
    pub boxes: Vec<OutputRent>,
    /// Recipient ERG that lets the first box pay one charge and keep the
    /// minimum box value, or `None` when the protocol cannot charge it.
    pub suggested_nano: Option<u64>,
}

/// Rent a recipient's boxes will owe if they are created at `height` and
/// never moved: the same floor and token layout the send builders apply
/// (`RecipientSpec::minimum_value`, `token_outputs`), measured box by box.
pub fn recipient_rent(
    ergo_tree_hex: &str,
    value_nano: u64,
    tokens: &[(String, u64)],
    height: u32,
    storage_fee_factor: i32,
) -> Result<RecipientRent, CoreError> {
    let min_box = citadel_core::constants::MIN_BOX_VALUE_NANO as u64;
    let spec = ergo_tx::RecipientSpec {
        ergo_tree: ergo_tree_hex.to_string(),
        amount_nano_erg: i64::try_from(value_nano)
            .map_err(|_| CoreError::Overflow("recipient value out of range".into()))?,
        tokens: tokens.to_vec(),
    };
    let assets: Vec<ergo_tx::Eip12Asset> = spec
        .assets()
        .map_err(|e| CoreError::Transaction(e.to_string()))?
        .into_iter()
        .map(|(id, amount)| ergo_tx::Eip12Asset::new(id, amount as i64))
        .collect();
    let floor = spec
        .minimum_value()
        .map_err(|e| CoreError::Transaction(e.to_string()))?;
    let value = value_nano.max(floor).max(min_box);
    let layout = ergo_tx::token_outputs(value, ergo_tree_hex, assets, height as i32, min_box)
        .map_err(|e| CoreError::Transaction(e.to_string()))?;

    let mut boxes = Vec::with_capacity(layout.len());
    let mut chunks = Vec::with_capacity(layout.len());
    for output in &layout {
        let box_value: u64 = output
            .value
            .parse()
            .map_err(|_| CoreError::Transaction("layout value".into()))?;
        let chunk: Vec<(String, u64)> = output
            .assets
            .iter()
            .map(|a| Ok((a.token_id.clone(), a.amount.parse::<u64>()?)))
            .collect::<Result<_, std::num::ParseIntError>>()
            .map_err(|_| CoreError::Transaction("layout token amount".into()))?;
        let size = candidate_size(&output_candidate(box_value, ergo_tree_hex, &chunk, height)?)?;
        boxes.push(OutputRent {
            value_nano: box_value,
            token_count: chunk.len(),
            rent: assess(box_value, size, height, storage_fee_factor, height),
        });
        chunks.push(chunk);
    }

    // Floors of every box after the first stay with them; the first box gets
    // whatever the recipient sends beyond those.
    let reserved: u64 = boxes.iter().skip(1).map(|b| b.value_nano).sum();
    let first_chunk = chunks.first().cloned().unwrap_or_default();
    let suggested_first = suggested_value(
        |v| candidate_size(&output_candidate(v, ergo_tree_hex, &first_chunk, height)?),
        storage_fee_factor,
        min_box,
    )?;
    Ok(RecipientRent {
        value_nano: value,
        boxes,
        suggested_nano: suggested_first.map(|v| v.saturating_add(reserved)),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const P2PK_G: &str = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    fn token(n: u8) -> String {
        format!("{n:02x}").repeat(32)
    }

    // ----- the fee, against the reference node -----

    #[test]
    fn fee_is_factor_times_bytes() {
        // arkadianet/ergo `small_box_default_factor_yields_positive_fee`.
        assert_eq!(storage_fee(76, 1_250_000), 95_000_000);
        assert_eq!(storage_fee(44, 1_250_000), 55_000_000);
        assert_eq!(storage_fee(76, 0), 0);
    }

    #[test]
    fn fee_wraps_like_the_node_int_product() {
        // Last positive product, then the wrap, then the positive re-wrap.
        assert_eq!(storage_fee(1_717, 1_250_000), 2_146_250_000);
        assert!(storage_fee(1_718, 1_250_000) < 0);
        assert!(storage_fee(3_435, 1_250_000) < 0);
        assert_eq!(storage_fee(3_436, 1_250_000), 32_704);
        assert_eq!(storage_fee(4_096, 1_250_000), 825_032_704);
    }

    #[test]
    fn jvm_oracle_true_box_at_the_floor() {
        // arkadianet/ergo test-vectors/ergo-sigma/verify/rent-cases.json,
        // `rent-true-box-at-floor` / `-below-floor`: a 1 ERG `true` box made
        // at height 0, collected in block 1,051,200 at factor 1,250,000. The
        // JVM accepts a recreated value of 945,000,000 and rejects one less.
        let bytes = hex::decode(concat!(
            "8094ebdc030008d3000000",
            "0000000000000000000000000000000000000000000000000000000000000000",
            "00"
        ))
        .unwrap();
        let ergo_box = ErgoBox::sigma_parse_bytes(&bytes).unwrap();
        assert_eq!(box_size(&ergo_box).unwrap(), 44);
        let rent = assess(1_000_000_000, 44, 0, 1_250_000, 1_051_199);
        assert_eq!(rent.fee_nano, 55_000_000);
        assert_eq!(rent.charge, RentCharge::Fee);
        assert_eq!(1_000_000_000 - rent.charge_nano, 945_000_000);
        assert_eq!(rent.due_height, 1_051_200);
        assert!(rent.collectable_now, "block 1,051,200 is the next block");
    }

    #[test]
    fn real_mainnet_oracle_box_is_measured_exactly() {
        // A mainnet box as the node returns it; ergo-lib checks the boxId
        // against the hash of the bytes measured here.
        let json = r#"{"boxId":"79b67d3adc64450e2b3c836d4a0d4f375205e09aa16e45325f922a2af9fe6608","value":10000000,"ergoTree":"100a040004000580dac409040004000e20f7f008ad8fcaad4490d8e78ab6d3f11efe7213a13f7b243795818b155e1acc920402040204020402d804d601b2a5e4e3000400d602db63087201d603db6308a7d604e4c6a70407ea02d1ededed93b27202730000b2720373010093c27201c2a7e6c67201040792c172017302eb02cd7204d1ededededed938cb2db6308b2a4730300730400017305938cb27202730600018cb2720373070001918cb27202730800028cb272037309000293e4c672010407720492c17201c1a7efe6c672010561","assets":[{"tokenId":"e5abaf1f0a9442123104cdf4d2d56ddd8065803e842bc6d433e712601133a9bc","amount":1},{"tokenId":"05965018a4525add81bdf6feb6dc4621dcef6789802fa53cebe39505a3b8588d","amount":15835}],"creationHeight":1865321,"additionalRegisters":{"R4":"0703bda2691a9f1a2adf122741390847e7dae2c75bd2eb3a0dc896388d4ec3e9577b","R5":"04fada01","R6":"1115a0d98ad91280eee7c2de04e0b19cb205f6f30af68c1bea378c10a0e5b901f8b406e0efcade39e0a389f08f03c0d0b44080baae06e0ca995bc099ab57c0fae30280dfd41196b4208a83dcae22f2b05100"},"transactionId":"441dc8526ac98cca5d83af1ba6166d56c4f47126a90ac5720881f9680f74a267","index":3}"#;
        let ergo_box: ErgoBox = serde_json::from_str(json).unwrap();
        let size = box_size(&ergo_box).unwrap();
        assert_eq!(size, 438);
        let rent = assess(10_000_000, size, 1_865_321, 1_250_000, 1_900_000);
        assert_eq!(rent.fee_nano, 547_500_000);
        // 0.01 ERG cannot pay 0.5475 ERG: the box and its two tokens go.
        assert_eq!(rent.charge, RentCharge::WholeBox);
        assert_eq!(rent.charge_nano, 10_000_000);
        assert_eq!(rent.due_height, 2_916_521);
        assert_eq!(rent.blocks_until_due, 1_016_521);
        assert!(!rent.collectable_now);
    }

    #[test]
    fn p2pk_box_without_tokens_matches_the_layout() {
        // 3 value + 36 tree + 1 height + 1 + 1 counts + 32 tx id + 1 index.
        let c = output_candidate(1_000_000, P2PK_G, &[], 0).unwrap();
        assert_eq!(candidate_size(&c).unwrap(), 75);
        let real =
            ErgoBox::from_box_candidate(&c, ergo_lib::ergotree_ir::chain::tx_id::TxId::zero(), 0)
                .unwrap();
        assert_eq!(box_size(&real).unwrap(), 75);
    }

    // ----- eligibility -----

    #[test]
    fn due_exactly_one_period_after_creation() {
        assert_eq!(due_height(0), u64::from(STORAGE_PERIOD));
        assert_eq!(due_height(1_600_000), 2_651_200);
        let early = assess(1_000_000_000, 100, 0, 1_250_000, STORAGE_PERIOD - 2);
        assert!(!early.collectable_now);
        assert_eq!(early.blocks_until_due, 2);
        let next = assess(1_000_000_000, 100, 0, 1_250_000, STORAGE_PERIOD - 1);
        assert!(next.collectable_now);
        let late = assess(1_000_000_000, 100, 0, 1_250_000, 2 * STORAGE_PERIOD);
        assert!(late.collectable_now);
        assert_eq!(late.blocks_until_due, -i64::from(STORAGE_PERIOD));
    }

    // ----- what a collector takes -----

    #[test]
    fn whole_box_when_value_does_not_exceed_the_fee() {
        assert_eq!(
            charge_for(55_000_000, 55_000_000),
            (RentCharge::WholeBox, 55_000_000)
        );
        assert_eq!(
            charge_for(1_000_000, 55_000_000),
            (RentCharge::WholeBox, 1_000_000)
        );
        assert_eq!(
            charge_for(55_000_001, 55_000_000),
            (RentCharge::Fee, 55_000_000)
        );
    }

    #[test]
    fn wrapped_fee_charges_nothing() {
        let rent = assess(1_000_000, 2_000, 0, 1_250_000, 2_000_000);
        assert!(rent.fee_nano < 0);
        assert_eq!(rent.charge, RentCharge::None);
        assert_eq!(rent.charge_nano, 0);
        // Re-wrapped positive: a near-limit box is charged again.
        let big = assess(1_451_520, 4_032, 0, 1_250_000, 2_000_000);
        assert_eq!(big.fee_nano, 745_032_704);
        assert_eq!(big.charge, RentCharge::WholeBox);
    }

    // ----- suggestions -----

    #[test]
    fn nft_to_p2pk_suggests_rent_plus_minimum_rounded_up() {
        // 3 value + 36 tree + 3 height + 1 count + 33 token + 1 + 32 + 1.
        let nft = vec![(token(7), 1)];
        let at_min = output_candidate(1_000_000, P2PK_G, &nft, 1_600_000).unwrap();
        assert_eq!(candidate_size(&at_min).unwrap(), 110);
        let r = recipient_rent(P2PK_G, 1_000_000, &nft, 1_600_000, 1_250_000).unwrap();
        assert_eq!(r.value_nano, 1_000_000);
        assert_eq!(r.boxes.len(), 1);
        assert_eq!(r.boxes[0].rent.fee_nano, 137_500_000);
        assert_eq!(r.boxes[0].rent.charge, RentCharge::WholeBox);
        assert_eq!(r.boxes[0].rent.due_height, 2_651_200);
        // At 0.14 ERG the value takes a fourth VLQ byte: 111 bytes, a
        // 0.13875 ERG fee, and 0.00125 ERG left after one charge.
        assert_eq!(r.suggested_nano, Some(140_000_000));
        let at_suggested = recipient_rent(P2PK_G, 140_000_000, &nft, 1_600_000, 1_250_000).unwrap();
        assert_eq!(at_suggested.boxes[0].rent.size_bytes, 111);
        assert_eq!(at_suggested.boxes[0].rent.charge, RentCharge::Fee);
        assert!(140_000_000 - at_suggested.boxes[0].rent.fee_nano as u64 >= 1_000_000);
    }

    #[test]
    fn suggestion_follows_a_voted_factor() {
        let nft = vec![(token(7), 1)];
        let r = recipient_rent(P2PK_G, 1_000_000, &nft, 1_600_000, 2_500_000).unwrap();
        // 110 bytes at 2.5 mERG per byte rounds up to 0.28 ERG, but 0.28 ERG
        // is past 2^28 nanoERG, a fifth VLQ byte: 112 bytes, a 0.28 ERG fee,
        // so the suggestion settles one step higher.
        assert_eq!(r.suggested_nano, Some(290_000_000));
        let settled = recipient_rent(P2PK_G, 290_000_000, &nft, 1_600_000, 2_500_000).unwrap();
        assert_eq!(settled.boxes[0].rent.size_bytes, 112);
        assert_eq!(settled.boxes[0].rent.fee_nano, 280_000_000);
        assert_eq!(
            recipient_rent(P2PK_G, 1, &nft, 1_600_000, 0)
                .unwrap()
                .suggested_nano,
            None
        );
    }

    #[test]
    fn large_bundles_follow_the_builder_layout() {
        // 150 distinct tokens do not fit one 4 KB box; the builders split
        // them and fund each extra box with its floor only.
        let tokens: Vec<(String, u64)> = (0..150u32)
            .map(|i| (format!("{i:064x}"), 1_000_000_000))
            .collect();
        let r = recipient_rent(P2PK_G, 1_000_000, &tokens, 1_600_000, 1_250_000).unwrap();
        assert_eq!(r.boxes.len(), 2);
        assert_eq!(r.boxes.iter().map(|b| b.token_count).sum::<usize>(), 150);
        let extra = &r.boxes[1];
        assert_eq!(
            extra.value_nano,
            ergo_tx::min_value_for(
                ergo_tx::box_bytes(
                    P2PK_G,
                    &tokens[r.boxes[0].token_count..]
                        .iter()
                        .map(|(id, a)| ergo_tx::Eip12Asset::new(id.clone(), *a as i64))
                        .collect::<Vec<_>>(),
                    &Default::default(),
                ),
                1_000_000,
            )
        );
        assert_eq!(
            r.value_nano,
            r.boxes.iter().map(|b| b.value_nano).sum::<u64>()
        );
        // The full first box is past 3,435 bytes, where the fee wraps back to
        // positive: at its floor value it would be taken whole.
        let first = &r.boxes[0];
        assert!(first.rent.size_bytes > 3_435 && first.rent.size_bytes <= 4_096);
        assert!(first.rent.fee_nano > 0);
        assert_eq!(first.rent.charge, RentCharge::WholeBox);
        // The suggestion covers the first box; the extra box keeps its floor.
        let suggested = r.suggested_nano.expect("chargeable first box");
        let funded = recipient_rent(P2PK_G, suggested, &tokens, 1_600_000, 1_250_000).unwrap();
        assert_eq!(funded.boxes[0].rent.charge, RentCharge::Fee);
        assert_eq!(funded.boxes[1].value_nano, extra.value_nano);
    }

    #[test]
    fn blank_amount_is_raised_to_the_size_floor_like_the_builders() {
        let tokens: Vec<(String, u64)> = (0..60u32).map(|i| (format!("{i:064x}"), 5)).collect();
        let r = recipient_rent(P2PK_G, 1_000_000, &tokens, 1_600_000, 1_250_000).unwrap();
        let spec = ergo_tx::RecipientSpec {
            ergo_tree: P2PK_G.into(),
            amount_nano_erg: 1_000_000,
            tokens: tokens.clone(),
        };
        assert_eq!(r.value_nano, spec.minimum_value().unwrap().max(1_000_000));
        // ~2,060 bytes: the fee wraps negative, so no charge and no suggestion.
        assert_eq!(r.boxes.len(), 1);
        assert_eq!(r.boxes[0].rent.charge, RentCharge::None);
        assert_eq!(r.suggested_nano, None);
    }
}
