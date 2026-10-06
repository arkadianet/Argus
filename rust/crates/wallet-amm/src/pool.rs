//! A Spectrum pool as the math needs it, with the checks that keep junk
//! boxes at the pool address out of prices and routes.
//!
//! Anyone can pay a box to the pool contract, so not everything discovery
//! returns is a pool. A box is only accepted when it could actually be
//! traded against: the token layout of its kind, a fee numerator in R4
//! (the contract reads it with `.get`), a fee no better than free, two
//! different assets on its sides, and for N2T more ERG than the contract's
//! storage floor.

use serde::Serialize;

use crate::contract::{FEE_DENOM, LP_EMISSION, N2T_MIN_VALUE_EXCLUSIVE};

/// One side of a pool: native ERG or a token id.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Asset {
    Erg,
    Token(String),
}

impl Asset {
    pub fn token(id: impl Into<String>) -> Self {
        Asset::Token(id.into())
    }

    /// The token id, or `None` for ERG: the encoding the app uses.
    pub fn token_id(&self) -> Option<&str> {
        match self {
            Asset::Erg => None,
            Asset::Token(id) => Some(id),
        }
    }

    pub fn is_erg(&self) -> bool {
        matches!(self, Asset::Erg)
    }

    pub fn from_token_id(id: Option<&str>) -> Self {
        match id {
            None => Asset::Erg,
            Some(id) => Asset::Token(id.to_string()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum PoolKind {
    N2T,
    T2T,
}

/// Why a box at the pool address is not used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PoolError {
    Layout(usize),
    MissingFee,
    Fee(i64),
    EmptyReserve,
    SameAsset,
    BelowStorageFloor(u64),
    LpLocked,
}

impl std::fmt::Display for PoolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PoolError::Layout(n) => write!(f, "{n} tokens is not a pool layout"),
            PoolError::MissingFee => write!(f, "no fee numerator in R4"),
            PoolError::Fee(v) => write!(f, "fee numerator {v} outside 1..={FEE_DENOM}"),
            PoolError::EmptyReserve => write!(f, "a reserve is empty"),
            PoolError::SameAsset => write!(f, "both sides are the same asset"),
            PoolError::BelowStorageFloor(v) => {
                write!(f, "{v} nanoERG is not above the storage floor")
            }
            PoolError::LpLocked => write!(f, "LP held by the pool exceeds the emission"),
        }
    }
}

/// A tradable pool. For N2T, `x` is ERG and `x_amount` is the box value.
#[derive(Debug, Clone, PartialEq)]
pub struct Pool {
    pub pool_id: String,
    pub box_id: String,
    pub kind: PoolKind,
    /// nanoERG in the pool box.
    pub value: u64,
    pub x: Asset,
    pub x_amount: u64,
    pub y: String,
    pub y_amount: u64,
    pub lp_token_id: String,
    /// LP supply as the contract counts it: emission minus what the pool
    /// box holds.
    pub lp_supply: u64,
    pub fee_num: u32,
}

fn check_fee(fee_num: Option<i64>) -> Result<u32, PoolError> {
    let v = fee_num.ok_or(PoolError::MissingFee)?;
    // A numerator above the denominator would pay traders out of the
    // liquidity; such a pool is not a market price.
    if v <= 0 || v > FEE_DENOM as i64 {
        return Err(PoolError::Fee(v));
    }
    Ok(v as u32)
}

fn lp_supply(lp_locked: u64) -> Result<u64, PoolError> {
    LP_EMISSION
        .checked_sub(lp_locked)
        .ok_or(PoolError::LpLocked)
}

impl Pool {
    #[allow(clippy::too_many_arguments)]
    pub fn n2t(
        pool_id: impl Into<String>,
        box_id: impl Into<String>,
        value: u64,
        y: impl Into<String>,
        y_amount: u64,
        lp_token_id: impl Into<String>,
        lp_locked: u64,
        fee_num: Option<i64>,
    ) -> Result<Pool, PoolError> {
        let fee_num = check_fee(fee_num)?;
        if y_amount == 0 || value == 0 {
            return Err(PoolError::EmptyReserve);
        }
        if value <= N2T_MIN_VALUE_EXCLUSIVE {
            return Err(PoolError::BelowStorageFloor(value));
        }
        Ok(Pool {
            pool_id: pool_id.into(),
            box_id: box_id.into(),
            kind: PoolKind::N2T,
            value,
            x: Asset::Erg,
            x_amount: value,
            y: y.into(),
            y_amount,
            lp_token_id: lp_token_id.into(),
            lp_supply: lp_supply(lp_locked)?,
            fee_num,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn t2t(
        pool_id: impl Into<String>,
        box_id: impl Into<String>,
        value: u64,
        x: impl Into<String>,
        x_amount: u64,
        y: impl Into<String>,
        y_amount: u64,
        lp_token_id: impl Into<String>,
        lp_locked: u64,
        fee_num: Option<i64>,
    ) -> Result<Pool, PoolError> {
        let fee_num = check_fee(fee_num)?;
        let (x, y) = (x.into(), y.into());
        if x == y {
            return Err(PoolError::SameAsset);
        }
        if x_amount == 0 || y_amount == 0 {
            return Err(PoolError::EmptyReserve);
        }
        Ok(Pool {
            pool_id: pool_id.into(),
            box_id: box_id.into(),
            kind: PoolKind::T2T,
            value,
            x: Asset::Token(x),
            x_amount,
            y,
            y_amount,
            lp_token_id: lp_token_id.into(),
            lp_supply: lp_supply(lp_locked)?,
            fee_num,
        })
    }

    /// A pool from the parts of its box: `tokens` in box order and the
    /// decoded `R4: Int`, if any. N2T boxes carry `[NFT, LP, Y]` and T2T
    /// boxes `[NFT, LP, X, Y]`; the contracts allow nothing else.
    pub fn from_box(
        box_id: impl Into<String>,
        value: u64,
        tokens: &[(String, u64)],
        r4_fee_num: Option<i64>,
    ) -> Result<Pool, PoolError> {
        match tokens {
            [(nft, _), (lp, locked), (y, y_amount)] => {
                if y == nft || y == lp {
                    return Err(PoolError::SameAsset);
                }
                Pool::n2t(nft, box_id, value, y, *y_amount, lp, *locked, r4_fee_num)
            }
            [(nft, _), (lp, locked), (x, x_amount), (y, y_amount)] => {
                if [x, y].iter().any(|t| *t == nft || *t == lp) {
                    return Err(PoolError::SameAsset);
                }
                Pool::t2t(
                    nft, box_id, value, x, *x_amount, y, *y_amount, lp, *locked, r4_fee_num,
                )
            }
            other => Err(PoolError::Layout(other.len())),
        }
    }

    pub fn y_asset(&self) -> Asset {
        Asset::Token(self.y.clone())
    }

    /// Both sides, X first.
    pub fn sides(&self) -> [(Asset, u64); 2] {
        [
            (self.x.clone(), self.x_amount),
            (self.y_asset(), self.y_amount),
        ]
    }

    /// What this pool holds of `asset`, when it trades it.
    pub fn reserve(&self, asset: &Asset) -> Option<u64> {
        self.sides()
            .into_iter()
            .find(|(a, _)| a == asset)
            .map(|(_, r)| r)
    }

    /// The other side of `asset`, when this pool trades it.
    pub fn counterpart(&self, asset: &Asset) -> Option<Asset> {
        let [(x, _), (y, _)] = self.sides();
        if &x == asset {
            Some(y)
        } else if &y == asset {
            Some(x)
        } else {
            None
        }
    }

    pub fn trades(&self, asset: &Asset) -> bool {
        self.reserve(asset).is_some()
    }

    /// Most ERG a single swap can take out of this pool: N2T only.
    pub fn erg_out_cap(&self) -> Option<u64> {
        match self.kind {
            PoolKind::N2T => Some(self.value.saturating_sub(N2T_MIN_VALUE_EXCLUSIVE + 1)),
            PoolKind::T2T => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(id: &str, n: u64) -> (String, u64) {
        (id.to_string(), n)
    }

    #[test]
    fn layouts_decide_the_kind() {
        let n2t = Pool::from_box(
            "b",
            50_000_000_000,
            &[t("nft", 1), t("lp", LP_EMISSION - 5_000), t("tok", 9)],
            Some(997),
        )
        .unwrap();
        assert_eq!(n2t.kind, PoolKind::N2T);
        assert_eq!(n2t.x, Asset::Erg);
        assert_eq!(n2t.x_amount, 50_000_000_000);
        assert_eq!(n2t.lp_supply, 5_000);
        assert_eq!(n2t.pool_id, "nft");

        let t2t = Pool::from_box(
            "b",
            1_000_000,
            &[t("nft", 1), t("lp", 7), t("a", 3), t("b", 4)],
            Some(995),
        )
        .unwrap();
        assert_eq!(t2t.kind, PoolKind::T2T);
        assert_eq!(t2t.x, Asset::token("a"));
        assert_eq!(t2t.reserve(&Asset::token("b")), Some(4));
        assert_eq!(
            t2t.reserve(&Asset::Erg),
            None,
            "a T2T pool's ERG is not a reserve"
        );

        assert_eq!(
            Pool::from_box("b", 1, &[t("nft", 1), t("lp", 1)], Some(997)),
            Err(PoolError::Layout(2))
        );
    }

    /// The contract reads R4 with `.get`; a box without it can never be
    /// spent, so it must not price anything. The vendored and ergo-pricing
    /// parsers both assume 997 instead.
    #[test]
    fn a_box_without_a_fee_is_not_a_pool() {
        let r = Pool::from_box(
            "b",
            50_000_000_000,
            &[t("nft", 1), t("lp", 1), t("tok", 9)],
            None,
        );
        assert_eq!(r, Err(PoolError::MissingFee));
    }

    #[test]
    fn fees_outside_the_contract_range_are_refused() {
        let tokens = [t("nft", 1), t("lp", 1), t("tok", 9)];
        assert_eq!(
            Pool::from_box("b", 50_000_000_000, &tokens, Some(0)),
            Err(PoolError::Fee(0))
        );
        assert_eq!(
            Pool::from_box("b", 50_000_000_000, &tokens, Some(1001)),
            Err(PoolError::Fee(1001))
        );
        assert!(
            Pool::from_box("b", 50_000_000_000, &tokens, Some(1000)).is_ok(),
            "a fee-free pool is valid"
        );
    }

    #[test]
    fn an_n2t_pool_at_the_storage_floor_cannot_trade() {
        let tokens = [t("nft", 1), t("lp", 1), t("tok", 9)];
        assert_eq!(
            Pool::from_box("b", N2T_MIN_VALUE_EXCLUSIVE, &tokens, Some(997)),
            Err(PoolError::BelowStorageFloor(N2T_MIN_VALUE_EXCLUSIVE))
        );
        let p = Pool::from_box("b", N2T_MIN_VALUE_EXCLUSIVE + 5, &tokens, Some(997)).unwrap();
        assert_eq!(p.erg_out_cap(), Some(4));
    }

    #[test]
    fn one_token_on_both_sides_is_refused() {
        assert_eq!(
            Pool::from_box(
                "b",
                1,
                &[t("nft", 1), t("lp", 1), t("a", 3), t("a", 4)],
                Some(997)
            ),
            Err(PoolError::SameAsset)
        );
        assert_eq!(
            Pool::from_box(
                "b",
                50_000_000_000,
                &[t("nft", 1), t("lp", 1), t("lp", 4)],
                Some(997)
            ),
            Err(PoolError::SameAsset)
        );
    }

    #[test]
    fn counterparts() {
        let p = Pool::n2t("p", "b", 50_000_000_000, "tok", 9, "lp", 1, Some(997)).unwrap();
        assert_eq!(p.counterpart(&Asset::Erg), Some(Asset::token("tok")));
        assert_eq!(p.counterpart(&Asset::token("tok")), Some(Asset::Erg));
        assert_eq!(p.counterpart(&Asset::token("other")), None);
    }
}
