//! SigmaFi behind the FFI: the market from explorer boxes, and the five
//! transactions as preparations for the ordinary confirm-and-sign flow.

use ergo_tx::Eip12InputBox;
use sigmafi::{ActiveBond, OpenOrder};

use crate::error::ArgusError;

fn ser_err(e: impl std::fmt::Display) -> String {
    ArgusError::SerializationError(e.to_string()).to_json_string()
}

fn build_err(e: impl std::fmt::Display) -> String {
    ArgusError::TxBuildFailed(e.to_string()).to_json_string()
}

/// The loan assets with the scripts to fetch boxes under.
pub fn contracts_json() -> String {
    let list: Vec<serde_json::Value> = sigmafi::LOAN_TOKENS
        .iter()
        .map(|t| {
            serde_json::json!({
                "id": t.id,
                "name": t.name,
                "decimals": t.decimals,
                "order_tree": sigmafi::order_contract(t.id),
                "bond_tree": sigmafi::bond_contract(t.id),
            })
        })
        .collect();
    serde_json::Value::Array(list).to_string()
}

/// Explorer (or node) boxes under the SigmaFi scripts, as the market.
pub fn market_json(boxes_json: &str, height: i64) -> Result<String, String> {
    let boxes = zerojoin::parse_explorer_boxes(boxes_json).map_err(ser_err)?;
    let height = i32::try_from(height).map_err(|_| build_err("height"))?;
    let market = sigmafi::parse_market(&boxes, height);
    serde_json::to_string(&market).map_err(ser_err)
}

/// One explorer box as an EIP-12 input.
pub fn parse_box(box_json: &str) -> Result<Eip12InputBox, String> {
    zerojoin::parse_explorer_boxes(&format!("[{box_json}]"))
        .map_err(ser_err)?
        .into_iter()
        .next()
        .ok_or_else(|| ser_err("no box"))
}

/// What a spend does with a protocol box, for the confirm sheet.
pub enum Spend {
    Cancel(OpenOrder),
    Close(OpenOrder),
    Repay(ActiveBond),
    Liquidate(ActiveBond),
}

impl Spend {
    /// Read the box as what `action` needs it to be.
    pub fn read(action: &str, b: &Eip12InputBox, height: i32) -> Result<Self, String> {
        let order = || {
            let asset = sigmafi::loan_asset_of_order(&b.ergo_tree)
                .ok_or_else(|| build_err("this box is not a SigmaFi order"))?;
            sigmafi::market::parse_order(b, &asset).map_err(build_err)
        };
        let bond = || {
            let asset = sigmafi::loan_asset_of_bond(&b.ergo_tree)
                .ok_or_else(|| build_err("this box is not a SigmaFi bond"))?;
            sigmafi::market::parse_bond(b, &asset, height).map_err(build_err)
        };
        match action {
            "cancel" => Ok(Spend::Cancel(order()?)),
            "close" => Ok(Spend::Close(order()?)),
            "repay" => Ok(Spend::Repay(bond()?)),
            "liquidate" => Ok(Spend::Liquidate(bond()?)),
            other => Err(build_err(format!("unknown SigmaFi action {other:?}"))),
        }
    }

    /// The wallet key the contract will ask for, if the spend needs one
    /// beyond the wallet's own inputs: the borrower's on cancel and repay,
    /// the lender's on liquidate. A close is signed by whoever lends.
    pub fn required_address(&self) -> Option<&str> {
        match self {
            Spend::Cancel(o) => Some(&o.borrower_address),
            Spend::Close(_) => None,
            Spend::Repay(b) => Some(&b.borrower_address),
            Spend::Liquidate(b) => Some(&b.lender_address),
        }
    }

    /// The tree the change returns to: the required key's own address
    /// where there is one, else the lender's.
    pub fn change_tree(&self, lender_tree: &str) -> String {
        match self {
            Spend::Cancel(o) => format!("0008cd{}", o.borrower_pk),
            Spend::Close(_) => lender_tree.to_string(),
            Spend::Repay(b) => format!("0008cd{}", b.borrower_pk),
            Spend::Liquidate(b) => format!("0008cd{}", b.lender_pk),
        }
    }

    pub fn build(
        &self,
        b: &Eip12InputBox,
        lender_tree: &str,
        ui_fee_tree: &str,
        utxos: &[Eip12InputBox],
        height: i32,
        miner_fee: i64,
    ) -> Result<ergo_tx::Eip12UnsignedTx, String> {
        match self {
            Spend::Cancel(_) => sigmafi::build_cancel_order(b, utxos, height, miner_fee),
            Spend::Close(_) => {
                sigmafi::build_close_order(b, lender_tree, ui_fee_tree, utxos, height, miner_fee)
            }
            Spend::Repay(_) => sigmafi::build_repay(b, utxos, height, miner_fee),
            Spend::Liquidate(_) => sigmafi::build_liquidate(b, utxos, height, miner_fee),
        }
        .map_err(build_err)
    }

    /// The figures the confirm sheet shows.
    pub fn summary(&self, height: i32) -> serde_json::Value {
        match self {
            Spend::Cancel(o) => serde_json::json!({
                "action": "cancel",
                "loan_asset": o.loan_asset,
                "collateral_erg": o.collateral_erg,
                "collateral_tokens": o.collateral_tokens,
            }),
            Spend::Close(o) => serde_json::json!({
                "action": "close",
                "loan_asset": o.loan_asset,
                "principal": o.principal,
                "repayment": o.repayment,
                "dev_fee": o.dev_fee,
                "ui_fee": o.ui_fee,
                "lender_cost": o.lender_cost(),
                "term_blocks": o.term_blocks,
                "maturity_height": height + o.term_blocks,
                "collateral_erg": o.collateral_erg,
                "collateral_tokens": o.collateral_tokens,
                "borrower_address": o.borrower_address,
            }),
            Spend::Repay(b) => serde_json::json!({
                "action": "repay",
                "loan_asset": b.loan_asset,
                "repayment": b.repayment,
                "collateral_erg": b.collateral_erg,
                "collateral_tokens": b.collateral_tokens,
                "lender_address": b.lender_address,
                "blocks_remaining": b.blocks_remaining,
            }),
            Spend::Liquidate(b) => serde_json::json!({
                "action": "liquidate",
                "loan_asset": b.loan_asset,
                "collateral_erg": b.collateral_erg,
                "collateral_tokens": b.collateral_tokens,
                "borrower_address": b.borrower_address,
                "blocks_overdue": -b.blocks_remaining,
            }),
        }
    }
}

/// `[{"token_id": "...", "amount": 5}]` as the builders take it.
pub fn parse_collateral_tokens(json: &str) -> Result<Vec<(String, u64)>, String> {
    if json.trim().is_empty() {
        return Ok(Vec::new());
    }
    let items: Vec<serde_json::Value> = serde_json::from_str(json).map_err(ser_err)?;
    items
        .iter()
        .map(|v| {
            let id = v["token_id"]
                .as_str()
                .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
                .ok_or_else(|| build_err("collateral token id"))?;
            let amount = v["amount"]
                .as_u64()
                .filter(|n| *n > 0)
                .ok_or_else(|| build_err(format!("collateral amount for {id}")))?;
            Ok((id.to_ascii_lowercase(), amount))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contracts_list_every_loan_asset_with_both_scripts() {
        let v: Vec<serde_json::Value> = serde_json::from_str(&contracts_json()).unwrap();
        assert_eq!(v.len(), sigmafi::LOAN_TOKENS.len());
        assert_eq!(v[0]["id"], "ERG");
        assert_eq!(v[0]["order_tree"], sigmafi::contracts::ERG_ORDER_ON_CLOSE);
        assert!(v[1]["bond_tree"].as_str().unwrap().contains(v[1]["id"].as_str().unwrap()));
    }

    #[test]
    fn collateral_tokens_are_checked() {
        assert_eq!(parse_collateral_tokens("").unwrap(), vec![]);
        let ok = parse_collateral_tokens(&format!(r#"[{{"token_id":"{}","amount":5}}]"#, "AB".repeat(32))).unwrap();
        assert_eq!(ok, vec![("ab".repeat(32), 5)]);
        assert!(parse_collateral_tokens(r#"[{"token_id":"xyz","amount":5}]"#).is_err());
        assert!(parse_collateral_tokens(&format!(r#"[{{"token_id":"{}","amount":0}}]"#, "ab".repeat(32))).is_err());
    }

    #[test]
    fn market_reads_explorer_boxes() {
        let json = include_str!("../../vendor/protocols/sigmafi/test/fixtures/orders_sigusd.json");
        let m: serde_json::Value = serde_json::from_str(&market_json(json, 1_300_000).unwrap()).unwrap();
        assert_eq!(m["orders"].as_array().unwrap().len(), 3);
        assert_eq!(m["bonds"].as_array().unwrap().len(), 0);
        let o = &m["orders"][0];
        assert!(o["box"]["boxId"].is_string());
        assert!(o["borrower_address"].as_str().unwrap().starts_with('9'));
        assert!(Spend::read("close", &parse_box(&serde_json::from_str::<Vec<serde_json::Value>>(json).unwrap()[0].to_string()).unwrap(), 1).is_ok());
        assert!(Spend::read("repay", &parse_box(&serde_json::from_str::<Vec<serde_json::Value>>(json).unwrap()[0].to_string()).unwrap(), 1).is_err());
    }
}
