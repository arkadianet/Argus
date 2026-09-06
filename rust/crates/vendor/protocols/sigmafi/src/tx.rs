//! The five SigmaFi transactions, in EIP-12 form, built the way
//! `sigmafi-ui` builds them so the contracts accept them.
//!
//! Output positions matter: the order and bond scripts read `OUTPUTS(0)`
//! (and `OUTPUTS(1)`), so the protocol outputs come first and the change
//! and miner fee last. The protocol box is always the first input.

use std::collections::HashMap;

use ergo_tx::{
    append_change_output, encode_sigma_coll_byte, encode_sigma_int, encode_sigma_long,
    select_erg_boxes, select_inputs_for_spend, Eip12Asset, Eip12InputBox, Eip12Output,
    Eip12UnsignedTx,
};

use crate::contracts::{bond_contract, is_on_close_order, loan_asset_of_bond, loan_asset_of_order, order_contract, DEV_FEE_TREE};
use crate::market::{parse_bond, parse_order, ActiveBond, OpenOrder};
use crate::{dev_fee, ui_fee, ERG, MIN_TERM_BLOCKS, SAFE_MIN_BOX_VALUE, STORAGE_PERIOD};

/// Change below this stays with the miner rather than making a dust box.
const MIN_CHANGE_VALUE: i64 = 1_000_000;

#[derive(Debug, thiserror::Error)]
pub enum SigmaFiTxError {
    #[error("{0}")]
    Invalid(String),
    #[error("not a SigmaFi {0} box")]
    NotProtocolBox(&'static str),
    #[error("{0}")]
    Market(#[from] crate::market::MarketError),
    #[error("could not pick inputs: {0}")]
    Selection(String),
    #[error("not enough funds: {0}")]
    Funds(String),
}

/// A P2PK tree (`0008cd` + key) as the SigmaProp register (`08cd` + key).
pub fn sigma_prop_of_p2pk(tree: &str) -> Result<String, SigmaFiTxError> {
    let tree = tree.to_ascii_lowercase();
    match tree.strip_prefix("0008cd") {
        Some(pk) if pk.len() == 66 => Ok(format!("08cd{pk}")),
        _ => Err(SigmaFiTxError::Invalid(
            "SigmaFi needs a plain P2PK address (a wallet address, not a contract)".into(),
        )),
    }
}

fn p2pk_tree_of_pk(pk: &str) -> String {
    format!("0008cd{pk}")
}

pub struct OpenOrderRequest<'a> {
    /// The borrower's P2PK tree; collateral returns here on cancel.
    pub borrower_tree: &'a str,
    /// Where the change goes; the borrower's tree when `None`.
    pub change_tree: Option<&'a str>,
    /// `"ERG"` or a token id.
    pub loan_asset: &'a str,
    pub principal: u64,
    pub repayment: u64,
    pub term_blocks: i32,
    /// nanoERG of collateral; zero for a token-only order (the box then
    /// holds the minimum value, which is not collateral).
    pub collateral_erg: u64,
    pub collateral_tokens: &'a [(String, u64)],
    pub utxos: &'a [Eip12InputBox],
    pub height: i32,
    pub miner_fee: i64,
}

/// Post an order: collateral into the "on close" order box, change back.
pub fn build_open_order(req: &OpenOrderRequest) -> Result<Eip12UnsignedTx, SigmaFiTxError> {
    if req.principal == 0 {
        return Err(SigmaFiTxError::Invalid("the loan must be more than nothing".into()));
    }
    if req.repayment < req.principal {
        return Err(SigmaFiTxError::Invalid("the repayment cannot be less than the loan".into()));
    }
    if req.term_blocks < MIN_TERM_BLOCKS {
        return Err(SigmaFiTxError::Invalid(format!(
            "the term must be at least {MIN_TERM_BLOCKS} blocks"
        )));
    }
    if req.term_blocks >= STORAGE_PERIOD {
        return Err(SigmaFiTxError::Invalid(format!(
            "the term must be under {STORAGE_PERIOD} blocks, the storage rent period"
        )));
    }
    if req.collateral_erg == 0 && req.collateral_tokens.is_empty() {
        return Err(SigmaFiTxError::Invalid("an order needs collateral".into()));
    }
    if req.collateral_tokens.iter().any(|(_, n)| *n == 0) {
        return Err(SigmaFiTxError::Invalid("a collateral token amount is zero".into()));
    }
    if req.miner_fee <= 0 {
        return Err(SigmaFiTxError::Invalid("miner fee".into()));
    }
    let registers = ergo_tx::sigma_registers!(
        "R4" => sigma_prop_of_p2pk(req.borrower_tree)?,
        "R5" => encode_sigma_long(req.principal as i64),
        "R6" => encode_sigma_long(req.repayment as i64),
        "R7" => encode_sigma_int(req.term_blocks),
    );
    let order_value = if req.collateral_erg > 0 {
        req.collateral_erg as i64
    } else {
        SAFE_MIN_BOX_VALUE
    };
    if order_value < SAFE_MIN_BOX_VALUE {
        return Err(SigmaFiTxError::Invalid(format!(
            "ERG collateral must be at least {SAFE_MIN_BOX_VALUE} nanoERG"
        )));
    }
    let order = Eip12Output {
        value: order_value.to_string(),
        ergo_tree: order_contract(req.loan_asset),
        assets: req
            .collateral_tokens
            .iter()
            .map(|(id, n)| Eip12Asset::new(id, *n as i64))
            .collect(),
        creation_height: req.height,
        additional_registers: registers,
    };
    let erg_used = (order_value + req.miner_fee) as u64;
    let spent: Vec<(&str, u64)> = req
        .collateral_tokens
        .iter()
        .map(|(id, n)| (id.as_str(), *n))
        .collect();
    let selected = ergo_tx::select_inputs_for_multi_spend(
        req.utxos,
        erg_used + MIN_CHANGE_VALUE as u64,
        &spent,
    )
    .map_err(|e| SigmaFiTxError::Selection(e.to_string()))?;
    let mut outputs = vec![order];
    append_change_output(
        &mut outputs,
        &selected,
        erg_used,
        &spent,
        req.change_tree.unwrap_or(req.borrower_tree),
        req.height,
        MIN_CHANGE_VALUE as u64,
    )
    .map_err(|e| SigmaFiTxError::Funds(e.to_string()))?;
    outputs.push(Eip12Output::fee(req.miner_fee, req.height));
    Ok(Eip12UnsignedTx {
        inputs: selected.boxes,
        data_inputs: vec![],
        outputs,
    })
}

/// The borrower takes an unfilled order back. Signed by the key in R4.
pub fn build_cancel_order(
    order_box: &Eip12InputBox,
    utxos: &[Eip12InputBox],
    height: i32,
    miner_fee: i64,
) -> Result<Eip12UnsignedTx, SigmaFiTxError> {
    let asset = loan_asset_of_order(&order_box.ergo_tree)
        .ok_or(SigmaFiTxError::NotProtocolBox("order"))?;
    let order = parse_order(order_box, &asset)?;
    let borrower_tree = p2pk_tree_of_pk(&order.borrower_pk);
    let back = Eip12Output::change(
        order.collateral_erg as i64,
        borrower_tree.clone(),
        order_box.assets.clone(),
        height,
    );
    spend_protocol_box(order_box, back, &borrower_tree, utxos, height, miner_fee)
}

/// A lender fills an order: the collateral becomes a bond, the loan goes
/// to the borrower, the contract fee to SigmaFi and the interface fee to
/// `ui_fee_tree`. The order's context variable 0 names the interface fee
/// recipient, as the script requires.
pub fn build_close_order(
    order_box: &Eip12InputBox,
    lender_tree: &str,
    ui_fee_tree: &str,
    utxos: &[Eip12InputBox],
    height: i32,
    miner_fee: i64,
) -> Result<Eip12UnsignedTx, SigmaFiTxError> {
    let asset = loan_asset_of_order(&order_box.ergo_tree)
        .ok_or(SigmaFiTxError::NotProtocolBox("order"))?;
    if !is_on_close_order(&order_box.ergo_tree) {
        return Err(SigmaFiTxError::Invalid(
            "this is a fixed-height order, which Argus does not fill".into(),
        ));
    }
    let order = parse_order(order_box, &asset)?;
    if order.term_blocks >= STORAGE_PERIOD {
        return Err(SigmaFiTxError::Invalid(
            "the order's term is over the storage rent period".into(),
        ));
    }
    if miner_fee <= 0 {
        return Err(SigmaFiTxError::Invalid("miner fee".into()));
    }
    let is_erg = asset == ERG;
    let ui_prop = sigma_prop_of_p2pk(ui_fee_tree)?;
    let lender_prop = sigma_prop_of_p2pk(lender_tree)?;
    let order_id = hex::decode(&order_box.box_id)
        .map_err(|_| SigmaFiTxError::Invalid("order box id".into()))?;
    let bond = Eip12Output {
        value: order_box.value.clone(),
        ergo_tree: bond_contract(&asset),
        assets: order_box.assets.clone(),
        creation_height: height,
        additional_registers: ergo_tx::sigma_registers!(
            "R4" => encode_sigma_coll_byte(&order_id),
            "R5" => format!("08cd{}", order.borrower_pk),
            "R6" => encode_sigma_long(order.repayment as i64),
            "R7" => encode_sigma_int(height + order.term_blocks),
            "R8" => lender_prop,
        ),
    };
    let borrower_tree = p2pk_tree_of_pk(&order.borrower_pk);
    let principal = order.principal;
    let fee_dev = dev_fee(principal);
    let fee_ui = ui_fee(principal);
    let asset_box = |value: i64, tree: &str, amount: u64| {
        if is_erg {
            Eip12Output::simple(value, tree, height)
        } else {
            let assets = if amount > 0 {
                vec![Eip12Asset::new(&asset, amount as i64)]
            } else {
                vec![]
            };
            Eip12Output::change(SAFE_MIN_BOX_VALUE, tree, assets, height)
        }
    };
    let loan = asset_box(principal as i64, &borrower_tree, principal);
    let dev = asset_box(fee_dev as i64, DEV_FEE_TREE, fee_dev);
    let ui = asset_box(fee_ui as i64, ui_fee_tree, fee_ui);
    let erg_out: i64 = if is_erg {
        (principal + fee_dev + fee_ui) as i64 + miner_fee
    } else {
        SAFE_MIN_BOX_VALUE * 3 + miner_fee
    };
    let token = (!is_erg).then_some((asset.as_str(), principal + fee_dev + fee_ui));
    let selected = select_inputs_for_spend(utxos, erg_out as u64 + MIN_CHANGE_VALUE as u64, token)
        .map_err(|e| SigmaFiTxError::Selection(e.to_string()))?;
    let spent: Vec<(&str, u64)> = token.into_iter().collect();
    let mut outputs = vec![bond, loan, dev, ui];
    append_change_output(
        &mut outputs,
        &selected,
        erg_out as u64,
        &spent,
        lender_tree,
        height,
        MIN_CHANGE_VALUE as u64,
    )
    .map_err(|e| SigmaFiTxError::Funds(e.to_string()))?;
    outputs.push(Eip12Output::fee(miner_fee, height));
    let mut order_input = order_box.clone();
    order_input.extension = HashMap::from([("0".to_string(), ui_prop)]);
    let mut inputs = vec![order_input];
    inputs.extend(selected.boxes);
    Ok(Eip12UnsignedTx {
        inputs,
        data_inputs: vec![],
        outputs,
    })
}

/// The borrower settles a bond before maturity: the repayment to the
/// lender (R4 = the bond's id) and the collateral back to the borrower.
pub fn build_repay(
    bond_box: &Eip12InputBox,
    utxos: &[Eip12InputBox],
    height: i32,
    miner_fee: i64,
) -> Result<Eip12UnsignedTx, SigmaFiTxError> {
    let asset = loan_asset_of_bond(&bond_box.ergo_tree)
        .ok_or(SigmaFiTxError::NotProtocolBox("bond"))?;
    let bond = parse_bond(bond_box, &asset, height)?;
    if miner_fee <= 0 {
        return Err(SigmaFiTxError::Invalid("miner fee".into()));
    }
    let is_erg = asset == ERG;
    let bond_id = hex::decode(&bond_box.box_id)
        .map_err(|_| SigmaFiTxError::Invalid("bond box id".into()))?;
    let lender_tree = p2pk_tree_of_pk(&bond.lender_pk);
    let borrower_tree = p2pk_tree_of_pk(&bond.borrower_pk);
    let repayment = Eip12Output {
        value: if is_erg { bond.repayment as i64 } else { SAFE_MIN_BOX_VALUE }.to_string(),
        ergo_tree: lender_tree,
        assets: if is_erg {
            vec![]
        } else {
            vec![Eip12Asset::new(&asset, bond.repayment as i64)]
        },
        creation_height: height,
        additional_registers: ergo_tx::sigma_registers!("R4" => encode_sigma_coll_byte(&bond_id)),
    };
    let collateral = Eip12Output::change(
        bond.collateral_erg as i64,
        borrower_tree.clone(),
        bond_box.assets.clone(),
        height,
    );
    let erg_out = if is_erg { bond.repayment as i64 } else { SAFE_MIN_BOX_VALUE } + miner_fee;
    let token = (!is_erg).then_some((asset.as_str(), bond.repayment));
    let selected = select_inputs_for_spend(utxos, erg_out as u64 + MIN_CHANGE_VALUE as u64, token)
        .map_err(|e| SigmaFiTxError::Selection(e.to_string()))?;
    let spent: Vec<(&str, u64)> = token.into_iter().collect();
    let mut outputs = vec![repayment, collateral];
    append_change_output(
        &mut outputs,
        &selected,
        erg_out as u64,
        &spent,
        &borrower_tree,
        height,
        MIN_CHANGE_VALUE as u64,
    )
    .map_err(|e| SigmaFiTxError::Funds(e.to_string()))?;
    outputs.push(Eip12Output::fee(miner_fee, height));
    let mut inputs = vec![bond_box.clone()];
    inputs.extend(selected.boxes);
    Ok(Eip12UnsignedTx {
        inputs,
        data_inputs: vec![],
        outputs,
    })
}

/// The lender takes the collateral of a matured bond (R4 = the bond's id).
pub fn build_liquidate(
    bond_box: &Eip12InputBox,
    utxos: &[Eip12InputBox],
    height: i32,
    miner_fee: i64,
) -> Result<Eip12UnsignedTx, SigmaFiTxError> {
    let asset = loan_asset_of_bond(&bond_box.ergo_tree)
        .ok_or(SigmaFiTxError::NotProtocolBox("bond"))?;
    let bond = parse_bond(bond_box, &asset, height)?;
    if bond.blocks_remaining > 0 {
        return Err(SigmaFiTxError::Invalid(format!(
            "the bond matures in {} blocks",
            bond.blocks_remaining
        )));
    }
    let bond_id = hex::decode(&bond_box.box_id)
        .map_err(|_| SigmaFiTxError::Invalid("bond box id".into()))?;
    let lender_tree = p2pk_tree_of_pk(&bond.lender_pk);
    let collateral = Eip12Output {
        value: bond_box.value.clone(),
        ergo_tree: lender_tree.clone(),
        assets: bond_box.assets.clone(),
        creation_height: height,
        additional_registers: ergo_tx::sigma_registers!("R4" => encode_sigma_coll_byte(&bond_id)),
    };
    spend_protocol_box(bond_box, collateral, &lender_tree, utxos, height, miner_fee)
}

/// Protocol box first, its contents to `out`, the miner fee from the
/// user's boxes, change to `user_tree`.
fn spend_protocol_box(
    protocol_box: &Eip12InputBox,
    out: Eip12Output,
    user_tree: &str,
    utxos: &[Eip12InputBox],
    height: i32,
    miner_fee: i64,
) -> Result<Eip12UnsignedTx, SigmaFiTxError> {
    if miner_fee <= 0 {
        return Err(SigmaFiTxError::Invalid("miner fee".into()));
    }
    let selected = select_erg_boxes(utxos, (miner_fee + MIN_CHANGE_VALUE) as u64)
        .map_err(|e| SigmaFiTxError::Selection(e.to_string()))?;
    let mut outputs = vec![out];
    append_change_output(
        &mut outputs,
        &selected,
        miner_fee as u64,
        &[],
        user_tree,
        height,
        MIN_CHANGE_VALUE as u64,
    )
    .map_err(|e| SigmaFiTxError::Funds(e.to_string()))?;
    outputs.push(Eip12Output::fee(miner_fee, height));
    let mut inputs = vec![protocol_box.clone()];
    inputs.extend(selected.boxes);
    Ok(Eip12UnsignedTx {
        inputs,
        data_inputs: vec![],
        outputs,
    })
}

/// What a market entry needs to know about the wallet: kept here so the
/// screen and the builders agree on who may do what.
impl OpenOrder {
    /// Whether `pk` (a wallet key) may cancel this order.
    pub fn cancellable_by(&self, pk: &str) -> bool {
        self.borrower_pk.eq_ignore_ascii_case(pk)
    }
}

impl ActiveBond {
    pub fn repayable_by(&self, pk: &str) -> bool {
        self.borrower_pk.eq_ignore_ascii_case(pk) && self.blocks_remaining > 0
    }
    pub fn liquidatable_by(&self, pk: &str) -> bool {
        self.lender_pk.eq_ignore_ascii_case(pk) && self.blocks_remaining <= 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::market::fixtures::*;
    use crate::MINER_FEE;

    const SIGUSD: &str = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";
    const USER: &str = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    const UI: &str = "0008cd02c1d434dac4c5e0e4c8e8f5b7c2d9a1b3e5f7a9c1d3e5f7a9c1d3e5f7a9c1d3e5";

    fn utxo(id: u8, value: i64, tokens: Vec<(&str, i64)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: format!("{id:02x}").repeat(32),
            transaction_id: "bb".repeat(32),
            index: 0,
            value: value.to_string(),
            ergo_tree: USER.into(),
            assets: tokens.into_iter().map(|(t, n)| Eip12Asset::new(t, n)).collect(),
            creation_height: 1000,
            additional_registers: HashMap::new(),
            extension: HashMap::new(),
        }
    }

    fn same_assets(a: &[Eip12Asset], b: &[Eip12Asset]) -> bool {
        a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.token_id == y.token_id && x.amount == y.amount)
    }
    fn sum_out(tx: &Eip12UnsignedTx) -> i64 {
        tx.outputs.iter().map(|o| o.value.parse::<i64>().unwrap()).sum()
    }
    fn sum_in(tx: &Eip12UnsignedTx) -> i64 {
        tx.inputs.iter().map(|o| o.value.parse::<i64>().unwrap()).sum()
    }

    #[test]
    fn open_erg_order_locks_collateral_under_the_order_script() {
        let tx = build_open_order(&OpenOrderRequest {
            borrower_tree: USER,
            change_tree: None,
            loan_asset: ERG,
            principal: 10_000_000_000,
            repayment: 10_500_000_000,
            term_blocks: 21_600,
            collateral_erg: 15_000_000_000,
            collateral_tokens: &[],
            utxos: &[utxo(1, 20_000_000_000, vec![])],
            height: 1000,
            miner_fee: MINER_FEE,
        })
        .unwrap();
        assert_eq!(tx.outputs.len(), 3);
        let order = &tx.outputs[0];
        assert_eq!(order.ergo_tree, crate::contracts::ERG_ORDER_ON_CLOSE);
        assert_eq!(order.value, "15000000000");
        assert_eq!(order.additional_registers["R4"], format!("08cd{}", &USER[6..]));
        assert_eq!(order.additional_registers["R5"], encode_sigma_long(10_000_000_000));
        assert_eq!(order.additional_registers["R6"], encode_sigma_long(10_500_000_000));
        assert_eq!(order.additional_registers["R7"], encode_sigma_int(21_600));
        assert_eq!(sum_in(&tx), sum_out(&tx));
        assert_eq!(tx.outputs[1].ergo_tree, USER);
        assert_eq!(tx.outputs[2].value, MINER_FEE.to_string());
        // Reads back as the order it is.
        let parsed = parse_order(
            &Eip12InputBox {
                box_id: "cc".repeat(32),
                transaction_id: "dd".repeat(32),
                index: 0,
                value: order.value.clone(),
                ergo_tree: order.ergo_tree.clone(),
                assets: vec![],
                creation_height: 1000,
                additional_registers: order.additional_registers.clone(),
                extension: HashMap::new(),
            },
            ERG,
        )
        .unwrap();
        assert_eq!(parsed.principal, 10_000_000_000);
        assert_eq!(parsed.term_blocks, 21_600);
    }

    #[test]
    fn open_token_order_with_token_collateral_uses_the_minimum_value() {
        let tx = build_open_order(&OpenOrderRequest {
            borrower_tree: USER,
            change_tree: Some(UI),
            loan_asset: SIGUSD,
            principal: 10_000,
            repayment: 10_400,
            term_blocks: 720,
            collateral_erg: 0,
            collateral_tokens: &[("aa".repeat(32), 5)],
            utxos: &[utxo(1, 5_000_000_000, vec![(&"aa".repeat(32), 7)])],
            height: 1000,
            miner_fee: MINER_FEE,
        })
        .unwrap();
        let order = &tx.outputs[0];
        assert_eq!(order.value, SAFE_MIN_BOX_VALUE.to_string());
        assert_eq!(order.ergo_tree, order_contract(SIGUSD));
        assert_eq!(order.assets.len(), 1);
        assert_eq!(order.assets[0].amount, "5");
        // The two spare tokens come back as change, to the change tree.
        assert_eq!(tx.outputs[1].assets[0].amount, "2");
        assert_eq!(tx.outputs[1].ergo_tree, UI);
    }

    #[test]
    fn open_order_rejects_what_the_contract_would() {
        let base = |term: i32, principal: u64, repayment: u64, erg: u64| OpenOrderRequest {
            borrower_tree: USER,
            change_tree: None,
            loan_asset: ERG,
            principal,
            repayment,
            term_blocks: term,
            collateral_erg: erg,
            collateral_tokens: &[],
            utxos: &[],
            height: 1000,
            miner_fee: MINER_FEE,
        };
        assert!(build_open_order(&base(30, 10, 11, 2_000_000)).is_err());
        assert!(build_open_order(&base(STORAGE_PERIOD, 10, 11, 2_000_000)).is_err());
        assert!(build_open_order(&base(100, 0, 11, 2_000_000)).is_err());
        assert!(build_open_order(&base(100, 12, 11, 2_000_000)).is_err());
        assert!(build_open_order(&base(100, 10, 11, 0)).is_err());
        assert!(build_open_order(&base(100, 10, 11, 500)).is_err());
        assert!(matches!(
            build_open_order(&OpenOrderRequest { borrower_tree: crate::contracts::ERG_BOND, ..base(100, 10, 11, 2_000_000) }),
            Err(SigmaFiTxError::Invalid(_))
        ));
    }

    #[test]
    fn cancel_returns_the_collateral_to_the_borrower() {
        let order = &erg_order();
        let parsed = parse_order(order, ERG).unwrap();
        let tx = build_cancel_order(order, &[utxo(1, 5_000_000_000, vec![])], 1_200_000, MINER_FEE).unwrap();
        assert_eq!(tx.inputs[0].box_id, order.box_id);
        assert_eq!(tx.inputs.len(), 2);
        assert_eq!(tx.outputs[0].value, order.value);
        assert_eq!(tx.outputs[0].ergo_tree, format!("0008cd{}", parsed.borrower_pk));
        assert!(same_assets(&tx.outputs[0].assets, &order.assets));
        assert_eq!(sum_in(&tx), sum_out(&tx));
    }

    #[test]
    fn close_erg_order_builds_the_bond_and_pays_everyone() {
        let order = erg_order();
        let parsed = parse_order(&order, ERG).unwrap();
        let height = 1_200_000;
        let tx = build_close_order(&order, USER, UI, &[utxo(1, 200_000_000_000, vec![])], height, MINER_FEE).unwrap();
        assert_eq!(tx.inputs[0].box_id, order.box_id);
        assert_eq!(tx.inputs[0].extension["0"], format!("08cd{}", &UI[6..]));
        let bond = &tx.outputs[0];
        assert_eq!(bond.ergo_tree, crate::contracts::ERG_BOND);
        assert_eq!(bond.value, order.value);
        assert!(same_assets(&bond.assets, &order.assets));
        assert_eq!(bond.additional_registers["R4"], format!("0e20{}", order.box_id));
        assert_eq!(bond.additional_registers["R5"], order.additional_registers["R4"]);
        assert_eq!(bond.additional_registers["R6"], order.additional_registers["R6"]);
        assert_eq!(bond.additional_registers["R7"], encode_sigma_int(height + parsed.term_blocks));
        assert_eq!(bond.additional_registers["R8"], format!("08cd{}", &USER[6..]));
        assert_eq!(tx.outputs[1].ergo_tree, format!("0008cd{}", parsed.borrower_pk));
        assert_eq!(tx.outputs[1].value, "100000000000");
        assert_eq!(tx.outputs[2].ergo_tree, DEV_FEE_TREE);
        assert_eq!(tx.outputs[2].value, "500000000");
        assert_eq!(tx.outputs[3].ergo_tree, UI);
        assert_eq!(tx.outputs[3].value, "400000000");
        assert_eq!(tx.outputs[4].ergo_tree, USER);
        assert_eq!(sum_in(&tx), sum_out(&tx));
        // The bond the fill makes reads back as one.
        let bond_box = Eip12InputBox {
            box_id: "ee".repeat(32),
            transaction_id: "ff".repeat(32),
            index: 0,
            value: bond.value.clone(),
            ergo_tree: bond.ergo_tree.clone(),
            assets: bond.assets.clone(),
            creation_height: height,
            additional_registers: bond.additional_registers.clone(),
            extension: HashMap::new(),
        };
        let b = parse_bond(&bond_box, ERG, height).unwrap();
        assert_eq!(b.order_box_id, order.box_id);
        assert_eq!(b.lender_pk, &USER[6..]);
        assert_eq!(b.repayment, parsed.repayment);
        assert_eq!(b.blocks_remaining, parsed.term_blocks);
    }

    #[test]
    fn close_token_order_pays_loan_and_fees_in_the_token() {
        let order = orders_sigusd().into_iter().find(|o| o.box_id.starts_with("fb9cae3c")).unwrap();
        let parsed = parse_order(&order, SIGUSD).unwrap();
        let need = parsed.lender_cost();
        let tx = build_close_order(
            &order,
            USER,
            UI,
            &[utxo(1, 1_000_000_000, vec![(SIGUSD, need as i64 + 10)])],
            1_300_000,
            MINER_FEE,
        )
        .unwrap();
        assert_eq!(tx.outputs[0].ergo_tree, bond_contract(SIGUSD));
        for (i, amount) in [(1, parsed.principal), (2, parsed.dev_fee), (3, parsed.ui_fee)] {
            assert_eq!(tx.outputs[i].value, SAFE_MIN_BOX_VALUE.to_string());
            assert_eq!(tx.outputs[i].assets[0].token_id, SIGUSD);
            assert_eq!(tx.outputs[i].assets[0].amount, amount.to_string());
        }
        assert_eq!(tx.outputs[4].assets[0].amount, "10");
        assert_eq!(sum_in(&tx), sum_out(&tx));
    }

    #[test]
    fn close_needs_a_p2pk_ui_fee_recipient() {
        let order = &erg_order();
        let err = build_close_order(order, USER, crate::contracts::ERG_BOND, &[utxo(1, 200_000_000_000, vec![])], 1, MINER_FEE);
        assert!(matches!(err, Err(SigmaFiTxError::Invalid(_))));
    }

    #[test]
    fn repay_pays_the_lender_and_frees_the_collateral() {
        let bond = &bonds_sigusd()[0];
        let parsed = parse_bond(bond, SIGUSD, 1_000_000).unwrap();
        let tx = build_repay(bond, &[utxo(1, 1_000_000_000, vec![(SIGUSD, parsed.repayment as i64)])], 1_000_000, MINER_FEE).unwrap();
        assert_eq!(tx.inputs[0].box_id, bond.box_id);
        let repay = &tx.outputs[0];
        assert_eq!(repay.ergo_tree, format!("0008cd{}", parsed.lender_pk));
        assert_eq!(repay.value, SAFE_MIN_BOX_VALUE.to_string());
        assert_eq!(repay.assets[0].amount, parsed.repayment.to_string());
        assert_eq!(repay.additional_registers["R4"], format!("0e20{}", bond.box_id));
        let back = &tx.outputs[1];
        assert_eq!(back.ergo_tree, format!("0008cd{}", parsed.borrower_pk));
        assert_eq!(back.value, bond.value);
        assert!(same_assets(&back.assets, &bond.assets));
        assert_eq!(sum_in(&tx), sum_out(&tx));
    }

    #[test]
    fn repay_erg_bond_pays_in_erg() {
        let bond = &bonds_erg()[0];
        let parsed = parse_bond(bond, ERG, 1_000_000).unwrap();
        let tx = build_repay(bond, &[utxo(1, parsed.repayment as i64 + 1_000_000_000, vec![])], 1_000_000, MINER_FEE).unwrap();
        assert_eq!(tx.outputs[0].value, parsed.repayment.to_string());
        assert!(tx.outputs[0].assets.is_empty());
        assert_eq!(sum_in(&tx), sum_out(&tx));
    }

    #[test]
    fn liquidate_only_after_maturity_and_to_the_lender() {
        let bond = &bonds_erg()[0];
        let parsed = parse_bond(bond, ERG, 0).unwrap();
        let early = build_liquidate(bond, &[utxo(1, 5_000_000_000, vec![])], parsed.maturity_height - 1, MINER_FEE);
        assert!(matches!(early, Err(SigmaFiTxError::Invalid(_))));
        let tx = build_liquidate(bond, &[utxo(1, 5_000_000_000, vec![])], parsed.maturity_height, MINER_FEE).unwrap();
        assert_eq!(tx.outputs[0].ergo_tree, format!("0008cd{}", parsed.lender_pk));
        assert_eq!(tx.outputs[0].value, bond.value);
        assert!(same_assets(&tx.outputs[0].assets, &bond.assets));
        assert_eq!(tx.outputs[0].additional_registers["R4"], format!("0e20{}", bond.box_id));
        assert_eq!(sum_in(&tx), sum_out(&tx));
    }

    #[test]
    fn a_foreign_box_is_refused_by_every_spender() {
        let mut b = erg_order();
        b.ergo_tree = USER.into();
        let u = [utxo(1, 5_000_000_000, vec![])];
        assert!(matches!(build_cancel_order(&b, &u, 1, MINER_FEE), Err(SigmaFiTxError::NotProtocolBox("order"))));
        assert!(matches!(build_close_order(&b, USER, UI, &u, 1, MINER_FEE), Err(SigmaFiTxError::NotProtocolBox("order"))));
        assert!(matches!(build_repay(&b, &u, 1, MINER_FEE), Err(SigmaFiTxError::NotProtocolBox("bond"))));
        assert!(matches!(build_liquidate(&b, &u, 1, MINER_FEE), Err(SigmaFiTxError::NotProtocolBox("bond"))));
    }

    #[test]
    fn roles_follow_the_keys_and_the_height() {
        let bond = parse_bond(&bonds_erg()[0], ERG, 0).unwrap();
        assert!(bond.repayable_by(&bond.borrower_pk));
        assert!(!bond.repayable_by(&bond.lender_pk));
        assert!(!bond.liquidatable_by(&bond.lender_pk));
        let matured = parse_bond(&bonds_erg()[0], ERG, bond.maturity_height).unwrap();
        assert!(matured.liquidatable_by(&matured.lender_pk));
        assert!(!matured.repayable_by(&matured.borrower_pk));
        let order = parse_order(&erg_order(), ERG).unwrap();
        assert!(order.cancellable_by(&order.borrower_pk.to_ascii_uppercase()));
    }
}
