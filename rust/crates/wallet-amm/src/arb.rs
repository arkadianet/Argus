//! Circular arbitrage: ERG → … → ERG cycles that pay out more ERG than goes
//! in, sized exactly and charged every cost a real chain of transactions
//! pays.
//!
//! A Spectrum pool contract names its successor as `OUTPUTS(0)`, so one
//! transaction can spend one pool box: an n-leg cycle is n transactions,
//! each paying a miner fee and the app fee. Between legs the bought token
//! sits in a wallet box that must carry the minimum box value; that ERG
//! comes back when the next leg spends the box, so it is capital, not cost.
//!
//! Sizing uses the cycle's closed-form curve ([`crate::math::Curve`]) for
//! the optimum, then the exact integer swaps around it, then trims the input
//! to the least that still buys the same final output. Profit is always the
//! exact integer quote, never the curve.

use std::collections::HashSet;

use serde::Serialize;

use crate::graph::{curve, input_for_path, quote_path, Edge, PoolGraph};
use crate::math::price_impact_pct;
use crate::pool::{Asset, Pool, PoolKind};
use crate::pricing::PriceBook;

/// What each leg of a chain costs and holds back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Costs {
    /// Network miner fee per leg transaction.
    pub miner_fee_nano: u64,
    /// App fee per leg transaction (0 when none is charged).
    pub app_fee_nano: u64,
    /// Smallest value a wallet box may hold.
    pub box_min_nano: u64,
}

impl Costs {
    pub fn per_leg(&self) -> u64 {
        self.miner_fee_nano + self.app_fee_nano
    }

    /// ERG the wallet must hold to run a `legs`-leg chain of `input`: the
    /// input, every leg's fees, the token box between legs and room for a
    /// change box.
    pub fn capital(&self, input: u64, legs: usize) -> u64 {
        input
            .saturating_add(self.per_leg().saturating_mul(legs as u64))
            .saturating_add(self.box_min_nano.saturating_mul(2))
    }
}

#[derive(Debug, Clone)]
pub struct ArbOptions {
    /// Longest cycle, in legs (transactions). At least 2.
    pub max_legs: usize,
    /// ERG-equivalent depth a pool needs to be on a route.
    pub min_depth_nano: u64,
    pub costs: Costs,
    pub min_net_profit_nano: u64,
    /// ERG the wallet can spend, or `None` to size without a budget.
    pub available_nano: Option<u64>,
    /// Token ids a route may pass through without a warning.
    pub trusted: HashSet<String>,
    pub include_untrusted: bool,
    /// Pool box ids a mempool transaction is already spending.
    pub busy_boxes: HashSet<String>,
    pub max_results: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ArbLeg {
    pub pool_id: String,
    pub box_id: String,
    /// `None` is ERG.
    pub from_token_id: Option<String>,
    pub to_token_id: Option<String>,
    pub amount_in: u64,
    pub amount_out: u64,
    pub reserve_in: u64,
    pub reserve_out: u64,
    pub fee_num: u32,
    pub price_impact_pct: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Opportunity {
    pub legs: Vec<ArbLeg>,
    pub input_nano: u64,
    pub output_nano: u64,
    /// Output minus input: what the pools return over what goes in, after
    /// their own fees.
    pub gross_profit_nano: i64,
    pub miner_fees_nano: u64,
    pub app_fees_nano: u64,
    /// Gross profit minus every leg's miner and app fee.
    pub net_profit_nano: i64,
    pub profit_pct: f64,
    /// ERG riding in the token box between legs, returned by the next leg.
    pub box_min_in_transit_nano: u64,
    /// ERG the wallet must hold to run the chain.
    pub capital_nano: u64,
    /// If the chain stops after the first leg and the token is sold straight
    /// back into the first pool: ERG lost, both transactions' fees included.
    pub unwind_loss_nano: Option<i64>,
    /// The best size were the wallet large enough.
    pub optimal_input_nano: u64,
    /// The input was cut down to what the wallet holds.
    pub sized_to_balance: bool,
    /// The wallet holds enough to run this chain.
    pub affordable: bool,
    /// Every token on the route is on the verified list.
    pub trusted: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ArbScan {
    pub opportunities: Vec<Opportunity>,
    pub cycles_checked: usize,
    pub pools_in_graph: usize,
    pub skipped_busy: usize,
    pub skipped_untrusted: usize,
}

/// Distinct final outputs walked either side of the analytic optimum.
const STEP_WALK: usize = 6;

/// `x`'s final output and the least input that still buys it. The
/// integer swaps make the output a staircase in the input; this is the
/// left edge of the stair `x` is on, where none of the input is wasted.
fn tighten(path: &[&Edge], x: u64) -> Option<(u64, u64)> {
    let out = *quote_path(path, x)?.last()?;
    let least = input_for_path(path, out).filter(|&t| t <= x).unwrap_or(x);
    Some((least, out))
}

/// Largest input below `x` that the pools can still fill.
fn largest_quotable(path: &[&Edge], x: u64) -> Option<u64> {
    let (mut lo, mut hi) = (1u64, x);
    quote_path(path, lo)?;
    while lo < hi {
        let mid = lo + (hi - lo).div_ceil(2);
        if quote_path(path, mid).is_some() {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    Some(lo)
}

/// The input, at most `cap`, that makes `path` return the most ERG over
/// what goes in, with the amounts after each swap. `None` when no input
/// makes a profit.
///
/// The unrounded curve's optimum is within a stair or two of the integer
/// one: profit is flat there, and rounding costs every stair start at most
/// a unit of each token. So the stairs around it are compared exactly
/// instead of searching the whole range, where a coarse token's stairs
/// (tens of millions of nanoERG for a two-decimal token) would mislead a
/// ternary search into a stair well off the optimum.
pub fn size_path(path: &[&Edge], cap: u64) -> Option<(u64, Vec<u64>)> {
    let seed = curve(path).best_input()?;
    if cap == 0 {
        return None;
    }
    let mut x0 = (seed.round().max(1.0) as u64).min(cap);
    if quote_path(path, x0).is_none() {
        // Past a pool's ERG floor; profit still rises towards it.
        x0 = largest_quotable(path, x0)?;
    }
    let start = tighten(path, x0)?;
    let mut stairs = vec![start];
    let mut out = start.1;
    for _ in 0..STEP_WALK {
        let next = out
            .checked_add(1)
            .and_then(|o| input_for_path(path, o))
            .filter(|&n| n <= cap);
        let Some(stair) = next.and_then(|n| tighten(path, n)) else {
            break;
        };
        out = stair.1;
        stairs.push(stair);
    }
    let mut least = start.0;
    for _ in 0..STEP_WALK {
        let below = least.checked_sub(1).filter(|&x| x > 0);
        let Some(stair) = below.and_then(|x| tighten(path, x)) else {
            break;
        };
        least = stair.0;
        stairs.push(stair);
    }
    let (input, output) = stairs
        .into_iter()
        .max_by_key(|&(x, y)| (y as i128 - x as i128, std::cmp::Reverse(x)))?;
    if output <= input {
        return None;
    }
    Some((input, quote_path(path, input)?))
}

/// Legs and totals of `path` at `input` with already-quoted `amounts`.
pub fn evaluate(
    pools: &[Pool],
    path: &[&Edge],
    input: u64,
    amounts: &[u64],
    costs: &Costs,
) -> Opportunity {
    let mut legs = Vec::with_capacity(path.len());
    let mut amount_in = input;
    for (edge, &amount_out) in path.iter().zip(amounts) {
        let pool = &pools[edge.pool];
        legs.push(ArbLeg {
            pool_id: pool.pool_id.clone(),
            box_id: pool.box_id.clone(),
            from_token_id: edge.from.token_id().map(str::to_string),
            to_token_id: edge.to.token_id().map(str::to_string),
            amount_in,
            amount_out,
            reserve_in: edge.reserve_in,
            reserve_out: edge.reserve_out,
            fee_num: edge.fee_num,
            price_impact_pct: price_impact_pct(edge.reserve_in, amount_in),
        });
        amount_in = amount_out;
    }
    let output = amounts.last().copied().unwrap_or(0);
    let n = path.len() as u64;
    let gross = output as i64 - input as i64;
    let net = gross - (costs.per_leg() * n) as i64;
    Opportunity {
        unwind_loss_nano: unwind_loss(path, input, amounts, costs),
        legs,
        input_nano: input,
        output_nano: output,
        gross_profit_nano: gross,
        miner_fees_nano: costs.miner_fee_nano * n,
        app_fees_nano: costs.app_fee_nano * n,
        net_profit_nano: net,
        profit_pct: if input == 0 {
            0.0
        } else {
            net as f64 / input as f64 * 100.0
        },
        box_min_in_transit_nano: if path.len() > 1 {
            costs.box_min_nano
        } else {
            0
        },
        capital_nano: costs.capital(input, path.len()),
        optimal_input_nano: input,
        sized_to_balance: false,
        affordable: true,
        trusted: true,
    }
}

/// ERG lost when only the first leg lands and its token is sold back into
/// the same pool right after: the first pool has moved by our own trade,
/// so this is the round trip's fees and impact plus two transactions.
fn unwind_loss(path: &[&Edge], input: u64, amounts: &[u64], costs: &Costs) -> Option<i64> {
    let first = path.first()?;
    if path.len() < 2 || !first.from.is_erg() {
        return None;
    }
    let bought = *amounts.first()?;
    let back = Edge {
        pool: first.pool,
        from: first.to.clone(),
        to: first.from.clone(),
        reserve_in: first.reserve_out.checked_sub(bought)?,
        reserve_out: first.reserve_in.checked_add(input)?,
        fee_num: first.fee_num,
        erg_out_cap: Some(
            first
                .reserve_in
                .checked_add(input)?
                .saturating_sub(crate::contract::N2T_MIN_VALUE_EXCLUSIVE + 1),
        ),
    };
    let erg_back = back.output(bought).unwrap_or(0);
    Some(input as i64 - erg_back as i64 + 2 * costs.per_leg() as i64)
}

fn route_trusted(path: &[&Edge], trusted: &HashSet<String>) -> bool {
    path.iter().all(|e| match &e.to {
        Asset::Erg => true,
        Asset::Token(id) => trusted.contains(id),
    })
}

/// Every opportunity the pool set offers under `opts`, best net profit
/// first. `book` supplies the ERG-equivalent depth of T2T pools.
pub fn scan(pools: &[Pool], book: &PriceBook, opts: &ArbOptions) -> ArbScan {
    let max_legs = opts.max_legs.max(2);
    let deep_enough = |p: &Pool| match p.kind {
        PoolKind::N2T => p.value >= opts.min_depth_nano,
        PoolKind::T2T => book
            .pool_depth_nano(p)
            .is_some_and(|d| d >= opts.min_depth_nano),
    };
    let graph = PoolGraph::build(pools, deep_enough);
    let cycles = graph.erg_cycles(max_legs);
    let mut result = ArbScan {
        cycles_checked: cycles.len(),
        pools_in_graph: graph.pool_count,
        ..ArbScan::default()
    };

    for cycle in &cycles {
        let path: Vec<&Edge> = cycle.iter().collect();
        let fees = opts.costs.per_leg() * path.len() as u64;
        // Rounding only ever lowers the exact profit, so a cycle whose
        // unrounded best cannot clear the fees and the minimum never will.
        if curve(&path).max_profit() < (fees + opts.min_net_profit_nano) as f64 {
            continue;
        }
        let Some((input, amounts)) = size_path(&path, u64::MAX) else {
            continue;
        };
        let mut opp = evaluate(pools, &path, input, &amounts, &opts.costs);
        if opp.net_profit_nano < opts.min_net_profit_nano as i64 {
            continue;
        }
        if path
            .iter()
            .any(|e| opts.busy_boxes.contains(&pools[e.pool].box_id))
        {
            result.skipped_busy += 1;
            continue;
        }
        opp.trusted = route_trusted(&path, &opts.trusted);
        if !opp.trusted && !opts.include_untrusted {
            result.skipped_untrusted += 1;
            continue;
        }
        if let Some(available) = opts.available_nano {
            opp = fit_to_balance(pools, &path, opp, available, opts);
        }
        result.opportunities.push(opp);
    }

    result.opportunities.sort_by(|a, b| {
        b.affordable
            .cmp(&a.affordable)
            .then(b.net_profit_nano.cmp(&a.net_profit_nano))
    });
    result.opportunities.truncate(opts.max_results.max(1));
    result
}

/// `opp` resized to what the wallet holds. When even the best affordable
/// size misses the minimum profit, the optimal numbers are kept and the
/// opportunity is marked unaffordable so the screen can say how much it
/// needs.
fn fit_to_balance(
    pools: &[Pool],
    path: &[&Edge],
    opp: Opportunity,
    available: u64,
    opts: &ArbOptions,
) -> Opportunity {
    if opp.capital_nano <= available {
        return opp;
    }
    let overhead = opts.costs.capital(0, path.len());
    let cap = available.saturating_sub(overhead);
    let optimal = opp.input_nano;
    if let Some((input, amounts)) = size_path(path, cap) {
        let mut fitted = evaluate(pools, path, input, &amounts, &opts.costs);
        if fitted.net_profit_nano >= opts.min_net_profit_nano as i64
            && fitted.capital_nano <= available
        {
            fitted.optimal_input_nano = optimal;
            fitted.sized_to_balance = true;
            fitted.trusted = opp.trusted;
            return fitted;
        }
    }
    Opportunity {
        affordable: false,
        ..opp
    }
}

/// One step of a route the caller already chose.
#[derive(Debug, Clone, PartialEq)]
pub struct RouteStep {
    pub pool_id: String,
    pub from: Asset,
    pub to: Asset,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RouteError {
    PoolMissing(String),
    PoolMismatch(String),
    NotACycle,
    Unquotable,
    NotProfitable {
        net_profit_nano: i64,
        min_net_profit_nano: u64,
    },
}

impl std::fmt::Display for RouteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RouteError::PoolMissing(id) => write!(f, "pool {id} is gone"),
            RouteError::PoolMismatch(id) => write!(f, "pool {id} no longer trades this pair"),
            RouteError::NotACycle => write!(f, "the route does not start and end in ERG"),
            RouteError::Unquotable => write!(f, "the pools cannot fill this route any more"),
            RouteError::NotProfitable { net_profit_nano, min_net_profit_nano } => write!(
                f,
                "expected net profit {net_profit_nano} nanoERG is below the minimum {min_net_profit_nano}"
            ),
        }
    }
}

/// The edges of a chosen route against `pools`, which should be freshly
/// read: each step must name a pool that still trades its pair.
pub fn route_edges(pools: &[Pool], steps: &[RouteStep]) -> Result<Vec<Edge>, RouteError> {
    if steps.len() < 2 || !steps[0].from.is_erg() || !steps[steps.len() - 1].to.is_erg() {
        return Err(RouteError::NotACycle);
    }
    let mut edges = Vec::with_capacity(steps.len());
    for (i, step) in steps.iter().enumerate() {
        if i > 0 && steps[i - 1].to != step.from {
            return Err(RouteError::NotACycle);
        }
        let (index, pool) = pools
            .iter()
            .enumerate()
            .find(|(_, p)| p.pool_id == step.pool_id)
            .ok_or_else(|| RouteError::PoolMissing(step.pool_id.clone()))?;
        let edge = Edge::both(index, pool)
            .into_iter()
            .find(|e| e.from == step.from && e.to == step.to)
            .ok_or_else(|| RouteError::PoolMismatch(step.pool_id.clone()))?;
        edges.push(edge);
    }
    Ok(edges)
}

/// A chosen route quoted again against fresh `pools`. With `input` set the
/// size is kept (the amount the user agreed to); without it the route is
/// re-sized within `cap`. Refused below `min_net_profit_nano`.
pub fn requote(
    pools: &[Pool],
    steps: &[RouteStep],
    input: Option<u64>,
    cap: u64,
    costs: &Costs,
    min_net_profit_nano: u64,
) -> Result<Opportunity, RouteError> {
    let edges = route_edges(pools, steps)?;
    let path: Vec<&Edge> = edges.iter().collect();
    let (input, amounts) = match input {
        Some(x) => (x, quote_path(&path, x).ok_or(RouteError::Unquotable)?),
        None => size_path(&path, cap).ok_or(RouteError::NotProfitable {
            net_profit_nano: 0,
            min_net_profit_nano,
        })?,
    };
    let opp = evaluate(pools, &path, input, &amounts, costs);
    if opp.net_profit_nano < min_net_profit_nano as i64 {
        return Err(RouteError::NotProfitable {
            net_profit_nano: opp.net_profit_nano,
            min_net_profit_nano,
        });
    }
    Ok(opp)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract::LP_EMISSION;
    use crate::pricing::{price_book, PricingOptions};

    const ERG: u64 = 1_000_000_000;

    const COSTS: Costs = Costs {
        miner_fee_nano: 1_100_000,
        app_fee_nano: 1_100_000,
        box_min_nano: 1_000_000,
    };

    fn n2t(id: &str, erg: u64, tok: &str, amount: u64) -> Pool {
        Pool::n2t(
            id,
            format!("box-{id}"),
            erg,
            tok,
            amount,
            format!("lp-{id}"),
            LP_EMISSION - 1_000,
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
            LP_EMISSION - 1_000,
            Some(997),
        )
        .unwrap()
    }

    fn opts() -> ArbOptions {
        ArbOptions {
            max_legs: 3,
            min_depth_nano: 50 * ERG,
            costs: COSTS,
            min_net_profit_nano: 0,
            available_nano: None,
            trusted: ["tok", "a", "b"].iter().map(|s| s.to_string()).collect(),
            include_untrusted: false,
            busy_boxes: HashSet::new(),
            max_results: 50,
        }
    }

    fn book(pools: &[Pool]) -> PriceBook {
        price_book(
            pools,
            &PricingOptions {
                min_depth_nano: 50 * ERG,
                trusted: HashSet::new(),
            },
        )
    }

    /// Two pools price the same token 100 and 120 nanoERG per unit.
    fn skewed() -> Vec<Pool> {
        vec![
            n2t("cheap", 1_000 * ERG, "tok", 10_000_000_000),
            n2t("dear", 1_200 * ERG, "tok", 10_000_000_000),
        ]
    }

    /// Profit of `path` at `x`, by brute force.
    fn exact_profit(path: &[&Edge], x: u64) -> i128 {
        quote_path(path, x)
            .map(|a| *a.last().unwrap() as i128 - x as i128)
            .unwrap_or(i128::MIN)
    }

    #[test]
    fn finds_and_sizes_a_two_pool_gap() {
        let pools = skewed();
        let scan = scan(&pools, &book(&pools), &opts());
        let best = scan.opportunities.first().expect("an opportunity");
        assert_eq!(best.legs.len(), 2);
        assert_eq!(
            best.legs[0].pool_id, "cheap",
            "buy where the token is cheap"
        );
        assert_eq!(best.legs[1].pool_id, "dear");
        assert_eq!(
            best.legs[0].amount_out, best.legs[1].amount_in,
            "legs chain"
        );
        assert_eq!(best.output_nano, best.legs[1].amount_out);
        // Accounting: gross is what the pools return, net pays both legs.
        assert_eq!(
            best.gross_profit_nano,
            best.output_nano as i64 - best.input_nano as i64
        );
        assert_eq!(best.net_profit_nano, best.gross_profit_nano - 2 * 2_200_000);
        assert_eq!(best.miner_fees_nano, 2_200_000);
        assert_eq!(best.app_fees_nano, 2_200_000);
        assert_eq!(best.box_min_in_transit_nano, 1_000_000);
        assert_eq!(best.capital_nano, best.input_nano + 4_400_000 + 2_000_000);
        assert!(best.net_profit_nano > 0);
        assert!(best.trusted);
    }

    fn cheap_then_dear(pools: &[Pool]) -> Vec<Edge> {
        PoolGraph::build(pools, |_| true)
            .erg_cycles(2)
            .into_iter()
            .find(|c| pools[c[0].pool].pool_id == "cheap")
            .unwrap()
    }

    /// Near the optimum the profit curve is flat and the integer swaps add
    /// a sawtooth one token unit wide, so "optimal" means: no size a brute
    /// force can find does better by more than rounding, and no nanoERG of
    /// the input is wasted.
    fn assert_sized_well(pools: &[Pool], step: u64) {
        let cycle = cheap_then_dear(pools);
        let path: Vec<&Edge> = cycle.iter().collect();
        let (x, amounts) = size_path(&path, u64::MAX).unwrap();
        let p = exact_profit(&path, x);
        assert_eq!(p, *amounts.last().unwrap() as i128 - x as i128);
        let mut best = i128::MIN;
        for k in -2_000i64..=2_000 {
            best = best.max(exact_profit(&path, (x as i64 + k * step as i64) as u64));
        }
        for k in 1..=400u64 {
            best = best.max(exact_profit(&path, k * ERG / 4));
        }
        assert!(p >= best - 10_000, "chosen {p}, brute force found {best}");
        let less = quote_path(&path, x - 1).unwrap();
        assert!(
            less.last() < amounts.last(),
            "one nanoERG less must buy less"
        );
    }

    #[test]
    fn the_size_is_as_good_as_brute_force() {
        let pools = skewed();
        assert_sized_well(&pools, 37);
        // The analytic optimum for these pools is ~46.3 ERG.
        let cycle = cheap_then_dear(&pools);
        let (x, _) = size_path(&cycle.iter().collect::<Vec<_>>(), u64::MAX).unwrap();
        assert!(x > 40 * ERG && x < 50 * ERG, "x = {x}");
    }

    /// A two-decimal token like SigUSD moves in steps of tens of millions of
    /// nanoERG; sizing must still land on the start of the best step.
    #[test]
    fn coarse_tokens_are_sized_on_step_boundaries() {
        let pools = vec![
            n2t("cheap", 1_000 * ERG, "tok", 30_000),
            n2t("dear", 1_200 * ERG, "tok", 30_000),
        ];
        assert_sized_well(&pools, 1_000_003);
    }

    #[test]
    fn balanced_pools_offer_nothing() {
        let pools = vec![
            n2t("a", 1_000 * ERG, "tok", 10_000_000_000),
            n2t("b", 2_000 * ERG, "tok", 20_000_000_000),
        ];
        let scan = scan(&pools, &book(&pools), &opts());
        assert!(scan.opportunities.is_empty());
        assert_eq!(scan.cycles_checked, 2);
    }

    #[test]
    fn fees_and_the_minimum_are_both_charged() {
        let pools = skewed();
        let all = scan(&pools, &book(&pools), &opts());
        let net = all.opportunities[0].net_profit_nano as u64;
        let at_min = scan(
            &pools,
            &book(&pools),
            &ArbOptions {
                min_net_profit_nano: net,
                ..opts()
            },
        );
        assert_eq!(at_min.opportunities.len(), 1);
        let above = scan(
            &pools,
            &book(&pools),
            &ArbOptions {
                min_net_profit_nano: net + 1,
                ..opts()
            },
        );
        assert!(above.opportunities.is_empty());
        // A tiny gap is real before fees but not after them.
        let tiny = vec![
            n2t("a", 1_000 * ERG, "tok", 10_000_000_000),
            n2t("b", 1_000 * ERG, "tok", 9_985_000_000),
        ];
        assert!(scan(&tiny, &book(&tiny), &opts()).opportunities.is_empty());
    }

    #[test]
    fn three_leg_cycles_through_a_token_pair() {
        let pools = vec![
            n2t("ea", 1_000 * ERG, "a", 1_000_000_000),
            t2t("ab", "a", 1_000_000_000, "b", 1_300_000_000),
            n2t("eb", 1_000 * ERG, "b", 1_000_000_000),
        ];
        let scan = scan(&pools, &book(&pools), &opts());
        let best = scan.opportunities.first().expect("triangle");
        assert_eq!(best.legs.len(), 3);
        assert_eq!(best.legs[1].pool_id, "ab");
        assert_eq!(best.net_profit_nano, best.gross_profit_nano - 3 * 2_200_000);
        assert_eq!(
            best.capital_nano,
            best.input_nano + 3 * 2_200_000 + 2_000_000
        );
    }

    #[test]
    fn shallow_and_unpriced_pools_stay_off_routes() {
        let mut pools = skewed();
        pools[1] = n2t("dear", 40 * ERG, "tok", 333_000_000);
        assert!(
            scan(&pools, &book(&pools), &opts())
                .opportunities
                .is_empty(),
            "40 ERG is below the floor"
        );
        // A T2T pool is as deep as its smaller priced side: here a few
        // nanoERG of `a` against a token nobody prices.
        let pools = vec![
            n2t("ea", 1_000 * ERG, "a", 1_000_000_000),
            t2t("ab", "a", 1_000, "zz", 1_300),
        ];
        let s = scan(&pools, &book(&pools), &opts());
        assert_eq!(s.pools_in_graph, 1);
    }

    #[test]
    fn busy_pools_and_unverified_tokens_are_skipped_and_counted() {
        let pools = skewed();
        let mut busy = opts();
        busy.busy_boxes.insert("box-dear".into());
        let s = scan(&pools, &book(&pools), &busy);
        assert!(s.opportunities.is_empty());
        assert_eq!(s.skipped_busy, 1);

        let mut untrusted = opts();
        untrusted.trusted.clear();
        let s = scan(&pools, &book(&pools), &untrusted);
        assert!(s.opportunities.is_empty());
        assert_eq!(s.skipped_untrusted, 1);
        let s = scan(
            &pools,
            &book(&pools),
            &ArbOptions {
                include_untrusted: true,
                ..untrusted
            },
        );
        assert_eq!(s.opportunities.len(), 1);
        assert!(!s.opportunities[0].trusted);
    }

    #[test]
    fn a_small_wallet_gets_a_smaller_trade_or_an_honest_no() {
        let pools = skewed();
        let full = scan(&pools, &book(&pools), &opts()).opportunities[0].clone();
        let s = scan(
            &pools,
            &book(&pools),
            &ArbOptions {
                available_nano: Some(10 * ERG),
                ..opts()
            },
        );
        let fitted = &s.opportunities[0];
        assert!(fitted.sized_to_balance && fitted.affordable);
        assert!(fitted.capital_nano <= 10 * ERG);
        assert!(fitted.net_profit_nano > 0 && fitted.net_profit_nano < full.net_profit_nano);
        assert_eq!(fitted.optimal_input_nano, full.input_nano);

        // 5 mERG cannot even pay the fees: keep the optimum, say unaffordable.
        let s = scan(
            &pools,
            &book(&pools),
            &ArbOptions {
                available_nano: Some(5_000_000),
                ..opts()
            },
        );
        let poor = &s.opportunities[0];
        assert!(!poor.affordable && !poor.sized_to_balance);
        assert_eq!(poor.input_nano, full.input_nano);
    }

    #[test]
    fn unwinding_after_the_first_leg_costs_the_round_trip() {
        let pools = skewed();
        let o = scan(&pools, &book(&pools), &opts()).opportunities[0].clone();
        let loss = o.unwind_loss_nano.expect("estimate");
        // Two pool fees of 0.3% and the impact of going there and back,
        // plus two transactions' fees.
        assert!(loss > 2 * 2_200_000);
        assert!(
            loss < (o.input_nano as f64 * 0.02) as i64,
            "loss {loss} of {}",
            o.input_nano
        );
    }

    #[test]
    fn requote_keeps_the_agreed_size_and_refuses_below_the_minimum() {
        let pools = skewed();
        let o = scan(&pools, &book(&pools), &opts()).opportunities[0].clone();
        let steps: Vec<RouteStep> = o
            .legs
            .iter()
            .map(|l| RouteStep {
                pool_id: l.pool_id.clone(),
                from: Asset::from_token_id(l.from_token_id.as_deref()),
                to: Asset::from_token_id(l.to_token_id.as_deref()),
            })
            .collect();
        let same = requote(&pools, &steps, Some(o.input_nano), u64::MAX, &COSTS, 0).unwrap();
        assert_eq!(same, o);

        // The dear pool loses most of its premium before signing.
        let mut moved = pools.clone();
        moved[1] = n2t("dear", 1_010 * ERG, "tok", 10_000_000_000);
        let err = requote(
            &moved,
            &steps,
            Some(o.input_nano),
            u64::MAX,
            &COSTS,
            1_000_000,
        )
        .unwrap_err();
        assert!(matches!(err, RouteError::NotProfitable { .. }), "{err}");

        // A pool that disappeared or no longer trades the pair is named.
        let gone = vec![pools[0].clone()];
        assert_eq!(
            requote(&gone, &steps, None, u64::MAX, &COSTS, 0),
            Err(RouteError::PoolMissing("dear".into()))
        );
        let mut swapped = pools.clone();
        swapped[1] = n2t("dear", 1_200 * ERG, "other", 10_000_000_000);
        assert_eq!(
            requote(&swapped, &steps, None, u64::MAX, &COSTS, 0),
            Err(RouteError::PoolMismatch("dear".into()))
        );
    }

    #[test]
    fn routes_must_be_erg_cycles() {
        let pools = skewed();
        let open = vec![RouteStep {
            pool_id: "cheap".into(),
            from: Asset::Erg,
            to: Asset::token("tok"),
        }];
        assert_eq!(route_edges(&pools, &open), Err(RouteError::NotACycle));
        let broken = vec![
            RouteStep {
                pool_id: "cheap".into(),
                from: Asset::Erg,
                to: Asset::token("tok"),
            },
            RouteStep {
                pool_id: "dear".into(),
                from: Asset::token("x"),
                to: Asset::Erg,
            },
        ];
        assert_eq!(route_edges(&pools, &broken), Err(RouteError::NotACycle));
    }
}
