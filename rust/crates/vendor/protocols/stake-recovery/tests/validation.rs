mod common;

use common::{reidentify, Historical, ERGOPAD, REFUND, UNSTAKE};
use ergo_tx::Eip12InputBox;
use ergotree_ir::{mir::constant::Constant, serialization::SigmaSerializable};
use stake_recovery::{
    boxes::canonical_box, contracts::Pool, validation::*, PaideiaProxyBox, RecoveryError, StakeBox,
    StakeStateBox,
};

fn register(input: &mut Eip12InputBox, name: &str, c: Constant) {
    input
        .additional_registers
        .insert(name.into(), hex::encode(c.sigma_serialize_bytes().unwrap()));
    reidentify(input);
}

#[test]
fn historical_models_and_full_unstake_figures_match_outputs() {
    for (json, pool, amount, checkpoint) in [
        (ERGOPAD, Pool::Ergopad, 614_682, 1095),
        (UNSTAKE, Pool::Paideia, 850_495_800, 790),
    ] {
        let h = Historical::load(json);
        validate_unique_inputs(&h.inputs).unwrap();
        let state = StakeStateBox::parse(&h.inputs[0], pool).unwrap();
        let stake = StakeBox::parse(&h.inputs[1], pool).unwrap();
        let after = validate_full_unstake(&state, &stake).unwrap();
        assert_eq!(stake.reward_amount(), amount);
        assert_eq!(stake.checkpoint(), checkpoint);
        assert_eq!(after.payout, amount);
        let output: ergotree_ir::chain::ergo_box::ErgoBox =
            serde_json::from_value(h.evidence["transaction"]["outputs"][0].clone()).unwrap();
        let input =
            Eip12InputBox::from_ergo_box(&output, output.transaction_id.to_string(), output.index);
        let next = StakeStateBox::parse(&input, pool).unwrap();
        assert_eq!(after.remaining_staked, next.total_staked());
        assert_eq!(after.remaining_stakers, next.stakers());
        assert_eq!(after.returned_stake_tokens, next.stake_token_amount());
        assert_eq!(state.last_checkpoint_ms(), next.last_checkpoint_ms());
        assert_eq!(state.cycle_duration_ms(), next.cycle_duration_ms());
        if pool == Pool::Paideia {
            let proxy = PaideiaProxyBox::parse(&h.inputs[2]).unwrap();
            assert_eq!(
                validate_proxy_unstake(&state, &stake, &proxy).unwrap(),
                after
            );
        } else {
            validate_key_box(&h.inputs[2], stake.key_id()).unwrap();
        }
    }
}

#[test]
fn supplied_ids_must_bind_every_creation_field_and_content() {
    let h = Historical::load(ERGOPAD);
    for field in ["boxId", "transactionId", "index", "creationHeight", "value"] {
        let mut value = serde_json::to_value(&h.inputs[1]).unwrap();
        value[field] = match field {
            "boxId" | "transactionId" => serde_json::json!("00".repeat(32)),
            "index" => serde_json::json!(15),
            "creationHeight" => serde_json::json!(1471943),
            _ => serde_json::json!("1000001"),
        };
        let input = serde_json::from_value(value).unwrap();
        assert!(canonical_box(&input).is_err(), "accepted altered {field}");
    }
}

#[test]
fn foreign_box_with_matching_tree_and_key_is_not_a_position() {
    let h = Historical::load(ERGOPAD);
    let mut input = h.inputs[1].clone();
    input.assets[0].token_id = "01".repeat(32);
    reidentify(&mut input);
    assert!(StakeBox::parse(&input, Pool::Ergopad).is_err());
}

#[test]
fn full_tree_and_positional_tokens_bind_the_pool() {
    let h = Historical::load(ERGOPAD);
    assert!(StakeBox::parse(&h.inputs[1], Pool::Egio).is_err());
    let mut input = h.inputs[1].clone();
    input.ergo_tree = hex::encode(
        Pool::Egio
            .contracts()
            .stake_tree()
            .unwrap()
            .sigma_serialize_bytes()
            .unwrap(),
    );
    reidentify(&mut input);
    assert!(StakeBox::parse(&input, Pool::Ergopad).is_err());
    assert!(StakeBox::parse(&input, Pool::Egio).is_err());
    for i in [0, 1] {
        let mut input = h.inputs[i].clone();
        input.assets.swap(0, 1);
        reidentify(&mut input);
        if i == 0 {
            assert!(StakeStateBox::parse(&input, Pool::Ergopad).is_err());
        } else {
            assert!(StakeBox::parse(&input, Pool::Ergopad).is_err());
        }
    }
}

#[test]
fn protocol_boxes_reject_extra_assets_and_non_singletons() {
    let h = Historical::load(UNSTAKE);
    for i in 0..3 {
        for extra in [false, true] {
            let mut input = h.inputs[i].clone();
            if extra {
                input
                    .assets
                    .push(ergo_tx::Eip12Asset::new("01".repeat(32), 1));
            } else {
                input.assets[0].amount = "2".into();
            }
            reidentify(&mut input);
            let rejected = match i {
                0 => StakeStateBox::parse(&input, Pool::Paideia).is_err(),
                1 => StakeBox::parse(&input, Pool::Paideia).is_err(),
                _ => PaideiaProxyBox::parse(&input).is_err(),
            };
            assert!(rejected);
        }
    }
}

#[test]
fn registers_require_exact_long_types_and_lengths() {
    let h = Historical::load(UNSTAKE);
    for (i, len) in [(0, 5), (1, 2), (2, 1)] {
        for c in [
            Constant::from(vec![1i32; len]),
            Constant::from(vec![1i64; len + 1]),
            Constant::from(vec![1i64; len - 1]),
            Constant::from(1i64),
        ] {
            let mut input = h.inputs[i].clone();
            register(&mut input, "R4", c);
            let rejected = match i {
                0 => StakeStateBox::parse(&input, Pool::Paideia).is_err(),
                1 => StakeBox::parse(&input, Pool::Paideia).is_err(),
                _ => PaideiaProxyBox::parse(&input).is_err(),
            };
            assert!(rejected);
        }
    }
}

#[test]
fn stake_key_requires_exactly_32_bytes_and_cannot_be_a_pool_asset() {
    let h = Historical::load(ERGOPAD);
    for c in [
        Constant::from(vec![1u8; 31]),
        Constant::from(vec![1u8; 33]),
        Constant::from(vec![1i64; 32]),
        Constant::from(hex::decode(Pool::Ergopad.contracts().reward_token).unwrap()),
    ] {
        let mut input = h.inputs[1].clone();
        register(&mut input, "R5", c);
        assert!(StakeBox::parse(&input, Pool::Ergopad).is_err());
    }
}

#[test]
fn malformed_missing_extra_and_trailing_registers_are_rejected() {
    let h = Historical::load(ERGOPAD);
    for raw in ["zz", "11", "11020000ff"] {
        let mut input = h.inputs[1].clone();
        input.additional_registers.insert("R4".into(), raw.into());
        assert!(matches!(
            StakeBox::parse(&input, Pool::Ergopad),
            Err(RecoveryError::Register { .. })
        ));
    }
    let mut input = h.inputs[1].clone();
    input.additional_registers.remove("R5");
    reidentify(&mut input);
    assert!(StakeBox::parse(&input, Pool::Ergopad).is_err());
    register(&mut input, "R5", Constant::from(vec![1u8; 32]));
    register(&mut input, "R6", Constant::from(1i64));
    assert!(StakeBox::parse(&input, Pool::Ergopad).is_err());
    input
        .additional_registers
        .insert("R10".into(), "0502".into());
    assert!(canonical_box(&input).is_err());
}

#[test]
fn stale_checkpoint_insufficient_state_and_overflow_are_rejected() {
    let h = Historical::load(ERGOPAD);
    let stake = StakeBox::parse(&h.inputs[1], Pool::Ergopad).unwrap();
    for r4 in [
        vec![24832149129i64, 1096, 1982, 1740595860900, 86400000],
        vec![1, 1095, 1982, 1740595860900, 86400000],
        vec![24832149129, 1095, 0, 1740595860900, 86400000],
    ] {
        let mut input = h.inputs[0].clone();
        register(&mut input, "R4", Constant::from(r4));
        let state = StakeStateBox::parse(&input, Pool::Ergopad).unwrap();
        assert!(validate_full_unstake(&state, &stake).is_err());
    }
    let mut input = h.inputs[0].clone();
    input.assets[1].amount = i64::MAX.to_string();
    reidentify(&mut input);
    let state = StakeStateBox::parse(&input, Pool::Ergopad).unwrap();
    assert_eq!(
        validate_full_unstake(&state, &stake),
        Err(RecoveryError::Overflow("stake token reserve"))
    );
}

#[test]
fn signed_boundaries_and_nonpositive_amounts_are_rejected() {
    let h = Historical::load(UNSTAKE);
    for amount in [i64::MIN, -1, 0] {
        let mut input = h.inputs[2].clone();
        register(&mut input, "R4", Constant::from(vec![amount]));
        assert!(PaideiaProxyBox::parse(&input).is_err());
    }
    for r4 in [
        vec![-1i64, 1, 1, 1, 1],
        vec![1, -1, 1, 1, 1],
        vec![1, 1, -1, 1, 1],
        vec![1, 1, 1, -1, 1],
        vec![1, 1, 1, 1, 0],
    ] {
        let mut input = h.inputs[0].clone();
        register(&mut input, "R4", Constant::from(r4));
        assert!(StakeStateBox::parse(&input, Pool::Paideia).is_err());
    }
    for amount in ["0", "-1", "9223372036854775808"] {
        let mut input = h.inputs[1].clone();
        input.assets[1].amount = amount.into();
        assert!(canonical_box(&input).is_err());
    }
}

#[test]
fn proxy_must_match_the_actual_full_unstake_key_and_amount() {
    let h = Historical::load(UNSTAKE);
    let state = StakeStateBox::parse(&h.inputs[0], Pool::Paideia).unwrap();
    let stake = StakeBox::parse(&h.inputs[1], Pool::Paideia).unwrap();
    for amount in [1, i64::MAX] {
        let mut input = h.inputs[2].clone();
        register(&mut input, "R4", Constant::from(vec![amount]));
        let proxy = PaideiaProxyBox::parse(&input).unwrap();
        assert!(validate_proxy_unstake(&state, &stake, &proxy).is_err());
    }
    let proxy = PaideiaProxyBox::parse(&Historical::load(REFUND).inputs[0]).unwrap();
    assert!(validate_proxy_unstake(&state, &stake, &proxy).is_err());
}

#[test]
fn refund_parsing_is_independent_and_recipient_policy_is_explicit() {
    let h = Historical::load(REFUND);
    let proxy = PaideiaProxyBox::parse(&h.inputs[0]).unwrap();
    proxy.validate_recipient(proxy.recipient()).unwrap();
    let other = PaideiaProxyBox::parse(&Historical::load(UNSTAKE).inputs[2]).unwrap();
    assert!(proxy.validate_recipient(other.recipient()).is_err());
    for recipient in [vec![], vec![0xff], vec![0, 8, 0xcd], {
        let mut b = proxy.recipient().sigma_serialize_bytes().unwrap();
        b.push(0);
        b
    }] {
        let mut input = h.inputs[0].clone();
        register(&mut input, "R5", Constant::from(recipient));
        assert!(PaideiaProxyBox::parse(&input).is_err());
    }
}

#[test]
fn duplicate_inputs_tokens_and_ambiguous_positions_are_rejected() {
    let h = Historical::load(ERGOPAD);
    assert!(validate_unique_inputs(&[h.inputs[1].clone(), h.inputs[1].clone()]).is_err());
    let stake = StakeBox::parse(&h.inputs[1], Pool::Ergopad).unwrap();
    assert!(unique_position(
        &[stake.clone(), stake.clone()],
        Pool::Ergopad,
        stake.key_id()
    )
    .is_err());
    assert!(
        unique_position(std::slice::from_ref(&stake), Pool::Ergopad, stake.key_id())
            .unwrap()
            .is_some()
    );
    assert!(unique_position(&[stake], Pool::Ergopad, &[0; 32])
        .unwrap()
        .is_none());
    let mut input = h.inputs[2].clone();
    input.assets.push(input.assets[0].clone());
    assert!(canonical_box(&input).is_err());
}

#[test]
fn wallet_key_validation_preserves_unrelated_assets_but_rejects_wrong_quantity() {
    let h = Historical::load(ERGOPAD);
    let stake = StakeBox::parse(&h.inputs[1], Pool::Ergopad).unwrap();
    assert_eq!(h.inputs[2].assets.len(), 4);
    validate_key_box(&h.inputs[2], stake.key_id()).unwrap();
    let mut input = h.inputs[2].clone();
    input.assets[1].amount = "2".into();
    reidentify(&mut input);
    assert!(validate_key_box(&input, stake.key_id()).is_err());
    assert!(validate_key_box(&h.inputs[2], &[0; 32]).is_err());
}

#[test]
fn malformed_context_extensions_are_not_silently_ignored() {
    let h = Historical::load(ERGOPAD);
    for (key, value) in [
        ("256", "0502"),
        ("01", "0502"),
        ("x", "0502"),
        ("0", "zz"),
        ("0", "050200"),
    ] {
        let mut input = h.inputs[2].clone();
        input.extension.insert(key.into(), value.into());
        assert!(canonical_box(&input).is_err());
    }
    let mut input = h.inputs[2].clone();
    input.extension.insert("0".into(), "0502".into());
    canonical_box(&input).unwrap();
}
