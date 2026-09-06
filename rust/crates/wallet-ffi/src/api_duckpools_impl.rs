//! Duckpools over the FFI: pool state with rates, quotes, and the two
//! transactions the wallet builds itself (posting an order, refunding
//! one). Fills are the bots' business.

use duckpools::{
    build_order_tx, classify_loan_spend, BorrowQuote, DexPrice, InterestHistory, InterestParams,
    LendQuote, LoanParams, LoanPosition, OrderKind, PartialRepayQuote, PoolState, RepayQuote,
    WithdrawQuote, POOLS,
};
use ergo_tx::Eip12InputBox;

use crate::error::ArgusError;

fn err(e: impl std::fmt::Display) -> String {
    ArgusError::TxBuildFailed(e.to_string()).to_json_string()
}

fn ser_err(e: impl std::fmt::Display) -> String {
    ArgusError::SerializationError(e.to_string()).to_json_string()
}

pub fn states(pool_boxes_json: &str) -> Result<Vec<PoolState>, String> {
    duckpools::parse_pool_boxes(pool_boxes_json).map_err(ser_err)
}

pub fn state_for(
    pool_boxes_json: &str,
    pool_key: &str,
) -> Result<(&'static duckpools::Pool, PoolState), String> {
    let pool =
        duckpools::pool_by_key(pool_key).ok_or_else(|| err(format!("unknown pool {pool_key}")))?;
    let state = states(pool_boxes_json)?
        .into_iter()
        .find(|s| s.pool == pool.key)
        .ok_or_else(|| {
            err(format!(
                "the {} pool box is not in the snapshot",
                pool.ticker
            ))
        })?;
    Ok((pool, state))
}

/// Interest parameters per pool key, from a list of parameter boxes
/// (explorer or node shape). Boxes that are not a known pool's are skipped.
pub fn interest_params(boxes_json: &str) -> Result<Vec<(&'static str, InterestParams)>, String> {
    if boxes_json.trim().is_empty() {
        return Ok(Vec::new());
    }
    let root: serde_json::Value = serde_json::from_str(boxes_json).map_err(ser_err)?;
    let items = match root.get("items") {
        Some(v) => v,
        None => &root,
    };
    let items = items
        .as_array()
        .ok_or_else(|| ser_err("expected an array of boxes"))?;
    let mut out = Vec::new();
    for it in items {
        for pool in POOLS {
            if let Ok(p) = InterestParams::parse(pool, it) {
                out.push((pool.key, p));
                break;
            }
        }
    }
    Ok(out)
}

/// The state JSON the app reads: one object per pool.
pub fn state_json(
    pool_boxes_json: &str,
    holdings_json: &str,
    interest_boxes_json: &str,
) -> Result<String, String> {
    let states = states(pool_boxes_json)?;
    let holdings: serde_json::Value = serde_json::from_str(holdings_json).map_err(ser_err)?;
    let params = interest_params(interest_boxes_json)?;
    let held = |id: &str| -> i64 {
        holdings
            .get(id)
            .and_then(|v| {
                v.as_i64()
                    .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
            })
            .unwrap_or(0)
    };
    let out: Vec<serde_json::Value> = states
        .iter()
        .map(|s| {
            let tokens = held(s.lend_token);
            let rates = params
                .iter()
                .find(|(k, _)| *k == s.pool)
                .map(|(_, p)| p.rates(s));
            serde_json::json!({
                "pool": s.pool,
                "ticker": s.ticker,
                "decimals": s.decimals,
                "pool_nft": s.pool_nft,
                "lend_token": s.lend_token,
                "box_id": s.box_id,
                "creation_height": s.creation_height,
                "pooled": s.pooled,
                "borrowed": s.borrowed,
                "lend_circulating": s.lend_circulating,
                "utilisation_bps": s.utilisation_bps(),
                "lend_token_price": s.lend_token_price(),
                "wallet_lend_tokens": tokens,
                "wallet_value": s.position_value(tokens),
                "borrow_apr_bps": rates.map(|r| r.borrow_apr_bps),
                "lend_apr_bps": rates.map(|r| r.lend_apr_bps),
            })
        })
        .collect();
    Ok(serde_json::json!(out).to_string())
}

/// The boxes a pool's loans are read from, as the app hands them over in
/// one JSON object: `collateral`, `parents`, `children`, `dex`, `params`
/// (each a list of boxes, all pools mixed). Rust sorts them by NFT.
pub struct LoanSnapshot {
    pub pool: &'static duckpools::Pool,
    /// The borrowing terms, or why they could not be read. Existing
    /// loans are valued without them, so a missing parameter box blocks
    /// new borrowing only.
    pub params: Result<LoanParams, String>,
    pub history: InterestHistory,
    pub dex: DexPrice,
    pub collateral: Vec<serde_json::Value>,
}

fn list<'a>(root: &'a serde_json::Value, key: &str) -> Vec<&'a serde_json::Value> {
    root.get(key)
        .and_then(|v| v.as_array())
        .map(|a| a.iter().collect())
        .unwrap_or_default()
}

fn carries(v: &serde_json::Value, nft: &str) -> bool {
    v.get("assets")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter().any(|t| {
                t.get("tokenId")
                    .and_then(|x| x.as_str())
                    .map(|x| x.eq_ignore_ascii_case(nft))
                    .unwrap_or(false)
                    && t.get("amount").and_then(|x| x.as_i64()) == Some(1)
            })
        })
        .unwrap_or(false)
}

impl LoanSnapshot {
    /// The snapshot for one pool, or why it cannot be read.
    pub fn parse(pool: &'static duckpools::Pool, root: &serde_json::Value) -> Result<Self, String> {
        let dex_nft = pool
            .erg_dex_nft
            .ok_or_else(|| err(format!("the {} pool takes no ERG collateral", pool.ticker)))?;
        let params = list(root, "params")
            .into_iter()
            .find(|b| carries(b, pool.param_nft))
            .ok_or_else(|| err(format!("the {} parameter box is missing", pool.ticker)))
            .and_then(|b| LoanParams::parse(pool, b).map_err(err));
        let parent = list(root, "parents")
            .into_iter()
            .find(|b| carries(b, pool.parent_nft))
            .ok_or_else(|| err(format!("the {} interest box is missing", pool.ticker)))?;
        let children: Vec<serde_json::Value> = list(root, "children")
            .into_iter()
            .filter(|b| carries(b, pool.child_nft))
            .cloned()
            .collect();
        let dex_box = list(root, "dex")
            .into_iter()
            .find(|b| carries(b, dex_nft))
            .ok_or_else(|| err(format!("the ERG/{} price box is missing", pool.ticker)))?;
        let collateral_tree =
            ergo_tx::address_to_ergo_tree(pool.collateral_address).map_err(err)?;
        let collateral: Vec<serde_json::Value> = list(root, "collateral")
            .into_iter()
            .filter(|b| {
                b.get("ergoTree")
                    .and_then(|t| t.as_str())
                    .map(|t| t.eq_ignore_ascii_case(&collateral_tree))
                    .unwrap_or(false)
            })
            .cloned()
            .collect();
        Ok(Self {
            pool,
            params,
            history: InterestHistory::parse(pool, parent, &children).map_err(err)?,
            dex: DexPrice::parse(dex_box).map_err(err)?,
            collateral,
        })
    }

    /// The borrowing terms, or the reason they are unavailable.
    pub fn terms(&self) -> Result<&LoanParams, String> {
        self.params.as_ref().map_err(|e| e.clone())
    }

    pub fn positions(&self, wallet_trees: &[String], height: i64) -> Result<Vec<LoanPosition>, String> {
        duckpools::positions(self.pool, &self.collateral, &self.history, &self.dex, wallet_trees, height)
            .map_err(err)
    }

    /// One loan by its collateral box id, whoever the borrower is.
    pub fn position(&self, collateral_box_id: &str, height: i64) -> Result<LoanPosition, String> {
        let v = self
            .collateral
            .iter()
            .find(|b| b.get("boxId").and_then(|x| x.as_str()) == Some(collateral_box_id))
            .ok_or_else(|| err("that loan is not in the snapshot; refresh and try again"))?;
        let c = duckpools::CollateralBox::parse(self.pool, v).map_err(err)?;
        LoanPosition::value(self.pool, &c, &self.history, &self.dex, height).map_err(err)
    }
}

/// The loans JSON the app reads: the wallet's positions and, per pool
/// that takes ERG collateral, the market it borrows against.
pub fn loans_json(loan_boxes_json: &str, wallet_trees: &[String], height: i64) -> Result<String, String> {
    let root: serde_json::Value = serde_json::from_str(loan_boxes_json).map_err(ser_err)?;
    let mut positions = Vec::new();
    let mut markets = Vec::new();
    for pool in POOLS {
        if pool.erg_dex_nft.is_none() {
            continue;
        }
        match LoanSnapshot::parse(pool, &root) {
            Ok(snap) => {
                // Existing loans first: they need the interest and price
                // boxes, not the borrowing terms.
                for p in snap.positions(wallet_trees, height)? {
                    let mut v = serde_json::to_value(&p).map_err(ser_err)?;
                    v["ticker"] = serde_json::json!(pool.ticker);
                    v["decimals"] = serde_json::json!(pool.decimals);
                    positions.push(v);
                }
                // The market: terms unavailable is this pool's error, not
                // every pool's, and not its loans'.
                let mut market = serde_json::json!({
                    "pool": pool.key,
                    "ticker": pool.ticker,
                    "decimals": pool.decimals,
                    "latest_rate": snap.history.latest_rate(),
                    "loans": snap.collateral.len(),
                });
                match snap.terms().and_then(|t| t.for_erg(pool).map_err(err)) {
                    Ok((threshold, penalty)) => {
                        market["threshold"] = serde_json::json!(threshold);
                        market["penalty"] = serde_json::json!(penalty);
                        // What one ERG of collateral counts for, after the
                        // contract's slippage and fees.
                        market["erg_value"] = serde_json::json!(
                            snap.dex.collateral_value(1_000_000_000 + duckpools::loans::MAX_NETWORK_FEE)
                        );
                    }
                    Err(e) => market["error"] = serde_json::json!(e),
                }
                markets.push(market);
            }
            Err(e) => markets.push(serde_json::json!({
                "pool": pool.key,
                "ticker": pool.ticker,
                "decimals": pool.decimals,
                "error": e,
            })),
        }
    }
    Ok(serde_json::json!({"positions": positions, "markets": markets}).to_string())
}

/// One order's quote and proxy box, any kind.
pub enum Quote {
    Lend(LendQuote),
    Withdraw(WithdrawQuote),
    Borrow(BorrowQuote),
    Repay(RepayQuote),
    PartialRepay(PartialRepayQuote),
}

/// What a loan-side quote needs beyond the amount.
pub struct LoanArgs<'a> {
    pub snapshot: &'a LoanSnapshot,
    pub collateral_nano: i64,
    pub collateral_box_id: &'a str,
    pub height: i64,
}

impl Quote {
    pub fn new(
        pool: &'static duckpools::Pool,
        state: &PoolState,
        kind: &str,
        amount: i64,
        slippage_bps: i64,
        refund_height: i64,
        loan: Option<LoanArgs<'_>>,
    ) -> Result<Self, String> {
        let refund_i32 = || -> Result<i32, String> {
            i32::try_from(refund_height).map_err(|_| err("refund height out of range"))
        };
        let loan_args = || loan.as_ref().ok_or_else(|| err("loan boxes are needed for this order"));
        match kind {
            "lend" => LendQuote::new(pool, state, amount, slippage_bps, refund_height)
                .map(Quote::Lend)
                .map_err(err),
            "withdraw" => WithdrawQuote::new(pool, state, amount, slippage_bps, refund_height)
                .map(Quote::Withdraw)
                .map_err(err),
            "borrow" => {
                let l = loan_args()?;
                BorrowQuote::new(
                    pool,
                    state,
                    l.snapshot.terms()?,
                    &l.snapshot.dex,
                    l.collateral_nano,
                    amount,
                    refund_i32()?,
                )
                .map(Quote::Borrow)
                .map_err(err)
            }
            "repay" => {
                let l = loan_args()?;
                let position = l.snapshot.position(l.collateral_box_id, l.height)?;
                RepayQuote::new(pool, &position, &l.snapshot.history, 2, refund_i32()?)
                    .map(Quote::Repay)
                    .map_err(err)
            }
            "partial_repay" => {
                let l = loan_args()?;
                let position = l.snapshot.position(l.collateral_box_id, l.height)?;
                PartialRepayQuote::new(pool, &position, &l.snapshot.history, amount, refund_height)
                    .map(Quote::PartialRepay)
                    .map_err(err)
            }
            other => Err(err(format!("unknown order kind {other:?}"))),
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Quote::Lend(_) => "lend",
            Quote::Withdraw(_) => "withdraw",
            Quote::Borrow(_) => "borrow",
            Quote::Repay(_) => "repay",
            Quote::PartialRepay(_) => "partial_repay",
        }
    }

    pub fn json(&self) -> serde_json::Value {
        let mut v = match self {
            Quote::Lend(q) => serde_json::to_value(q),
            Quote::Withdraw(q) => serde_json::to_value(q),
            Quote::Borrow(q) => serde_json::to_value(q),
            Quote::Repay(q) => serde_json::to_value(q),
            Quote::PartialRepay(q) => serde_json::to_value(q),
        }
        .unwrap_or_default();
        v["kind"] = serde_json::json!(self.kind());
        v
    }

    pub fn proxy_box(
        &self,
        pool: &duckpools::Pool,
        user_tree: &str,
    ) -> Result<duckpools::ProxyBox, String> {
        match self {
            Quote::Lend(q) => q.proxy_box(pool, user_tree),
            Quote::Withdraw(q) => q.proxy_box(pool, user_tree),
            Quote::Borrow(q) => q.proxy_box(pool, user_tree),
            Quote::Repay(q) => q.proxy_box(pool, user_tree),
            Quote::PartialRepay(q) => q.proxy_box(pool, user_tree),
        }
        .map_err(err)
    }

    /// The wallet token the order must carry, if any.
    pub fn token_needed(&self, pool: &duckpools::Pool) -> Option<(String, u64)> {
        match self {
            Quote::Lend(q) => pool.currency_id.map(|id| (id.to_string(), q.amount as u64)),
            Quote::Withdraw(q) => Some((pool.lend_token.to_string(), q.lend_tokens as u64)),
            Quote::Borrow(_) => None,
            Quote::Repay(q) => pool.currency_id.map(|id| (id.to_string(), q.repayment as u64)),
            Quote::PartialRepay(q) => pool.currency_id.map(|id| (id.to_string(), q.repayment as u64)),
        }
    }

    pub fn box_value(&self) -> i64 {
        match self {
            Quote::Lend(q) => q.box_value,
            Quote::Withdraw(q) => q.box_value,
            Quote::Borrow(q) => q.box_value,
            Quote::Repay(q) => q.box_value,
            Quote::PartialRepay(q) => q.box_value,
        }
    }
}

/// Build the order transaction from `utxos`, selecting inputs for the
/// proxy box, the app fee and the miner fee, and once more with room for a
/// change box if the first pick would leave dust.
pub fn build_order(
    proxy: &duckpools::ProxyBox,
    utxos: &[Eip12InputBox],
    token: Option<(&str, u64)>,
    change_tree: &str,
    app_fee: Option<(&str, i64)>,
    miner_fee: i64,
    height: i32,
) -> Result<(ergo_tx::Eip12UnsignedTx, Vec<Eip12InputBox>), String> {
    let base = (proxy.value + app_fee.map(|(_, n)| n).unwrap_or(0) + miner_fee) as u64;
    for extra in [0u64, duckpools::MIN_BOX_VALUE as u64] {
        let selected =
            wallet_core::spend::select_for_send(utxos, base + extra, token).map_err(err)?;
        match build_order_tx(
            proxy,
            &selected.boxes,
            change_tree,
            app_fee,
            miner_fee,
            height,
        ) {
            Ok(tx) => return Ok((tx, selected.boxes)),
            Err(e) if extra == 0 && e.to_string().contains("change") => continue,
            Err(e) => return Err(err(e)),
        }
    }
    Err(err("could not select inputs that leave a valid change box"))
}

pub fn outcome_json(kind: &str, proxy_box_id: &str, tx_json: &str) -> Result<String, String> {
    let kind = OrderKind::parse(kind).ok_or_else(|| err(format!("unknown order kind {kind:?}")))?;
    let tx: serde_json::Value = serde_json::from_str(tx_json).map_err(ser_err)?;
    let outcome = classify_loan_spend(kind, proxy_box_id, &tx).map_err(ser_err)?;
    serde_json::to_string(&outcome).map_err(ser_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ERG_POOL: &str =
        include_str!("../../vendor/protocols/duckpools/test/fixtures/pool_erg.json");
    const ERG_PARAM: &str =
        include_str!("../../vendor/protocols/duckpools/test/fixtures/interest_param_erg.json");

    #[test]
    fn state_json_carries_rates_when_the_parameter_box_is_given() {
        let boxes = format!("[{ERG_POOL}]");
        let with = state_json(&boxes, "{}", &format!("[{ERG_PARAM}]")).unwrap();
        let v: serde_json::Value = serde_json::from_str(&with).unwrap();
        assert_eq!(v[0]["borrow_apr_bps"], 107);
        assert_eq!(v[0]["lend_apr_bps"], 0);
        let without = state_json(&boxes, "{}", "").unwrap();
        let v: serde_json::Value = serde_json::from_str(&without).unwrap();
        assert!(v[0]["borrow_apr_bps"].is_null());
    }

    #[test]
    fn an_order_is_built_from_wallet_boxes_with_the_app_fee_and_change() {
        let (pool, state) = state_for(&format!("[{ERG_POOL}]"), "erg").unwrap();
        let q = Quote::new(pool, &state, "lend", 1_000_000_000, 100, 1_900_000, None).unwrap();
        let user = "0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582";
        let proxy = q.proxy_box(pool, user).unwrap();
        let utxo = Eip12InputBox {
            box_id: "11".repeat(32),
            transaction_id: "22".repeat(32),
            index: 0,
            value: "5000000000".into(),
            ergo_tree: user.into(),
            assets: vec![],
            creation_height: 1,
            additional_registers: Default::default(),
            extension: Default::default(),
        };
        let (tx, used) = build_order(
            &proxy,
            &[utxo],
            None,
            user,
            Some(("bb", 1_100_000)),
            1_100_000,
            100,
        )
        .unwrap();
        assert_eq!(used.len(), 1);
        assert_eq!(tx.outputs.len(), 4);
        assert_eq!(tx.outputs[0].value, proxy.value.to_string());
        assert_eq!(q.json()["kind"], "lend");
        assert!(q.json()["min_lend_tokens"].as_i64().unwrap() > 0);
    }

    const FIX: &str = "../../vendor/protocols/duckpools/test/fixtures";

    fn loan_boxes() -> String {
        serde_json::json!({
            "collateral": [serde_json::from_str::<serde_json::Value>(include_str!(concat!("../../vendor/protocols/duckpools/test/fixtures/", "collateral_sigusd.json"))).unwrap()],
            "parents": [serde_json::from_str::<serde_json::Value>(include_str!(concat!("../../vendor/protocols/duckpools/test/fixtures/", "interest_parent_sigusd.json"))).unwrap()],
            "children": serde_json::from_str::<serde_json::Value>(include_str!(concat!("../../vendor/protocols/duckpools/test/fixtures/", "interest_children_sigusd.json"))).unwrap(),
            "dex": [serde_json::from_str::<serde_json::Value>(include_str!(concat!("../../vendor/protocols/duckpools/test/fixtures/", "dex_erg_sigusd.json"))).unwrap()],
            "params": [serde_json::from_str::<serde_json::Value>(include_str!(concat!("../../vendor/protocols/duckpools/test/fixtures/", "pool_param_sigusd.json"))).unwrap()],
        })
        .to_string()
    }

    #[test]
    fn loans_json_lists_the_wallets_loan_and_every_readable_market() {
        let _ = FIX;
        let borrower = "0008cd02c2e577f9bb9cb6b39cb0e38ccba615937fc34a3dcc69f01d012f0d8ec4724c79".to_string();
        let out = loans_json(&loan_boxes(), &[borrower.clone()], 1_866_418).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["positions"].as_array().unwrap().len(), 1);
        assert_eq!(v["positions"][0]["owed"], 23_939);
        assert_eq!(v["positions"][0]["ticker"], "SigUSD");
        let markets = v["markets"].as_array().unwrap();
        let sigusd = markets.iter().find(|m| m["pool"] == "sigusd").unwrap();
        assert_eq!(sigusd["threshold"], 1400);
        assert!(sigusd["erg_value"].as_i64().unwrap() > 0);
        // Pools whose boxes were not given say so rather than vanish.
        assert!(markets.iter().any(|m| m["pool"] == "quacks" && m["error"].is_string()));
        // A parameter box that lists no ERG terms is that pool's error only.
        let mut root: serde_json::Value = serde_json::from_str(&loan_boxes()).unwrap();
        root["params"][0]["additionalRegisters"]["R6"] = serde_json::json!({"serializedValue": "1a00"});
        let out = loans_json(&root.to_string(), &[borrower], 1).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        let sigusd = v["markets"].as_array().unwrap().iter().find(|m| m["pool"] == "sigusd").unwrap();
        assert!(sigusd["error"].as_str().unwrap().contains("ERG"), "{sigusd}");
        assert_eq!(v["positions"].as_array().unwrap().len(), 1, "the loan is still listed");
        // No parameter box at all: the loan is listed, borrowing is not.
        let mut root: serde_json::Value = serde_json::from_str(&loan_boxes()).unwrap();
        root["params"] = serde_json::json!([]);
        let out = loans_json(&root.to_string(), &["0008cd02c2e577f9bb9cb6b39cb0e38ccba615937fc34a3dcc69f01d012f0d8ec4724c79".into()], 1_866_418).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["positions"].as_array().unwrap().len(), 1);
        let sigusd = v["markets"].as_array().unwrap().iter().find(|m| m["pool"] == "sigusd").unwrap();
        assert!(sigusd["error"].as_str().unwrap().contains("parameter box"), "{sigusd}");
        assert!(sigusd["threshold"].is_null());
        let none = loans_json(&loan_boxes(), &["0008cd00".into()], 1).unwrap();
        assert!(serde_json::from_str::<serde_json::Value>(&none).unwrap()["positions"].as_array().unwrap().is_empty());
    }

    #[test]
    fn loan_quotes_come_from_the_snapshot() {
        let pool = duckpools::pool_by_key("sigusd").unwrap();
        let state = PoolState::parse(
            pool,
            &serde_json::from_str(include_str!("../../vendor/protocols/duckpools/test/fixtures/pool_sigusd.json")).unwrap(),
        )
        .unwrap();
        let root: serde_json::Value = serde_json::from_str(&loan_boxes()).unwrap();
        let snap = LoanSnapshot::parse(pool, &root).unwrap();
        let args = |id: &'static str, nano: i64| LoanArgs {
            snapshot: &snap,
            collateral_nano: nano,
            collateral_box_id: id,
            height: 1_866_418,
        };
        let b = Quote::new(pool, &state, "borrow", 500, 0, 1_900_000, Some(args("", 100_000_000_000))).unwrap();
        assert_eq!(b.kind(), "borrow");
        assert!(b.token_needed(pool).is_none());
        assert_eq!(b.box_value(), 100_002_000_000);
        let loan_id = "a532bba7bec01fe0ddbd02c13cdf6284b28dc7df9aa1d0d669e58cd1e2bad0d3";
        let r = Quote::new(pool, &state, "repay", 0, 0, 1_900_000, Some(args(loan_id, 0))).unwrap();
        assert_eq!(r.token_needed(pool).unwrap().0, pool.currency_id.unwrap());
        assert!(r.json()["repayment"].as_i64().unwrap() > 23_939);
        let p = Quote::new(pool, &state, "partial_repay", 5_000, 0, 1_900_000, Some(args(loan_id, 0))).unwrap();
        assert_eq!(p.token_needed(pool).unwrap().1, 5_000);
        assert!(Quote::new(pool, &state, "repay", 0, 0, 1_900_000, Some(args("ff", 0))).is_err());
        assert!(Quote::new(pool, &state, "borrow", 1, 0, 1_900_000, None).is_err());
    }
}
