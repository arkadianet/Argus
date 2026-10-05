//! Babel fees (EIP-31): pay the miner fee in a token.
//!
//! A supporter publishes a *babel box* under a contract fixed to one
//! token: ERG guarded by a price in R5 (nanoERG the supporter pays per
//! token unit) and their key in R4. Anyone may spend it who recreates it
//! with the same script and registers, `R6 = the spent box's id`, less
//! ERG and more of the token such that `tokens added × price ≥ ERG
//! taken`, and who names the recreated output's index in the spending
//! input's context variable 0.
//!
//! Argus applies this as a step after an ordinary build: the babel box
//! is one of the inputs the builder saw (so its ERG covered the fee), and
//! this module then takes that ERG back out of the change, moves the
//! tokens, and adds the recreated babel box.

use std::collections::HashMap;

use crate::eip12::{Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};
use citadel_core::constants::{MINER_FEE_ERGO_TREE, MIN_BOX_VALUE_NANO as MIN_BOX_VALUE};

/// `blake2b256` of the contract template, for explorer lookups.
pub const BABEL_TEMPLATE_HASH: &str =
    "4e83fa68ef3ed9794bbab5d8799998a9e09fb10a0afe8d1bf928936dfd11c465";
const PREFIX: &str = "100604000e20";
const SUFFIX: &str = "0400040005000500d803d601e30004d602e4c6a70408d603e4c6a7050595e67201d804d604b2a5e4720100d605b2db63087204730000d606db6308a7d60799c1a7c17204d1968302019683050193c27204c2a7938c720501730193e4c672040408720293e4c672040505720393e4c67204060ec5a796830201929c998c7205029591b1720673028cb272067303000273047203720792720773057202";

/// The babel contract for `token_id`: the template with the id in it.
pub fn babel_ergo_tree(token_id: &str) -> String {
    format!("{PREFIX}{}{SUFFIX}", token_id.to_ascii_lowercase())
}

/// The token a babel contract is for, if the tree is one.
pub fn babel_token_of(ergo_tree: &str) -> Option<String> {
    let t = ergo_tree.to_ascii_lowercase();
    let body = t.strip_prefix(PREFIX)?.strip_suffix(SUFFIX)?;
    (body.len() == 64 && body.chars().all(|c| c.is_ascii_hexdigit())).then(|| body.to_string())
}

#[derive(Debug, thiserror::Error)]
pub enum BabelError {
    #[error("not a babel box for this token")]
    NotBabel,
    #[error("babel box has no price")]
    NoPrice,
    #[error("babel box price must be positive")]
    BadPrice,
    #[error("babel box holds too little ERG for this fee")]
    TooSmall,
    #[error("the transaction has no miner fee output")]
    NoFee,
    #[error("the transaction has no change box to take the fee's ERG from")]
    NoChange,
    #[error("change would fall below the minimum box value; add a little ERG")]
    ChangeTooSmall,
    #[error("inputs hold {have} of the fee token but the fee needs {need}")]
    InsufficientTokens { have: u64, need: u64 },
    #[error("the babel box is not among the inputs")]
    NotAnInput,
    #[error("the designated change outputs are invalid")]
    InvalidChangeRange,
    #[error("the transaction contains an invalid ERG or token amount")]
    InvalidAmount,
    #[error("ERG or token amount exceeds the representable range")]
    AmountOverflow,
    #[error("change after paying the token fee requires {min} nanoERG, have {have}")]
    ChangeNeedsErg { have: i64, min: i64 },
    #[error("change after paying the token fee cannot be built: {0}")]
    ChangeLayout(String),
}

/// A babel box, read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BabelBox {
    pub box_id: String,
    pub token_id: String,
    pub value: i64,
    /// nanoERG the supporter pays per token unit (`R5`).
    pub price: i64,
    /// Tokens already in the box (`tokens(0)`), possibly none.
    pub tokens_before: u64,
    r4: String,
    r5: String,
}

/// A `Coll[Byte]` constant: `0e`, the length as an unsigned VLQ, the bytes.
fn coll_byte_hex(bytes: &[u8]) -> String {
    let mut out = vec![0x0eu8];
    let mut n = bytes.len() as u64;
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            break;
        }
        out.push(b | 0x80);
    }
    out.extend_from_slice(bytes);
    hex::encode(out)
}

/// A `Long` constant: `05` then the zigzag VLQ.
fn decode_long(hex_str: &str) -> Option<i64> {
    let bytes = hex::decode(hex_str).ok()?;
    if bytes.first() != Some(&0x05) {
        return None;
    }
    let mut v: u64 = 0;
    let mut shift = 0;
    for b in &bytes[1..] {
        v |= u64::from(b & 0x7f) << shift;
        if b & 0x80 == 0 {
            return Some(((v >> 1) as i64) ^ -((v & 1) as i64));
        }
        shift += 7;
        if shift > 63 {
            return None;
        }
    }
    None
}

/// An `Int` constant: `04` then the zigzag VLQ.
fn int_hex(v: i32) -> String {
    let mut n = ((v as i64) << 1) ^ ((v as i64) >> 31);
    let mut out = vec![0x04u8];
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            break;
        }
        out.push(b | 0x80);
    }
    hex::encode(out)
}

impl BabelBox {
    pub fn parse(input: &Eip12InputBox, token_id: &str) -> Result<Self, BabelError> {
        match babel_token_of(&input.ergo_tree) {
            Some(t) if t.eq_ignore_ascii_case(token_id) => {}
            _ => return Err(BabelError::NotBabel),
        }
        let r4 = input
            .additional_registers
            .get("R4")
            .cloned()
            .ok_or(BabelError::NotBabel)?;
        let r5 = input
            .additional_registers
            .get("R5")
            .cloned()
            .ok_or(BabelError::NoPrice)?;
        let price = decode_long(&r5).ok_or(BabelError::NoPrice)?;
        if price <= 0 {
            return Err(BabelError::BadPrice);
        }
        let tokens_before = match input.assets.first() {
            Some(a) if a.token_id.eq_ignore_ascii_case(token_id) => a.amount.parse().unwrap_or(0),
            Some(_) => return Err(BabelError::NotBabel),
            None => 0,
        };
        Ok(Self {
            box_id: input.box_id.clone(),
            token_id: token_id.to_ascii_lowercase(),
            value: input.value.parse().unwrap_or(0),
            price,
            tokens_before,
            r4,
            r5,
        })
    }

    /// Tokens that buy `nano` of ERG at this price, rounded up.
    pub fn tokens_for(&self, nano: i64) -> u64 {
        if nano <= 0 {
            return 0;
        }
        (nano as u64).div_ceil(self.price as u64)
    }

    /// Whether the box can pay `fee` and still be a box afterwards.
    pub fn can_pay(&self, fee: i64) -> bool {
        self.value - fee >= MIN_BOX_VALUE
    }
}

/// The best babel box for `token_id` among `candidates` that can pay
/// `fee`: the one asking the fewest tokens, i.e. the highest price.
pub fn pick_babel_box(candidates: &[Eip12InputBox], token_id: &str, fee: i64) -> Option<BabelBox> {
    candidates
        .iter()
        .filter_map(|b| BabelBox::parse(b, token_id).ok())
        .filter(|b| b.can_pay(fee))
        .max_by_key(|b| b.price)
}

/// What a babel swap cost.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BabelSummary {
    pub token_id: String,
    pub tokens_paid: u64,
    pub price: i64,
    pub fee_nano: i64,
    pub babel_box_id: String,
}

/// Turn a built transaction whose inputs include `babel`'s box into a
/// babel-fee transaction: the fee's ERG comes out of the change (where
/// the builder put the babel box's ERG), the tokens move into the
/// recreated babel box, and the babel input names that output.
pub fn apply_babel(
    tx: &mut Eip12UnsignedTx,
    babel: &BabelBox,
    change_tree: &str,
) -> Result<BabelSummary, BabelError> {
    let babel_index = tx
        .inputs
        .iter()
        .position(|i| i.box_id == babel.box_id)
        .ok_or(BabelError::NotAnInput)?;
    let fee_index = tx
        .outputs
        .iter()
        .position(|o| o.ergo_tree == MINER_FEE_ERGO_TREE)
        .ok_or(BabelError::NoFee)?;
    let fee: i64 = tx.outputs[fee_index].value.parse().unwrap_or(0);
    if !babel.can_pay(fee) {
        return Err(BabelError::TooSmall);
    }
    let needed = babel.tokens_for(fee);
    // From the end: the builders put the recipients first and the change
    // after them, and a send to the wallet's own change address gives the
    // recipient box the same script. Taking the first match would move the
    // babel ERG and tokens out of what the user meant to send.
    let change_index = tx
        .outputs
        .iter()
        .rposition(|o| o.ergo_tree == change_tree)
        .ok_or(BabelError::NoChange)?;

    // The change: give back the babel box's ERG (less the fee it pays),
    // and hand over the babel box's own tokens plus the fee's worth.
    let change = &mut tx.outputs[change_index];
    let change_value: i64 = change.value.parse().unwrap_or(0) - (babel.value - fee);
    if change_value < MIN_BOX_VALUE {
        return Err(BabelError::ChangeTooSmall);
    }
    change.value = change_value.to_string();
    let have: u64 = change
        .assets
        .iter()
        .find(|a| a.token_id.eq_ignore_ascii_case(&babel.token_id))
        .and_then(|a| a.amount.parse().ok())
        .unwrap_or(0);
    let take = babel.tokens_before + needed;
    if have < take {
        return Err(BabelError::InsufficientTokens {
            have: have.saturating_sub(babel.tokens_before),
            need: needed,
        });
    }
    let left = have - take;
    change
        .assets
        .retain(|a| !a.token_id.eq_ignore_ascii_case(&babel.token_id));
    if left > 0 {
        change
            .assets
            .push(Eip12Asset::new(babel.token_id.clone(), left as i64));
    }

    // The recreated babel box, just before the fee.
    let mut registers = HashMap::new();
    registers.insert("R4".into(), babel.r4.clone());
    registers.insert("R5".into(), babel.r5.clone());
    registers.insert(
        "R6".into(),
        coll_byte_hex(&hex::decode(&babel.box_id).unwrap_or_default()),
    );
    let height = tx.outputs[fee_index].creation_height;
    tx.outputs.insert(
        fee_index,
        Eip12Output {
            value: (babel.value - fee).to_string(),
            ergo_tree: babel_ergo_tree(&babel.token_id),
            assets: vec![Eip12Asset::new(babel.token_id.clone(), take as i64)],
            creation_height: height,
            additional_registers: registers,
        },
    );
    tx.inputs[babel_index]
        .extension
        .insert("0".into(), int_hex(fee_index as i32));
    Ok(BabelSummary {
        token_id: babel.token_id.clone(),
        tokens_paid: needed,
        price: babel.price,
        fee_nano: fee,
        babel_box_id: babel.box_id.clone(),
    })
}

/// Apply a token fee using only the builder's designated change outputs.
/// Large bundles can split change across boxes, including the fee token in
/// an earlier box. A recipient may also have the same script as change.
/// Repacking the complete change range preserves every recipient and funds
/// each remaining change box. Failure leaves the original transaction intact.
pub fn apply_babel_to_change_outputs(
    tx: &mut Eip12UnsignedTx,
    babel: &BabelBox,
    change_tree: &str,
    change_range: std::ops::Range<usize>,
) -> Result<BabelSummary, BabelError> {
    if change_range.is_empty() || change_range.end > tx.outputs.len() {
        return Err(BabelError::InvalidChangeRange);
    }
    let babel_index = tx
        .inputs
        .iter()
        .position(|input| input.box_id == babel.box_id)
        .ok_or(BabelError::NotAnInput)?;
    // The supplied quote must describe the actual input being recreated.
    if BabelBox::parse(&tx.inputs[babel_index], &babel.token_id)? != *babel {
        return Err(BabelError::NotBabel);
    }
    let mut fees = tx
        .outputs
        .iter()
        .enumerate()
        .filter(|(_, output)| output.ergo_tree == MINER_FEE_ERGO_TREE);
    let (fee_index, fee_output) = fees.next().ok_or(BabelError::NoFee)?;
    if fees.next().is_some() || change_range.contains(&fee_index) {
        return Err(BabelError::InvalidChangeRange);
    }
    let fee = fee_output
        .value
        .parse::<i64>()
        .ok()
        .filter(|fee| *fee > 0)
        .ok_or(BabelError::InvalidAmount)?;
    if babel.price <= 0 || babel.value <= fee {
        return Err(BabelError::TooSmall);
    }
    let recreated_value = babel
        .value
        .checked_sub(fee)
        .ok_or(BabelError::AmountOverflow)?;
    let needed = babel.tokens_for(fee);
    let take = babel
        .tokens_before
        .checked_add(needed)
        .filter(|amount| *amount <= i64::MAX as u64)
        .ok_or(BabelError::AmountOverflow)?;

    let mut change_value = 0i64;
    let mut change_assets: Vec<Eip12Asset> = Vec::new();
    for output in &tx.outputs[change_range.clone()] {
        if output.ergo_tree != change_tree || !output.additional_registers.is_empty() {
            return Err(BabelError::InvalidChangeRange);
        }
        let value = output
            .value
            .parse::<i64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or(BabelError::InvalidAmount)?;
        change_value = change_value
            .checked_add(value)
            .ok_or(BabelError::AmountOverflow)?;
        for asset in &output.assets {
            let amount = asset
                .amount
                .parse::<u64>()
                .ok()
                .filter(|amount| *amount > 0)
                .ok_or(BabelError::InvalidAmount)?;
            match change_assets
                .iter_mut()
                .find(|a| a.token_id.eq_ignore_ascii_case(&asset.token_id))
            {
                Some(held) => {
                    let held_amount = held
                        .amount
                        .parse::<u64>()
                        .map_err(|_| BabelError::InvalidAmount)?;
                    held.amount = held_amount
                        .checked_add(amount)
                        .ok_or(BabelError::AmountOverflow)?
                        .to_string();
                }
                None => change_assets.push(asset.clone()),
            }
        }
    }
    let change_value = change_value
        .checked_sub(recreated_value)
        .ok_or(BabelError::AmountOverflow)?;
    let token_position = change_assets
        .iter()
        .position(|asset| asset.token_id.eq_ignore_ascii_case(&babel.token_id));
    let have = token_position
        .map(|position| change_assets[position].amount.parse::<u64>())
        .transpose()
        .map_err(|_| BabelError::InvalidAmount)?
        .unwrap_or(0);
    if have < take {
        return Err(BabelError::InsufficientTokens {
            have: have.saturating_sub(babel.tokens_before),
            need: needed,
        });
    }
    if let Some(position) = token_position {
        if have == take {
            change_assets.remove(position);
        } else {
            change_assets[position].amount = (have - take).to_string();
        }
    }
    if change_value < MIN_BOX_VALUE {
        return Err(BabelError::ChangeNeedsErg {
            have: change_value,
            min: MIN_BOX_VALUE,
        });
    }
    if change_assets.iter().any(|asset| {
        asset
            .amount
            .parse::<u64>()
            .map_or(true, |amount| amount > i64::MAX as u64)
    }) {
        return Err(BabelError::AmountOverflow);
    }
    let height = fee_output.creation_height;
    let new_change = crate::token_outputs(
        change_value as u64,
        change_tree,
        change_assets,
        height,
        MIN_BOX_VALUE as u64,
    )
    .map_err(|error| match error {
        crate::ChangeOutputError::NotEnoughErg {
            min_value,
            available,
        } => BabelError::ChangeNeedsErg {
            have: available as i64,
            min: min_value as i64,
        },
        other => BabelError::ChangeLayout(other.to_string()),
    })?;

    let mut registers = HashMap::new();
    registers.insert("R4".into(), babel.r4.clone());
    registers.insert("R5".into(), babel.r5.clone());
    let box_id = hex::decode(&babel.box_id).map_err(|_| BabelError::NotBabel)?;
    if box_id.len() != 32 {
        return Err(BabelError::NotBabel);
    }
    registers.insert("R6".into(), coll_byte_hex(&box_id));
    let recreated = Eip12Output {
        value: recreated_value.to_string(),
        ergo_tree: babel_ergo_tree(&babel.token_id),
        assets: vec![Eip12Asset::new(babel.token_id.clone(), take as i64)],
        creation_height: height,
        additional_registers: registers,
    };
    let recreated_bytes = crate::box_bytes(
        &recreated.ergo_tree,
        &recreated.assets,
        &recreated.additional_registers,
    );
    if recreated_bytes > crate::MAX_BOX_BYTES
        || recreated_value < crate::min_value_for(recreated_bytes, MIN_BOX_VALUE as u64) as i64
    {
        return Err(BabelError::TooSmall);
    }

    let mut updated = tx.clone();
    updated.outputs.splice(change_range, new_change);
    let recreated_index = updated
        .outputs
        .iter()
        .position(|output| output.ergo_tree == MINER_FEE_ERGO_TREE)
        .ok_or(BabelError::NoFee)?;
    let context_index = i32::try_from(recreated_index).map_err(|_| BabelError::AmountOverflow)?;
    updated.outputs.insert(recreated_index, recreated);
    updated.inputs[babel_index]
        .extension
        .insert("0".into(), int_hex(context_index));
    *tx = updated;
    Ok(BabelSummary {
        token_id: babel.token_id.clone(),
        tokens_paid: needed,
        price: babel.price,
        fee_nano: fee,
        babel_box_id: babel.box_id.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";
    const USER: &str = "0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582";

    fn input(
        id: &str,
        value: i64,
        tree: &str,
        assets: Vec<(&str, i64)>,
        regs: Vec<(&str, &str)>,
    ) -> Eip12InputBox {
        Eip12InputBox {
            box_id: id.repeat(32),
            transaction_id: "00".repeat(32),
            index: 0,
            value: value.to_string(),
            ergo_tree: tree.into(),
            assets: assets
                .into_iter()
                .map(|(t, n)| Eip12Asset::new(t.to_string(), n))
                .collect(),
            creation_height: 1,
            additional_registers: regs
                .into_iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            extension: HashMap::new(),
        }
    }

    /// A supporter's box: 1 ERG at 1,000,000 nanoERG per SigUSD cent, 5 cents in it already.
    fn babel_input() -> Eip12InputBox {
        // 1_000_000 as a Long: 05 + zigzag(2_000_000) = 80 89 7a.
        input(
            "bb",
            1_000_000_000,
            &babel_ergo_tree(TOKEN),
            vec![(TOKEN, 5)],
            vec![("R4", "08cd02aa"), ("R5", "0580897a")],
        )
    }

    fn split_change_tx(wallet_value: i64) -> Eip12UnsignedTx {
        let ids: Vec<String> = (100..230).map(|i| format!("{i:064x}")).collect();
        let mut first_assets = vec![Eip12Asset::new(TOKEN, 12)];
        first_assets.extend(ids[..80].iter().map(|id| Eip12Asset::new(id, 7)));
        let second_assets: Vec<_> = ids[80..].iter().map(|id| Eip12Asset::new(id, 7)).collect();
        let mut first_input = input(
            "aa",
            wallet_value - MIN_BOX_VALUE,
            USER,
            vec![(TOKEN, 10)],
            vec![],
        );
        first_input
            .assets
            .extend(ids[..80].iter().map(|id| Eip12Asset::new(id, 7)));
        let mut second_input = input("cc", MIN_BOX_VALUE, USER, vec![], vec![]);
        second_input.assets = second_assets.clone();
        Eip12UnsignedTx {
            inputs: vec![first_input, second_input, babel_input()],
            data_inputs: vec![],
            outputs: vec![
                // A self-send recipient outside the designated change range.
                Eip12Output::change(MIN_BOX_VALUE, USER, vec![Eip12Asset::new(TOKEN, 3)], 100),
                Eip12Output::change(
                    wallet_value + 1_000_000_000 - 2 * MIN_BOX_VALUE - 1_100_000,
                    USER,
                    first_assets,
                    100,
                ),
                Eip12Output::change(MIN_BOX_VALUE, USER, second_assets, 100),
                Eip12Output::fee(1_100_000, 100),
            ],
        }
    }

    fn token_totals(assets: impl Iterator<Item = Eip12Asset>) -> HashMap<String, u64> {
        let mut totals = HashMap::new();
        for asset in assets {
            *totals.entry(asset.token_id).or_insert(0) += asset.amount.parse::<u64>().unwrap();
        }
        totals
    }

    #[test]
    fn token_fee_relayouts_all_change_and_preserves_self_send_recipient() {
        let mut tx = split_change_tx(40_000_000);
        let babel = BabelBox::parse(&tx.inputs[2], TOKEN).unwrap();
        assert!(tx.outputs[1]
            .assets
            .iter()
            .any(|asset| asset.token_id == TOKEN));
        assert!(!tx.outputs[2]
            .assets
            .iter()
            .any(|asset| asset.token_id == TOKEN));
        let recipient = serde_json::to_value(&tx.outputs[0]).unwrap();
        let input_tokens = token_totals(tx.inputs.iter().flat_map(|input| input.assets.clone()));
        let summary = apply_babel_to_change_outputs(&mut tx, &babel, USER, 1..3).unwrap();
        assert_eq!(summary.tokens_paid, 2);
        assert_eq!(serde_json::to_value(&tx.outputs[0]).unwrap(), recipient);
        assert_eq!(
            tx.outputs
                .iter()
                .map(|output| output.value.parse::<i64>().unwrap())
                .sum::<i64>(),
            1_040_000_000
        );
        assert_eq!(
            token_totals(tx.outputs.iter().flat_map(|output| output.assets.clone())),
            input_tokens
        );
        let recreated_index = tx
            .outputs
            .iter()
            .position(|output| output.ergo_tree == babel_ergo_tree(TOKEN))
            .unwrap();
        assert_eq!(tx.outputs[recreated_index].value, "998900000");
        assert_eq!(tx.outputs[recreated_index].assets[0].amount, "7");
        assert_eq!(
            tx.inputs[2].extension.get("0"),
            Some(&int_hex(recreated_index as i32))
        );
        let change = &tx.outputs[1..recreated_index];
        assert_eq!(change.len(), 2);
        assert_eq!(
            change
                .iter()
                .map(|output| output.value.parse::<i64>().unwrap())
                .sum::<i64>(),
            39_000_000
        );
        for output in change {
            let bytes = crate::box_bytes(
                &output.ergo_tree,
                &output.assets,
                &output.additional_registers,
            );
            assert!(bytes <= crate::MAX_BOX_BYTES);
            assert!(output.assets.len() <= crate::MAX_TOKENS_PER_BOX);
            assert!(
                output.value.parse::<u64>().unwrap()
                    >= crate::min_value_for(bytes, MIN_BOX_VALUE as u64)
            );
        }
    }

    #[test]
    fn token_fee_change_shortfall_and_invalid_range_leave_transaction_untouched() {
        let mut tx = split_change_tx(2_100_000);
        let babel = BabelBox::parse(&tx.inputs[2], TOKEN).unwrap();
        let before = serde_json::to_value(&tx).unwrap();
        let error = apply_babel_to_change_outputs(&mut tx, &babel, USER, 1..3).unwrap_err();
        assert!(
            matches!(error, BabelError::ChangeNeedsErg { have: 1_100_000, min } if min > 2_000_000)
        );
        assert_eq!(serde_json::to_value(&tx).unwrap(), before);
        for range in [1..4, 2..1, 1..5] {
            assert!(matches!(
                apply_babel_to_change_outputs(&mut tx, &babel, USER, range),
                Err(BabelError::InvalidChangeRange)
            ));
            assert_eq!(serde_json::to_value(&tx).unwrap(), before);
        }
        assert!(matches!(
            apply_babel_to_change_outputs(&mut tx, &babel, "other-tree", 1..3),
            Err(BabelError::InvalidChangeRange)
        ));
        assert_eq!(serde_json::to_value(&tx).unwrap(), before);
    }

    #[test]
    fn the_contract_is_the_template_with_the_token_in_it() {
        let tree = babel_ergo_tree(TOKEN);
        assert!(tree.starts_with("100604000e20"));
        assert_eq!(babel_token_of(&tree).as_deref(), Some(TOKEN));
        assert!(babel_token_of(USER).is_none());
        assert_eq!(decode_long("0580897a"), Some(1_000_000));
        assert_eq!(decode_long("0501"), Some(-1));
        assert_eq!(int_hex(0), "0400");
        assert_eq!(int_hex(3), "0406");
    }

    #[test]
    fn a_babel_box_is_read_and_the_fee_priced_in_tokens() {
        let b = BabelBox::parse(&babel_input(), TOKEN).unwrap();
        assert_eq!(b.price, 1_000_000);
        assert_eq!(b.tokens_before, 5);
        // 0.0011 ERG at 0.001 ERG a cent: 2 cents, rounded up.
        assert_eq!(b.tokens_for(1_100_000), 2);
        assert_eq!(b.tokens_for(1_000_000), 1);
        assert!(b.can_pay(1_100_000));
        assert!(!b.can_pay(999_500_000));
        assert!(BabelBox::parse(&babel_input(), "ff").is_err());
        let cheaper = input(
            "cc",
            1_000_000_000,
            &babel_ergo_tree(TOKEN),
            vec![],
            vec![("R4", "08cd02aa"), ("R5", "0502")],
        );
        let picked = pick_babel_box(&[babel_input(), cheaper], TOKEN, 1_100_000).unwrap();
        assert_eq!(
            picked.box_id,
            "bb".repeat(32),
            "the box asking fewer tokens"
        );
    }

    #[test]
    fn applying_babel_moves_the_fee_from_erg_to_tokens() {
        let babel = BabelBox::parse(&babel_input(), TOKEN).unwrap();
        // As the builder left it: babel ERG credited to change, its 5
        // tokens and the user's 100 in the change, fee 0.0011 last.
        let mut tx = Eip12UnsignedTx {
            inputs: vec![
                input("aa", 10_000_000, USER, vec![(TOKEN, 100)], vec![]),
                babel_input(),
            ],
            data_inputs: vec![],
            outputs: vec![
                Eip12Output::simple(2_000_000, "0008cd03", 5),
                Eip12Output {
                    value: (10_000_000 - 2_000_000 - 1_100_000 + 1_000_000_000).to_string(),
                    ergo_tree: USER.into(),
                    assets: vec![Eip12Asset::new(TOKEN.to_string(), 105)],
                    creation_height: 5,
                    additional_registers: HashMap::new(),
                },
                Eip12Output::fee(1_100_000, 5),
            ],
        };
        let s = apply_babel(&mut tx, &babel, USER).unwrap();
        assert_eq!(s.tokens_paid, 2);
        assert_eq!(tx.outputs.len(), 4);
        let change = &tx.outputs[1];
        assert_eq!(
            change.value,
            (10_000_000 - 2_000_000).to_string(),
            "the user pays no ERG fee"
        );
        assert_eq!(change.assets[0].amount, "98");
        let recreated = &tx.outputs[2];
        assert_eq!(recreated.ergo_tree, babel_ergo_tree(TOKEN));
        assert_eq!(recreated.value, (1_000_000_000 - 1_100_000).to_string());
        assert_eq!(recreated.assets[0].amount, "7");
        assert_eq!(recreated.additional_registers["R4"], "08cd02aa");
        assert_eq!(recreated.additional_registers["R5"], "0580897a");
        assert_eq!(
            recreated.additional_registers["R6"],
            format!("0e20{}", "bb".repeat(32))
        );
        assert_eq!(
            tx.inputs[1].extension["0"], "0404",
            "context variable 0 names output 2"
        );
        assert_eq!(tx.outputs[3].ergo_tree, MINER_FEE_ERGO_TREE);
    }

    #[test]
    fn a_send_to_the_wallets_own_change_address_still_takes_the_change_box() {
        let babel = BabelBox::parse(&babel_input(), TOKEN).unwrap();
        // The recipient is the wallet's own change address, so output 0
        // and output 1 share a script; only output 1 is the change.
        let mut tx = Eip12UnsignedTx {
            inputs: vec![
                input("aa", 10_000_000, USER, vec![(TOKEN, 100)], vec![]),
                babel_input(),
            ],
            data_inputs: vec![],
            outputs: vec![
                Eip12Output {
                    value: "2000000".into(),
                    ergo_tree: USER.into(),
                    assets: vec![],
                    creation_height: 5,
                    additional_registers: HashMap::new(),
                },
                Eip12Output {
                    value: (10_000_000 - 2_000_000 - 1_100_000 + 1_000_000_000).to_string(),
                    ergo_tree: USER.into(),
                    assets: vec![Eip12Asset::new(TOKEN.to_string(), 105)],
                    creation_height: 5,
                    additional_registers: HashMap::new(),
                },
                Eip12Output::fee(1_100_000, 5),
            ],
        };
        apply_babel(&mut tx, &babel, USER).unwrap();
        assert_eq!(
            tx.outputs[0].value, "2000000",
            "the recipient box is untouched"
        );
        assert!(tx.outputs[0].assets.is_empty());
        assert_eq!(tx.outputs[1].value, (10_000_000 - 2_000_000).to_string());
        assert_eq!(tx.outputs[1].assets[0].amount, "98");
    }

    #[test]
    fn refuses_when_the_change_cannot_carry_it() {
        let babel = BabelBox::parse(&babel_input(), TOKEN).unwrap();
        let mut tx = Eip12UnsignedTx {
            inputs: vec![
                input("aa", 3_500_000, USER, vec![(TOKEN, 1)], vec![]),
                babel_input(),
            ],
            data_inputs: vec![],
            outputs: vec![
                Eip12Output::simple(2_000_000, "0008cd03", 5),
                Eip12Output {
                    value: (3_500_000 - 2_000_000 - 1_100_000 + 1_000_000_000).to_string(),
                    ergo_tree: USER.into(),
                    assets: vec![Eip12Asset::new(TOKEN.to_string(), 6)],
                    creation_height: 5,
                    additional_registers: HashMap::new(),
                },
                Eip12Output::fee(1_100_000, 5),
            ],
        };
        // 1 token held, 2 needed.
        assert!(matches!(
            apply_babel(&mut tx.clone(), &babel, USER),
            Err(BabelError::InsufficientTokens { have: 1, need: 2 })
        ));
        // Enough tokens, but the change would be 0.0004 ERG.
        tx.outputs[1].assets[0].amount = "10".into();
        tx.outputs[1].value = (3_500_000 - 2_000_000 - 1_100_000 + 1_000_000_000).to_string();
        let mut tx2 = tx.clone();
        tx2.outputs[1].value =
            (3_500_000 - 2_000_000 - 1_100_000 + 1_000_000_000 - 1_000_000).to_string();
        assert!(matches!(
            apply_babel(&mut tx2, &babel, USER),
            Err(BabelError::ChangeTooSmall)
        ));
        assert!(matches!(
            apply_babel(&mut tx.clone(), &babel, "0008cd09"),
            Err(BabelError::NoChange)
        ));
    }
}
