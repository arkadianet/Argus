//! Following a broadcast chain of legs: has it landed, and if it broke,
//! what does the wallet hold now.
//!
//! Each leg spends the previous leg's output box, so a leg can only land
//! after every leg before it. When one is rejected or later dropped (its
//! pool box went to someone else first), every leg after it is invalid too,
//! and the wallet is left holding the token the last good leg bought.

use serde::{Deserialize, Serialize};

use crate::arb::ArbLeg;
use crate::graph::Edge;
use crate::math::price_impact_pct;
use crate::pool::{Asset, Pool, PoolKind};

/// What the node says about one leg's transaction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LegStatus {
    /// Never accepted by the node.
    NotSubmitted,
    Pending,
    Confirmed,
    /// Accepted earlier, now neither in the mempool nor in a block.
    Missing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ChainState {
    /// Every leg is in a block.
    Complete,
    /// Every leg is in the mempool or a block, or the node's answers do not
    /// agree with each other yet.
    InFlight,
    /// The first leg never landed, so nothing changed.
    NothingHappened,
    /// The legs before `failed_leg` landed or are pending and it did not.
    Stranded { failed_leg: usize },
}

pub fn classify(statuses: &[LegStatus]) -> ChainState {
    let failed = |s: &LegStatus| matches!(s, LegStatus::NotSubmitted | LegStatus::Missing);
    let Some(k) = statuses.iter().position(failed) else {
        return if statuses.iter().all(|s| *s == LegStatus::Confirmed) {
            ChainState::Complete
        } else {
            ChainState::InFlight
        };
    };
    // A later leg cannot land without this one: the node answered from two
    // different moments, so wait for a consistent picture.
    if statuses[k + 1..].iter().any(|s| !failed(s)) {
        return ChainState::InFlight;
    }
    if k == 0 {
        ChainState::NothingHappened
    } else {
        ChainState::Stranded { failed_leg: k }
    }
}

/// The token and amount left in the wallet when `failed_leg` did not land:
/// what the leg before it bought.
pub fn stranded_holding(legs: &[ArbLeg], failed_leg: usize) -> Option<(String, u64)> {
    let last_good = legs.get(failed_leg.checked_sub(1)?)?;
    Some((last_good.to_token_id.clone()?, last_good.amount_out))
}

/// The way back to ERG for a stranded token: the ERG pool paying the most
/// for `amount` of it right now.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ExitQuote {
    /// Index into the pool slice quoted against.
    #[serde(skip)]
    pub pool: usize,
    pub pool_id: String,
    pub erg_out_nano: u64,
    pub price_impact_pct: f64,
}

pub fn best_exit(pools: &[Pool], token_id: &str, amount: u64) -> Option<ExitQuote> {
    let token = Asset::token(token_id);
    pools
        .iter()
        .enumerate()
        .filter(|(_, p)| p.kind == PoolKind::N2T && p.y == token_id)
        .filter_map(|(i, p)| {
            let [_, to_erg] = Edge::both(i, p);
            debug_assert_eq!(to_erg.from, token);
            let out = to_erg.output(amount)?;
            Some(ExitQuote {
                pool: i,
                pool_id: p.pool_id.clone(),
                erg_out_nano: out,
                price_impact_pct: price_impact_pct(to_erg.reserve_in, amount),
            })
        })
        .max_by(|a, b| {
            a.erg_out_nano
                .cmp(&b.erg_out_nano)
                .then(b.pool_id.cmp(&a.pool_id))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use LegStatus::*;

    fn leg(to: Option<&str>, out: u64) -> ArbLeg {
        ArbLeg {
            pool_id: "p".into(),
            box_id: "b".into(),
            from_token_id: None,
            to_token_id: to.map(str::to_string),
            amount_in: 1,
            amount_out: out,
            reserve_in: 1,
            reserve_out: 1,
            fee_num: 997,
            price_impact_pct: 0.0,
        }
    }

    #[test]
    fn complete_and_in_flight() {
        assert_eq!(classify(&[Confirmed, Confirmed]), ChainState::Complete);
        assert_eq!(classify(&[Confirmed, Pending]), ChainState::InFlight);
        assert_eq!(classify(&[Pending, Pending, Pending]), ChainState::InFlight);
    }

    #[test]
    fn a_first_leg_that_never_landed_changed_nothing() {
        assert_eq!(
            classify(&[NotSubmitted, NotSubmitted]),
            ChainState::NothingHappened
        );
        assert_eq!(
            classify(&[Missing, Missing, Missing]),
            ChainState::NothingHappened
        );
    }

    #[test]
    fn a_later_leg_failing_strands_the_token() {
        assert_eq!(
            classify(&[Pending, NotSubmitted]),
            ChainState::Stranded { failed_leg: 1 }
        );
        assert_eq!(
            classify(&[Confirmed, Missing]),
            ChainState::Stranded { failed_leg: 1 }
        );
        assert_eq!(
            classify(&[Confirmed, Confirmed, Missing]),
            ChainState::Stranded { failed_leg: 2 }
        );
    }

    #[test]
    fn contradictory_answers_wait() {
        assert_eq!(classify(&[Missing, Pending]), ChainState::InFlight);
    }

    #[test]
    fn the_exit_is_the_pool_paying_the_most_erg() {
        let pools = [
            Pool::n2t(
                "deep",
                "b1",
                1_000_000_000_000,
                "tok",
                1_000_000,
                "l1",
                1,
                Some(997),
            )
            .unwrap(),
            // Same price, a twentieth of the depth: more impact, less ERG.
            Pool::n2t(
                "shallow",
                "b2",
                50_000_000_000,
                "tok",
                50_000,
                "l2",
                1,
                Some(997),
            )
            .unwrap(),
            Pool::n2t(
                "other",
                "b3",
                9_000_000_000_000,
                "zzz",
                1_000,
                "l3",
                1,
                Some(997),
            )
            .unwrap(),
        ];
        let exit = best_exit(&pools, "tok", 10_000).unwrap();
        assert_eq!(exit.pool_id, "deep");
        assert_eq!(
            exit.erg_out_nano,
            crate::math::swap_output(1_000_000, 1_000_000_000_000, 10_000, 997)
        );
        assert!(best_exit(&pools, "nope", 1).is_none());
    }

    #[test]
    fn the_stranded_token_is_what_the_last_good_leg_bought() {
        let legs = [
            leg(Some("sigusd"), 4_500),
            leg(Some("spf"), 90),
            leg(None, 13),
        ];
        assert_eq!(stranded_holding(&legs, 1), Some(("sigusd".into(), 4_500)));
        assert_eq!(stranded_holding(&legs, 2), Some(("spf".into(), 90)));
        assert_eq!(stranded_holding(&legs, 0), None, "nothing landed");
    }
}
