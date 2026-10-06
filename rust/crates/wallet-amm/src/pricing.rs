//! Token and LP-token prices in ERG from pool reserves.
//!
//! The rules, in order of preference for a token:
//!
//! 1. **Direct**: the deepest N2T pool for the token whose ERG side is at
//!    least the depth floor. Depth is the ERG reserve; a price nobody can
//!    trade at is not a price.
//! 2. **One hop**: with no direct pool passing the floor, a T2T pool
//!    against a token that has a direct price (e.g. token → SigUSD → ERG),
//!    when that T2T pool's ERG-equivalent depth (its anchor side at the
//!    anchor's price) also passes the floor. The route with the deepest
//!    weaker pool wins.
//!
//! Prices are spot prices, the pool's own ratio before its fee. Every price
//! says whether it is `trusted`: every token it rests on is on the
//! caller's verified list. Untrusted prices are still returned so a row
//! can show them; the app leaves them out of totals.
//!
//! An LP token is worth its share of both reserves, the token side at the
//! pool's own price. For an N2T pool that is twice the ERG side. A T2T pool
//! has no ERG side, so each side is valued at its own token's price and the
//! smaller of the two anchors the pool: twice that side, the pool's internal
//! price applied from the more conservative end. ergo-pricing sums both
//! sides at outside prices instead, which counts a pool's mispricing as
//! value the holder cannot redeem at that rate.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde::Serialize;

use crate::pool::{Asset, Pool, PoolKind};

#[derive(Debug, Clone, Default)]
pub struct PricingOptions {
    /// Minimum ERG-side depth, in nanoERG, for a pool to set a price.
    pub min_depth_nano: u64,
    /// Token ids whose prices may count towards totals.
    pub trusted: HashSet<String>,
}

/// How a token got its price.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "route", rename_all = "snake_case")]
pub enum PriceRoute {
    Direct {
        pool_id: String,
    },
    Hop {
        via_token_id: String,
        pool_ids: [String; 2],
    },
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TokenQuote {
    /// nanoERG per base unit of the token (no decimals applied).
    pub nano_erg_per_unit: f64,
    /// ERG-side depth of the shallowest pool on the route, in nanoERG.
    pub depth_nano: u64,
    #[serde(flatten)]
    pub route: PriceRoute,
    pub trusted: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LpQuote {
    /// nanoERG per base unit of the LP token.
    pub nano_erg_per_unit: f64,
    /// ERG-equivalent depth of the pool's anchor side, in nanoERG.
    pub depth_nano: u64,
    pub pool_id: String,
    /// The pool's sides; `None` is ERG.
    pub x_token_id: Option<String>,
    pub y_token_id: String,
    pub trusted: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct PriceBook {
    pub tokens: BTreeMap<String, TokenQuote>,
    pub lp_tokens: BTreeMap<String, LpQuote>,
}

impl PriceBook {
    /// nanoERG per base unit of `asset`, ERG included.
    pub fn nano_per_unit(&self, asset: &Asset) -> Option<f64> {
        match asset {
            Asset::Erg => Some(1.0),
            Asset::Token(id) => self.tokens.get(id).map(|q| q.nano_erg_per_unit),
        }
    }

    pub fn is_trusted(&self, asset: &Asset) -> bool {
        match asset {
            Asset::Erg => true,
            Asset::Token(id) => self.tokens.get(id).is_some_and(|q| q.trusted),
        }
    }

    /// ERG-equivalent of `amount` of `asset`, when priced.
    pub fn value_nano(&self, asset: &Asset, amount: u64) -> Option<f64> {
        self.nano_per_unit(asset).map(|p| p * amount as f64)
    }

    /// ERG-equivalent depth of `pool`: the ERG side of an N2T pool, the
    /// smaller priced side of a T2T pool. `None` when a T2T pool has no
    /// priced side.
    pub fn pool_depth_nano(&self, pool: &Pool) -> Option<u64> {
        match pool.kind {
            PoolKind::N2T => Some(pool.value),
            PoolKind::T2T => t2t_anchor(self, pool).map(|(v, _)| v as u64),
        }
    }
}

/// The smaller priced side of a T2T pool, in nanoERG, with whether every
/// price it used is trusted.
fn t2t_anchor(book: &PriceBook, pool: &Pool) -> Option<(f64, bool)> {
    let sides = pool.sides();
    let valued: Vec<(f64, bool)> = sides
        .iter()
        .filter_map(|(asset, amount)| {
            book.value_nano(asset, *amount)
                .map(|v| (v, book.is_trusted(asset)))
        })
        .collect();
    valued.into_iter().min_by(|a, b| a.0.total_cmp(&b.0))
}

fn is_trusted(opts: &PricingOptions, asset: &Asset) -> bool {
    match asset {
        Asset::Erg => true,
        Asset::Token(id) => opts.trusted.contains(id),
    }
}

/// Every price the pool set supports under `opts`.
pub fn price_book(pools: &[Pool], opts: &PricingOptions) -> PriceBook {
    let mut book = PriceBook::default();

    // 1. Direct: deepest N2T pool per token, at or above the floor.
    let mut best: HashMap<&str, &Pool> = HashMap::new();
    for pool in pools
        .iter()
        .filter(|p| p.kind == PoolKind::N2T && p.value >= opts.min_depth_nano)
    {
        let slot = best.entry(pool.y.as_str()).or_insert(pool);
        if (pool.value, std::cmp::Reverse(&pool.pool_id))
            > (slot.value, std::cmp::Reverse(&slot.pool_id))
        {
            *slot = pool;
        }
    }
    for (token, pool) in best {
        book.tokens.insert(
            token.to_string(),
            TokenQuote {
                nano_erg_per_unit: pool.value as f64 / pool.y_amount as f64,
                depth_nano: pool.value,
                route: PriceRoute::Direct {
                    pool_id: pool.pool_id.clone(),
                },
                trusted: opts.trusted.contains(token),
            },
        );
    }

    // 2. One hop through a T2T pool to a directly priced token.
    let mut hops: BTreeMap<String, TokenQuote> = BTreeMap::new();
    for pool in pools.iter().filter(|p| p.kind == PoolKind::T2T) {
        let [(x, xa), (y, ya)] = pool.sides();
        for ((token, token_amount), (via, via_amount)) in
            [((&x, xa), (&y, ya)), ((&y, ya), (&x, xa))]
        {
            let (Asset::Token(token_id), Asset::Token(via_id)) = (token, via) else {
                continue;
            };
            if book.tokens.contains_key(token_id) {
                continue;
            }
            let Some(anchor) = book.tokens.get(via_id) else {
                continue;
            };
            if !matches!(anchor.route, PriceRoute::Direct { .. }) {
                continue;
            }
            let t2t_depth = (via_amount as f64 * anchor.nano_erg_per_unit) as u64;
            let depth = t2t_depth.min(anchor.depth_nano);
            if t2t_depth < opts.min_depth_nano {
                continue;
            }
            let PriceRoute::Direct {
                pool_id: anchor_pool,
            } = &anchor.route
            else {
                continue;
            };
            let quote = TokenQuote {
                nano_erg_per_unit: via_amount as f64 / token_amount as f64
                    * anchor.nano_erg_per_unit,
                depth_nano: depth,
                route: PriceRoute::Hop {
                    via_token_id: via_id.clone(),
                    pool_ids: [pool.pool_id.clone(), anchor_pool.clone()],
                },
                trusted: opts.trusted.contains(token_id) && anchor.trusted,
            };
            if hops
                .get(token_id)
                .is_none_or(|old| rank(&quote) > rank(old))
            {
                hops.insert(token_id.clone(), quote);
            }
        }
    }
    book.tokens.extend(hops);

    // 3. LP tokens. A pool's LP id can be copied into a junk box at the
    // pool address, but nobody can lock more of it than circulates outside
    // the real pool, so the box locking the most (least supply) is real.
    let mut by_lp: HashMap<&str, &Pool> = HashMap::new();
    for pool in pools.iter().filter(|p| p.lp_supply > 0) {
        let slot = by_lp.entry(pool.lp_token_id.as_str()).or_insert(pool);
        if pool.lp_supply < slot.lp_supply {
            *slot = pool;
        }
    }
    for (lp, pool) in by_lp {
        let (anchor_nano, anchor_trusted) = match pool.kind {
            PoolKind::N2T => (pool.value as f64, true),
            PoolKind::T2T => match t2t_anchor(&book, pool) {
                Some(a) => a,
                None => continue,
            },
        };
        if anchor_nano < opts.min_depth_nano as f64 {
            continue;
        }
        let trusted = anchor_trusted && is_trusted(opts, &pool.x) && opts.trusted.contains(&pool.y);
        book.lp_tokens.insert(
            lp.to_string(),
            LpQuote {
                nano_erg_per_unit: 2.0 * anchor_nano / pool.lp_supply as f64,
                depth_nano: anchor_nano as u64,
                pool_id: pool.pool_id.clone(),
                x_token_id: pool.x.token_id().map(str::to_string),
                y_token_id: pool.y.clone(),
                trusted,
            },
        );
    }
    book
}

/// Deeper routes rank higher; between equally deep ones the lower first
/// pool id wins, so the book does not depend on discovery order.
fn rank(q: &TokenQuote) -> (u64, std::cmp::Reverse<&str>) {
    let first = match &q.route {
        PriceRoute::Hop { pool_ids, .. } => pool_ids[0].as_str(),
        PriceRoute::Direct { pool_id } => pool_id.as_str(),
    };
    (q.depth_nano, std::cmp::Reverse(first))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract::LP_EMISSION;

    const ERG: u64 = 1_000_000_000;

    fn n2t(id: &str, erg: u64, tok: &str, amount: u64) -> Pool {
        Pool::n2t(
            id,
            format!("box-{id}"),
            erg,
            tok,
            amount,
            format!("lp-{id}"),
            LP_EMISSION - 1_000_000,
            Some(997),
        )
        .unwrap()
    }

    fn t2t(id: &str, x: &str, xa: u64, y: &str, ya: u64) -> Pool {
        Pool::t2t(
            id,
            format!("box-{id}"),
            1_000_000,
            x,
            xa,
            y,
            ya,
            format!("lp-{id}"),
            LP_EMISSION - 1_000_000,
            Some(997),
        )
        .unwrap()
    }

    fn opts(trusted: &[&str]) -> PricingOptions {
        PricingOptions {
            min_depth_nano: 50 * ERG,
            trusted: trusted.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn deepest_pool_above_the_floor_sets_the_price() {
        let pools = [
            n2t("shallow", 10 * ERG, "spf", 1_000_000_000), // below the floor
            n2t("deep", 500 * ERG, "spf", 10_000_000_000),  // 50 nanoERG per unit
            n2t("mid", 200 * ERG, "spf", 1_000_000_000),    // would say 200
        ];
        let book = price_book(&pools, &opts(&["spf"]));
        let q = &book.tokens["spf"];
        assert_eq!(
            q.route,
            PriceRoute::Direct {
                pool_id: "deep".into()
            }
        );
        assert_eq!(q.depth_nano, 500 * ERG);
        assert!((q.nano_erg_per_unit - 50.0).abs() < 1e-9);
        assert!(q.trusted);
    }

    #[test]
    fn below_the_floor_everywhere_is_unpriced() {
        let book = price_book(&[n2t("p", 10 * ERG, "spf", 1_000)], &opts(&["spf"]));
        assert!(book.tokens.is_empty());
        assert!(
            book.lp_tokens.is_empty(),
            "the LP of a shallow pool is not valued either"
        );
    }

    #[test]
    fn unverified_tokens_are_priced_but_not_trusted() {
        let book = price_book(&[n2t("p", 1_000 * ERG, "scam", 1_000)], &opts(&[]));
        assert!(!book.tokens["scam"].trusted);
    }

    /// A token with no ERG pool of its own is priced through one T2T hop
    /// to a token that has one, when both pools pass the floor.
    #[test]
    fn one_hop_through_sigusd() {
        let pools = [
            n2t("sigusd-erg", 1_000 * ERG, "sigusd", 30_000), // 1 SigUSD cent = 1/30 ERG
            t2t("tok-sigusd", "tok", 2_000_000, "sigusd", 20_000), // 100 tok units per cent
        ];
        let book = price_book(&pools, &opts(&["tok", "sigusd"]));
        let q = &book.tokens["tok"];
        let cent = 1_000.0 * ERG as f64 / 30_000.0;
        assert!((q.nano_erg_per_unit - cent / 100.0).abs() < 1e-6);
        assert_eq!(
            q.route,
            PriceRoute::Hop {
                via_token_id: "sigusd".into(),
                pool_ids: ["tok-sigusd".into(), "sigusd-erg".into()]
            }
        );
        // The T2T pool's anchor side is 20_000 cents ≈ 666 ERG; the ERG pool
        // is 1_000 ERG deep; the route is as deep as the weaker pool.
        assert_eq!(q.depth_nano, (20_000.0 * cent) as u64);
        assert!(q.trusted);
    }

    #[test]
    fn a_hop_needs_both_pools_above_the_floor() {
        let thin_t2t = [
            n2t("s", 1_000 * ERG, "sigusd", 30_000),
            t2t("t", "tok", 2_000_000, "sigusd", 100),
        ];
        assert!(price_book(&thin_t2t, &opts(&[]))
            .tokens
            .get("tok")
            .is_none());
        let thin_anchor = [
            n2t("s", 10 * ERG, "sigusd", 300),
            t2t("t", "tok", 2_000_000, "sigusd", 300),
        ];
        assert!(price_book(&thin_anchor, &opts(&[]))
            .tokens
            .get("tok")
            .is_none());
    }

    #[test]
    fn a_hop_through_an_unverified_token_is_untrusted() {
        let pools = [
            n2t("s", 1_000 * ERG, "fakeusd", 30_000),
            t2t("t", "tok", 2_000_000, "fakeusd", 20_000),
        ];
        let book = price_book(&pools, &opts(&["tok"]));
        assert!(!book.tokens["tok"].trusted);
    }

    #[test]
    fn a_direct_pool_wins_over_a_hop() {
        let pools = [
            n2t("s", 1_000 * ERG, "sigusd", 30_000),
            n2t("direct", 60 * ERG, "tok", 6_000),
            t2t("t", "tok", 2_000_000, "sigusd", 20_000),
        ];
        let book = price_book(&pools, &opts(&[]));
        assert_eq!(
            book.tokens["tok"].route,
            PriceRoute::Direct {
                pool_id: "direct".into()
            }
        );
    }

    #[test]
    fn hops_go_only_one_level_deep() {
        // tok2 → tok (hop-priced) → sigusd → ERG would be two hops.
        let pools = [
            n2t("s", 1_000 * ERG, "sigusd", 30_000),
            t2t("t", "tok", 2_000_000, "sigusd", 20_000),
            t2t("u", "tok2", 5, "tok", 1_000_000),
        ];
        let book = price_book(&pools, &opts(&[]));
        assert!(book.tokens.contains_key("tok"));
        assert!(!book.tokens.contains_key("tok2"));
    }

    #[test]
    fn n2t_lp_is_twice_the_erg_side_over_the_supply() {
        let pool = Pool::n2t(
            "p",
            "b",
            600 * ERG,
            "spf",
            12_000,
            "lp",
            LP_EMISSION - 3_000,
            Some(997),
        )
        .unwrap();
        let book = price_book(&[pool], &opts(&["spf"]));
        let lp = &book.lp_tokens["lp"];
        assert_eq!(lp.pool_id, "p");
        assert_eq!(lp.depth_nano, 600 * ERG);
        // 1_200 ERG of reserves over 3_000 units.
        assert!((lp.nano_erg_per_unit - 400_000_000.0).abs() < 1e-3);
        assert!(lp.trusted);
        let untrusted = price_book(
            &[Pool::n2t("p", "b", 600 * ERG, "spf", 12_000, "lp", 1, Some(997)).unwrap()],
            &opts(&[]),
        );
        assert!(
            !untrusted.lp_tokens["lp"].trusted,
            "an LP of an unverified token stays out of totals"
        );
    }

    #[test]
    fn t2t_lp_is_anchored_on_the_smaller_side() {
        // SigUSD side is worth 600 ERG at the ERG pool's price; the tok side
        // at its own (cheaper) ERG pool is worth 500 ERG: the pool is
        // valued at 2 × 500 ERG.
        let pools = [
            n2t("s", 3_000 * ERG, "sigusd", 300_000), // 1 cent = 0.01 ERG
            n2t("k", 1_000 * ERG, "tok", 2_000),      // 1 tok unit = 0.5 ERG
            Pool::t2t(
                "t",
                "bt",
                1_000_000,
                "tok",
                1_000,
                "sigusd",
                60_000,
                "lp-t",
                LP_EMISSION - 10_000,
                Some(997),
            )
            .unwrap(),
        ];
        let book = price_book(&pools, &opts(&["tok", "sigusd"]));
        let lp = &book.lp_tokens["lp-t"];
        assert_eq!(lp.depth_nano, 500 * ERG);
        assert!((lp.nano_erg_per_unit - (1_000.0 * ERG as f64 / 10_000.0)).abs() < 1e-3);
        assert!(lp.trusted);
        assert_eq!(lp.x_token_id.as_deref(), Some("tok"));
    }

    #[test]
    fn a_t2t_lp_with_no_priced_side_is_unpriced() {
        let pools = [t2t("t", "a", 1_000, "b", 1_000)];
        assert!(price_book(&pools, &opts(&["a", "b"])).lp_tokens.is_empty());
    }

    /// Someone holding a few LP units can put them in a junk box at the
    /// pool address; the real pool locks far more and is the one valued.
    #[test]
    fn a_copied_lp_id_does_not_displace_the_real_pool() {
        let real = Pool::n2t(
            "real",
            "b1",
            600 * ERG,
            "spf",
            12_000,
            "lp",
            LP_EMISSION - 3_000,
            Some(997),
        )
        .unwrap();
        let junk = Pool::n2t("junk", "b2", 5_000 * ERG, "spf", 12, "lp", 2_000, Some(997)).unwrap();
        let book = price_book(&[junk, real], &opts(&["spf"]));
        assert_eq!(book.lp_tokens["lp"].pool_id, "real");
    }

    #[test]
    fn the_book_is_the_same_whatever_the_pool_order() {
        let mut pools = vec![
            n2t("s", 1_000 * ERG, "sigusd", 30_000),
            n2t("a1", 100 * ERG, "a", 1_000),
            n2t("a2", 100 * ERG, "a", 2_000),
            t2t("t", "tok", 2_000_000, "sigusd", 20_000),
        ];
        let first = price_book(&pools, &opts(&[]));
        pools.reverse();
        assert_eq!(first, price_book(&pools, &opts(&[])));
        assert_eq!(
            first.tokens["a"].route,
            PriceRoute::Direct {
                pool_id: "a1".into()
            },
            "equal depth: lower id"
        );
    }
}
