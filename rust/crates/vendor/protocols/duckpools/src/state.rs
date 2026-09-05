//! A pool box, read.

use crate::pools::{pool_by_nft, Pool};
use crate::MAX_BORROW_TOKENS;

#[derive(Debug, thiserror::Error)]
pub enum PoolsError {
    #[error("serialization error: {0}")]
    Serialization(String),
    #[error("box {box_id} is not the {pool} pool box: {why}")]
    NotAPoolBox {
        box_id: String,
        pool: &'static str,
        why: &'static str,
    },
    #[error("no pool matches box {0}")]
    UnknownPool(String),
}

/// What a pool box says right now.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct PoolState {
    pub pool: &'static str,
    pub ticker: &'static str,
    pub decimals: u8,
    pub pool_nft: &'static str,
    pub lend_token: &'static str,
    pub box_id: String,
    pub creation_height: i64,
    /// Units of the pooled asset sitting in the box.
    pub pooled: i64,
    /// Borrow tokens out, which is principal borrowed in asset units.
    pub borrowed: i64,
    /// Lend tokens in circulation, held by lenders.
    pub lend_circulating: i64,
}

impl PoolState {
    /// Read the pool box for `pool`. The script must be the pool's and the
    /// pool NFT must be present: the deployer's token bag also holds NFT
    /// units and must never be mistaken for the pool.
    pub fn parse(pool: &'static Pool, v: &serde_json::Value) -> Result<Self, PoolsError> {
        let box_id = v
            .get("boxId")
            .and_then(|x| x.as_str())
            .ok_or_else(|| PoolsError::Serialization("box is missing boxId".into()))?
            .to_string();
        let tree = v
            .get("ergoTree")
            .and_then(|x| x.as_str())
            .unwrap_or_default();
        if !tree.eq_ignore_ascii_case(pool.ergo_tree) {
            return Err(PoolsError::NotAPoolBox {
                box_id,
                pool: pool.key,
                why: "script differs from the pool contract",
            });
        }
        let amount = |id: &str| -> i64 {
            v.get("assets")
                .and_then(|a| a.as_array())
                .map(|a| {
                    a.iter()
                        .filter(|t| {
                            t.get("tokenId")
                                .and_then(|x| x.as_str())
                                .map(|x| x.eq_ignore_ascii_case(id))
                                .unwrap_or(false)
                        })
                        .filter_map(|t| {
                            t.get("amount").and_then(|x| {
                                x.as_i64()
                                    .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
                            })
                        })
                        .sum()
                })
                .unwrap_or(0)
        };
        if amount(pool.pool_nft) != 1 {
            return Err(PoolsError::NotAPoolBox {
                box_id,
                pool: pool.key,
                why: "the pool NFT is not on it exactly once",
            });
        }
        let lend_held = amount(pool.lend_token);
        let borrow_held = amount(pool.borrow_token);
        if lend_held <= 0
            || borrow_held <= 0
            || lend_held > pool.max_lend_tokens()
            || borrow_held > MAX_BORROW_TOKENS
        {
            return Err(PoolsError::NotAPoolBox {
                box_id,
                pool: pool.key,
                why: "lend or borrow token count is outside the contract's range",
            });
        }
        let value = v
            .get("value")
            .and_then(|x| {
                x.as_i64()
                    .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
            })
            .ok_or_else(|| PoolsError::Serialization("box is missing value".into()))?;
        let pooled = match pool.currency_id {
            None => value,
            Some(id) => amount(id),
        };
        Ok(PoolState {
            pool: pool.key,
            ticker: pool.ticker,
            decimals: pool.decimals,
            pool_nft: pool.pool_nft,
            lend_token: pool.lend_token,
            box_id,
            creation_height: v
                .get("creationHeight")
                .and_then(|x| x.as_i64())
                .unwrap_or(0),
            pooled,
            borrowed: MAX_BORROW_TOKENS - borrow_held,
            lend_circulating: pool.max_lend_tokens() - lend_held,
        })
    }

    /// Everything lenders own: what is in the box plus what is out on loan.
    pub fn total_assets(&self) -> i128 {
        self.pooled as i128 + self.borrowed as i128
    }

    /// Share of lenders' assets currently lent out, in basis points.
    pub fn utilisation_bps(&self) -> i64 {
        let total = self.total_assets();
        if total <= 0 {
            return 0;
        }
        ((self.borrowed as i128 * 10_000) / total) as i64
    }

    /// The asset units `lend_tokens` can be redeemed for now, floored, as
    /// the contract values them: `tokens × (pooled + borrowed) / circulating`.
    pub fn position_value(&self, lend_tokens: i64) -> i64 {
        if self.lend_circulating <= 0 || lend_tokens <= 0 {
            return 0;
        }
        ((lend_tokens as i128 * self.total_assets()) / self.lend_circulating as i128) as i64
    }

    /// Asset units per lend token, as a float for display only.
    pub fn lend_token_price(&self) -> f64 {
        if self.lend_circulating <= 0 {
            return 0.0;
        }
        self.total_assets() as f64 / self.lend_circulating as f64
    }

    /// Lend tokens a deposit of `amount` would mint today, as the contract
    /// computes it: circulating grows in proportion to the assets.
    pub fn tokens_for_deposit(&self, amount: i64) -> i64 {
        let total = self.total_assets();
        if total <= 0 || amount <= 0 {
            return 0;
        }
        let after = (self.lend_circulating as i128 * (total + amount as i128)) / total;
        (after - self.lend_circulating as i128) as i64
    }
}

/// Read every pool box in a list (explorer or node shape). Boxes under an
/// unknown script are skipped; a box under a pool's script that is not
/// that pool's box is an error, because a look-alike must not be trusted.
pub fn parse_pool_boxes(json: &str) -> Result<Vec<PoolState>, PoolsError> {
    let root: serde_json::Value =
        serde_json::from_str(json).map_err(|e| PoolsError::Serialization(e.to_string()))?;
    let items = match root.get("items") {
        Some(v) => v,
        None => &root,
    };
    let items = items
        .as_array()
        .ok_or_else(|| PoolsError::Serialization("expected an array of boxes".into()))?;
    let mut out = Vec::new();
    for it in items {
        let tree = it
            .get("ergoTree")
            .and_then(|x| x.as_str())
            .unwrap_or_default();
        let Some(pool) = crate::POOLS
            .iter()
            .find(|p| p.ergo_tree.eq_ignore_ascii_case(tree))
        else {
            continue;
        };
        // The deployer's bag shares no script with a pool, so a script hit
        // without the NFT is a real anomaly.
        match PoolState::parse(pool, it) {
            Ok(s) => out.push(s),
            Err(PoolsError::NotAPoolBox { why, .. }) if why.contains("NFT") => {
                let id = it.get("boxId").and_then(|x| x.as_str()).unwrap_or("?");
                let _ = pool_by_nft(id);
                continue;
            }
            Err(e) => return Err(e),
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::POOLS;

    fn fixture(key: &str) -> serde_json::Value {
        let json = match key {
            "erg" => include_str!("../test/fixtures/pool_erg.json"),
            "sigusd" => include_str!("../test/fixtures/pool_sigusd.json"),
            "quacks" => include_str!("../test/fixtures/pool_quacks.json"),
            "sigrsv" => include_str!("../test/fixtures/pool_sigrsv.json"),
            "rsn" => include_str!("../test/fixtures/pool_rsn.json"),
            "rsada" => include_str!("../test/fixtures/pool_rsada.json"),
            "spf" => include_str!("../test/fixtures/pool_spf.json"),
            "rsbtc" => include_str!("../test/fixtures/pool_rsbtc.json"),
            _ => panic!("no fixture for {key}"),
        };
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn every_mainnet_pool_box_parses_as_its_pool() {
        for pool in POOLS {
            let s = PoolState::parse(pool, &fixture(pool.key))
                .unwrap_or_else(|e| panic!("{}: {e}", pool.key));
            assert_eq!(s.pool, pool.key);
            assert!(s.pooled > 0, "{}: nothing pooled?", pool.key);
            assert!(s.lend_circulating > 0, "{}: no lenders?", pool.key);
            assert!(s.borrowed >= 0);
        }
    }

    #[test]
    fn the_erg_pool_numbers_match_the_captured_box() {
        let s = PoolState::parse(&POOLS[0], &fixture("erg")).unwrap();
        assert_eq!(s.pooled, 15_055_088_456_407);
        assert_eq!(s.borrowed, 0, "nobody had borrowed ERG on 2026-09-05");
        assert_eq!(
            s.lend_circulating,
            9_000_000_001_000_000 - 8_992_729_440_272_047
        );
        assert_eq!(s.utilisation_bps(), 0);
        // About 2.07 nanoERG per lend token.
        assert!(
            (s.lend_token_price() - 2.0707).abs() < 0.001,
            "{}",
            s.lend_token_price()
        );
        // A whole ERG of lend tokens is worth a whole ERG back, within floor.
        let tokens = s.tokens_for_deposit(1_000_000_000);
        let back = s.position_value(tokens);
        assert!(back <= 1_000_000_000 && back > 999_999_990, "{back}");
    }

    #[test]
    fn the_sigusd_pool_has_real_borrowing() {
        let s = PoolState::parse(&POOLS[1], &fixture("sigusd")).unwrap();
        assert_eq!(s.pooled, 1_467_024, "14,670.24 SigUSD in cents");
        assert_eq!(s.borrowed, 555_799, "5,557.99 SigUSD out on loan");
        // Token pools cap lend tokens ten above the maximum, not a million.
        assert_eq!(
            s.lend_circulating,
            9_000_000_000_000_010 - 8_999_999_998_813_195
        );
        assert!(
            (s.lend_token_price() - 1.7047).abs() < 0.001,
            "{}",
            s.lend_token_price()
        );
        assert_eq!(s.utilisation_bps(), 2747, "floored");
    }

    #[test]
    fn a_box_under_the_script_without_the_nft_is_refused() {
        let mut v = fixture("erg");
        v["assets"] = serde_json::json!([]);
        let err = PoolState::parse(&POOLS[0], &v).unwrap_err().to_string();
        assert!(err.contains("NFT"), "{err}");
        let mut wrong = fixture("erg");
        wrong["ergoTree"] = serde_json::json!("0008cd00");
        assert!(PoolState::parse(&POOLS[0], &wrong).is_err());
    }

    #[test]
    fn a_mixed_list_yields_every_pool_and_skips_strangers() {
        let mut all: Vec<serde_json::Value> = POOLS.iter().map(|p| fixture(p.key)).collect();
        all.push(serde_json::json!({"boxId":"x","ergoTree":"0008cd00","value":1,"assets":[]}));
        let states = parse_pool_boxes(&serde_json::json!(all).to_string()).unwrap();
        assert_eq!(states.len(), POOLS.len());
        assert_eq!(
            states.iter().map(|s| s.pool).collect::<Vec<_>>(),
            POOLS.iter().map(|p| p.key).collect::<Vec<_>>()
        );
    }
}
