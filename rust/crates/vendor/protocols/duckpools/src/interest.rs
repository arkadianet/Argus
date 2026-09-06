//! The borrow rate, as the interest contract computes it.
//!
//! Every `updateFrequency` blocks a bot appends the current rate to the
//! child interest box. The rate for a period is
//! `M + a + b·x/D + c·x²/(D·M) + d·x³/(D·M²) + e·x⁴/(D·M³) + f·x⁵/(D·M⁴)`
//! where `x` is utilisation scaled by `M`, the coefficients `a…f` sit in
//! the interest parameter box's R4, and `M = D = 10⁸`. Dividing by `M`
//! gives the growth factor of every borrower's debt over one period.

use crate::state::{PoolState, PoolsError};
use crate::Pool;

/// `InterestDenomination` in the contract.
pub const INTEREST_DENOMINATION: i128 = 100_000_000;
/// `CoefficientDenomination` in the contract.
pub const COEFFICIENT_DENOMINATION: i128 = 100_000_000;
/// `updateFrequency`: blocks between rate updates.
pub const UPDATE_FREQUENCY_BLOCKS: i64 = 120;
/// Two-minute blocks.
pub const BLOCKS_PER_YEAR: i64 = 262_800;

/// The six coefficients of a pool's rate curve.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct InterestParams {
    pub coefficients: [i64; 6],
}

/// A register's bytes from either explorer shape (`{serializedValue}`) or
/// the node's plain hex.
fn register_hex<'a>(v: &'a serde_json::Value, name: &str) -> Option<&'a str> {
    let r = v.get("additionalRegisters")?.get(name)?;
    r.as_str()
        .or_else(|| r.get("serializedValue").and_then(|s| s.as_str()))
}

impl InterestParams {
    /// Read the interest parameter box for `pool`: it must carry the
    /// pool's interest parameter NFT exactly once and six `Long`s in R4.
    pub fn parse(pool: &Pool, v: &serde_json::Value) -> Result<Self, PoolsError> {
        let has_nft = v
            .get("assets")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter().any(|t| {
                    t.get("tokenId")
                        .and_then(|x| x.as_str())
                        .map(|x| x.eq_ignore_ascii_case(pool.interest_param_nft))
                        .unwrap_or(false)
                        && t.get("amount").and_then(|x| x.as_i64()) == Some(1)
                })
            })
            .unwrap_or(false);
        if !has_nft {
            return Err(PoolsError::Serialization(format!(
                "not the {} interest parameter box",
                pool.key
            )));
        }
        let hex_r4 = register_hex(v, "R4")
            .ok_or_else(|| PoolsError::Serialization("interest parameter box has no R4".into()))?;
        let bytes = hex::decode(hex_r4).map_err(|e| PoolsError::Serialization(e.to_string()))?;
        use ergo_lib::ergotree_ir::mir::constant::Constant;
        use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
        let constant = Constant::sigma_parse_bytes(&bytes)
            .map_err(|e| PoolsError::Serialization(format!("R4: {e}")))?;
        let longs = ergo_tx::ergo_box_utils::extract_long_coll(&constant)
            .map_err(|e| PoolsError::Serialization(format!("R4: {e}")))?;
        if longs.len() != 6 {
            return Err(PoolsError::Serialization(format!(
                "R4 holds {} coefficients, expected 6",
                longs.len()
            )));
        }
        let mut coefficients = [0i64; 6];
        coefficients.copy_from_slice(&longs);
        Ok(Self { coefficients })
    }

    /// The contract's `currentRate` for utilisation `x` (scaled by `M`):
    /// the growth factor of debt over one period, scaled by `M`.
    pub fn rate_scaled(&self, util_scaled: i128) -> i128 {
        let [a, b, c, d, e, f] = self.coefficients.map(i128::from);
        let m = INTEREST_DENOMINATION;
        let dd = COEFFICIENT_DENOMINATION;
        let x = util_scaled.clamp(0, m);
        let t1 = a;
        let t2 = (b * x) / dd;
        let t3 = (c * x) / dd * x / m;
        let t4 = (d * x) / dd * x / m * x / m;
        let t5 = (e * x) / dd * x / m * x / m * x / m;
        let t6 = (f * x) / dd * x / m * x / m * x / m * x / m;
        m + t1 + t2 + t3 + t4 + t5 + t6
    }

    /// Simple (non-compounded) yearly rates for a pool at its current
    /// utilisation, in basis points. Lenders earn the borrow rate times
    /// utilisation, less nothing: the service fee is charged on movement,
    /// not on interest.
    pub fn rates(&self, state: &PoolState) -> Rates {
        let total = state.total_assets();
        let util_scaled = if total <= 0 {
            0
        } else {
            INTEREST_DENOMINATION * state.borrowed as i128 / total
        };
        let per_period = self.rate_scaled(util_scaled) - INTEREST_DENOMINATION;
        let periods = (BLOCKS_PER_YEAR / UPDATE_FREQUENCY_BLOCKS) as i128;
        let borrow_apr_bps = (per_period * periods * 10_000 / INTEREST_DENOMINATION) as i64;
        let lend_apr_bps = (borrow_apr_bps as i128 * util_scaled / INTEREST_DENOMINATION) as i64;
        Rates {
            borrow_apr_bps,
            lend_apr_bps,
        }
    }
}

/// Yearly rates in basis points.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct Rates {
    pub borrow_apr_bps: i64,
    pub lend_apr_bps: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::POOLS;

    fn param(key: &str) -> serde_json::Value {
        serde_json::from_str(match key {
            "erg" => include_str!("../test/fixtures/interest_param_erg.json"),
            "sigusd" => include_str!("../test/fixtures/interest_param_sigusd.json"),
            _ => panic!(),
        })
        .unwrap()
    }

    fn pool_state(key: &str) -> PoolState {
        let v: serde_json::Value = serde_json::from_str(match key {
            "erg" => include_str!("../test/fixtures/pool_erg.json"),
            "sigusd" => include_str!("../test/fixtures/pool_sigusd.json"),
            _ => panic!(),
        })
        .unwrap();
        PoolState::parse(crate::pool_by_key(key).unwrap(), &v).unwrap()
    }

    #[test]
    fn the_live_coefficients_parse_and_price_an_idle_pool_at_about_one_percent() {
        let p = InterestParams::parse(&POOLS[0], &param("erg")).unwrap();
        assert_eq!(p.coefficients, [490, 4000, 0, 0, 23000, 9840]);
        assert_eq!(p.rate_scaled(0), INTEREST_DENOMINATION + 490);
        let r = p.rates(&pool_state("erg"));
        // 490 / 1e8 per 120 blocks, 2190 periods a year: 1.07% APR.
        assert_eq!(r.borrow_apr_bps, 107);
        assert_eq!(r.lend_apr_bps, 0, "nothing borrowed, nothing earned");
    }

    #[test]
    fn the_sigusd_pool_pays_lenders_a_share_of_the_borrow_rate() {
        let p = InterestParams::parse(&POOLS[1], &param("sigusd")).unwrap();
        let s = pool_state("sigusd");
        let r = p.rates(&s);
        assert!(r.borrow_apr_bps > 107 && r.borrow_apr_bps < 1000, "{r:?}");
        assert!(
            r.lend_apr_bps > 0 && r.lend_apr_bps < r.borrow_apr_bps,
            "{r:?}"
        );
        // Utilisation 27.47%: lend ≈ borrow × 0.2747.
        assert_eq!(r.lend_apr_bps, r.borrow_apr_bps * 2747 / 10_000);
    }

    #[test]
    fn full_utilisation_is_the_top_of_the_curve() {
        let p = InterestParams {
            coefficients: [490, 4000, 0, 0, 23000, 9840],
        };
        let top = p.rate_scaled(INTEREST_DENOMINATION) - INTEREST_DENOMINATION;
        assert_eq!(top, 490 + 4000 + 23000 + 9840);
        assert_eq!(
            p.rate_scaled(INTEREST_DENOMINATION * 2),
            p.rate_scaled(INTEREST_DENOMINATION),
            "clamped"
        );
        assert!(
            InterestParams::parse(&POOLS[1], &param("erg")).is_err(),
            "another pool's box"
        );
    }
}
