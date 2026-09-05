//! Loans: what a collateral box owes today, what ERG collateral is worth
//! to the contract, and the borrow, repay and partial-repay orders.
//!
//! A loan lives in a *collateral box* under the pool's collateral
//! contract: the ERG put up, the pool's borrow tokens recording the
//! principal, and where in the interest history the loan began. The
//! contract compounds every rate the interest boxes recorded since then
//! (`collateral.md`, `totalOwed`), prices the collateral through the
//! Spectrum ERG/asset pool with two percent slippage and the DEX fee
//! (`collateralValue`), and lets anyone liquidate once that value falls
//! to `owed × threshold / 1000`, or after the forced-liquidation height.
//!
//! Token pools take ERG collateral and price it in their asset; the ERG
//! pool takes tokens (SigUSD, SigRSV, RSN, rsADA) and prices them in ERG
//! through the same Spectrum pools read the other way round. Every
//! amount below is in the *pool's* asset units unless it says otherwise.

use std::collections::{BTreeMap, HashMap};

use ergo_lib::ergotree_ir::mir::constant::{Constant, TryExtractInto};
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_tx::Eip12Asset;

use crate::encode;
use crate::interest::INTEREST_DENOMINATION;
use crate::orders::ProxyBox;
use crate::state::{PoolState, PoolsError};
use crate::{Pool, MIN_BOX_VALUE, TX_FEE};

/// `MaximumNetworkFee` in the token pools' collateral contract: taken off
/// ERG collateral before it is priced.
pub const MAX_NETWORK_FEE: i64 = 5_000_000;
/// `MaximumNetworkFee` in the ERG pool's collateral contract: taken off a
/// token collateral's ERG value.
pub const ERG_POOL_MAX_NETWORK_FEE: i64 = 4_000_000;
/// `MinLoanValue` in the ERG pool contract: the least ERG loan, nanoERG.
pub const MIN_ERG_LOAN: i64 = 50_000_000;
/// The ERG pool's collateral box carries this much ERG, from the proxy.
pub const ERG_POOL_COLLATERAL_BOX_VALUE: i64 = 4_000_000;
/// `Slippage` in the collateral contract, percent.
pub const PRICE_SLIPPAGE_PERCENT: i128 = 2;
/// `DexLpTaxDenomination`: the DEX fee in R4 is out of this.
pub const DEX_FEE_DENOMINATION: i128 = 1000;
/// `LiquidationThresholdDenom` and `PenaltyDenom`.
pub const THRESHOLD_DENOMINATION: i128 = 1000;
/// `MinLoanValue` in the pool contract: the least ERG collateral, nanoERG.
pub const MIN_COLLATERAL: i64 = 50_000_000;
/// The borrow proxy asks the bot to set the forced liquidation this many
/// blocks ahead, at most (`validForcedLiquidation`).
pub const FORCED_LIQUIDATION_BLOCKS: i64 = 65_520;

fn err(msg: impl Into<String>) -> PoolsError {
    PoolsError::Serialization(msg.into())
}

fn register_hex<'a>(v: &'a serde_json::Value, name: &str) -> Option<&'a str> {
    let r = v.get("additionalRegisters")?.get(name)?;
    r.as_str()
        .or_else(|| r.get("serializedValue").and_then(|s| s.as_str()))
}

fn constant(v: &serde_json::Value, name: &str) -> Result<Constant, PoolsError> {
    let hex_r = register_hex(v, name).ok_or_else(|| err(format!("box has no {name}")))?;
    let bytes = hex::decode(hex_r).map_err(|e| err(format!("{name}: {e}")))?;
    Constant::sigma_parse_bytes(&bytes).map_err(|e| err(format!("{name}: {e}")))
}

fn reg_longs(v: &serde_json::Value, name: &str) -> Result<Vec<i64>, PoolsError> {
    ergo_tx::ergo_box_utils::extract_long_coll(&constant(v, name)?)
        .map_err(|e| err(format!("{name}: {e}")))
}

fn reg_int(v: &serde_json::Value, name: &str) -> Result<i32, PoolsError> {
    constant(v, name)?
        .try_extract_into::<i32>()
        .map_err(|e| err(format!("{name}: {e:?}")))
}

fn reg_bytes(v: &serde_json::Value, name: &str) -> Result<Vec<u8>, PoolsError> {
    constant(v, name)?
        .try_extract_into::<Vec<u8>>()
        .map_err(|e| err(format!("{name}: {e:?}")))
}

fn reg_int_pair(v: &serde_json::Value, name: &str) -> Result<(i32, i32), PoolsError> {
    constant(v, name)?
        .try_extract_into::<(i32, i32)>()
        .map_err(|e| err(format!("{name}: {e:?}")))
}

fn reg_long_pair(v: &serde_json::Value, name: &str) -> Result<(i64, i64), PoolsError> {
    constant(v, name)?
        .try_extract_into::<(i64, i64)>()
        .map_err(|e| err(format!("{name}: {e:?}")))
}

fn reg_byte_colls(v: &serde_json::Value, name: &str) -> Result<Vec<Vec<u8>>, PoolsError> {
    constant(v, name)?
        .try_extract_into::<Vec<Vec<u8>>>()
        .map_err(|e| err(format!("{name}: {e:?}")))
}

fn box_id(v: &serde_json::Value) -> Result<String, PoolsError> {
    Ok(v.get("boxId")
        .and_then(|x| x.as_str())
        .ok_or_else(|| err("box is missing boxId"))?
        .to_string())
}

fn box_value(v: &serde_json::Value) -> Result<i64, PoolsError> {
    v.get("value")
        .and_then(|x| {
            x.as_i64()
                .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
        })
        .ok_or_else(|| err("box is missing value"))
}

fn assets(v: &serde_json::Value) -> Vec<(String, i64)> {
    v.get("assets")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|t| {
                    let id = t.get("tokenId")?.as_str()?.to_ascii_lowercase();
                    let n = t.get("amount").and_then(|x| {
                        x.as_i64()
                            .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
                    })?;
                    Some((id, n))
                })
                .collect()
        })
        .unwrap_or_default()
}

fn has_nft(v: &serde_json::Value, nft: &str) -> bool {
    assets(v)
        .iter()
        .any(|(id, n)| id.eq_ignore_ascii_case(nft) && *n == 1)
}

/// The pool's parameter box: per collateral asset, its liquidation
/// threshold, penalty and the Spectrum pool that prices it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct LoanParams {
    pub thresholds: Vec<i64>,
    /// `R5`: the collateral token per price source; a placeholder byte
    /// where the collateral is ERG.
    pub asset_ids: Vec<String>,
    pub dex_nfts: Vec<String>,
    pub penalties: Vec<i64>,
}

impl LoanParams {
    pub fn parse(pool: &Pool, v: &serde_json::Value) -> Result<Self, PoolsError> {
        if !has_nft(v, pool.param_nft) {
            return Err(err(format!("not the {} parameter box", pool.key)));
        }
        let thresholds = reg_longs(v, "R4")?;
        let asset_ids: Vec<String> = reg_byte_colls(v, "R5")?
            .into_iter()
            .map(hex::encode)
            .collect();
        let dex_nfts: Vec<String> = reg_byte_colls(v, "R6")?
            .into_iter()
            .map(hex::encode)
            .collect();
        let penalties = reg_longs(v, "R7")?;
        // The live SigUSD box lists one price source but two thresholds;
        // the contract indexes by price source, so that is what must fit.
        if thresholds.len() < dex_nfts.len() || penalties.len() < dex_nfts.len() {
            return Err(err("parameter box lists more price sources than thresholds"));
        }
        Ok(Self {
            thresholds,
            asset_ids,
            dex_nfts,
            penalties,
        })
    }

    /// `(price source, threshold, penalty)` for a token collateral, as the
    /// ERG pool contract looks it up: by the price source whose R5 entry
    /// names the token.
    pub fn for_asset(&self, asset_id: &str) -> Option<(String, i64, i64)> {
        let i = self
            .asset_ids
            .iter()
            .position(|a| a.eq_ignore_ascii_case(asset_id))?;
        let nft = self.dex_nfts.get(i)?.clone();
        Some((nft, self.thresholds[i], self.penalties[i]))
    }

    /// `(threshold, penalty)` for the collateral priced by `dex_nft`, as
    /// the pool contract looks it up (`indexOfParams`).
    pub fn for_dex(&self, dex_nft: &str) -> Option<(i64, i64)> {
        let i = self
            .dex_nfts
            .iter()
            .position(|n| n.eq_ignore_ascii_case(dex_nft))?;
        Some((self.thresholds[i], self.penalties[i]))
    }

    /// `(threshold, penalty)` for ERG collateral in `pool`.
    pub fn for_erg(&self, pool: &Pool) -> Result<(i64, i64), PoolsError> {
        let nft = pool
            .erg_dex_nft
            .ok_or_else(|| err(format!("the {} pool takes no ERG collateral", pool.key)))?;
        self.for_dex(nft)
            .ok_or_else(|| err(format!("the {} parameter box lists no ERG collateral", pool.key)))
    }
}

/// The Spectrum ERG/asset pool the contract prices collateral through.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct DexPrice {
    pub nft: String,
    pub erg_reserve: i64,
    pub token_reserve: i64,
    /// `R4`: the fee kept by liquidity providers, out of 1000.
    pub fee: i64,
}

impl DexPrice {
    /// Read a Spectrum N2T pool box: NFT, LP token, asset in that order.
    pub fn parse(v: &serde_json::Value) -> Result<Self, PoolsError> {
        let a = assets(v);
        if a.len() < 3 || a[0].1 != 1 {
            return Err(err("not a Spectrum ERG pool box"));
        }
        Ok(Self {
            nft: a[0].0.clone(),
            erg_reserve: box_value(v)?,
            token_reserve: a[2].1,
            fee: i64::from(reg_int(v, "R4")?),
        })
    }

    /// `collateralValue`: what `collateral_nano` of ERG buys in the asset
    /// after the maximum network fee, two percent slippage and the DEX fee.
    pub fn collateral_value(&self, collateral_nano: i64) -> i64 {
        let input = i128::from(collateral_nano) - i128::from(MAX_NETWORK_FEE);
        if input <= 0 {
            return 0;
        }
        let erg = i128::from(self.erg_reserve);
        let fee = i128::from(self.fee);
        let n = i128::from(self.token_reserve) * input * fee;
        let d = (erg + erg * PRICE_SLIPPAGE_PERCENT / 100) * DEX_FEE_DENOMINATION + input * fee;
        (n / d) as i64
    }

    /// The least ERG whose [`Self::collateral_value`] reaches `value`, by
    /// bisection; the contract's own arithmetic decides, so callers add
    /// their own margin.
    pub fn collateral_for_value(&self, value: i64) -> i64 {
        bisect(value, |c| self.collateral_value(c))
    }

    /// What `amount` of the pool's token sells for in nanoERG after two
    /// percent slippage and the DEX fee, before the network fee the ERG
    /// pool's collateral contract also takes off.
    pub fn token_value_raw(&self, amount: i64) -> i64 {
        if amount <= 0 {
            return 0;
        }
        let input = i128::from(amount);
        let tok = i128::from(self.token_reserve);
        let fee = i128::from(self.fee);
        let n = i128::from(self.erg_reserve) * input * fee;
        let d = (tok + tok * PRICE_SLIPPAGE_PERCENT / 100) * DEX_FEE_DENOMINATION + input * fee;
        (n / d) as i64
    }

    /// `collateralValue` in the ERG pool's contracts: what `amount` of the
    /// token counts for as collateral, nanoERG.
    pub fn token_collateral_value(&self, amount: i64) -> i64 {
        (self.token_value_raw(amount) - ERG_POOL_MAX_NETWORK_FEE).max(0)
    }

    /// The fewest tokens whose [`Self::token_collateral_value`] reaches
    /// `nano`.
    pub fn tokens_for_value(&self, nano: i64) -> i64 {
        bisect(nano, |a| self.token_collateral_value(a))
    }
}

fn bisect(target: i64, f: impl Fn(i64) -> i64) -> i64 {
    if target <= 0 {
        return 0;
    }
    let (mut lo, mut hi) = (0i64, i64::MAX / 4);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if f(mid) >= target {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    lo
}

/// The pool's interest history: the parent box's compounded rate per
/// child, and every child box's rate per period, by child index.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct InterestHistory {
    pub parent_rates: Vec<i64>,
    pub children: BTreeMap<i32, Vec<i64>>,
}

impl InterestHistory {
    /// `parent` is the pool's parent interest box; `children` every live
    /// child interest box (each carries the child NFT once and its index
    /// in R6).
    pub fn parse(
        pool: &Pool,
        parent: &serde_json::Value,
        children: &[serde_json::Value],
    ) -> Result<Self, PoolsError> {
        if !has_nft(parent, pool.parent_nft) {
            return Err(err(format!("not the {} parent interest box", pool.key)));
        }
        let parent_rates = reg_longs(parent, "R4")?;
        let mut map = BTreeMap::new();
        for c in children {
            if !has_nft(c, pool.child_nft) {
                continue;
            }
            map.insert(reg_int(c, "R6")?, reg_longs(c, "R4")?);
        }
        if !map.contains_key(&(parent_rates.len() as i32)) {
            return Err(err(format!(
                "the {} head child interest box (index {}) is missing",
                pool.key,
                parent_rates.len()
            )));
        }
        Ok(Self {
            parent_rates,
            children: map,
        })
    }

    /// The index the head child carries: where a new loan begins.
    pub fn head_index(&self) -> i32 {
        self.parent_rates.len() as i32
    }

    /// The rate the last period charged, scaled by `M`.
    pub fn latest_rate(&self) -> i64 {
        self.children
            .get(&self.head_index())
            .and_then(|r| r.last().copied())
            .or_else(|| self.parent_rates.last().copied())
            .unwrap_or(INTEREST_DENOMINATION as i64)
    }

    /// `compoundedInterest` for a loan that began at `(parent_index,
    /// child_index)`, scaled by `M`, folded exactly as the contract does.
    pub fn compounded(&self, parent_index: i32, child_index: i32) -> Result<i128, PoolsError> {
        let m = INTEREST_DENOMINATION;
        let fold = |z: i128, rates: &[i64]| rates.iter().fold(z, |z, r| z * i128::from(*r) / m);
        let base = self
            .children
            .get(&parent_index)
            .ok_or_else(|| err(format!("child interest box {parent_index} is missing")))?;
        let start = (child_index.max(0) as usize).min(base.len());
        let mut z = fold(m, &base[start..]);
        let live = self.head_index();
        if live != parent_index {
            let head = &self.children[&live];
            z = fold(z, head);
            if live != parent_index + 1 {
                let from = (parent_index + 1).max(0) as usize;
                z = fold(z, &self.parent_rates[from.min(self.parent_rates.len())..]);
            }
        }
        Ok(z)
    }

    /// `totalOwed` on a loan of `loan` units begun at the given indexes.
    pub fn owed(&self, loan: i64, parent_index: i32, child_index: i32) -> Result<i64, PoolsError> {
        let z = self.compounded(parent_index, child_index)?;
        Ok((1 + i128::from(loan) * z / INTEREST_DENOMINATION) as i64)
    }
}

/// A collateral box, read.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CollateralBox {
    pub box_id: String,
    /// The box's ERG: the collateral itself in a token pool, the
    /// contract's fixed carry in the ERG pool.
    pub collateral_nano: i64,
    /// The collateral token, or none when the collateral is ERG.
    pub collateral_asset: Option<String>,
    /// Units of the collateral: nanoERG, or the token's units.
    pub collateral_amount: i64,
    /// Principal, in the pool's borrow tokens (asset units).
    pub loan: i64,
    pub borrower_tree: String,
    pub parent_index: i32,
    pub child_index: i32,
    pub threshold: i64,
    pub penalty: i64,
    pub dex_nft: String,
    pub user_pk: String,
    pub forced_liquidation_height: i64,
    pub liquidation_buffer_height: i64,
}

impl CollateralBox {
    pub fn parse(pool: &Pool, v: &serde_json::Value) -> Result<Self, PoolsError> {
        let tree = v
            .get("ergoTree")
            .and_then(|x| x.as_str())
            .unwrap_or_default();
        let expected = ergo_tx::address_to_ergo_tree(pool.collateral_address)
            .map_err(|e| err(e.to_string()))?;
        if !tree.eq_ignore_ascii_case(&expected) {
            return Err(err(format!("not a {} collateral box", pool.key)));
        }
        let a = assets(v);
        let value = box_value(v)?;
        let (collateral_asset, collateral_amount, loan) = if pool.is_erg() {
            match (a.first(), a.get(1)) {
                (Some((c, n)), Some((id, loan))) if id.eq_ignore_ascii_case(pool.borrow_token) => {
                    (Some(c.clone()), *n, *loan)
                }
                _ => return Err(err("collateral box carries no collateral and borrow tokens")),
            }
        } else {
            match a.first() {
                Some((id, n)) if id.eq_ignore_ascii_case(pool.borrow_token) => (None, value, *n),
                _ => return Err(err("collateral box carries no borrow tokens")),
            }
        };
        let (parent_index, child_index) = reg_int_pair(v, "R5")?;
        let (threshold, penalty) = reg_long_pair(v, "R6")?;
        let (forced, buffer) = reg_long_pair(v, "R9")?;
        let pk_hex = register_hex(v, "R8").unwrap_or_default();
        let user_pk = pk_hex
            .strip_prefix("07")
            .filter(|k| k.len() == 66)
            .ok_or_else(|| err("R8 is not a public key"))?
            .to_ascii_lowercase();
        Ok(Self {
            box_id: box_id(v)?,
            collateral_nano: value,
            collateral_asset,
            collateral_amount,
            loan,
            borrower_tree: hex::encode(reg_bytes(v, "R4")?),
            parent_index,
            child_index,
            threshold,
            penalty,
            dex_nft: hex::encode(reg_bytes(v, "R7")?),
            user_pk,
            forced_liquidation_height: forced,
            liquidation_buffer_height: buffer,
        })
    }
}

/// A loan, valued.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct LoanPosition {
    pub pool: &'static str,
    pub box_id: String,
    pub borrower_tree: String,
    pub collateral_nano: i64,
    pub collateral_asset: Option<String>,
    pub collateral_amount: i64,
    pub loan: i64,
    /// What repaying today costs, in asset units.
    pub owed: i64,
    /// What the contract thinks the collateral is worth, in asset units.
    pub collateral_value: i64,
    pub threshold: i64,
    pub penalty: i64,
    /// `collateral_value / (owed × threshold / 1000)` in basis points:
    /// 10 000 is the liquidation line.
    pub health_bps: i64,
    /// The collateral value at which liquidation opens.
    pub liquidation_value: i64,
    pub liquidatable: bool,
    pub forced_liquidation_height: i64,
    pub parent_index: i32,
    pub child_index: i32,
}

impl LoanPosition {
    pub fn value(
        pool: &'static Pool,
        c: &CollateralBox,
        history: &InterestHistory,
        dex: &DexPrice,
        height: i64,
    ) -> Result<Self, PoolsError> {
        if !dex.nft.eq_ignore_ascii_case(&c.dex_nft) {
            return Err(err("price box does not match the loan's collateral"));
        }
        let owed = history.owed(c.loan, c.parent_index, c.child_index)?;
        let collateral_value = match c.collateral_asset {
            None => dex.collateral_value(c.collateral_nano),
            Some(_) => dex.token_collateral_value(c.collateral_amount),
        };
        let liquidation_value =
            (i128::from(owed) * i128::from(c.threshold) / THRESHOLD_DENOMINATION) as i64;
        let health_bps = if liquidation_value <= 0 {
            i64::MAX
        } else {
            (i128::from(collateral_value) * 10_000 / i128::from(liquidation_value)) as i64
        };
        let liquidatable = (collateral_value <= liquidation_value
            && height >= c.liquidation_buffer_height)
            || height > c.forced_liquidation_height;
        Ok(Self {
            pool: pool.key,
            box_id: c.box_id.clone(),
            borrower_tree: c.borrower_tree.clone(),
            collateral_nano: c.collateral_nano,
            collateral_asset: c.collateral_asset.clone(),
            collateral_amount: c.collateral_amount,
            loan: c.loan,
            owed,
            collateral_value,
            threshold: c.threshold,
            penalty: c.penalty,
            health_bps,
            liquidation_value,
            liquidatable,
            forced_liquidation_height: c.forced_liquidation_height,
            parent_index: c.parent_index,
            child_index: c.child_index,
        })
    }
}

/// Every loan under `pool` whose borrower is one of `wallet_trees`, from
/// the collateral boxes given (any shape; non-loans are skipped), priced
/// by whichever of `dexes` the loan names.
pub fn positions(
    pool: &'static Pool,
    collateral_boxes: &[serde_json::Value],
    history: &InterestHistory,
    dexes: &[DexPrice],
    wallet_trees: &[String],
    height: i64,
) -> Result<Vec<LoanPosition>, PoolsError> {
    let mut out = Vec::new();
    for v in collateral_boxes {
        let c = match CollateralBox::parse(pool, v) {
            Ok(c) => c,
            Err(_) => continue,
        };
        if !wallet_trees
            .iter()
            .any(|t| t.eq_ignore_ascii_case(&c.borrower_tree))
        {
            continue;
        }
        let dex = dexes
            .iter()
            .find(|d| d.nft.eq_ignore_ascii_case(&c.dex_nft))
            .ok_or_else(|| err(format!("no price box for loan {}", c.box_id)))?;
        out.push(LoanPosition::value(pool, &c, history, dex, height)?);
    }
    Ok(out)
}

/// A borrow order, before it is posted.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct BorrowQuote {
    pub pool: &'static str,
    /// The collateral token, or none for ERG.
    pub collateral_asset: Option<String>,
    /// Units of collateral: nanoERG, or the token's units.
    pub collateral_amount: i64,
    /// ERG the proxy locks as collateral (token pools), or the fixed
    /// carry of an ERG pool collateral box.
    pub collateral_nano: i64,
    pub loan: i64,
    /// What the contract will value the collateral at.
    pub collateral_value: i64,
    /// The most the collateral could borrow at the threshold.
    pub max_loan: i64,
    pub threshold: i64,
    pub penalty: i64,
    /// Health at open, basis points.
    pub health_bps: i64,
    /// nanoERG the proxy carries: collateral, the bot's box, the fill fee.
    pub box_value: i64,
    pub refund_height: i32,
    pub dex_nft: String,
}

impl BorrowQuote {
    /// `collateral_asset` is none for ERG (token pools) or the token the
    /// ERG pool is asked to lend against; `collateral_amount` is in that
    /// collateral's units.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        pool: &'static Pool,
        state: &PoolState,
        params: &LoanParams,
        dex: &DexPrice,
        collateral_asset: Option<&str>,
        collateral_amount: i64,
        loan: i64,
        refund_height: i32,
    ) -> Result<Self, PoolsError> {
        if loan <= 0 {
            return Err(err("loan must be positive"));
        }
        if loan > state.pooled {
            return Err(err("the pool does not hold that much"));
        }
        match (pool.is_erg(), collateral_asset) {
            (true, Some(asset)) => {
                let (dex_nft, threshold, penalty) = params
                    .for_asset(asset)
                    .ok_or_else(|| err("the ERG pool does not take that token as collateral"))?;
                if !dex.nft.eq_ignore_ascii_case(&dex_nft) {
                    return Err(err("price box is not this collateral's market"));
                }
                if loan < MIN_ERG_LOAN {
                    return Err(err(format!("the ERG pool lends at least {MIN_ERG_LOAN} nanoERG")));
                }
                if collateral_amount <= 0 {
                    return Err(err("collateral must be positive"));
                }
                let collateral_value = dex.token_collateral_value(collateral_amount);
                let max_loan = (i128::from(collateral_value) * THRESHOLD_DENOMINATION
                    / i128::from(threshold)) as i64;
                // The ERG pool contract accepts the line itself.
                if loan > max_loan {
                    return Err(err(format!("collateral only supports a loan up to {max_loan}")));
                }
                let liquidation_value =
                    (i128::from(loan) * i128::from(threshold) / THRESHOLD_DENOMINATION) as i64;
                let health_bps = (i128::from(collateral_value) * 10_000
                    / i128::from(liquidation_value.max(1))) as i64;
                Ok(Self {
                    pool: pool.key,
                    collateral_asset: Some(asset.to_ascii_lowercase()),
                    collateral_amount,
                    collateral_nano: ERG_POOL_COLLATERAL_BOX_VALUE,
                    loan,
                    collateral_value,
                    max_loan,
                    threshold,
                    penalty,
                    health_bps,
                    // The collateral box's carry, the bot's fee, the fill fee.
                    box_value: ERG_POOL_COLLATERAL_BOX_VALUE + MIN_BOX_VALUE + TX_FEE,
                    refund_height,
                    dex_nft,
                })
            }
            (true, None) => Err(err("the ERG pool lends against tokens; pick a collateral")),
            (false, Some(_)) => Err(err(format!("the {} pool takes only ERG as collateral", pool.ticker))),
            (false, None) => {
                let collateral_nano = collateral_amount;
                let dex_nft = pool.erg_dex_nft.ok_or_else(|| err("no price source"))?;
                if !dex.nft.eq_ignore_ascii_case(dex_nft) {
                    return Err(err("price box is not this pool's ERG market"));
                }
                let (threshold, penalty) = params.for_erg(pool)?;
                if collateral_nano < MIN_COLLATERAL + 2 * MIN_BOX_VALUE {
                    return Err(err(format!(
                        "collateral must be at least {} nanoERG",
                        MIN_COLLATERAL + 2 * MIN_BOX_VALUE
                    )));
                }
                let collateral_value = dex.collateral_value(collateral_nano);
                let max_loan = (i128::from(collateral_value) * THRESHOLD_DENOMINATION
                    / i128::from(threshold)) as i64;
                // The token pool contracts demand strictly more collateral
                // than the line.
                if loan >= max_loan {
                    return Err(err(format!("collateral only supports a loan below {max_loan}")));
                }
                let liquidation_value = (i128::from(loan + 1) * i128::from(threshold)
                    / THRESHOLD_DENOMINATION) as i64;
                let health_bps = (i128::from(collateral_value) * 10_000
                    / i128::from(liquidation_value.max(1))) as i64;
                Ok(Self {
                    pool: pool.key,
                    collateral_asset: None,
                    collateral_amount: collateral_nano,
                    collateral_nano,
                    loan,
                    collateral_value,
                    max_loan,
                    threshold,
                    penalty,
                    health_bps,
                    box_value: collateral_nano + MIN_BOX_VALUE + TX_FEE,
                    refund_height,
                    dex_nft: dex_nft.to_string(),
                })
            }
        }
    }

    /// The proxy box (`proxyBorrow.md`): R4 user tree, R5 loan, R6 refund
    /// height, R7 (threshold, penalty) as the parameter box has them, R8
    /// the price NFT, R9 the user's key so they can take it back any time.
    pub fn proxy_box(&self, pool: &Pool, user_tree_hex: &str) -> Result<ProxyBox, PoolsError> {
        let user = hex::decode(user_tree_hex).map_err(|e| err(e.to_string()))?;
        let pk = encode::p2pk_key(user_tree_hex)
            .ok_or_else(|| err("borrow orders need a single-key (P2PK) address"))?;
        let mut registers = HashMap::new();
        registers.insert("R4".into(), encode::coll_byte(&user)?);
        registers.insert("R5".into(), encode::long(self.loan)?);
        registers.insert("R6".into(), encode::int(self.refund_height)?);
        registers.insert("R7".into(), encode::long_pair(self.threshold, self.penalty)?);
        registers.insert(
            "R8".into(),
            encode::coll_byte(&hex::decode(&self.dex_nft).map_err(|e| err(e.to_string()))?)?,
        );
        registers.insert("R9".into(), encode::group_element(&pk)?);
        let assets = match &self.collateral_asset {
            Some(id) => vec![Eip12Asset {
                token_id: id.clone(),
                amount: self.collateral_amount.to_string(),
            }],
            None => Vec::new(),
        };
        Ok(ProxyBox {
            ergo_tree: ergo_tx::address_to_ergo_tree(pool.borrow_proxy_address)
                .map_err(|e| err(e.to_string()))?,
            value: self.box_value,
            assets,
            registers,
        })
    }
}

/// A full repayment, before it is posted. Whatever the proxy carries
/// above what is owed at fill time stays with the protocol, so the
/// margin covers only the periods the order may wait.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct RepayQuote {
    pub pool: &'static str,
    pub collateral_box_id: String,
    pub owed_now: i64,
    /// Asset units the proxy carries: as tokens for a token pool, as the
    /// box's ERG for the ERG pool.
    pub repayment: i64,
    /// The collateral returned on fill: its ERG (token pools) or the
    /// token and amount (ERG pool).
    pub collateral_nano: i64,
    pub collateral_asset: Option<String>,
    pub collateral_amount: i64,
    pub box_value: i64,
    pub refund_height: i32,
}

impl RepayQuote {
    /// `margin_periods` extra 120-block periods of interest at the latest
    /// rate, so the order still covers the debt when a bot gets to it.
    pub fn new(
        pool: &'static Pool,
        position: &LoanPosition,
        history: &InterestHistory,
        margin_periods: u32,
        refund_height: i32,
    ) -> Result<Self, PoolsError> {
        let m = INTEREST_DENOMINATION;
        let rate = i128::from(history.latest_rate());
        let mut owed = i128::from(position.owed);
        for _ in 0..margin_periods {
            owed = owed * rate / m + 1;
        }
        let (repayment, box_value) = if pool.is_erg() {
            // The fill's repayment box is the proxy less the borrower's
            // box and the fee, plus the collateral box's own ERG, and must
            // reach `owed + fee` (`validRepaymentValue`).
            let need = (owed as i64 + TX_FEE + MIN_BOX_VALUE + TX_FEE - position.collateral_nano)
                .max(2 * MIN_BOX_VALUE);
            (need, need)
        } else {
            // The collateral contract wants strictly more than owed.
            ((owed + 1) as i64, MIN_BOX_VALUE + 2 * TX_FEE)
        };
        Ok(Self {
            pool: pool.key,
            collateral_box_id: position.box_id.clone(),
            owed_now: position.owed,
            repayment,
            collateral_nano: position.collateral_nano,
            collateral_asset: position.collateral_asset.clone(),
            collateral_amount: position.collateral_amount,
            box_value,
            refund_height,
        })
    }

    /// The proxy box (`repay.md`, `proxyRepay.md`): R4 what the borrower
    /// must get back (the collateral's ERG, or the token amount), R5
    /// borrower tree, R6 refund height, R7 the collateral box id, and for
    /// the ERG pool R8 the collateral token. A token pool's repayment
    /// rides as tokens; the ERG pool's is the box's ERG.
    pub fn proxy_box(&self, pool: &Pool, user_tree_hex: &str) -> Result<ProxyBox, PoolsError> {
        let user = hex::decode(user_tree_hex).map_err(|e| err(e.to_string()))?;
        let mut registers = HashMap::new();
        registers.insert("R5".into(), encode::coll_byte(&user)?);
        registers.insert("R6".into(), encode::int(self.refund_height)?);
        registers.insert("R7".into(), encode::box_id_register(&self.collateral_box_id)?);
        let assets = match (&self.collateral_asset, pool.currency_id) {
            (Some(asset), _) => {
                registers.insert("R4".into(), encode::long(self.collateral_amount)?);
                registers.insert(
                    "R8".into(),
                    encode::coll_byte(&hex::decode(asset).map_err(|e| err(e.to_string()))?)?,
                );
                Vec::new()
            }
            (None, Some(currency)) => {
                registers.insert("R4".into(), encode::long(self.collateral_nano)?);
                vec![Eip12Asset {
                    token_id: currency.to_string(),
                    amount: self.repayment.to_string(),
                }]
            }
            (None, None) => return Err(err("an ERG pool loan has token collateral")),
        };
        Ok(ProxyBox {
            ergo_tree: ergo_tx::address_to_ergo_tree(pool.repay_proxy_address)
                .map_err(|e| err(e.to_string()))?,
            value: self.box_value,
            assets,
            registers,
        })
    }
}

/// A partial repayment: the principal falls by `repayment / compounded`,
/// the collateral stays.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct PartialRepayQuote {
    pub pool: &'static str,
    pub collateral_box_id: String,
    pub repayment: i64,
    /// Borrow tokens left on the loan (`R5`).
    pub final_borrow_tokens: i64,
    pub owed_after: i64,
    pub box_value: i64,
    pub refund_height: i64,
}

impl PartialRepayQuote {
    pub fn new(
        pool: &'static Pool,
        position: &LoanPosition,
        history: &InterestHistory,
        repayment: i64,
        refund_height: i64,
    ) -> Result<Self, PoolsError> {
        if repayment <= 0 {
            return Err(err("repayment must be positive"));
        }
        if repayment >= position.owed {
            return Err(err("that repays the whole loan; use a full repayment"));
        }
        let m = INTEREST_DENOMINATION;
        let z = history.compounded(position.parent_index, position.child_index)?;
        // `expectedBorrowTokens` in the collateral contract; the successor
        // must hold at least this many.
        let expected = i128::from(position.loan) - i128::from(repayment) * m / z;
        if expected <= 0 {
            return Err(err("repayment too large"));
        }
        let owed_after = (1 + expected * z / m) as i64;
        if pool.is_erg() && owed_after < MIN_ERG_LOAN {
            return Err(err(format!(
                "the ERG pool keeps loans at {MIN_ERG_LOAN} nanoERG or more; repay in full instead"
            )));
        }
        Ok(Self {
            pool: pool.key,
            collateral_box_id: position.box_id.clone(),
            repayment,
            final_borrow_tokens: expected as i64,
            owed_after,
            // A token pool's repayment rides as tokens; the ERG pool's is
            // the box's ERG less the fee and the repayment box's minimum.
            box_value: if pool.is_erg() {
                repayment + MIN_BOX_VALUE + TX_FEE
            } else {
                MIN_BOX_VALUE + 2 * TX_FEE
            },
            refund_height,
        })
    }

    /// The proxy box (`partialRepay.md`): R4 collateral box id, R5 the
    /// borrow tokens to leave, R6 user tree, R7 refund height (Long).
    pub fn proxy_box(&self, pool: &Pool, user_tree_hex: &str) -> Result<ProxyBox, PoolsError> {
        let user = hex::decode(user_tree_hex).map_err(|e| err(e.to_string()))?;
        let mut registers = HashMap::new();
        registers.insert("R4".into(), encode::box_id_register(&self.collateral_box_id)?);
        registers.insert("R5".into(), encode::long(self.final_borrow_tokens)?);
        registers.insert("R6".into(), encode::coll_byte(&user)?);
        registers.insert("R7".into(), encode::long(self.refund_height)?);
        let assets = match pool.currency_id {
            Some(currency) => vec![Eip12Asset {
                token_id: currency.to_string(),
                amount: self.repayment.to_string(),
            }],
            None => Vec::new(),
        };
        Ok(ProxyBox {
            ergo_tree: ergo_tx::address_to_ergo_tree(pool.partial_repay_proxy_address)
                .map_err(|e| err(e.to_string()))?,
            value: self.box_value,
            assets,
            registers,
        })
    }
}

/// What kind of order a proxy box is, for reading its fate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderKind {
    Lend,
    Withdraw,
    Borrow,
    Repay,
    PartialRepay,
}

impl OrderKind {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "lend" => Self::Lend,
            "withdraw" => Self::Withdraw,
            "borrow" => Self::Borrow,
            "repay" => Self::Repay,
            "partial_repay" => Self::PartialRepay,
            _ => return None,
        })
    }
}

/// Classify the transaction that spent a loan-side proxy box. Borrow and
/// repay fills mark the user's box with `R4 = proxy id`, as refunds do,
/// so the two are told apart by the transaction's shape: a fill has the
/// pool, the collateral and the user's box, a refund only the user's box
/// and the fee. A partial repay marks nothing: a fill rebuilds the
/// collateral box, a refund pays the user.
pub fn classify_loan_spend(
    kind: OrderKind,
    proxy_box_id: &str,
    tx: &serde_json::Value,
) -> Result<crate::OrderOutcome, PoolsError> {
    use crate::OrderOutcome;
    let marker = encode::box_id_register(proxy_box_id)?;
    let outputs = tx
        .get("outputs")
        .and_then(|o| o.as_array())
        .ok_or_else(|| err("transaction has no outputs"))?;
    let marked = outputs
        .iter()
        .find(|o| register_hex(o, "R4") == Some(marker.as_str()));
    let eip12 = |o: &serde_json::Value| -> (i64, Vec<Eip12Asset>) {
        (
            box_value(o).unwrap_or(0),
            assets(o)
                .into_iter()
                .map(|(id, n)| Eip12Asset {
                    token_id: id,
                    amount: n.to_string(),
                })
                .collect(),
        )
    };
    let fill_shaped = outputs.len() >= 3;
    Ok(match kind {
        OrderKind::Lend | OrderKind::Withdraw => return crate::classify_spend(proxy_box_id, tx),
        OrderKind::Borrow => match marked {
            Some(o) => {
                let (value, a) = eip12(o);
                if fill_shaped {
                    OrderOutcome::Filled { value, assets: a }
                } else {
                    OrderOutcome::Refunded { value, assets: a }
                }
            }
            // The borrower's own signature can spend it any way at all.
            None => OrderOutcome::Unknown,
        },
        OrderKind::Repay => match marked {
            Some(o) if fill_shaped => {
                let (value, a) = eip12(o);
                OrderOutcome::Filled { value, assets: a }
            }
            _ if !fill_shaped => match outputs.first() {
                Some(o) => {
                    let (value, a) = eip12(o);
                    OrderOutcome::Refunded { value, assets: a }
                }
                None => OrderOutcome::Unknown,
            },
            _ => OrderOutcome::Unknown,
        },
        OrderKind::PartialRepay => match outputs.first() {
            Some(o) if fill_shaped => {
                let (value, a) = eip12(o);
                OrderOutcome::Filled { value, assets: a }
            }
            Some(o) => {
                let (value, a) = eip12(o);
                OrderOutcome::Refunded { value, assets: a }
            }
            None => OrderOutcome::Unknown,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{pool_by_key, OrderOutcome};

    fn fixture(name: &str) -> serde_json::Value {
        serde_json::from_str(match name {
            "collateral" => include_str!("../test/fixtures/collateral_sigusd.json"),
            "param" => include_str!("../test/fixtures/pool_param_sigusd.json"),
            "param_quacks" => include_str!("../test/fixtures/pool_param_quacks.json"),
            "dex" => include_str!("../test/fixtures/dex_erg_sigusd.json"),
            "parent" => include_str!("../test/fixtures/interest_parent_sigusd.json"),
            "children" => include_str!("../test/fixtures/interest_children_sigusd.json"),
            "pool" => include_str!("../test/fixtures/pool_sigusd.json"),
            _ => panic!("{name}"),
        })
        .unwrap()
    }

    fn sigusd() -> &'static Pool {
        pool_by_key("sigusd").unwrap()
    }

    fn history() -> InterestHistory {
        let children: Vec<serde_json::Value> = fixture("children").as_array().unwrap().clone();
        InterestHistory::parse(sigusd(), &fixture("parent"), &children).unwrap()
    }

    fn position() -> LoanPosition {
        let c = CollateralBox::parse(sigusd(), &fixture("collateral")).unwrap();
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        LoanPosition::value(sigusd(), &c, &history(), &dex, 1_866_418).unwrap()
    }

    const BORROWER: &str =
        "0008cd02c2e577f9bb9cb6b39cb0e38ccba615937fc34a3dcc69f01d012f0d8ec4724c79";

    #[test]
    fn the_parameter_box_names_erg_collateral_at_140_percent() {
        let p = LoanParams::parse(sigusd(), &fixture("param")).unwrap();
        assert_eq!(p.for_erg(sigusd()).unwrap(), (1400, 400));
        let q = LoanParams::parse(pool_by_key("quacks").unwrap(), &fixture("param_quacks")).unwrap();
        assert_eq!(q.for_erg(pool_by_key("quacks").unwrap()).unwrap(), (1400, 300));
        assert!(LoanParams::parse(sigusd(), &fixture("param_quacks")).is_err());
    }

    #[test]
    fn a_live_loan_is_read_and_valued_as_the_contract_would() {
        // Captured 2026-09-05 at height 1 866 418 together with the
        // interest and price boxes; the numbers below were recomputed
        // from the contract's formulas independently.
        let c = CollateralBox::parse(sigusd(), &fixture("collateral")).unwrap();
        assert_eq!(c.collateral_nano, 2_500_000_000_000);
        assert_eq!(c.loan, 23_899);
        assert_eq!((c.parent_index, c.child_index), (14, 118));
        assert_eq!((c.threshold, c.penalty), (1400, 400));
        assert_eq!(c.borrower_tree, BORROWER);
        assert_eq!(c.forced_liquidation_height, 1_920_515);
        let h = history();
        assert_eq!(h.head_index(), 14);
        assert_eq!(h.compounded(14, 118).unwrap(), 100_166_756);
        let p = position();
        assert_eq!(p.owed, 23_939);
        assert_eq!(p.collateral_value, 62_316);
        assert_eq!(p.liquidation_value, 33_514);
        assert_eq!(p.health_bps, 62_316 * 10_000 / 33_514);
        assert!(!p.liquidatable);
    }

    #[test]
    fn an_older_loan_compounds_through_the_head_child_and_the_parent() {
        let h = history();
        // A loan opened at child 12 folds: child 12 from its index, then
        // the head child, then parent entries 13.. ; strictly more than a
        // loan opened at the head.
        let old = h.compounded(12, 0).unwrap();
        let new = h.compounded(14, 118).unwrap();
        assert!(old > new, "{old} vs {new}");
        assert!(h.compounded(3, 0).unwrap() > old);
        assert!(h.compounded(99, 0).is_err());
    }

    #[test]
    fn positions_only_lists_the_wallets_loans() {
        let boxes = vec![fixture("collateral"), fixture("param")];
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        let mine = positions(sigusd(), &boxes, &history(), &[dex.clone()], &[BORROWER.into()], 1).unwrap();
        assert_eq!(mine.len(), 1);
        let none = positions(sigusd(), &boxes, &history(), &[dex], &["0008cd00".into()], 1).unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn a_borrow_quote_prices_collateral_and_builds_the_proxy() {
        let state = PoolState::parse(sigusd(), &fixture("pool")).unwrap();
        let params = LoanParams::parse(sigusd(), &fixture("param")).unwrap();
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        // 100 ERG at ~0.25 SigUSD/ERG after slippage and fees: about
        // 25 SigUSD of collateral, so a 10 SigUSD loan opens at ~178%.
        let q = BorrowQuote::new(sigusd(), &state, &params, &dex, None, 100_000_000_000, 1_000, 1_000_000).unwrap();
        assert!(q.collateral_value > 2_400 && q.collateral_value < 2_600, "{q:?}");
        assert_eq!(q.max_loan, q.collateral_value * 1000 / 1400);
        assert!(q.health_bps > 10_000);
        assert_eq!(q.box_value, 100_000_000_000 + 2_000_000);
        assert!(BorrowQuote::new(sigusd(), &state, &params, &dex, None, 100_000_000_000, q.max_loan, 1).is_err());
        assert!(BorrowQuote::new(sigusd(), &state, &params, &dex, None, 10_000_000, 1, 1).is_err());
        assert!(BorrowQuote::new(sigusd(), &state, &params, &dex, Some("03faf2"), 10_000_000, 1, 1).is_err());
        let b = q.proxy_box(sigusd(), BORROWER).unwrap();
        assert_eq!(b.registers["R4"], format!("0e24{BORROWER}"));
        assert_eq!(b.registers["R5"], encode::long(1_000).unwrap());
        assert_eq!(b.registers["R6"], encode::int(1_000_000).unwrap());
        assert_eq!(b.registers["R7"], encode::long_pair(1400, 400).unwrap());
        assert_eq!(b.registers["R8"], format!("0e20{}", sigusd().erg_dex_nft.unwrap()));
        assert_eq!(b.registers["R9"], format!("07{}", &BORROWER[6..]));
        assert!(b.assets.is_empty());
        assert!(dex.collateral_value(dex.collateral_for_value(50_000)) >= 50_000);
        assert!(dex.collateral_value(dex.collateral_for_value(50_000) - 1) < 50_000);
    }

    #[test]
    fn a_repay_quote_covers_two_more_periods_and_a_partial_keeps_the_ratio() {
        let p = position();
        let h = history();
        let r = RepayQuote::new(sigusd(), &p, &h, 2, 1_000_000).unwrap();
        assert!(r.repayment > p.owed && r.repayment <= p.owed + 5, "{r:?}");
        let b = r.proxy_box(sigusd(), BORROWER).unwrap();
        assert_eq!(b.assets[0].token_id, sigusd().currency_id.unwrap());
        assert_eq!(b.assets[0].amount, r.repayment.to_string());
        assert_eq!(b.registers["R4"], encode::long(2_500_000_000_000).unwrap());
        assert_eq!(b.registers["R7"], format!("0e20{}", p.box_id));
        assert_eq!(b.value, 3_000_000);

        let part = PartialRepayQuote::new(sigusd(), &p, &h, 10_000, 1_000_000).unwrap();
        // 100 SigUSD off a 239.39 debt leaves about 139.4 owed.
        assert!(part.final_borrow_tokens < p.loan);
        assert!(part.owed_after > 13_900 && part.owed_after < 13_950, "{part:?}");
        let b = part.proxy_box(sigusd(), BORROWER).unwrap();
        assert_eq!(b.registers["R5"], encode::long(part.final_borrow_tokens).unwrap());
        assert_eq!(b.registers["R7"], encode::long(1_000_000).unwrap());
        assert!(PartialRepayQuote::new(sigusd(), &p, &h, p.owed, 1).is_err());
    }

    #[test]
    fn loan_spends_are_classified_by_their_marker_and_shape() {
        let id = "ab".repeat(32);
        let marker = encode::box_id_register(&id).unwrap();
        let out = |value: i64, tokens: usize, r4: Option<&str>| {
            let mut o = serde_json::json!({"value": value, "assets": (0..tokens).map(|i| serde_json::json!({"tokenId": format!("{i:064}"), "amount": 5})).collect::<Vec<_>>()});
            if let Some(r) = r4 {
                o["additionalRegisters"] = serde_json::json!({"R4": r});
            }
            o
        };
        let tx = |outs: Vec<serde_json::Value>| serde_json::json!({"outputs": outs});
        let filled = |o: OrderOutcome| matches!(o, OrderOutcome::Filled { .. });
        let refunded = |o: OrderOutcome| matches!(o, OrderOutcome::Refunded { .. });
        // Borrow: fill puts the loan tokens in the marked user box.
        let fill = tx(vec![out(1, 3, None), out(2, 1, None), out(3, 1, Some(&marker)), out(4, 0, None)]);
        assert!(filled(classify_loan_spend(OrderKind::Borrow, &id, &fill).unwrap()));
        // The ERG pool pays the loan as ERG: still a fill by shape.
        let fill = tx(vec![out(1, 3, None), out(2, 2, None), out(3, 0, Some(&marker)), out(4, 0, None)]);
        assert!(filled(classify_loan_spend(OrderKind::Borrow, &id, &fill).unwrap()));
        let refund = tx(vec![out(9, 0, Some(&marker)), out(1, 0, None)]);
        assert!(refunded(classify_loan_spend(OrderKind::Borrow, &id, &refund).unwrap()));
        // Repay: fill returns the collateral with no tokens; refund returns the tokens.
        let fill = tx(vec![out(9, 0, Some(&marker)), out(2, 2, None), out(1, 0, None)]);
        assert!(filled(classify_loan_spend(OrderKind::Repay, &id, &fill).unwrap()));
        let refund = tx(vec![out(2, 1, None), out(1, 0, None)]);
        assert!(refunded(classify_loan_spend(OrderKind::Repay, &id, &refund).unwrap()));
        // Partial: a fill rebuilds the collateral box first.
        let fill = tx(vec![out(9, 1, None), out(2, 2, None), out(1, 0, None)]);
        assert!(filled(classify_loan_spend(OrderKind::PartialRepay, &id, &fill).unwrap()));
        assert!(refunded(classify_loan_spend(OrderKind::PartialRepay, &id, &refund).unwrap()));
        assert!(matches!(classify_loan_spend(OrderKind::Borrow, &id, &tx(vec![out(1, 0, None)])).unwrap(), OrderOutcome::Unknown));
    }

    fn erg_pool() -> &'static Pool {
        pool_by_key("erg").unwrap()
    }

    fn erg_params() -> LoanParams {
        LoanParams::parse(erg_pool(), &serde_json::from_str(include_str!("../test/fixtures/pool_param_erg.json")).unwrap()).unwrap()
    }

    /// A loan in the ERG pool: 1,000 SigUSD locked against 1,000 ERG, as
    /// the bot would build it, priced through the same SigUSD market.
    fn erg_loan_box(loan: i64) -> serde_json::Value {
        let sigusd = crate::pools::ERG_POOL_COLLATERALS[0];
        serde_json::json!({
            "boxId": "cc".repeat(32),
            "value": ERG_POOL_COLLATERAL_BOX_VALUE,
            "ergoTree": ergo_tx::address_to_ergo_tree(erg_pool().collateral_address).unwrap(),
            "assets": [
                {"tokenId": sigusd.id, "amount": 100_000},
                {"tokenId": erg_pool().borrow_token, "amount": loan},
            ],
            "additionalRegisters": {
                "R4": encode::coll_byte(&hex::decode(BORROWER).unwrap()).unwrap(),
                "R5": encode::int_pair(0, 0).unwrap(),
                "R6": encode::long_pair(1250, 300).unwrap(),
                "R7": encode::coll_byte(&hex::decode(sigusd.dex_nft).unwrap()).unwrap(),
                "R8": encode::group_element(&BORROWER[6..]).unwrap(),
                "R9": encode::long_pair(1_930_000, 100_000_000).unwrap(),
            }
        })
    }

    fn flat_history() -> InterestHistory {
        // One child, one period at the idle rate.
        let mut children = BTreeMap::new();
        children.insert(0, vec![100_000_490]);
        InterestHistory {
            parent_rates: vec![],
            children,
        }
    }

    #[test]
    fn the_erg_pool_parameter_box_lists_four_token_collaterals() {
        let p = erg_params();
        assert_eq!(p.asset_ids.len(), 4);
        let (nft, thr, pen) = p.for_asset(crate::pools::ERG_POOL_COLLATERALS[0].id).unwrap();
        assert_eq!((nft.as_str(), thr, pen), (crate::pools::ERG_POOL_COLLATERALS[0].dex_nft, 1250, 300));
        assert_eq!(p.for_asset(crate::pools::ERG_POOL_COLLATERALS[3].id).unwrap().1, 1500);
        assert!(p.for_asset("ff").is_none());
        assert!(p.for_erg(erg_pool()).is_err());
        assert_eq!(erg_pool().dex_nfts().len(), 4);
        assert!(erg_pool().lends() && sigusd().lends());
    }

    #[test]
    fn token_collateral_is_priced_in_erg_the_way_the_erg_pool_contract_does() {
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        // 1,000 SigUSD through the live market: recomputed by hand from
        // the contract's formula, network fee off.
        assert_eq!(dex.token_collateral_value(100_000), 3_716_169_901_634);
        assert_eq!(dex.token_collateral_value(5_000), 188_709_605_368);
        assert_eq!(dex.token_collateral_value(0), 0);
        assert_eq!(dex.tokens_for_value(3_716_169_901_634), 100_000);
        assert!(dex.token_collateral_value(dex.tokens_for_value(1_000_000_000_000)) >= 1_000_000_000_000);
    }

    #[test]
    fn an_erg_pool_loan_is_read_valued_and_repaid_in_erg() {
        let c = CollateralBox::parse(erg_pool(), &erg_loan_box(1_000_000_000_000)).unwrap();
        assert_eq!(c.collateral_asset.as_deref(), Some(crate::pools::ERG_POOL_COLLATERALS[0].id));
        assert_eq!(c.collateral_amount, 100_000);
        assert_eq!(c.loan, 1_000_000_000_000);
        assert!(CollateralBox::parse(sigusd(), &erg_loan_box(1)).is_err(), "another pool's script");
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        let h = flat_history();
        let p = LoanPosition::value(erg_pool(), &c, &h, &dex, 1).unwrap();
        assert_eq!(p.owed, 1 + (1_000_000_000_000i128 * 100_000_490 / 100_000_000) as i64);
        assert_eq!(p.collateral_value, 3_716_169_901_634);
        assert_eq!(p.liquidation_value, p.owed * 1250 / 1000);
        assert!(p.health_bps > 29_000 && p.health_bps < 30_000, "{}", p.health_bps);
        let mine = positions(erg_pool(), &[erg_loan_box(5)], &h, &[dex.clone()], &[BORROWER.into()], 1).unwrap();
        assert_eq!(mine.len(), 1);

        let r = RepayQuote::new(erg_pool(), &p, &h, 0, 1_000_000).unwrap();
        // The proxy's ERG plus the collateral box's 0.004, less the
        // borrower's box and the fee, must reach owed + fee.
        assert_eq!(r.repayment + ERG_POOL_COLLATERAL_BOX_VALUE - MIN_BOX_VALUE - TX_FEE, p.owed + TX_FEE);
        assert_eq!(r.box_value, r.repayment);
        let b = r.proxy_box(erg_pool(), BORROWER).unwrap();
        assert!(b.assets.is_empty());
        assert_eq!(b.registers["R4"], encode::long(100_000).unwrap());
        assert_eq!(b.registers["R8"], format!("0e20{}", crate::pools::ERG_POOL_COLLATERALS[0].id));

        let part = PartialRepayQuote::new(erg_pool(), &p, &h, 400_000_000_000, 1_000_000).unwrap();
        assert_eq!(part.box_value, 400_000_000_000 + MIN_BOX_VALUE + TX_FEE);
        assert!(part.proxy_box(erg_pool(), BORROWER).unwrap().assets.is_empty());
        assert!(
            PartialRepayQuote::new(erg_pool(), &p, &h, p.owed - 10_000_000, 1).is_err(),
            "would leave less than the minimum loan"
        );
    }

    #[test]
    fn an_erg_pool_borrow_locks_tokens_and_asks_for_erg() {
        let state = PoolState::parse(erg_pool(), &serde_json::from_str(include_str!("../test/fixtures/pool_erg.json")).unwrap()).unwrap();
        let dex = DexPrice::parse(&fixture("dex")).unwrap();
        let sigusd = crate::pools::ERG_POOL_COLLATERALS[0].id;
        let q = BorrowQuote::new(erg_pool(), &state, &erg_params(), &dex, Some(sigusd), 100_000, 1_000_000_000_000, 1_900_000).unwrap();
        assert_eq!(q.collateral_value, 3_716_169_901_634);
        assert_eq!(q.max_loan, 2_972_935_921_307);
        assert_eq!(q.box_value, 6_000_000);
        assert_eq!((q.threshold, q.penalty), (1250, 300));
        // The ERG pool accepts a loan on the line itself.
        assert!(BorrowQuote::new(erg_pool(), &state, &erg_params(), &dex, Some(sigusd), 100_000, q.max_loan, 1).is_ok());
        assert!(BorrowQuote::new(erg_pool(), &state, &erg_params(), &dex, Some(sigusd), 100_000, q.max_loan + 1, 1).is_err());
        assert!(BorrowQuote::new(erg_pool(), &state, &erg_params(), &dex, Some(sigusd), 100_000, 1_000, 1).is_err(), "below the minimum loan");
        assert!(BorrowQuote::new(erg_pool(), &state, &erg_params(), &dex, None, 100_000, 1_000_000_000, 1).is_err());
        let b = q.proxy_box(erg_pool(), BORROWER).unwrap();
        assert_eq!(b.assets.len(), 1);
        assert_eq!(b.assets[0].token_id, sigusd);
        assert_eq!(b.assets[0].amount, "100000");
        assert_eq!(b.registers["R7"], encode::long_pair(1250, 300).unwrap());
        assert_eq!(b.registers["R8"], format!("0e20{}", crate::pools::ERG_POOL_COLLATERALS[0].dex_nft));
        assert_eq!(b.ergo_tree, ergo_tx::address_to_ergo_tree(erg_pool().borrow_proxy_address).unwrap());
    }
}
