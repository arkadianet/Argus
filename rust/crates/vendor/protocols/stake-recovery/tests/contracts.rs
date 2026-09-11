mod common;

use common::{Historical, ERGOPAD as HISTORY, REFUND, UNSTAKE};
use ergotree_ir::serialization::SigmaSerializable;
use stake_recovery::contracts::*;

#[test]
fn derived_full_trees_equal_historical_protocol_inputs() {
    for (json, pool) in [(HISTORY, Pool::Ergopad), (UNSTAKE, Pool::Paideia)] {
        let h = Historical::load(json);
        let c = pool.contracts();
        assert_eq!(
            hex::encode(c.state_tree().unwrap().sigma_serialize_bytes().unwrap()),
            h.inputs[0].ergo_tree
        );
        assert_eq!(
            hex::encode(c.stake_tree().unwrap().sigma_serialize_bytes().unwrap()),
            h.inputs[1].ergo_tree
        );
    }
    let proxy = hex::encode(
        tree_from_address(PAIDEIA_PROXY_ADDRESS)
            .unwrap()
            .sigma_serialize_bytes()
            .unwrap(),
    );
    assert_eq!(proxy, Historical::load(UNSTAKE).inputs[2].ergo_tree);
    assert_eq!(proxy, Historical::load(REFUND).inputs[0].ergo_tree);
    let incentive = hex::encode(
        tree_from_address(PAIDEIA_INCENTIVE_ADDRESS)
            .unwrap()
            .sigma_serialize_bytes()
            .unwrap(),
    );
    assert_eq!(
        incentive,
        Historical::load(UNSTAKE).evidence["transaction"]["outputs"][2]["ergoTree"]
    );
}

#[test]
fn egio_and_ergopad_stake_templates_are_identical_but_full_trees_differ() {
    let ergopad = ERGOPAD.stake_tree().unwrap();
    let egio = EGIO.stake_tree().unwrap();
    assert_eq!(
        ergopad.template_bytes().unwrap(),
        egio.template_bytes().unwrap()
    );
    assert_ne!(
        ergopad.sigma_serialize_bytes().unwrap(),
        egio.sigma_serialize_bytes().unwrap()
    );
}

#[test]
fn all_registered_addresses_parse_and_egio_is_inactive() {
    for pool in [Pool::Ergopad, Pool::Paideia, Pool::Egio] {
        pool.contracts()
            .stake_tree()
            .unwrap()
            .proposition()
            .unwrap();
        pool.contracts()
            .state_tree()
            .unwrap()
            .proposition()
            .unwrap();
    }
    assert!(!Pool::Egio.contracts().active);
    assert!(Pool::Ergopad.contracts().active);
    assert!(Pool::Paideia.contracts().active);
}

#[test]
fn incentive_preimage_and_fixed_values_match_the_proxy_and_history() {
    use ergotree_ir::mir::constant::TryExtractInto;
    verify_incentive_commitment().unwrap();
    let proxy = tree_from_address(PAIDEIA_PROXY_ADDRESS).unwrap();
    for (index, expected) in [
        (16, INCENTIVE_VALUE),
        (18, EXECUTOR_VALUE),
        (20, EXECUTION_FEE),
        (24, REFUND_FEE),
    ] {
        assert_eq!(
            proxy
                .get_constant(index)
                .unwrap()
                .unwrap()
                .try_extract_into::<i64>()
                .unwrap(),
            expected
        );
    }
    let h = Historical::load(UNSTAKE);
    for (i, amount) in [
        (2, INCENTIVE_VALUE),
        (3, EXECUTOR_VALUE),
        (4, EXECUTION_FEE),
    ] {
        assert_eq!(
            h.evidence["transaction"]["outputs"][i]["value"]
                .as_i64()
                .unwrap(),
            amount
        );
    }
}
