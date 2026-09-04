//! The round model: pure functions from boxes and secrets to outputs.
//!
//! Nothing here touches the network or builds a transaction; everything is a
//! total function of its arguments, so the accounting the contracts enforce
//! can be tested exhaustively. [`crate::tx_builder`] assembles these outputs
//! into transactions.
//!
//! ## What a round costs in mixing tokens
//!
//! Every mixing transaction burns one or two units of the mixing token, and
//! the fee emission contract checks the burn: it is what stops the operator's
//! fee box from being drained by transactions that are not mixes.
//!
//! - remix as Alice (full → half): burns exactly 1, from one input box.
//! - remix as Bob (full + half → full + full): the two inputs' levels are
//!   pooled, each output gets `(total - 1) / 2`, and `total - 2 * that` — one
//!   or two units — is burned.
//! - entering as Bob with a freshly bought batch: outputs get
//!   `(half_level + bought) / 2` each and the remainder is burned.
//! - withdrawing: every remaining unit is burned.

use std::collections::HashMap;

use ergo_chain_types::EcPoint;
use ergo_tx::{Eip12Asset, Eip12Output};

use crate::boxes::{coll_byte_register, group_element_register, FullMixBox, HalfMixBox};
use crate::contracts::{
    FULL_MIX_ERGO_TREE_HEX, HALF_MIX_ERGO_TREE_HEX, HALF_MIX_SCRIPT_HASH_HEX, MIXING_TOKEN_ID,
};
use crate::error::ZeroJoinError;
use crate::secret::MixSecret;

/// How the honest pair `(gY, gXY)` is written into the two full-mix boxes.
///
/// Bob must choose this uniformly at random and must not remember it in a way
/// anyone else can recover: it *is* the mix. The choice is the caller's so
/// that the round model stays deterministic and testable, and so the source
/// of randomness is the wallet's, not this crate's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairOrder {
    /// `OUTPUTS(0)` gets `(c1, c2) = (gXY, gY)`, so its `c2` is `g^y` and the
    /// first box is Bob's.
    BobFirst,
    /// `OUTPUTS(0)` gets `(c1, c2) = (gY, gXY)`, so `c2 = c1^x` and the first
    /// box is Alice's.
    AliceFirst,
}

impl PairOrder {
    /// Pick from a single random bit, matching ErgoMixer's `Random.nextBoolean`.
    pub fn from_bit(bit: bool) -> Self {
        if bit {
            PairOrder::BobFirst
        } else {
            PairOrder::AliceFirst
        }
    }
}

/// Mixing-token accounting for one transaction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MixTokenSplit {
    /// Units on each full-mix output (or on the single half-mix output).
    pub per_output: i64,
    /// Units destroyed. The fee emission contract checks this exactly.
    pub burned: i64,
}

/// Tokens for a remix as Bob: pool both inputs, halve, burn the remainder.
///
/// The fee emission contract accepts a burn of 1 or 2 and nothing else, so
/// this errors rather than emitting a transaction that cannot validate.
pub fn remix_as_bob_tokens(
    full_level: i64,
    half_level: i64,
) -> Result<MixTokenSplit, ZeroJoinError> {
    if full_level < 1 || half_level < 1 {
        return Err(ZeroJoinError::TokenAccounting(format!(
            "both boxes need at least one mixing token (full={full_level}, half={half_level})"
        )));
    }
    let total = full_level + half_level;
    let per_output = (total - 1) / 2;
    let burned = total - per_output * 2;
    if !(1..=2).contains(&burned) {
        return Err(ZeroJoinError::TokenAccounting(format!(
            "burn of {burned} is outside the 1..=2 the fee contract allows"
        )));
    }
    Ok(MixTokenSplit {
        per_output,
        burned,
    })
}

/// Tokens for entering as Bob against a half-mix box, buying `bought` units.
///
/// The half-mix contract's `bobEntranceLogic` requires
/// `OUTPUTS(0).tokens(0)._2 * 2 > SELF.tokens(0)._2`, so a purchase too small
/// for the waiting box is rejected here rather than on chain.
pub fn enter_as_bob_tokens(
    half_level: i64,
    bought: i64,
) -> Result<MixTokenSplit, ZeroJoinError> {
    if bought < 1 {
        return Err(ZeroJoinError::TokenAccounting(
            "entering as Bob requires buying at least one mixing token".into(),
        ));
    }
    let total = half_level + bought;
    let per_output = total / 2;
    let burned = total - per_output * 2;
    if per_output * 2 <= half_level {
        return Err(ZeroJoinError::TokenAccounting(format!(
            "buying {bought} tokens is too few for a half-mix box at level {half_level}"
        )));
    }
    Ok(MixTokenSplit {
        per_output,
        burned,
    })
}

/// Tokens for a remix as Alice: exactly one unit burned.
pub fn remix_as_alice_tokens(full_level: i64) -> Result<MixTokenSplit, ZeroJoinError> {
    if full_level < 2 {
        return Err(ZeroJoinError::TokenAccounting(format!(
            "a full-mix box at level {full_level} cannot pay for another round; withdraw instead"
        )));
    }
    Ok(MixTokenSplit {
        per_output: full_level - 1,
        burned: 1,
    })
}

/// The pair `(c1, c2)` for `OUTPUTS(0)`; `OUTPUTS(1)` gets it reversed.
///
/// `gY = g^y` and `gXY = gX^y`. The box holding `c2 == gY` is spendable by
/// `proveDlog` with `y` (Bob's); the other is spendable by the DH tuple with
/// `x` (Alice's).
pub fn full_mix_pair(g_x: &EcPoint, y: &MixSecret, order: PairOrder) -> (EcPoint, EcPoint) {
    let g_y = *y.public_key();
    let g_xy = y.raise(g_x);
    match order {
        PairOrder::BobFirst => (g_xy, g_y),
        PairOrder::AliceFirst => (g_y, g_xy),
    }
}

fn assets(level: i64, mixing_token: &Option<(String, i64)>) -> Vec<Eip12Asset> {
    let mut v = vec![Eip12Asset::new(MIXING_TOKEN_ID, level)];
    if let Some((id, amount)) = mixing_token {
        v.push(Eip12Asset::new(id.clone(), *amount));
    }
    v
}

/// Registers of a full-mix output: R4 `c1`, R5 `c2`, R6 `gX`, R7 `delta`.
fn full_mix_registers(
    c1: &EcPoint,
    c2: &EcPoint,
    g_x: &EcPoint,
) -> Result<HashMap<String, String>, ZeroJoinError> {
    let delta = hex::decode(HALF_MIX_SCRIPT_HASH_HEX)
        .map_err(|_| ZeroJoinError::Serialization("half-mix script hash".into()))?;
    Ok(HashMap::from([
        ("R4".to_string(), group_element_register(c1)?),
        ("R5".to_string(), group_element_register(c2)?),
        ("R6".to_string(), group_element_register(g_x)?),
        ("R7".to_string(), coll_byte_register(&delta)?),
    ]))
}

/// The two full-mix outputs of a round, in transaction order.
///
/// Both carry the same value and the same tokens; only R4/R5 differ, swapped.
/// An observer cannot tell which is whose, which is the whole protocol.
pub fn full_mix_outputs(
    value: i64,
    g_x: &EcPoint,
    y: &MixSecret,
    order: PairOrder,
    split: MixTokenSplit,
    mixing_token: &Option<(String, i64)>,
    height: i32,
) -> Result<[Eip12Output; 2], ZeroJoinError> {
    let (c1, c2) = full_mix_pair(g_x, y, order);
    let tokens = assets(split.per_output, mixing_token);
    let make = |a: &EcPoint, b: &EcPoint| -> Result<Eip12Output, ZeroJoinError> {
        Ok(Eip12Output {
            value: value.to_string(),
            ergo_tree: FULL_MIX_ERGO_TREE_HEX.to_string(),
            assets: tokens.clone(),
            creation_height: height,
            additional_registers: full_mix_registers(a, b, g_x)?,
        })
    };
    Ok([make(&c1, &c2)?, make(&c2, &c1)?])
}

/// A half-mix output: the wallet re-entering as Alice for the next round.
pub fn half_mix_output(
    value: i64,
    next_x: &MixSecret,
    level: i64,
    mixing_token: &Option<(String, i64)>,
    height: i32,
) -> Result<Eip12Output, ZeroJoinError> {
    Ok(Eip12Output {
        value: value.to_string(),
        ergo_tree: HALF_MIX_ERGO_TREE_HEX.to_string(),
        assets: assets(level, mixing_token),
        creation_height: height,
        additional_registers: HashMap::from([(
            "R4".to_string(),
            group_element_register(next_x.public_key())?,
        )]),
    })
}

/// Everything a remix-as-Alice produces, before fee and change.
#[derive(Debug, Clone)]
pub struct AliceRound {
    pub half_mix: Eip12Output,
    pub tokens: MixTokenSplit,
}

/// Turn a full-mix box into the next round's half-mix box.
pub fn next_half_mix(
    full: &FullMixBox,
    next_x: &MixSecret,
    height: i32,
) -> Result<AliceRound, ZeroJoinError> {
    let tokens = remix_as_alice_tokens(full.mix_level)?;
    Ok(AliceRound {
        half_mix: half_mix_output(
            full.value,
            next_x,
            tokens.per_output,
            &full.mixing_token,
            height,
        )?,
        tokens,
    })
}

/// Everything a remix-as-Bob produces, before fee and change.
#[derive(Debug, Clone)]
pub struct BobRound {
    pub outputs: [Eip12Output; 2],
    pub tokens: MixTokenSplit,
}

/// Spend a half-mix box together with our own full-mix box of the same
/// denomination, producing the round's two full-mix outputs.
pub fn next_full_mix(
    full: &FullMixBox,
    half: &HalfMixBox,
    next_y: &MixSecret,
    order: PairOrder,
    height: i32,
) -> Result<BobRound, ZeroJoinError> {
    if full.value != half.value {
        return Err(ZeroJoinError::Invalid(format!(
            "denomination mismatch: full-mix box holds {} but the half-mix box holds {}",
            full.value, half.value
        )));
    }
    if full.mixing_token.as_ref().map(|(id, a)| (id.as_str(), *a))
        != half.mixing_token.as_ref().map(|(id, a)| (id.as_str(), *a))
    {
        return Err(ZeroJoinError::Invalid(
            "the two boxes are not in the same token ring".into(),
        ));
    }
    let tokens = remix_as_bob_tokens(full.mix_level, half.mix_level)?;
    Ok(BobRound {
        outputs: full_mix_outputs(
            full.value,
            &half.g_x,
            next_y,
            order,
            tokens,
            &full.mixing_token,
            height,
        )?,
        tokens,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{synthetic_full_mix, synthetic_half_mix, test_secret};

    #[test]
    fn remix_as_bob_pools_halves_and_burns_one_or_two() {
        // Odd total: one unit is burned.
        let s = remix_as_bob_tokens(51, 78).unwrap();
        assert_eq!(s.per_output, 64);
        assert_eq!(s.burned, 1);
        assert_eq!(s.per_output * 2 + s.burned, 51 + 78);
        // Even total: two are burned, because the halving rounds down from
        // `total - 1`.
        let s = remix_as_bob_tokens(50, 78).unwrap();
        assert_eq!(s.per_output, 63);
        assert_eq!(s.burned, 2);
        assert_eq!(s.per_output * 2 + s.burned, 128);
    }

    #[test]
    fn remix_as_bob_conserves_tokens_for_every_plausible_level() {
        for full in 1..80i64 {
            for half in 1..80i64 {
                let s = remix_as_bob_tokens(full, half).unwrap();
                assert_eq!(s.per_output * 2 + s.burned, full + half);
                assert!((1..=2).contains(&s.burned));
            }
        }
    }

    #[test]
    fn remix_as_bob_needs_a_token_on_each_side() {
        assert!(remix_as_bob_tokens(0, 10).is_err());
        assert!(remix_as_bob_tokens(10, 0).is_err());
    }

    #[test]
    fn remix_as_alice_burns_exactly_one() {
        let s = remix_as_alice_tokens(30).unwrap();
        assert_eq!(s, MixTokenSplit { per_output: 29, burned: 1 });
        // A box down to its last token has paid for its last round.
        assert!(remix_as_alice_tokens(1).is_err());
        assert!(remix_as_alice_tokens(0).is_err());
    }

    #[test]
    fn entering_as_bob_must_buy_enough_for_the_waiting_box() {
        // ErgoMixer's own rule: `per_output * 2 > half_level`.
        let s = enter_as_bob_tokens(90, 90).unwrap();
        assert_eq!(s.per_output, 90);
        assert_eq!(s.burned, 0, "an even total leaves nothing to burn");
        // A batch smaller than the waiting box is still fine, as long as the
        // halved total stays above it.
        assert_eq!(enter_as_bob_tokens(90, 30).unwrap().per_output, 60);
        // One token cannot lift a box of 90: 91 halves back down to 90.
        assert!(enter_as_bob_tokens(90, 1).is_err());
        assert!(enter_as_bob_tokens(90, 0).is_err());
        // An odd total burns the leftover unit.
        let s = enter_as_bob_tokens(89, 90).unwrap();
        assert_eq!(s.per_output, 89);
        assert_eq!(s.burned, 1);
    }

    #[test]
    fn the_two_full_mix_outputs_are_mirror_images() {
        let x = test_secret(1, 0);
        let y = test_secret(2, 0);
        let split = MixTokenSplit { per_output: 10, burned: 1 };
        let outs = full_mix_outputs(
            1_000_000_000,
            x.public_key(),
            &y,
            PairOrder::BobFirst,
            split,
            &None,
            1_000_000,
        )
        .unwrap();
        assert_eq!(outs[0].value, outs[1].value);
        assert_eq!(
            outs[0].assets.iter().map(|a| (&a.token_id, &a.amount)).collect::<Vec<_>>(),
            outs[1].assets.iter().map(|a| (&a.token_id, &a.amount)).collect::<Vec<_>>()
        );
        assert_eq!(outs[0].additional_registers["R4"], outs[1].additional_registers["R5"]);
        assert_eq!(outs[0].additional_registers["R5"], outs[1].additional_registers["R4"]);
        assert_eq!(outs[0].additional_registers["R6"], outs[1].additional_registers["R6"]);
        assert_eq!(outs[0].additional_registers["R7"], outs[1].additional_registers["R7"]);
    }

    #[test]
    fn the_order_swaps_which_box_belongs_to_whom() {
        let x = test_secret(1, 0);
        let y = test_secret(2, 0);
        let split = MixTokenSplit { per_output: 10, burned: 1 };
        let bob_first = full_mix_outputs(1, x.public_key(), &y, PairOrder::BobFirst, split, &None, 1).unwrap();
        let alice_first = full_mix_outputs(1, x.public_key(), &y, PairOrder::AliceFirst, split, &None, 1).unwrap();
        assert_eq!(bob_first[0].additional_registers, alice_first[1].additional_registers);
        assert_eq!(bob_first[1].additional_registers, alice_first[0].additional_registers);
        assert_ne!(PairOrder::from_bit(true), PairOrder::from_bit(false));
    }

    #[test]
    fn each_party_can_identify_and_only_identify_its_own_output() {
        let x = test_secret(1, 0);
        let y = test_secret(2, 0);
        for order in [PairOrder::BobFirst, PairOrder::AliceFirst] {
            let outs = full_mix_outputs(
                1_000_000_000,
                x.public_key(),
                &y,
                order,
                MixTokenSplit { per_output: 10, burned: 1 },
                &None,
                1,
            )
            .unwrap();
            let parsed: Vec<_> = outs
                .iter()
                .map(crate::testing::full_mix_from_output)
                .collect();
            let bob: Vec<_> = parsed.iter().filter(|f| y.owns_as_bob(f)).collect();
            let alice: Vec<_> = parsed.iter().filter(|f| x.owns_as_alice(f)).collect();
            assert_eq!(bob.len(), 1, "exactly one box is Bob's");
            assert_eq!(alice.len(), 1, "exactly one box is Alice's");
            assert_ne!(bob[0].c1, alice[0].c1, "and they are different boxes");
            // Neither can claim the other's.
            assert!(!x.owns_as_alice(bob[0]));
            assert!(!y.owns_as_bob(alice[0]));
        }
    }

    #[test]
    fn a_round_refuses_boxes_from_different_rings() {
        let x = test_secret(1, 0);
        let y = test_secret(2, 0);
        let full = synthetic_full_mix(x.public_key(), &y, PairOrder::BobFirst, 1_000_000_000, 20);
        let half = synthetic_half_mix(*x.public_key(), 500_000_000, 20);
        assert!(next_full_mix(&full, &half, &y, PairOrder::BobFirst, 1).is_err());
    }

    #[test]
    fn next_half_mix_carries_the_denomination_and_burns_one_token() {
        let x = test_secret(1, 0);
        let y = test_secret(2, 0);
        let full = synthetic_full_mix(x.public_key(), &y, PairOrder::BobFirst, 1_000_000_000, 20);
        let next = test_secret(1, 1);
        let round = next_half_mix(&full, &next, 900_000).unwrap();
        assert_eq!(round.half_mix.value, "1000000000");
        assert_eq!(round.tokens.burned, 1);
        assert_eq!(round.half_mix.assets[0].amount, "19");
        assert_eq!(
            round.half_mix.additional_registers["R4"],
            group_element_register(next.public_key()).unwrap()
        );
    }
}
