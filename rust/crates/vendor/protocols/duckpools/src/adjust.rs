//! Collateral adjustment: the borrower re-creates their own collateral
//! box with more or less collateral in it.
//!
//! This is the collateral contract's first branch (`INPUTS(0) == SELF`):
//! no bot and no proxy. The borrower signs with the key the box records
//! in R8, spends the box as the first input with the interest boxes and
//! the price box as data inputs (base child, parent, head child, DEX, in
//! that order), and the successor must keep the script, the borrow
//! tokens and every register while its collateral still values above
//! the liquidation line. A token pool lets the ERG go up or down as long
//! as 0.004 ERG remains; the ERG pool lets the token amount change but
//! never the box's ERG.

use std::collections::HashMap;

use ergo_tx::{Eip12Asset, Eip12DataInputBox, Eip12InputBox, Eip12Output, Eip12UnsignedTx};

use crate::loans::{DexPrice, InterestHistory, LoanPosition};
use crate::state::PoolsError;
use crate::{Pool, MIN_BOX_VALUE, TX_FEE};

/// The least ERG a token pool's collateral box may hold after an
/// adjustment (`3 * MinimumBoxValue + MinimumTransactionFee`).
pub const MIN_ADJUSTED_COLLATERAL_NANO: i64 = 3 * MIN_BOX_VALUE + TX_FEE;

fn err(msg: impl Into<String>) -> PoolsError {
    PoolsError::Serialization(msg.into())
}

fn parse_amount(s: &str) -> Result<i64, PoolsError> {
    s.parse().map_err(|_| err(format!("bad amount {s:?}")))
}

/// An adjustment, before it is built.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct AdjustQuote {
    pub pool: &'static str,
    pub collateral_box_id: String,
    pub collateral_asset: Option<String>,
    /// Units of collateral now and after: nanoERG, or the token's units.
    pub current_amount: i64,
    pub new_amount: i64,
    /// Positive when collateral is added from the wallet, negative when
    /// it is released to the wallet.
    pub delta: i64,
    pub owed: i64,
    pub collateral_value_after: i64,
    pub liquidation_value: i64,
    pub health_after_bps: i64,
    /// The least collateral the contract would accept right now.
    pub min_amount: i64,
}

impl AdjustQuote {
    pub fn new(
        pool: &'static Pool,
        position: &LoanPosition,
        dex: &DexPrice,
        new_amount: i64,
    ) -> Result<Self, PoolsError> {
        let liquidation_value = position.liquidation_value;
        let (collateral_value_after, min_amount) = match &position.collateral_asset {
            None => {
                if new_amount < MIN_ADJUSTED_COLLATERAL_NANO {
                    return Err(err(format!(
                        "a collateral box keeps at least {MIN_ADJUSTED_COLLATERAL_NANO} nanoERG"
                    )));
                }
                (
                    dex.collateral_value(new_amount),
                    dex.collateral_for_value(liquidation_value + 1)
                        .max(MIN_ADJUSTED_COLLATERAL_NANO),
                )
            }
            Some(_) => {
                if new_amount <= 0 {
                    return Err(err("collateral must stay positive"));
                }
                (
                    dex.token_collateral_value(new_amount),
                    dex.tokens_for_value(liquidation_value + 1).max(1),
                )
            }
        };
        // `isCorrectCollateralAmount`: strictly above the line.
        if collateral_value_after <= liquidation_value {
            return Err(err(format!(
                "that leaves the loan at or below its liquidation line; keep at least {min_amount}"
            )));
        }
        if new_amount == position.collateral_amount {
            return Err(err("that is the collateral already"));
        }
        let health_after_bps = (i128::from(collateral_value_after) * 10_000
            / i128::from(liquidation_value.max(1))) as i64;
        Ok(Self {
            pool: pool.key,
            collateral_box_id: position.box_id.clone(),
            collateral_asset: position.collateral_asset.clone(),
            current_amount: position.collateral_amount,
            new_amount,
            delta: new_amount - position.collateral_amount,
            owed: position.owed,
            collateral_value_after,
            liquidation_value,
            health_after_bps,
            min_amount,
        })
    }

    /// ERG the wallet must add beyond the fee, and the token it must add,
    /// if any.
    pub fn wallet_needs(&self) -> (i64, Option<(String, i64)>) {
        match (&self.collateral_asset, self.delta) {
            (None, d) if d > 0 => (d, None),
            (Some(id), d) if d > 0 => (0, Some((id.clone(), d))),
            _ => (0, None),
        }
    }
}

/// The four boxes the collateral contract reads, in the order it reads
/// them.
#[derive(Debug, Clone)]
pub struct AdjustDataInputs {
    pub base_child: Eip12InputBox,
    pub parent: Eip12InputBox,
    pub head_child: Eip12InputBox,
    pub dex: Eip12InputBox,
}

impl AdjustDataInputs {
    /// Pick the boxes for a loan from the interest boxes and price boxes
    /// the app read: the base child is the one whose index is the loan's
    /// parent index, the head child the one at the parent's length.
    pub fn select(
        position: &LoanPosition,
        history: &InterestHistory,
        children: &[(i32, Eip12InputBox)],
        parent: Eip12InputBox,
        dexes: &[Eip12InputBox],
    ) -> Result<Self, PoolsError> {
        let child = |index: i32| -> Result<Eip12InputBox, PoolsError> {
            children
                .iter()
                .find(|(i, _)| *i == index)
                .map(|(_, b)| b.clone())
                .ok_or_else(|| err(format!("child interest box {index} is missing")))
        };
        let dex = dexes
            .iter()
            .find(|d| {
                d.assets
                    .first()
                    .map(|a| a.token_id.eq_ignore_ascii_case(&position_dex_nft(position)))
                    .unwrap_or(false)
            })
            .cloned()
            .ok_or_else(|| err("the loan's price box is missing"))?;
        Ok(Self {
            base_child: child(position.parent_index)?,
            parent,
            head_child: child(history.head_index())?,
            dex,
        })
    }

    fn list(&self) -> Vec<Eip12DataInputBox> {
        [&self.base_child, &self.parent, &self.head_child, &self.dex]
            .into_iter()
            .map(|b| Eip12DataInputBox {
                box_id: b.box_id.clone(),
                transaction_id: b.transaction_id.clone(),
                index: b.index,
                value: b.value.clone(),
                ergo_tree: b.ergo_tree.clone(),
                assets: b.assets.clone(),
                creation_height: b.creation_height,
                additional_registers: b.additional_registers.clone(),
            })
            .collect()
    }
}

fn position_dex_nft(position: &LoanPosition) -> String {
    position.dex_nft.clone()
}

/// Build the adjustment: the collateral box first, then the wallet's
/// `inputs`; the successor first, then change to `change_tree` with
/// whatever the wallet put in or the box let go, then the fee. Fails
/// rather than build a change box below the minimum.
pub fn build_adjust_tx(
    quote: &AdjustQuote,
    collateral: &Eip12InputBox,
    inputs: &[Eip12InputBox],
    data: &AdjustDataInputs,
    change_tree: &str,
    miner_fee: i64,
    height: i32,
) -> Result<Eip12UnsignedTx, PoolsError> {
    if collateral.box_id != quote.collateral_box_id {
        return Err(err("collateral box does not match the quote"));
    }
    if inputs.iter().any(|b| b.box_id == collateral.box_id) {
        return Err(err("the collateral box is not a wallet input"));
    }
    let current_value = parse_amount(&collateral.value)?;
    // The successor: same script, same registers, adjusted collateral.
    let (successor_value, successor_assets): (i64, Vec<Eip12Asset>) = match &quote.collateral_asset {
        None => (quote.new_amount, collateral.assets.clone()),
        Some(id) => {
            let mut a = collateral.assets.clone();
            match a.first_mut() {
                Some(first) if first.token_id.eq_ignore_ascii_case(id) => {
                    first.amount = quote.new_amount.to_string();
                }
                _ => return Err(err("collateral box does not carry the collateral token first")),
            }
            (current_value, a)
        }
    };
    // Everything in, everything out.
    let mut total: i64 = current_value;
    let mut tokens: HashMap<String, i64> = HashMap::new();
    for a in &collateral.assets {
        *tokens.entry(a.token_id.to_ascii_lowercase()).or_default() += parse_amount(&a.amount)?;
    }
    for b in inputs {
        total = total
            .checked_add(parse_amount(&b.value)?)
            .ok_or_else(|| err("input value overflows"))?;
        for a in &b.assets {
            *tokens.entry(a.token_id.to_ascii_lowercase()).or_default() += parse_amount(&a.amount)?;
        }
    }
    for a in &successor_assets {
        let have = tokens.get(&a.token_id.to_ascii_lowercase()).copied().unwrap_or(0);
        let need = parse_amount(&a.amount)?;
        if have < need {
            return Err(err(format!(
                "inputs hold {have} of {} but the collateral needs {need}",
                a.token_id
            )));
        }
        tokens.insert(a.token_id.to_ascii_lowercase(), have - need);
    }
    let spend = successor_value + miner_fee;
    if total < spend {
        return Err(err(format!(
            "inputs hold {total} nanoERG but the adjustment needs {spend}"
        )));
    }
    let change = total - spend;
    let change_tokens: Vec<Eip12Asset> = tokens
        .into_iter()
        .filter(|(_, n)| *n > 0)
        .map(|(id, n)| Eip12Asset {
            token_id: id,
            amount: n.to_string(),
        })
        .collect();
    if (change > 0 && change < MIN_BOX_VALUE) || (change == 0 && !change_tokens.is_empty()) {
        return Err(err(
            "change would be below the minimum box value; add an input or adjust the amount",
        ));
    }
    let mut all_inputs = vec![collateral.clone()];
    all_inputs.extend_from_slice(inputs);
    let mut outputs = vec![Eip12Output {
        value: successor_value.to_string(),
        ergo_tree: collateral.ergo_tree.clone(),
        assets: successor_assets,
        creation_height: height,
        additional_registers: collateral.additional_registers.clone(),
    }];
    if change > 0 {
        outputs.push(Eip12Output {
            value: change.to_string(),
            ergo_tree: change_tree.to_string(),
            assets: change_tokens,
            creation_height: height,
            additional_registers: HashMap::new(),
        });
    }
    outputs.push(Eip12Output::fee(miner_fee, height));
    Ok(Eip12UnsignedTx {
        inputs: all_inputs,
        data_inputs: data.list(),
        outputs,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::loans::CollateralBox;
    use crate::pool_by_key;

    fn fixture(name: &str) -> serde_json::Value {
        serde_json::from_str(match name {
            "collateral" => include_str!("../test/fixtures/collateral_sigusd.json"),
            "dex" => include_str!("../test/fixtures/dex_erg_sigusd.json"),
            "parent" => include_str!("../test/fixtures/interest_parent_sigusd.json"),
            "children" => include_str!("../test/fixtures/interest_children_sigusd.json"),
            _ => panic!("{name}"),
        })
        .unwrap()
    }

    const BORROWER: &str =
        "0008cd02c2e577f9bb9cb6b39cb0e38ccba615937fc34a3dcc69f01d012f0d8ec4724c79";

    fn position() -> (LoanPosition, InterestHistory, DexPrice) {
        let pool = pool_by_key("sigusd").unwrap();
        let children: Vec<serde_json::Value> = fixture("children").as_array().unwrap().clone();
        let h = InterestHistory::parse(pool, &fixture("parent"), &children).unwrap();
        let c = CollateralBox::parse(pool, &fixture("collateral")).unwrap();
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        let p = LoanPosition::value(pool, &c, &h, &dex, 1_866_418).unwrap();
        (p, h, dex)
    }

    fn input(id: &str, value: i64, tree: &str, assets: Vec<(&str, i64)>, regs: &[(&str, &str)]) -> Eip12InputBox {
        Eip12InputBox {
            box_id: id.repeat(32),
            transaction_id: "22".repeat(32),
            index: 0,
            value: value.to_string(),
            ergo_tree: tree.into(),
            assets: assets
                .into_iter()
                .map(|(t, n)| Eip12Asset {
                    token_id: t.into(),
                    amount: n.to_string(),
                })
                .collect(),
            creation_height: 1,
            additional_registers: regs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            extension: HashMap::new(),
        }
    }

    fn live_collateral_input() -> Eip12InputBox {
        let v = fixture("collateral");
        let regs: Vec<(String, String)> = v["additionalRegisters"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, r)| (k.clone(), r["serializedValue"].as_str().unwrap().to_string()))
            .collect();
        let mut b = input(
            "aa",
            v["value"].as_i64().unwrap(),
            v["ergoTree"].as_str().unwrap(),
            vec![(v["assets"][0]["tokenId"].as_str().unwrap(), v["assets"][0]["amount"].as_i64().unwrap())],
            &[],
        );
        b.box_id = v["boxId"].as_str().unwrap().to_string();
        b.additional_registers = regs.into_iter().collect();
        b
    }

    #[test]
    fn a_token_pool_loan_can_release_erg_down_to_the_line_and_add_any_amount() {
        let (p, _, dex) = position();
        // 2,500 ERG backs 239.39 SigUSD at 140% with ERG near 0.25
        // SigUSD: about 1,338 ERG is the least.
        let q = AdjustQuote::new(pool_by_key("sigusd").unwrap(), &p, &dex, 1_500_000_000_000).unwrap();
        assert_eq!(q.delta, -1_000_000_000_000);
        assert!(q.health_after_bps > 10_000 && q.health_after_bps < p.health_bps);
        assert!(q.min_amount > 1_300_000_000_000 && q.min_amount < 1_400_000_000_000, "{}", q.min_amount);
        assert!(dex.collateral_value(q.min_amount) > p.liquidation_value);
        assert!(dex.collateral_value(q.min_amount - 1) <= p.liquidation_value);
        assert_eq!(q.wallet_needs(), (0, None));
        let up = AdjustQuote::new(pool_by_key("sigusd").unwrap(), &p, &dex, 2_600_000_000_000).unwrap();
        assert_eq!(up.wallet_needs(), (100_000_000_000, None));
        assert!(AdjustQuote::new(pool_by_key("sigusd").unwrap(), &p, &dex, q.min_amount - 1).is_err());
        assert!(AdjustQuote::new(pool_by_key("sigusd").unwrap(), &p, &dex, 3_000_000).is_err(), "below the box minimum");
        assert!(AdjustQuote::new(pool_by_key("sigusd").unwrap(), &p, &dex, p.collateral_amount).is_err(), "no change");
    }

    #[test]
    fn the_adjustment_keeps_the_script_and_registers_and_moves_the_difference() {
        let (p, h, dex) = position();
        let pool = pool_by_key("sigusd").unwrap();
        let collateral = live_collateral_input();
        let children: Vec<(i32, Eip12InputBox)> = (0..=14).map(|i| (i, input("c1", 1, "cc", vec![], &[]))).collect();
        let parent = input("c2", 1, "pp", vec![], &[]);
        let dex_box = input("c3", 1, "dd", vec![(&dex.nft, 1)], &[]);
        let data = AdjustDataInputs::select(&p, &h, &children, parent, &[dex_box]).unwrap();
        assert_eq!(data.list().len(), 4);

        // Release 1,000 ERG: no wallet input needed, the fee comes out of it.
        let q = AdjustQuote::new(pool, &p, &dex, 1_500_000_000_000).unwrap();
        let tx = build_adjust_tx(&q, &collateral, &[], &data, BORROWER, TX_FEE, 100).unwrap();
        assert_eq!(tx.inputs.len(), 1);
        assert_eq!(tx.data_inputs.len(), 4);
        assert_eq!(tx.outputs.len(), 3);
        let successor = &tx.outputs[0];
        assert_eq!(successor.value, "1500000000000");
        assert_eq!(successor.ergo_tree, collateral.ergo_tree);
        assert_eq!(successor.assets.len(), 1);
        assert_eq!(successor.assets[0].amount, collateral.assets[0].amount);
        assert_eq!(successor.additional_registers, collateral.additional_registers);
        assert_eq!(tx.outputs[1].value, (1_000_000_000_000 - TX_FEE).to_string());
        assert_eq!(tx.outputs[1].ergo_tree, BORROWER);

        // Add 100 ERG from a 150 ERG wallet box with a token: change keeps the token.
        let up = AdjustQuote::new(pool, &p, &dex, 2_600_000_000_000).unwrap();
        let wallet = input("bb", 150_000_000_000, BORROWER, vec![("ee", 7)], &[]);
        let tx = build_adjust_tx(&up, &collateral, &[wallet.clone()], &data, BORROWER, TX_FEE, 100).unwrap();
        assert_eq!(tx.inputs[0].box_id, collateral.box_id, "the collateral box is INPUTS(0)");
        assert_eq!(tx.outputs[0].value, "2600000000000");
        assert_eq!(tx.outputs[1].value, (50_000_000_000 - TX_FEE).to_string());
        assert_eq!(tx.outputs[1].assets[0].token_id, "ee");
        assert!(build_adjust_tx(&up, &collateral, &[], &data, BORROWER, TX_FEE, 100).is_err(), "nothing to add from");
        assert!(build_adjust_tx(&up, &collateral, &[collateral.clone()], &data, BORROWER, TX_FEE, 100).is_err());
        assert!(AdjustDataInputs::select(&p, &h, &children[..3], input("c2", 1, "pp", vec![], &[]), &[]).is_err());
    }

    #[test]
    fn an_erg_pool_loan_moves_tokens_and_keeps_its_erg() {
        let pool = pool_by_key("erg").unwrap();
        let sigusd = crate::pools::ERG_POOL_COLLATERALS[0];
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        let mut children = std::collections::BTreeMap::new();
        children.insert(0, vec![100_000_490]);
        let h = InterestHistory { parent_rates: vec![], children };
        let regs = [
            ("R4", crate::encode::coll_byte(&hex::decode(BORROWER).unwrap()).unwrap()),
            ("R5", crate::encode::int_pair(0, 0).unwrap()),
            ("R6", crate::encode::long_pair(1250, 300).unwrap()),
            ("R7", crate::encode::coll_byte(&hex::decode(sigusd.dex_nft).unwrap()).unwrap()),
            ("R8", crate::encode::group_element(&BORROWER[6..]).unwrap()),
            ("R9", crate::encode::long_pair(1_930_000, 100_000_000).unwrap()),
        ];
        let regs_ref: Vec<(&str, &str)> = regs.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let collateral = input(
            "aa",
            crate::loans::ERG_POOL_COLLATERAL_BOX_VALUE,
            &ergo_tx::address_to_ergo_tree(pool.collateral_address).unwrap(),
            vec![(sigusd.id, 100_000), (pool.borrow_token, 1_000_000_000_000)],
            &regs_ref,
        );
        let v: serde_json::Value = serde_json::json!({
            "boxId": collateral.box_id, "value": crate::loans::ERG_POOL_COLLATERAL_BOX_VALUE,
            "ergoTree": collateral.ergo_tree,
            "assets": [{"tokenId": sigusd.id, "amount": 100_000}, {"tokenId": pool.borrow_token, "amount": 1_000_000_000_000i64}],
            "additionalRegisters": regs.iter().map(|(k, v)| (k.to_string(), serde_json::json!(v))).collect::<serde_json::Map<_, _>>(),
        });
        let c = CollateralBox::parse(pool, &v).unwrap();
        let p = LoanPosition::value(pool, &c, &h, &dex, 1).unwrap();
        // Release 600 SigUSD; 400 still backs 1,000 ERG at 125%.
        let q = AdjustQuote::new(pool, &p, &dex, 40_000).unwrap();
        assert_eq!(q.delta, -60_000);
        assert!(q.min_amount > 33_000 && q.min_amount < 40_000, "{}", q.min_amount);
        assert!(AdjustQuote::new(pool, &p, &dex, 30_000).is_err());
        let data = AdjustDataInputs {
            base_child: input("c1", 1, "cc", vec![], &[]),
            parent: input("c2", 1, "pp", vec![], &[]),
            head_child: input("c1", 1, "cc", vec![], &[]),
            dex: input("c3", 1, "dd", vec![(&dex.nft, 1)], &[]),
        };
        // The fee must come from the wallet: the box's ERG never changes.
        assert!(build_adjust_tx(&q, &collateral, &[], &data, BORROWER, TX_FEE, 100).is_err());
        let wallet = input("bb", 10_000_000, BORROWER, vec![], &[]);
        let tx = build_adjust_tx(&q, &collateral, &[wallet], &data, BORROWER, TX_FEE, 100).unwrap();
        assert_eq!(tx.outputs[0].value, crate::loans::ERG_POOL_COLLATERAL_BOX_VALUE.to_string());
        assert_eq!(tx.outputs[0].assets[0].amount, "40000");
        assert_eq!(tx.outputs[0].assets[1].amount, "1000000000000");
        assert_eq!(tx.outputs[1].assets[0].amount, "60000", "released tokens come back");
        assert_eq!(tx.outputs[1].value, (10_000_000 - TX_FEE).to_string());
        // Add 100 SigUSD from the wallet.
        let up = AdjustQuote::new(pool, &p, &dex, 110_000).unwrap();
        assert_eq!(up.wallet_needs(), (0, Some((sigusd.id.to_string(), 10_000))));
        let wallet = input("bb", 10_000_000, BORROWER, vec![(sigusd.id, 12_000)], &[]);
        let tx = build_adjust_tx(&up, &collateral, &[wallet], &data, BORROWER, TX_FEE, 100).unwrap();
        assert_eq!(tx.outputs[0].assets[0].amount, "110000");
        assert_eq!(tx.outputs[1].assets[0].amount, "2000");
    }
}
