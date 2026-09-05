//! Duckpools over the FFI: pool state with rates, quotes, and the two
//! transactions the wallet builds itself (posting an order, refunding
//! one). Fills are the bots' business.

use duckpools::{
    build_order_tx, classify_spend, InterestParams, LendQuote, PoolState, WithdrawQuote, POOLS,
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

/// One order's quote and proxy box, either kind.
pub enum Quote {
    Lend(LendQuote),
    Withdraw(WithdrawQuote),
}

impl Quote {
    pub fn new(
        pool: &'static duckpools::Pool,
        state: &PoolState,
        kind: &str,
        amount: i64,
        slippage_bps: i64,
        refund_height: i64,
    ) -> Result<Self, String> {
        match kind {
            "lend" => LendQuote::new(pool, state, amount, slippage_bps, refund_height)
                .map(Quote::Lend)
                .map_err(err),
            "withdraw" => WithdrawQuote::new(pool, state, amount, slippage_bps, refund_height)
                .map(Quote::Withdraw)
                .map_err(err),
            other => Err(err(format!("unknown order kind {other:?}"))),
        }
    }

    pub fn json(&self) -> serde_json::Value {
        match self {
            Quote::Lend(q) => {
                let mut v = serde_json::to_value(q).unwrap_or_default();
                v["kind"] = serde_json::json!("lend");
                v
            }
            Quote::Withdraw(q) => {
                let mut v = serde_json::to_value(q).unwrap_or_default();
                v["kind"] = serde_json::json!("withdraw");
                v
            }
        }
    }

    pub fn proxy_box(
        &self,
        pool: &duckpools::Pool,
        user_tree: &str,
    ) -> Result<duckpools::ProxyBox, String> {
        match self {
            Quote::Lend(q) => q.proxy_box(pool, user_tree).map_err(err),
            Quote::Withdraw(q) => q.proxy_box(pool, user_tree).map_err(err),
        }
    }

    /// The wallet token the order must carry, if any.
    pub fn token_needed(&self, pool: &duckpools::Pool) -> Option<(String, u64)> {
        match self {
            Quote::Lend(q) => pool.currency_id.map(|id| (id.to_string(), q.amount as u64)),
            Quote::Withdraw(q) => Some((pool.lend_token.to_string(), q.lend_tokens as u64)),
        }
    }

    pub fn box_value(&self) -> i64 {
        match self {
            Quote::Lend(q) => q.box_value,
            Quote::Withdraw(q) => q.box_value,
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

pub fn outcome_json(proxy_box_id: &str, tx_json: &str) -> Result<String, String> {
    let tx: serde_json::Value = serde_json::from_str(tx_json).map_err(ser_err)?;
    let outcome = classify_spend(proxy_box_id, &tx).map_err(ser_err)?;
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
        let q = Quote::new(pool, &state, "lend", 1_000_000_000, 100, 1_900_000).unwrap();
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
}
