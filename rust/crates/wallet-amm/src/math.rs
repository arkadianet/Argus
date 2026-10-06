//! Constant-product arithmetic exactly as the pool contract checks it.
//!
//! Integer results follow the contract's inequality (see [`crate::contract`]):
//! outputs round down, required inputs round up. The vendored calculator
//! adds one to a floored division instead of taking the ceiling, which
//! overpays by a unit whenever the division is exact; Pantheon's ergo-pricing
//! takes the true ceiling, and that is what is used here.
//!
//! Products stay in `u128` when they fit and fall back to arbitrary
//! precision when they do not, so no reserve or amount a box can hold
//! overflows.

use num_bigint::BigUint;

use crate::contract::FEE_DENOM;

/// `a * b * c` when it fits in `u128`.
fn mul3(a: u64, b: u64, c: u64) -> Option<u128> {
    (a as u128).checked_mul(b as u128)?.checked_mul(c as u128)
}

fn big(a: u64) -> BigUint {
    BigUint::from(a)
}

/// The most a swap of `amount_in` may take out of `reserve_out`, for a pool
/// whose fee numerator is `fee_num`. Zero when nothing comes out.
pub fn swap_output(reserve_in: u64, reserve_out: u64, amount_in: u64, fee_num: u32) -> u64 {
    if reserve_in == 0 || reserve_out == 0 || amount_in == 0 || fee_num == 0 {
        return 0;
    }
    let f = fee_num as u64;
    let d = FEE_DENOM as u64;
    // Both denominator terms are below 2^64 * 2^10, so their sum fits.
    let den = reserve_in as u128 * d as u128 + amount_in as u128 * f as u128;
    let out = match mul3(reserve_out, amount_in, f) {
        Some(num) => num / den,
        None => {
            let q = big(reserve_out) * big(amount_in) * big(f) / BigUint::from(den);
            // The quotient is below reserve_out, so it fits in u64.
            u64::try_from(q).unwrap_or(0) as u128
        }
    };
    out as u64
}

/// The least input that makes the pool pay `amount_out`, or `None` when the
/// pool cannot pay that much at any price.
pub fn swap_input(reserve_in: u64, reserve_out: u64, amount_out: u64, fee_num: u32) -> Option<u64> {
    if reserve_in == 0 || reserve_out == 0 || amount_out == 0 || fee_num == 0 {
        return None;
    }
    if amount_out >= reserve_out {
        return None;
    }
    let f = fee_num as u64;
    let d = FEE_DENOM as u64;
    let den = (reserve_out - amount_out) as u128 * f as u128;
    match mul3(reserve_in, amount_out, d) {
        Some(num) => u64::try_from(num.div_ceil(den)).ok(),
        None => {
            let num = big(reserve_in) * big(amount_out) * big(d);
            let den = BigUint::from(den);
            let q = (num + &den - 1u32) / den;
            u64::try_from(q).ok()
        }
    }
}

/// How far a trade of `amount_in` moves a pool holding `reserve_in` of the
/// input, in percent. Reserve-based like the rest of the app, so the floor
/// on a low-decimal output does not read as impact.
pub fn price_impact_pct(reserve_in: u64, amount_in: u64) -> f64 {
    if reserve_in == 0 && amount_in == 0 {
        return 0.0;
    }
    amount_in as f64 / (reserve_in as f64 + amount_in as f64) * 100.0
}

/// A chain of swaps folded into one curve, `out(x) = a·x / (c·x + 1)`.
///
/// One swap without rounding is `out = R_out·γ·x / (R_in + γ·x)` with
/// `γ = feeNum / FeeDenom`, a fractional-linear map; composing any number
/// of them gives another. That turns sizing a cyclic trade from a blind
/// search into a formula: the cycle is profitable at some size exactly when
/// its marginal rate `a` exceeds 1, the best input is
/// `x* = (√a − 1) / c`, and the most it can make before fees is
/// `(√a − 1)² / c`. The vendored router and Pantheon both ternary-search
/// every cycle over its whole range instead.
///
/// The integer swaps can only round down, so the true profit never beats
/// [`Curve::max_profit`]; it is a safe bound to discard cycles with.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Curve {
    pub a: f64,
    pub c: f64,
}

impl Curve {
    /// The identity curve, `out(x) = x`.
    pub fn identity() -> Self {
        Curve { a: 1.0, c: 0.0 }
    }

    /// This curve followed by one more swap.
    pub fn then(self, reserve_in: u64, reserve_out: u64, fee_num: u32) -> Self {
        let g = fee_num as f64 / FEE_DENOM as f64;
        let rin = reserve_in as f64;
        let p = reserve_out as f64 * g / rin;
        let q = g / rin;
        Curve {
            a: p * self.a,
            c: q * self.a + self.c,
        }
    }

    pub fn output(&self, x: f64) -> f64 {
        self.a * x / (self.c * x + 1.0)
    }

    /// Input with the most profit, or `None` when no size is profitable.
    pub fn best_input(&self) -> Option<f64> {
        if !(self.a > 1.0) || !(self.c > 0.0) || !self.a.is_finite() {
            return None;
        }
        Some((self.a.sqrt() - 1.0) / self.c)
    }

    /// Profit at [`Curve::best_input`], before fees and rounding.
    pub fn max_profit(&self) -> f64 {
        match self.best_input() {
            Some(_) => (self.a.sqrt() - 1.0).powi(2) / self.c,
            None => 0.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The contract's own check, used to prove the integer helpers sit
    /// exactly on its boundary.
    fn contract_accepts(r_in: u64, r_out: u64, din: u64, dout: u64, f: u32) -> bool {
        let lhs = big(r_out) * big(din) * big(f as u64);
        let rhs = big(dout) * (big(r_in) * big(FEE_DENOM as u64) + big(din) * big(f as u64));
        lhs >= rhs
    }

    #[test]
    fn golden_values_match_hand_computation() {
        // (500000 * 1e9 * 997) / (1e11 * 1000 + 1e9 * 997) = 4935.38… → 4935
        assert_eq!(
            swap_output(100_000_000_000, 500_000, 1_000_000_000, 997),
            4935
        );
        assert_eq!(swap_output(1000, 2000, 100, 997), 181);
    }

    #[test]
    fn output_is_the_largest_amount_the_contract_accepts() {
        let cases = [
            (100_000_000_000u64, 500_000u64, 1_000_000_000u64, 997u32),
            (1_000, 2_000, 100, 997),
            (7_777_777, 13, 1, 990),
            (u64::MAX / 3, u64::MAX / 5, u64::MAX / 7, 995),
        ];
        for (r_in, r_out, din, f) in cases {
            let out = swap_output(r_in, r_out, din, f);
            assert!(
                contract_accepts(r_in, r_out, din, out, f),
                "{out} must be valid"
            );
            assert!(
                !contract_accepts(r_in, r_out, din, out + 1, f),
                "{} must not be",
                out + 1
            );
        }
    }

    #[test]
    fn input_is_the_least_amount_the_contract_accepts() {
        let cases = [
            (100_000_000_000u64, 500_000u64, 4_935u64, 997u32),
            (1_000, 2_000, 181, 997),
            (10_000, 20_000, 1_000, 1000),
            (u64::MAX / 3, u64::MAX / 5, u64::MAX / 11, 995),
        ];
        for (r_in, r_out, out, f) in cases {
            let din = swap_input(r_in, r_out, out, f).expect("payable");
            assert!(contract_accepts(r_in, r_out, din, out, f));
            assert!(
                !contract_accepts(r_in, r_out, din - 1, out, f),
                "{din} is the minimum"
            );
            assert!(swap_output(r_in, r_out, din, f) >= out);
        }
    }

    #[test]
    fn exact_division_does_not_overpay() {
        // 10_000 * 1_000 * 1000 / ((20_000 - 1_000) * 1000) is not exact,
        // but 1_000 * 10 * 1000 / ((20 - 10) * 1000) = 1000 exactly: the
        // ceiling is 1000 where floor + 1 would ask for 1001.
        assert_eq!(swap_input(1_000, 20, 10, 1000), Some(1000));
    }

    #[test]
    fn unpayable_and_degenerate_requests() {
        assert_eq!(swap_input(1_000, 2_000, 2_000, 997), None);
        assert_eq!(swap_input(1_000, 2_000, 0, 997), None);
        assert_eq!(swap_input(0, 2_000, 1, 997), None);
        assert_eq!(swap_output(0, 2_000, 10, 997), 0);
        assert_eq!(swap_output(1_000, 2_000, 10, 0), 0);
    }

    #[test]
    fn curve_matches_the_unrounded_swaps() {
        let c = Curve::identity()
            .then(100_000_000_000, 1_000_000, 997)
            .then(1_000_000, 120_000_000_000, 997);
        // Two pools pricing the token 100 vs 120 nanoERG per unit.
        let x = 1_000_000_000.0;
        let step1 = 1_000_000.0 * 0.997 * x / (100_000_000_000.0 + 0.997 * x);
        let step2 = 120_000_000_000.0 * 0.997 * step1 / (1_000_000.0 + 0.997 * step1);
        assert!((c.output(x) - step2).abs() / step2 < 1e-12);
        let best = c.best_input().expect("profitable");
        // The derivative of the profit vanishes at the optimum.
        let h = best * 1e-6;
        let slope =
            (c.output(best + h) - (best + h) - (c.output(best - h) - (best - h))) / (2.0 * h);
        assert!(slope.abs() < 1e-6, "slope {slope}");
        assert!((c.max_profit() - (c.output(best) - best)).abs() < 1.0);
    }

    #[test]
    fn a_fair_cycle_has_no_profitable_size() {
        let c = Curve::identity()
            .then(100_000_000_000, 1_000_000, 997)
            .then(1_000_000, 100_000_000_000, 997);
        assert!(c.best_input().is_none());
        assert_eq!(c.max_profit(), 0.0);
    }
}
