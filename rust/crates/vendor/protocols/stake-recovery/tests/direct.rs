mod common;
use common::{reidentify, Historical, ERGOPAD};
use ergo_tx::{Eip12Asset, Eip12InputBox};
use ergotree_ir::{mir::constant::Constant, serialization::SigmaSerializable};
use stake_recovery::{
    direct::{self, DirectRequest},
    Pool, StakeBox,
};

fn run(
    inputs: &[Eip12InputBox],
) -> Result<ergo_tx::Eip12UnsignedTx, stake_recovery::RecoveryError> {
    let h = Historical::load(ERGOPAD);
    let key = *StakeBox::parse(&h.inputs[1], Pool::Ergopad)
        .unwrap()
        .key_id();
    direct::build(&DirectRequest {
        inputs,
        key: &key,
        recipient: &h.inputs[2].ergo_tree,
        wallet_trees: &[h.inputs[2].ergo_tree.clone()],
        height: 1765291,
        miner_fee: 1_100_000,
    })
}

#[test]
fn native_builder_reduces_protocol_true_and_wallet_to_its_exact_key() {
    let h = Historical::load(ERGOPAD);
    let tx = run(&h.inputs).unwrap();
    direct::reduce(&tx, &h.context).unwrap();
    assert_eq!(
        tx.inputs.iter().map(|b| &b.box_id).collect::<Vec<_>>(),
        h.inputs.iter().map(|b| &b.box_id).collect::<Vec<_>>()
    );
    assert_eq!(tx.outputs.len(), 5);
    assert_eq!(tx.outputs[3].value, "1100000");
    assert_eq!(tx.outputs[4].value, "1100000");
    assert_eq!(tx.outputs[2].ergo_tree, h.inputs[2].ergo_tree);
    for asset in &h.inputs[2].assets {
        let returned = tx.outputs[2]
            .assets
            .iter()
            .find(|a| a.token_id == asset.token_id)
            .unwrap();
        assert_eq!(returned.amount, asset.amount);
    }
}

#[test]
fn builder_refuses_adversarial_actual_inputs() {
    let h = Historical::load(ERGOPAD);
    for case in 0..23 {
        let mut inputs = h.inputs.clone();
        match case {
            0 => {
                inputs[1].assets[0].token_id = "01".repeat(32);
                reidentify(&mut inputs[1]);
            }
            1 | 2 => {
                let i = case - 1;
                inputs[i].assets.push(Eip12Asset::new("01".repeat(32), 1));
                reidentify(&mut inputs[i]);
            }
            3 => {
                inputs[0].additional_registers.insert(
                    "R4".into(),
                    hex::encode(
                        Constant::from(vec![24832149129i64, 1096, 1982, 1740595860900, 86400000])
                            .sigma_serialize_bytes()
                            .unwrap(),
                    ),
                );
                reidentify(&mut inputs[0]);
            }
            4 => inputs.swap(0, 1),
            5 => inputs.swap(1, 2),
            6 => inputs.push(inputs[2].clone()),
            7 => {
                inputs[1]
                    .additional_registers
                    .insert("R4".into(), "zz".into());
            }
            8 => {
                inputs[1].additional_registers.insert(
                    "R4".into(),
                    hex::encode(
                        Constant::from(vec![1095i32, 1])
                            .sigma_serialize_bytes()
                            .unwrap(),
                    ),
                );
                reidentify(&mut inputs[1]);
            }
            9 => {
                inputs[0].assets[1].amount = i64::MAX.to_string();
                reidentify(&mut inputs[0]);
            }
            10 => inputs[2].value = "9223372036854775808".into(),
            11 => {
                inputs[1].assets[0].amount = "2".into();
                reidentify(&mut inputs[1]);
            }
            12 => {
                inputs[0].assets[0].token_id = "01".repeat(32);
                reidentify(&mut inputs[0]);
            }
            13 => {
                inputs[1].additional_registers.insert(
                    "R5".into(),
                    hex::encode(
                        Constant::from(vec![1u8; 32])
                            .sigma_serialize_bytes()
                            .unwrap(),
                    ),
                );
                reidentify(&mut inputs[1]);
            }
            14 => {
                inputs[2].assets[1].amount = "2".into();
                reidentify(&mut inputs[2]);
            }
            15 => {
                inputs[2].value = "1000000".into();
                reidentify(&mut inputs[2]);
            }
            16 => {
                inputs[1].ergo_tree = hex::encode(
                    Pool::Egio
                        .contracts()
                        .stake_tree()
                        .unwrap()
                        .sigma_serialize_bytes()
                        .unwrap(),
                );
                reidentify(&mut inputs[1]);
            }
            17 => {
                inputs[0].assets[0].amount = "2".into();
                reidentify(&mut inputs[0]);
            }
            18 | 19 => {
                let r4 = if case == 18 {
                    vec![1i64, 1095, 1982, 1740595860900, 86400000]
                } else {
                    vec![24832149129i64, 1095, 0, 1740595860900, 86400000]
                };
                inputs[0].additional_registers.insert(
                    "R4".into(),
                    hex::encode(Constant::from(r4).sigma_serialize_bytes().unwrap()),
                );
                reidentify(&mut inputs[0]);
            }
            20 => inputs[1].assets[1].amount = "0".into(),
            21 => {
                inputs[1].additional_registers.remove("R5");
                reidentify(&mut inputs[1]);
            }
            22 => {
                inputs[1].additional_registers.insert(
                    "R5".into(),
                    hex::encode(
                        Constant::from(vec![1u8; 31])
                            .sigma_serialize_bytes()
                            .unwrap(),
                    ),
                );
                reidentify(&mut inputs[1]);
            }
            _ => unreachable!(),
        }
        assert!(run(&inputs).is_err(), "accepted case {case}");
    }
}

#[test]
fn wallet_policy_refuses_foreign_recipient_and_layout_or_burn_edits() {
    let h = Historical::load(ERGOPAD);
    let key = *StakeBox::parse(&h.inputs[1], Pool::Ergopad)
        .unwrap()
        .key_id();
    let trees = [h.inputs[2].ergo_tree.clone()];
    let mut request = DirectRequest {
        inputs: &h.inputs,
        key: &key,
        recipient: &trees[0],
        wallet_trees: &trees,
        height: 1765291,
        miner_fee: 1_100_000,
    };
    let tx = direct::build(&request).unwrap();
    for case in 0..9 {
        let mut changed = tx.clone();
        match case {
            0 => changed.outputs.swap(0, 1),
            1 => changed.outputs.swap(1, 2),
            2 => changed.inputs.swap(1, 2),
            3 => {
                changed.outputs[2].assets.remove(0);
            }
            4 => changed.outputs[3].value = "1100001".into(),
            5 => changed.outputs[1].assets[0].amount = "614683".into(),
            6 => {
                changed.outputs.pop();
            }
            7 => changed.outputs[2]
                .assets
                .retain(|a| a.token_id != hex::encode(key)),
            8 => {
                changed.outputs[2].ergo_tree =
                    ergo_tx::address_to_ergo_tree(direct::APP_FEE_ADDRESS).unwrap()
            }
            _ => unreachable!(),
        }
        assert!(direct::validate(&request, &changed).is_err());
    }
    let foreign = ergo_tx::address_to_ergo_tree(direct::APP_FEE_ADDRESS).unwrap();
    request.recipient = &foreign;
    assert!(direct::build(&request).is_err());
    // Recipient theft can satisfy the contracts; wallet policy must stop it.
    let mut theft = tx;
    theft.outputs[2].ergo_tree = foreign;
    direct::reduce(&theft, &h.context).unwrap();
}

#[test]
fn contract_rejects_reordered_protocol_inputs_and_state_output() {
    let h = Historical::load(ERGOPAD);
    let tx = run(&h.inputs).unwrap();
    let mut changed = tx.clone();
    changed.inputs.swap(1, 2);
    assert!(direct::reduce(&changed, &h.context).is_err());
    let mut changed = tx;
    changed.outputs.swap(0, 1);
    assert!(direct::reduce(&changed, &h.context).is_err());
}

#[test]
fn conservation_with_additional_wallet_funding_and_distinct_wallet_change() {
    use std::collections::BTreeMap;
    let h = Historical::load(ERGOPAD);
    let mut inputs = h.inputs.clone();
    let mut extra = inputs[2].clone();
    extra.index += 1;
    extra.assets = vec![
        Eip12Asset::new("01".repeat(32), 123),
        Eip12Asset::new(Pool::Ergopad.contracts().reward_token, 7),
    ];
    reidentify(&mut extra);
    inputs.push(extra);
    let key = *StakeBox::parse(&inputs[1], Pool::Ergopad).unwrap().key_id();
    // Pure policy trusts this allow-list; real ownership is tested at the FFI.
    let change = ergo_tx::address_to_ergo_tree(direct::APP_FEE_ADDRESS).unwrap();
    let trees = [inputs[2].ergo_tree.clone(), change.clone()];
    let request = DirectRequest {
        inputs: &inputs,
        key: &key,
        recipient: &change,
        wallet_trees: &trees,
        height: 1765291,
        miner_fee: 1_100_000,
    };
    let tx = direct::build(&request).unwrap();
    direct::reduce(&tx, &h.context).unwrap();
    assert_eq!(tx.outputs[1].ergo_tree, inputs[2].ergo_tree);
    assert_eq!(tx.outputs[2].ergo_tree, change);
    let mut totals = BTreeMap::<String, i128>::new();
    for a in tx.inputs.iter().flat_map(|b| &b.assets) {
        *totals.entry(a.token_id.clone()).or_default() += a.amount.parse::<i128>().unwrap();
    }
    for a in tx.outputs.iter().flat_map(|b| &b.assets) {
        *totals.entry(a.token_id.clone()).or_default() -= a.amount.parse::<i128>().unwrap();
    }
    assert!(totals.values().all(|n| *n == 0));
    assert_eq!(
        tx.inputs
            .iter()
            .map(|b| b.value.parse::<i128>().unwrap())
            .sum::<i128>(),
        tx.outputs
            .iter()
            .map(|b| b.value.parse::<i128>().unwrap())
            .sum::<i128>()
    );
    assert_eq!(
        tx.outputs[2]
            .assets
            .iter()
            .find(|a| a.token_id == hex::encode(key))
            .unwrap()
            .amount,
        "1"
    );
    assert_eq!(
        tx.outputs[2]
            .assets
            .iter()
            .find(|a| a.token_id == "01".repeat(32))
            .unwrap()
            .amount,
        "123"
    );
}

#[test]
fn builder_refuses_integer_boundaries_foreign_funding_and_ambiguous_positions() {
    let h = Historical::load(ERGOPAD);
    let key = *StakeBox::parse(&h.inputs[1], Pool::Ergopad)
        .unwrap()
        .key_id();
    let trees = [h.inputs[2].ergo_tree.clone()];
    for fee in [i64::MIN, -1, 0, 999_999, i64::MAX] {
        assert!(direct::build(&DirectRequest {
            inputs: &h.inputs,
            key: &key,
            recipient: &trees[0],
            wallet_trees: &trees,
            height: 1765291,
            miner_fee: fee
        })
        .is_err());
    }
    for height in [i32::MIN, -1, 0] {
        assert!(direct::build(&DirectRequest {
            inputs: &h.inputs,
            key: &key,
            recipient: &trees[0],
            wallet_trees: &trees,
            height,
            miner_fee: 1_100_000
        })
        .is_err());
    }
    let mut inputs = h.inputs.clone();
    inputs[2].ergo_tree = ergo_tx::address_to_ergo_tree(direct::APP_FEE_ADDRESS).unwrap();
    reidentify(&mut inputs[2]);
    assert!(run(&inputs).is_err());
    let mut inputs = h.inputs.clone();
    let mut other = inputs[1].clone();
    other.index += 1;
    reidentify(&mut other);
    inputs.push(other);
    assert!(run(&inputs).is_err());
    let mut inputs = h.inputs.clone();
    inputs[2].assets[0].amount = i64::MAX.to_string();
    reidentify(&mut inputs[2]);
    let mut extra = inputs[2].clone();
    extra.index += 1;
    extra.assets = vec![Eip12Asset::new(inputs[2].assets[0].token_id.clone(), 1)];
    reidentify(&mut extra);
    inputs.push(extra);
    assert!(run(&inputs).is_err());
    let mut inputs = h.inputs.clone();
    inputs[2].value = i64::MAX.to_string();
    reidentify(&mut inputs[2]);
    assert!(run(&inputs).is_err());
}
