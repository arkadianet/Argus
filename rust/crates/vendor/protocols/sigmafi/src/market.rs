//! Order and bond boxes read into what a screen shows.

use ergo_tx::Eip12InputBox;
use serde::Serialize;

use crate::contracts::{is_on_close_order, loan_asset_of_bond, loan_asset_of_order};
use crate::{dev_fee, ui_fee};

#[derive(Debug, thiserror::Error)]
pub enum MarketError {
    #[error("box {box_id}: register {register} {why}")]
    Register {
        box_id: String,
        register: &'static str,
        why: String,
    },
    #[error("box {box_id}: {why}")]
    Box { box_id: String, why: String },
}

/// A loan request waiting for a lender.
#[derive(Debug, Clone, Serialize)]
pub struct OpenOrder {
    pub box_id: String,
    /// `"ERG"` or a token id.
    pub loan_asset: String,
    /// Whether the term starts at the fill (the variant Argus fills).
    pub on_close: bool,
    pub borrower_pk: String,
    pub borrower_address: String,
    /// Loan asset units the borrower asks for.
    pub principal: u64,
    /// Loan asset units the borrower will repay.
    pub repayment: u64,
    /// Blocks from the fill to maturity.
    pub term_blocks: i32,
    /// nanoERG locked as collateral (the box value).
    pub collateral_erg: u64,
    /// Tokens locked as collateral.
    pub collateral_tokens: Vec<(String, u64)>,
    /// `(repayment - principal) / principal`, in percent.
    pub interest_percent: f64,
    /// The interest annualised over the term at two-minute blocks.
    pub apr_percent: f64,
    /// Contract fee the lender pays on top of the loan, loan asset units.
    pub dev_fee: u64,
    /// Interface fee the lender pays on top of the loan, loan asset units.
    pub ui_fee: u64,
    /// The box, to spend it later.
    #[serde(rename = "box")]
    pub input: Eip12InputBox,
}

impl OpenOrder {
    /// Everything the lender parts with in the loan asset.
    pub fn lender_cost(&self) -> u64 {
        self.principal + self.dev_fee + self.ui_fee
    }
}

/// A filled loan: collateral held until repayment or maturity.
#[derive(Debug, Clone, Serialize)]
pub struct ActiveBond {
    pub box_id: String,
    pub loan_asset: String,
    /// The order this bond came from (R4).
    pub order_box_id: String,
    pub borrower_pk: String,
    pub borrower_address: String,
    pub lender_pk: String,
    pub lender_address: String,
    /// Loan asset units that settle the bond.
    pub repayment: u64,
    /// The block from which the lender may liquidate.
    pub maturity_height: i32,
    pub collateral_erg: u64,
    pub collateral_tokens: Vec<(String, u64)>,
    /// Blocks until maturity at `height`; zero or negative once the
    /// lender can liquidate.
    pub blocks_remaining: i32,
    #[serde(rename = "box")]
    pub input: Eip12InputBox,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Market {
    pub orders: Vec<OpenOrder>,
    pub bonds: Vec<ActiveBond>,
    /// Boxes under a SigmaFi script that did not parse; shown, not hidden.
    pub skipped: Vec<String>,
}

/// Sort every box under a SigmaFi script into orders and bonds. Boxes
/// under other scripts are ignored; SigmaFi boxes with broken registers
/// are listed in `skipped` with the reason.
pub fn parse_market(boxes: &[Eip12InputBox], height: i32) -> Market {
    let mut market = Market::default();
    for b in boxes {
        // Dust sent to a contract address carries no registers; it is not
        // a broken order, just not one at all.
        if b.additional_registers.is_empty() {
            continue;
        }
        if let Some(asset) = loan_asset_of_order(&b.ergo_tree) {
            match parse_order(b, &asset) {
                Ok(o) => market.orders.push(o),
                Err(e) => market.skipped.push(e.to_string()),
            }
        } else if let Some(asset) = loan_asset_of_bond(&b.ergo_tree) {
            match parse_bond(b, &asset, height) {
                Ok(o) => market.bonds.push(o),
                Err(e) => market.skipped.push(e.to_string()),
            }
        }
    }
    market
}

pub fn parse_order(b: &Eip12InputBox, asset: &str) -> Result<OpenOrder, MarketError> {
    let borrower_pk = sigma_prop_pk(b, "R4")?;
    let principal = long(b, "R5")?;
    let repayment = long(b, "R6")?;
    let term_blocks = int(b, "R7")?;
    if principal <= 0 || repayment < principal {
        return Err(MarketError::Box {
            box_id: b.box_id.clone(),
            why: format!("principal {principal} and repayment {repayment} make no loan"),
        });
    }
    let interest_percent = (repayment - principal) as f64 / principal as f64 * 100.0;
    Ok(OpenOrder {
        box_id: b.box_id.clone(),
        loan_asset: asset.to_string(),
        on_close: is_on_close_order(&b.ergo_tree),
        borrower_address: address_of_pk(&borrower_pk),
        borrower_pk,
        principal: principal as u64,
        repayment: repayment as u64,
        term_blocks,
        collateral_erg: value(b)?,
        collateral_tokens: tokens(b)?,
        interest_percent,
        apr_percent: apr_percent(interest_percent, term_blocks),
        dev_fee: dev_fee(principal as u64),
        ui_fee: ui_fee(principal as u64),
        input: b.clone(),
    })
}

pub fn parse_bond(b: &Eip12InputBox, asset: &str, height: i32) -> Result<ActiveBond, MarketError> {
    let order_box_id = coll_byte_hex(b, "R4")?;
    let borrower_pk = sigma_prop_pk(b, "R5")?;
    let repayment = long(b, "R6")?;
    let maturity_height = int(b, "R7")?;
    let lender_pk = sigma_prop_pk(b, "R8")?;
    if repayment <= 0 {
        return Err(MarketError::Box {
            box_id: b.box_id.clone(),
            why: format!("repayment {repayment}"),
        });
    }
    Ok(ActiveBond {
        box_id: b.box_id.clone(),
        loan_asset: asset.to_string(),
        order_box_id,
        borrower_address: address_of_pk(&borrower_pk),
        borrower_pk,
        lender_address: address_of_pk(&lender_pk),
        lender_pk,
        repayment: repayment as u64,
        maturity_height,
        collateral_erg: value(b)?,
        collateral_tokens: tokens(b)?,
        blocks_remaining: maturity_height.saturating_sub(height),
        input: b.clone(),
    })
}

/// Interest over `term_blocks` blocks scaled to a year of two-minute
/// blocks; zero for a term of no blocks.
pub fn apr_percent(interest_percent: f64, term_blocks: i32) -> f64 {
    if term_blocks <= 0 {
        return 0.0;
    }
    interest_percent * (365.0 * 24.0 * 30.0) / term_blocks as f64
}

/// The mainnet P2PK address of a 33-byte public key; the hex itself when
/// it is not a valid key, so one odd box cannot hide the whole market.
pub fn address_of_pk(pk_hex: &str) -> String {
    ergo_tx::address::ergo_tree_to_address(&format!("0008cd{pk_hex}"))
        .unwrap_or_else(|_| pk_hex.to_string())
}

fn register<'a>(b: &'a Eip12InputBox, name: &'static str) -> Result<&'a str, MarketError> {
    b.additional_registers
        .get(name)
        .map(String::as_str)
        .ok_or(MarketError::Register {
            box_id: b.box_id.clone(),
            register: name,
            why: "is missing".into(),
        })
}

fn sigma_prop_pk(b: &Eip12InputBox, name: &'static str) -> Result<String, MarketError> {
    let hex = register(b, name)?.to_ascii_lowercase();
    if hex.len() == 70 && hex.starts_with("08cd") {
        Ok(hex[4..].to_string())
    } else {
        Err(MarketError::Register {
            box_id: b.box_id.clone(),
            register: name,
            why: "is not a ProveDlog SigmaProp".into(),
        })
    }
}

fn coll_byte_hex(b: &Eip12InputBox, name: &'static str) -> Result<String, MarketError> {
    let hex = register(b, name)?.to_ascii_lowercase();
    match hex.strip_prefix("0e20") {
        Some(rest) if rest.len() == 64 => Ok(rest.to_string()),
        _ => Err(MarketError::Register {
            box_id: b.box_id.clone(),
            register: name,
            why: "is not a 32-byte Coll[Byte]".into(),
        }),
    }
}

fn long(b: &Eip12InputBox, name: &'static str) -> Result<i64, MarketError> {
    ergo_tx::sigma::decode_sigma_long(register(b, name)?).map_err(|e| MarketError::Register {
        box_id: b.box_id.clone(),
        register: name,
        why: format!("is not a Long: {e}"),
    })
}

fn int(b: &Eip12InputBox, name: &'static str) -> Result<i32, MarketError> {
    decode_sigma_int(register(b, name)?).ok_or(MarketError::Register {
        box_id: b.box_id.clone(),
        register: name,
        why: "is not an Int".into(),
    })
}

/// `04` + zigzag VLQ.
pub(crate) fn decode_sigma_int(hex_str: &str) -> Option<i32> {
    let bytes = hex::decode(hex_str).ok()?;
    if bytes.len() < 2 || bytes[0] != 0x04 {
        return None;
    }
    let mut result: u64 = 0;
    let mut shift = 0;
    let mut done = false;
    for &byte in &bytes[1..] {
        result |= ((byte & 0x7F) as u64) << shift;
        if byte & 0x80 == 0 {
            done = true;
            break;
        }
        shift += 7;
        if shift > 35 {
            return None;
        }
    }
    if !done || result > u32::MAX as u64 {
        return None;
    }
    let result = result as u32;
    Some(if result & 1 == 0 {
        (result >> 1) as i32
    } else {
        -((result >> 1) as i32) - 1
    })
}

fn value(b: &Eip12InputBox) -> Result<u64, MarketError> {
    b.value.parse().map_err(|_| MarketError::Box {
        box_id: b.box_id.clone(),
        why: format!("value {:?}", b.value),
    })
}

fn tokens(b: &Eip12InputBox) -> Result<Vec<(String, u64)>, MarketError> {
    b.assets
        .iter()
        .map(|a| {
            a.amount
                .parse()
                .map(|n| (a.token_id.clone(), n))
                .map_err(|_| MarketError::Box {
                    box_id: b.box_id.clone(),
                    why: format!("token {} amount {:?}", a.token_id, a.amount),
                })
        })
        .collect()
}

#[cfg(test)]
pub(crate) mod fixtures {
    use ergo_tx::{Eip12Asset, Eip12InputBox};
    use std::collections::HashMap;

    /// Explorer boxes as EIP-12 inputs (registers by `serializedValue`).
    pub fn boxes(json: &str) -> Vec<Eip12InputBox> {
        let items: Vec<serde_json::Value> = serde_json::from_str(json).unwrap();
        items
            .iter()
            .map(|b| Eip12InputBox {
                box_id: b["boxId"].as_str().unwrap().into(),
                transaction_id: b["transactionId"].as_str().unwrap().into(),
                index: b["index"].as_u64().unwrap() as u16,
                value: b["value"].as_u64().unwrap().to_string(),
                ergo_tree: b["ergoTree"].as_str().unwrap().into(),
                assets: b["assets"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|a| Eip12Asset::new(a["tokenId"].as_str().unwrap(), a["amount"].as_i64().unwrap()))
                    .collect(),
                creation_height: b["creationHeight"].as_i64().unwrap() as i32,
                additional_registers: b["additionalRegisters"]
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(k, v)| (k.clone(), v["serializedValue"].as_str().unwrap().to_string()))
                    .collect(),
                extension: HashMap::new(),
            })
            .collect()
    }

    pub fn orders_erg() -> Vec<Eip12InputBox> {
        boxes(include_str!("../test/fixtures/orders_erg.json"))
    }
    /// A live ERG order with all four registers.
    pub fn erg_order() -> Eip12InputBox {
        orders_erg().into_iter().find(|o| o.box_id.starts_with("117fb5c8")).unwrap()
    }
    pub fn orders_sigusd() -> Vec<Eip12InputBox> {
        boxes(include_str!("../test/fixtures/orders_sigusd.json"))
    }
    pub fn bonds_erg() -> Vec<Eip12InputBox> {
        boxes(include_str!("../test/fixtures/bonds_erg.json"))
    }
    pub fn bonds_sigusd() -> Vec<Eip12InputBox> {
        boxes(include_str!("../test/fixtures/bonds_sigusd.json"))
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;
    use crate::ERG;

    const SIGUSD: &str = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";

    #[test]
    fn live_erg_order_reads_its_registers() {
        // Three live boxes under the script: one is dust with no registers.
        let m = parse_market(&orders_erg(), 1_200_000);
        assert!(m.skipped.is_empty(), "{:?}", m.skipped);
        assert_eq!(m.orders.len(), 2);
        assert!(m.bonds.is_empty());
        // 117fb5c8…: 100 ERG asked, 104 ERG back over 259200 blocks (~1 year).
        let o = m.orders.iter().find(|o| o.box_id.starts_with("117fb5c8")).unwrap();
        assert_eq!(o.loan_asset, ERG);
        assert!(o.on_close);
        assert_eq!(o.principal, 100_000_000_000);
        assert_eq!(o.repayment, 104_000_000_000);
        assert_eq!(o.term_blocks, 259_200);
        assert_eq!(o.collateral_erg, 1_000_000);
        assert_eq!(o.collateral_tokens.len(), 1);
        assert!((o.interest_percent - 4.0).abs() < 1e-9);
        // 4% over 259200 blocks; a year is 262800 two-minute blocks.
        assert!((o.apr_percent - 4.0 * 262_800.0 / 259_200.0).abs() < 1e-9, "{}", o.apr_percent);
        assert_eq!(o.dev_fee, 500_000_000);
        assert_eq!(o.ui_fee, 400_000_000);
        assert_eq!(o.lender_cost(), 100_900_000_000);
        assert!(o.borrower_address.starts_with('9'), "{}", o.borrower_address);
        assert_eq!(o.borrower_pk.len(), 66);
    }

    #[test]
    fn live_sigusd_boxes_read_as_token_orders_and_bonds() {
        let mut all = orders_sigusd();
        all.extend(bonds_sigusd());
        let m = parse_market(&all, 1_300_000);
        assert!(m.skipped.is_empty(), "{:?}", m.skipped);
        assert_eq!(m.orders.len(), 3);
        assert_eq!(m.bonds.len(), 3);
        assert!(m.orders.iter().all(|o| o.loan_asset == SIGUSD));
        assert!(m.bonds.iter().all(|b| b.loan_asset == SIGUSD));
        for b in &m.bonds {
            assert_eq!(b.order_box_id.len(), 64);
            assert_eq!(b.blocks_remaining, b.maturity_height - 1_300_000);
            assert!(b.lender_address.starts_with('9'));
            assert!(b.borrower_address.starts_with('9'));
        }
    }

    #[test]
    fn live_erg_bonds_carry_token_collateral() {
        let m = parse_market(&bonds_erg(), 1_000_000);
        assert_eq!(m.bonds.len(), 3);
        assert!(m.bonds.iter().all(|b| b.loan_asset == ERG && !b.collateral_tokens.is_empty()));
    }

    #[test]
    fn a_broken_register_skips_only_that_box() {
        let mut boxes = orders_erg();
        boxes[1].additional_registers.insert("R5".into(), "0400".into());
        let m = parse_market(&boxes, 1);
        assert_eq!(m.orders.len(), 1);
        assert_eq!(m.skipped.len(), 1);
        assert!(m.skipped[0].contains("R5"), "{}", m.skipped[0]);
    }

    #[test]
    fn foreign_boxes_are_ignored_silently() {
        let mut b = orders_erg().remove(1);
        b.ergo_tree = "0008cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a02".into();
        let m = parse_market(&[b], 1);
        assert!(m.orders.is_empty() && m.bonds.is_empty() && m.skipped.is_empty());
    }

    #[test]
    fn int_decoding_round_trips() {
        for v in [0, 1, -1, 30, 259_200, 1_356_075, i32::MAX, i32::MIN] {
            assert_eq!(decode_sigma_int(&ergo_tx::sigma::encode_sigma_int(v)), Some(v));
        }
        assert_eq!(decode_sigma_int("0500"), None);
        assert_eq!(decode_sigma_int("04"), None);
    }

    #[test]
    fn apr_scales_interest_to_a_year() {
        // 5% over 30 days of blocks is about 60.8% a year.
        assert!((apr_percent(5.0, 21_600) - 60.833).abs() < 0.01);
        assert_eq!(apr_percent(5.0, 0), 0.0);
    }
}
