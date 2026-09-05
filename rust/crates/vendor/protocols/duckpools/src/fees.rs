//! The protocol's service fee, exactly as the pool contract computes it
//! from the change in pooled assets, and its inverse for a deposit.

use crate::Pool;

const DIVISOR_ONE: i64 = 160;
const DIVISOR_TWO: i64 = 200;
const DIVISOR_THREE: i64 = 250;

/// The fee the pool contract demands on a change of `delta` asset units,
/// in asset units: `1/160` of the first step, `1/200` of the next, `1/250`
/// above, never below the pool's minimum.
pub fn service_fee(pool: &Pool, delta: i64) -> i64 {
    let (step_one, step_two) = pool.fee_thresholds;
    let delta = delta.max(0);
    let raw = if delta <= step_one {
        delta / DIVISOR_ONE
    } else if delta <= step_two {
        (delta - step_one) / DIVISOR_TWO + step_one / DIVISOR_ONE
    } else {
        (delta - step_two - step_one) / DIVISOR_THREE
            + step_two / DIVISOR_TWO
            + step_one / DIVISOR_ONE
    };
    raw.max(pool.min_service_fee())
}

/// Split `total` into what reaches the pool and the fee on it, so that
/// `given + service_fee(given) <= total` with `given` as large as
/// possible. This is what a bot does with a lend order's usable value.
pub fn split_for_deposit(pool: &Pool, total: i64) -> (i64, i64) {
    if total <= 0 {
        return (0, 0);
    }
    let mut lo = 0i64;
    let mut hi = total;
    // Monotone: more given means more fee. Binary search the largest
    // `given` whose fee still fits.
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        if mid + service_fee(pool, mid) <= total {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    let given = lo;
    (given, total - given)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::POOLS;

    #[test]
    fn erg_pool_fee_tiers_match_the_contract() {
        let erg = &POOLS[0];
        assert_eq!(erg.fee_thresholds, (20_000_000_000, 200_000_000_000));
        // 1 ERG: 1/160 = 0.00625 ERG.
        assert_eq!(service_fee(erg, 1_000_000_000), 6_250_000);
        // 20 ERG: still 1/160.
        assert_eq!(service_fee(erg, 20_000_000_000), 125_000_000);
        // 100 ERG: 20/160 + 80/200 = 0.125 + 0.4.
        assert_eq!(service_fee(erg, 100_000_000_000), 525_000_000);
        // 300 ERG: 0.125 + 180/200 + 100/250 = 0.125 + 0.9 + 0.4.
        assert_eq!(service_fee(erg, 300_000_000_000), 1_425_000_000);
        // Tiny amounts pay the minimum box.
        assert_eq!(service_fee(erg, 1_000), 1_000_000);
    }

    #[test]
    fn a_deposit_splits_so_that_fee_and_pool_share_fit_exactly() {
        let erg = &POOLS[0];
        for total in [
            1_000_000_000i64,
            1_006_250_000,
            50_000_000_000,
            123_456_789_012,
        ] {
            let (given, fee) = split_for_deposit(erg, total);
            assert!(given + service_fee(erg, given) <= total, "{total}");
            assert!(
                given + 1 + service_fee(erg, given + 1) > total,
                "{total}: not maximal"
            );
            assert_eq!(fee, total - given);
            assert!(fee >= service_fee(erg, given));
        }
        // A token pool's minimum is one unit.
        let sigusd = &POOLS[1];
        assert_eq!(service_fee(sigusd, 10), 1);
        assert_eq!(
            split_for_deposit(sigusd, 2000).0 + split_for_deposit(sigusd, 2000).1,
            2000
        );
    }
}
