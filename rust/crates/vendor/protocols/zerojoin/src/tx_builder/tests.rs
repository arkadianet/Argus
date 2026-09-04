//! Builder tests.
//!
//! The invariants checked here are the ones the deployed contracts check:
//! input and output *positions*, `INPUTS.size` / `OUTPUTS.size`, the mixing
//! token burn, and ERG conservation. A builder that gets any of them wrong
//! produces a transaction the network rejects — or, worse, one that strands a
//! box nobody can spend.

use super::*;
use crate::contracts::{
    FEE_EMISSION_ERGO_TREE_HEX, FULL_MIX_ERGO_TREE_HEX, HALF_MIX_ERGO_TREE_HEX,
    MIXER_INCOME_ERGO_TREE_HEX, TOKEN_EMISSION_ERGO_TREE_HEX,
};
use crate::testing::{
    fixture_fee_box, fixture_token_box, funding_box, synthetic_half_mix, synthetic_own_half_mix,
    synthetic_round, test_secret,
};

const RING: i64 = 1_000_000_000;
const FEE: i64 = 1_500_000;
const HEIGHT: i32 = 1_500_000;

const DESTINATION: &str = "0008cd0385d10043e1ff4a3bef3f99961d5f16e1f2978f900e16421d3998f8d09fd6412c";

fn trees(boxes: &[Eip12InputBox]) -> Vec<&str> {
    boxes.iter().map(|b| b.ergo_tree.as_str()).collect()
}

fn out_trees(outs: &[Eip12Output]) -> Vec<&str> {
    outs.iter().map(|b| b.ergo_tree.as_str()).collect()
}

// ---------------------------------------------------------------------------
// Remixing
// ---------------------------------------------------------------------------

#[test]
fn remix_as_alice_has_the_layout_the_full_mix_contract_demands() {
    let x = test_secret(1, 0);
    let y = test_secret(2, 0);
    let [bobs, alices] = synthetic_round(x.public_key(), &y, PairOrder::BobFirst, RING, 20);
    let next = test_secret(2, 1);
    let fee_box = fixture_fee_box();

    // Whoever we were last round, the shape is the same.
    for (secret, full) in [(&y, &bobs), (&x, &alices)] {
        let tx = build_remix_as_alice(&RemixAsAlice {
            full,
            current: secret,
            next_x: &next,
            fee_box: &fee_box,
            miner_fee: FEE,
            height: HEIGHT,
        })
        .expect("builds");

        // nextAlice = isHalf(OUTPUTS(0)) && INPUTS(1) is the fee emission box.
        assert_eq!(
            trees(&tx.unsigned_tx.inputs),
            vec![FULL_MIX_ERGO_TREE_HEX, FEE_EMISSION_ERGO_TREE_HEX]
        );
        assert_eq!(tx.unsigned_tx.outputs.len(), 3, "fee contract pins this");
        assert_eq!(tx.unsigned_tx.outputs[0].ergo_tree, HALF_MIX_ERGO_TREE_HEX);
        assert_eq!(
            tx.unsigned_tx.outputs[1].ergo_tree,
            FEE_EMISSION_ERGO_TREE_HEX
        );
        assert_eq!(mixing_tokens_burned(&tx.unsigned_tx), 1);
        assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
        assert_eq!(tx.prover_inputs.len(), 1);
        assert_eq!(tx.summary.mix_level_after, 19);
    }
}

#[test]
fn remix_as_alice_picks_a_dlog_proof_for_bobs_box_and_a_tuple_for_alices() {
    let x = test_secret(1, 0);
    let y = test_secret(2, 0);
    let [bobs, alices] = synthetic_round(x.public_key(), &y, PairOrder::BobFirst, RING, 20);
    let next = test_secret(2, 1);
    let fee_box = fixture_fee_box();

    let bob_tx = build_remix_as_alice(&RemixAsAlice {
        full: &bobs,
        current: &y,
        next_x: &next,
        fee_box: &fee_box,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap();
    assert!(matches!(bob_tx.prover_inputs[0], MixProverInput::Dlog(_)));

    let alice_tx = build_remix_as_alice(&RemixAsAlice {
        full: &alices,
        current: &x,
        next_x: &next,
        fee_box: &fee_box,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap();
    assert!(matches!(
        alice_tx.prover_inputs[0],
        MixProverInput::DhTuple(_)
    ));
}

#[test]
fn a_box_that_is_not_ours_cannot_be_remixed() {
    let x = test_secret(1, 0);
    let y = test_secret(2, 0);
    let stranger = test_secret(99, 99);
    let [bobs, _] = synthetic_round(x.public_key(), &y, PairOrder::BobFirst, RING, 20);
    let err = build_remix_as_alice(&RemixAsAlice {
        full: &bobs,
        current: &stranger,
        next_x: &test_secret(99, 100),
        fee_box: &fixture_fee_box(),
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap_err();
    assert!(matches!(err, ZeroJoinError::Invalid(_)));
}

#[test]
fn remix_as_bob_has_the_layout_both_mix_contracts_demand() {
    let x = test_secret(1, 0);
    let y = test_secret(2, 0);
    let [ours, _] = synthetic_round(x.public_key(), &y, PairOrder::BobFirst, RING, 20);
    let stranger = test_secret(50, 0);
    let half = synthetic_half_mix(*stranger.public_key(), RING, 30);
    let next = test_secret(2, 1);

    let tx = build_remix_as_bob(&RemixAsBob {
        half: &half,
        full: &ours,
        current: &y,
        next_y: &next,
        fee_box: &fixture_fee_box(),
        order: PairOrder::AliceFirst,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .expect("builds");

    // nextBob = isHalf(INPUTS(0)) && INPUTS(2) is the fee emission box;
    // bobFullLogic = INPUTS(1) is a full-mix box.
    assert_eq!(
        trees(&tx.unsigned_tx.inputs),
        vec![
            HALF_MIX_ERGO_TREE_HEX,
            FULL_MIX_ERGO_TREE_HEX,
            FEE_EMISSION_ERGO_TREE_HEX
        ]
    );
    assert_eq!(
        out_trees(&tx.unsigned_tx.outputs)[..3],
        [
            FULL_MIX_ERGO_TREE_HEX,
            FULL_MIX_ERGO_TREE_HEX,
            FEE_EMISSION_ERGO_TREE_HEX
        ]
    );
    assert_eq!(tx.unsigned_tx.outputs.len(), 4, "fee contract pins this");
    // 20 + 30 = 50; each output gets 24 and one unit is burned.
    assert_eq!(tx.summary.mix_level_after, 24);
    assert_eq!(mixing_tokens_burned(&tx.unsigned_tx), 2);
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
    // The half-mix box and our own box each need a proof.
    assert_eq!(tx.prover_inputs.len(), 2);
    assert!(matches!(tx.prover_inputs[0], MixProverInput::DhTuple(_)));
}

#[test]
fn remix_as_bob_refuses_a_half_mix_box_of_another_denomination() {
    let x = test_secret(1, 0);
    let y = test_secret(2, 0);
    let [ours, _] = synthetic_round(x.public_key(), &y, PairOrder::BobFirst, RING, 20);
    let half = synthetic_half_mix(*test_secret(50, 0).public_key(), RING / 2, 30);
    assert!(build_remix_as_bob(&RemixAsBob {
        half: &half,
        full: &ours,
        current: &y,
        next_y: &test_secret(2, 1),
        fee_box: &fixture_fee_box(),
        order: PairOrder::BobFirst,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .is_err());
}

// ---------------------------------------------------------------------------
// Leaving
// ---------------------------------------------------------------------------

#[test]
fn withdraw_burns_every_mixing_token_and_pays_out_the_full_denomination() {
    let x = test_secret(1, 0);
    let y = test_secret(2, 0);
    let [ours, _] = synthetic_round(x.public_key(), &y, PairOrder::BobFirst, RING, 20);

    let tx = build_withdraw(&Withdraw {
        full: &ours,
        current: &y,
        fee_box: &fixture_fee_box(),
        destination_ergo_tree: DESTINATION,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .expect("builds");

    assert_eq!(tx.unsigned_tx.inputs.len(), 2);
    assert_eq!(tx.unsigned_tx.outputs.len(), 3);
    assert_eq!(tx.unsigned_tx.outputs[0].ergo_tree, DESTINATION);
    // The whole denomination arrives: the operator's fee box paid the miner.
    assert_eq!(tx.unsigned_tx.outputs[0].value, RING.to_string());
    assert!(tx.unsigned_tx.outputs[0].assets.is_empty());
    assert_eq!(mixing_tokens_burned(&tx.unsigned_tx), 20);
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
}

#[test]
fn a_fee_above_the_boxs_maximum_is_refused_before_it_reaches_the_chain() {
    let x = test_secret(1, 0);
    let y = test_secret(2, 0);
    let [ours, _] = synthetic_round(x.public_key(), &y, PairOrder::BobFirst, RING, 20);
    let fee_box = fixture_fee_box();
    let err = build_withdraw(&Withdraw {
        full: &ours,
        current: &y,
        fee_box: &fee_box,
        destination_ergo_tree: DESTINATION,
        miner_fee: fee_box.max_fee + 1,
        height: HEIGHT,
    })
    .unwrap_err();
    assert!(matches!(err, ZeroJoinError::FeeTooLarge { .. }));
}

#[test]
fn reclaiming_an_unmatched_half_mix_box_pays_its_own_fee() {
    let x = test_secret(3, 0);
    let half = synthetic_own_half_mix(&x, RING, 20);

    let tx = build_reclaim_half_mix(&ReclaimHalfMix {
        half: &half,
        x: &x,
        destination_ergo_tree: DESTINATION,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .expect("builds");

    assert_eq!(tx.unsigned_tx.inputs.len(), 1);
    assert_eq!(tx.unsigned_tx.outputs.len(), 2);
    assert_eq!(
        tx.unsigned_tx.outputs[0].value,
        (RING - FEE).to_string(),
        "no fee emission box here, so the fee comes out of the box"
    );
    assert_eq!(mixing_tokens_burned(&tx.unsigned_tx), 20);
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
    assert!(matches!(tx.prover_inputs[0], MixProverInput::Dlog(_)));
}

#[test]
fn someone_elses_half_mix_box_cannot_be_reclaimed() {
    let mine = test_secret(3, 0);
    let theirs = test_secret(4, 0);
    let half = synthetic_own_half_mix(&theirs, RING, 20);
    assert!(build_reclaim_half_mix(&ReclaimHalfMix {
        half: &half,
        x: &mine,
        destination_ergo_tree: DESTINATION,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .is_err());
}

// ---------------------------------------------------------------------------
// Entering
// ---------------------------------------------------------------------------

#[test]
fn alice_entry_matches_the_token_emission_contracts_alice_branch() {
    let token_box = fixture_token_box();
    let level = token_box.levels()[0];
    let x = test_secret(5, 0);
    let fee = operator_fee(&token_box, RING, level).unwrap();
    let funding = funding_box(RING + FEE + fee.total(), vec![]);

    let tx = build_alice_entry(&AliceEntry {
        funding: &funding,
        token_box: &token_box,
        x: &x,
        denomination: RING,
        level,
        ring_token: None,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .expect("builds");

    // aliceBuying: INPUTS.size == 2, OUTPUTS.size == 4, isHalf(OUTPUTS(0)),
    // isCopy((OUTPUTS(2), OUTPUTS(1))).
    assert_eq!(tx.unsigned_tx.inputs.len(), 2);
    assert_eq!(tx.unsigned_tx.inputs[1].ergo_tree, TOKEN_EMISSION_ERGO_TREE_HEX);
    assert_eq!(tx.unsigned_tx.outputs.len(), 4);
    assert_eq!(
        out_trees(&tx.unsigned_tx.outputs)[..3],
        [
            HALF_MIX_ERGO_TREE_HEX,
            MIXER_INCOME_ERGO_TREE_HEX,
            TOKEN_EMISSION_ERGO_TREE_HEX
        ]
    );
    // The income box must cover the batch price plus the proportional cut.
    let income: i64 = tx.unsigned_tx.outputs[1].value.parse().unwrap();
    assert!(income >= fee.total(), "{income} < {}", fee.total());
    // Tokens move from the emission box to the half-mix box; none are burned.
    assert_eq!(mixing_tokens_burned(&tx.unsigned_tx), 0);
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
    assert_eq!(tx.summary.mix_level_after, level as i64);
}

#[test]
fn alice_entry_refuses_a_level_the_emission_box_does_not_sell() {
    let token_box = fixture_token_box();
    let bogus = token_box.levels().iter().max().unwrap() + 1;
    let funding = funding_box(10 * RING, vec![]);
    let err = build_alice_entry(&AliceEntry {
        funding: &funding,
        token_box: &token_box,
        x: &test_secret(5, 0),
        denomination: RING,
        level: bogus,
        ring_token: None,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap_err();
    assert!(matches!(err, ZeroJoinError::NoSuchBatch { .. }));
}

#[test]
fn alice_entry_refuses_funding_that_cannot_cover_the_operator_fee() {
    let token_box = fixture_token_box();
    let level = token_box.levels()[0];
    let funding = funding_box(RING + FEE, vec![]);
    let err = build_alice_entry(&AliceEntry {
        funding: &funding,
        token_box: &token_box,
        x: &test_secret(5, 0),
        denomination: RING,
        level,
        ring_token: None,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap_err();
    assert!(matches!(err, ZeroJoinError::InsufficientFunds { .. }));
}

#[test]
fn bob_entry_matches_the_token_emission_contracts_bob_branch() {
    let token_box = fixture_token_box();
    let level = *token_box.levels().iter().max().unwrap();
    let stranger = test_secret(60, 0);
    // `bobEntranceLogic` needs `bought * 2 > half_level`, so match the level.
    let half = synthetic_half_mix(*stranger.public_key(), RING, level as i64);
    let y = test_secret(6, 0);
    let fee = operator_fee(&token_box, RING, level).unwrap();
    let funding = funding_box(RING + FEE + fee.total(), vec![]);

    let tx = build_bob_entry(&BobEntry {
        half: &half,
        funding: &funding,
        token_box: &token_box,
        y: &y,
        level,
        order: PairOrder::BobFirst,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .expect("builds");

    // bobBuying: INPUTS.size == 3 with the half-mix box first,
    // OUTPUTS.size == 5, isCopy((OUTPUTS(3), OUTPUTS(2))).
    assert_eq!(
        trees(&tx.unsigned_tx.inputs),
        vec![
            HALF_MIX_ERGO_TREE_HEX,
            funding.ergo_tree.as_str(),
            TOKEN_EMISSION_ERGO_TREE_HEX
        ]
    );
    assert_eq!(tx.unsigned_tx.outputs.len(), 5);
    assert_eq!(
        out_trees(&tx.unsigned_tx.outputs)[..4],
        [
            FULL_MIX_ERGO_TREE_HEX,
            FULL_MIX_ERGO_TREE_HEX,
            MIXER_INCOME_ERGO_TREE_HEX,
            TOKEN_EMISSION_ERGO_TREE_HEX
        ]
    );
    // OUTPUTS(0).tokens(0)._2 * 2 > SELF.tokens(0)._2, the contract's rule.
    let per_output: i64 = tx.unsigned_tx.outputs[0].assets[0].amount.parse().unwrap();
    assert!(per_output * 2 > half.mix_level);
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
    assert_eq!(tx.prover_inputs.len(), 1);
}

#[test]
fn bob_entry_refuses_funding_that_cannot_cover_the_operator_fee() {
    let token_box = fixture_token_box();
    let level = token_box.levels()[0];
    let half = synthetic_half_mix(
        *test_secret(60, 0).public_key(),
        RING,
        level as i64,
    );
    let err = build_bob_entry(&BobEntry {
        half: &half,
        // Enough for the second mix box and the miner, nothing for the operator.
        funding: &funding_box(RING + FEE, vec![]),
        token_box: &token_box,
        y: &test_secret(6, 0),
        level,
        order: PairOrder::BobFirst,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap_err();
    assert!(matches!(err, ZeroJoinError::InsufficientFunds { .. }));
}

// ---------------------------------------------------------------------------
// Round trip
// ---------------------------------------------------------------------------

#[test]
fn a_three_round_mix_conserves_erg_and_walks_the_level_down() {
    let stranger = test_secret(70, 0);
    let fee_box = fixture_fee_box();
    let mut level = 30i64;

    // Round 0: we are Bob against a stranger's half-mix box.
    let y0 = test_secret(9, 0);
    let half0 = synthetic_half_mix(*stranger.public_key(), RING, level);
    // Our own box from a previous round, to remix with.
    let [ours, _] = synthetic_round(
        stranger.public_key(),
        &test_secret(8, 0),
        PairOrder::BobFirst,
        RING,
        level,
    );
    let tx = build_remix_as_bob(&RemixAsBob {
        half: &half0,
        full: &ours,
        current: &test_secret(8, 0),
        next_y: &y0,
        fee_box: &fee_box,
        order: PairOrder::BobFirst,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap();
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
    level = tx.summary.mix_level_after;

    // Round 1: we take the box that is ours and re-enter as Alice.
    let mine = crate::testing::full_mix_from_output(&tx.unsigned_tx.outputs[0]);
    assert!(y0.owns_as_bob(&mine));
    let x1 = test_secret(9, 1);
    let tx = build_remix_as_alice(&RemixAsAlice {
        full: &mine,
        current: &y0,
        next_x: &x1,
        fee_box: &fee_box,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap();
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
    assert_eq!(tx.summary.mix_level_after, level - 1);

    // Round 2: a stranger takes our half-mix box; the box that comes back is
    // ours as Alice, and we withdraw it.
    let posted = crate::testing::synthetic_own_half_mix(&x1, RING, level - 1);
    let their_y = test_secret(71, 0);
    let round = crate::testing::synthetic_round(
        &posted.g_x,
        &their_y,
        PairOrder::AliceFirst,
        RING,
        level - 2,
    );
    let ours_now = round
        .iter()
        .find(|f| x1.owns_as_alice(f))
        .expect("one of the two is ours");
    let tx = build_withdraw(&Withdraw {
        full: ours_now,
        current: &x1,
        fee_box: &fee_box,
        destination_ergo_tree: DESTINATION,
        miner_fee: FEE,
        height: HEIGHT,
    })
    .unwrap();
    assert_eq!(erg_imbalance(&tx.unsigned_tx), 0);
    assert_eq!(tx.unsigned_tx.outputs[0].value, RING.to_string());
}
