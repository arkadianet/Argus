//! On-chain token and LP-token prices for the token pricer, computed by
//! `wallet-amm` from the Spectrum pool set the app already holds.
//!
//! The pool set is the one `amm_pools` returns (and the app keeps on disk
//! for a quick first price), so pricing adds no node request of its own.
//! Only the arithmetic and the selection rules moved here from Dart: the
//! deepest trustworthy pool, one hop for tokens without an ERG pool, and
//! LP shares.

use std::collections::HashSet;

use serde::Deserialize;
use wallet_amm::contract::{FEE_DENOM, LP_EMISSION};
use wallet_amm::{price_book, Pool, PricingOptions};

use crate::error::ArgusError;

/// One pool as `amm_pools` serialises it.
#[derive(Deserialize)]
struct PoolJson {
    pool_id: String,
    pool_type: String,
    box_id: String,
    erg_reserves: Option<u64>,
    token_x: Option<TokenJson>,
    token_y: TokenJson,
    lp_token_id: String,
    lp_circulating: u64,
    fee_num: i64,
    fee_denom: i64,
}

#[derive(Deserialize)]
struct TokenJson {
    token_id: String,
    amount: u64,
}

#[derive(Deserialize)]
struct Options {
    min_depth_nano: u64,
    #[serde(default)]
    trusted_token_ids: Vec<String>,
}

/// The pool, or `None` when it fails `wallet-amm`'s checks. The vendored
/// discovery behind `amm_pools` assumes a fee of 997 when R4 is missing,
/// so that one check cannot be made from this shape; the arbitrage scan
/// reads boxes itself and makes it.
fn to_pool(p: PoolJson) -> Option<Pool> {
    if p.fee_denom != FEE_DENOM as i64 {
        return None;
    }
    let lp_locked = LP_EMISSION.checked_sub(p.lp_circulating)?;
    let fee = Some(p.fee_num);
    match p.pool_type.as_str() {
        "N2T" => Pool::n2t(
            p.pool_id,
            p.box_id,
            p.erg_reserves?,
            p.token_y.token_id,
            p.token_y.amount,
            p.lp_token_id,
            lp_locked,
            fee,
        )
        .ok(),
        "T2T" => {
            let x = p.token_x?;
            Pool::t2t(
                p.pool_id,
                p.box_id,
                p.erg_reserves.unwrap_or(0),
                x.token_id,
                x.amount,
                p.token_y.token_id,
                p.token_y.amount,
                p.lp_token_id,
                lp_locked,
                fee,
            )
            .ok()
        }
        _ => None,
    }
}

fn price_json(pools_json: &str, options_json: &str) -> Result<String, String> {
    let raw: Vec<serde_json::Value> = serde_json::from_str(pools_json)
        .map_err(|e| ArgusError::SerializationError(format!("pools: {e}")).to_json_string())?;
    let opts: Options = serde_json::from_str(options_json)
        .map_err(|e| ArgusError::SerializationError(format!("options: {e}")).to_json_string())?;
    let total = raw.len();
    // A pool the app cannot read is skipped, never fatal: one odd box must
    // not blank every price in the wallet.
    let pools: Vec<Pool> = raw
        .into_iter()
        .filter_map(|v| serde_json::from_value::<PoolJson>(v).ok())
        .filter_map(to_pool)
        .collect();
    let book = price_book(
        &pools,
        &PricingOptions {
            min_depth_nano: opts.min_depth_nano,
            trusted: opts.trusted_token_ids.into_iter().collect::<HashSet<_>>(),
        },
    );
    let mut out = serde_json::to_value(&book)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    out["pools_used"] = serde_json::json!(pools.len());
    out["pools_skipped"] = serde_json::json!(total - pools.len());
    Ok(out.to_string())
}

/// ERG prices for every token and LP token a pool set supports.
///
/// `pools_json` is the `pools` array of `amm_pools`. `options_json` is
/// `{"min_depth_nano": u64, "trusted_token_ids": [id…]}`: pools whose ERG
/// side (or a T2T pool's ERG-equivalent side) is shallower than the depth
/// are ignored, and only prices resting entirely on trusted tokens are
/// marked `trusted`.
///
/// Answers `{"tokens": {id: quote}, "lp_tokens": {id: quote}, …}` with
/// prices in nanoERG per base unit.
#[flutter_rust_bridge::frb]
pub async fn pricing_pool_prices(
    pools_json: String,
    options_json: String,
) -> Result<String, String> {
    price_json(&pools_json, &options_json)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIGUSD: &str = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";

    fn n2t(id: &str, erg: u64, token: &str, amount: u64, lp_circulating: u64) -> serde_json::Value {
        serde_json::json!({
            "pool_id": id, "pool_type": "N2T", "box_id": format!("box-{id}"),
            "erg_reserves": erg,
            "token_y": {"token_id": token, "amount": amount},
            "lp_token_id": format!("lp-{id}"), "lp_circulating": lp_circulating,
            "fee_num": 997, "fee_denom": 1000,
        })
    }

    fn options(trusted: &[&str]) -> String {
        serde_json::json!({"min_depth_nano": 50_000_000_000u64, "trusted_token_ids": trusted})
            .to_string()
    }

    /// The JSON `amm_pools` produces goes in; prices in nanoERG per unit,
    /// LP values and trust flags come out.
    #[test]
    fn prices_the_pool_set_the_app_holds() {
        let pools = serde_json::json!([
            n2t("sig", 1_000_000_000_000, SIGUSD, 30_000, 5_000),
            n2t("thin", 10_000_000_000, "abc", 10, 1_000),
            {"pool_id": "t", "pool_type": "T2T", "box_id": "bt", "erg_reserves": 1_000_000,
             "token_x": {"token_id": "tok", "amount": 2_000_000},
             "token_y": {"token_id": SIGUSD, "amount": 20_000},
             "lp_token_id": "lp-t", "lp_circulating": 7, "fee_num": 997, "fee_denom": 1000},
            {"unexpected": true},
            {"pool_id": "odd", "pool_type": "N2T", "box_id": "bo", "erg_reserves": 9_000_000_000_000u64,
             "token_y": {"token_id": "x", "amount": 1}, "lp_token_id": "l", "lp_circulating": 1,
             "fee_num": 997, "fee_denom": 997},
        ]);
        let out: serde_json::Value =
            serde_json::from_str(&price_json(&pools.to_string(), &options(&[SIGUSD])).unwrap())
                .unwrap();
        let sig = &out["tokens"][SIGUSD];
        assert!((sig["nano_erg_per_unit"].as_f64().unwrap() - 1e12 / 30_000.0).abs() < 1e-3);
        assert_eq!(sig["route"], "direct");
        assert_eq!(sig["pool_id"], "sig");
        assert_eq!(sig["trusted"], true);
        assert!(out["tokens"].get("abc").is_none(), "below the depth floor");
        let tok = &out["tokens"]["tok"];
        assert_eq!(tok["route"], "hop");
        assert_eq!(tok["via_token_id"], SIGUSD);
        assert_eq!(tok["trusted"], false, "tok is not on the trusted list");
        let lp = &out["lp_tokens"]["lp-sig"];
        assert!((lp["nano_erg_per_unit"].as_f64().unwrap() - 2e12 / 5_000.0).abs() < 1e-3);
        assert_eq!(lp["x_token_id"], serde_json::Value::Null);
        assert_eq!(out["pools_used"], 3);
        assert_eq!(
            out["pools_skipped"], 2,
            "a malformed entry and a non-standard fee denominator"
        );
    }

    #[test]
    fn malformed_input_is_a_structured_error() {
        let err = price_json("not json", &options(&[])).unwrap_err();
        assert!(err.contains("SERIALIZATION_ERROR"), "{err}");
        let err = price_json("[]", "{}").unwrap_err();
        assert!(err.contains("options"), "{err}");
    }
}
