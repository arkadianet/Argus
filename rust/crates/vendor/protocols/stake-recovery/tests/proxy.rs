mod common;
use common::{reidentify, Historical, REFUND, UNSTAKE};
use ergo_tx::{Eip12Asset, Eip12InputBox};
use ergotree_ir::{
    mir::constant::Constant, serialization::SigmaSerializable,
    sigma_protocol::sigma_boolean::SigmaBoolean,
};
use stake_recovery::{proxy::*, PaideiaProxyBox};

fn creation_inputs(h: &Historical) -> (Vec<Eip12InputBox>, Vec<String>) {
    let recipient = hex::encode(
        PaideiaProxyBox::parse(&h.inputs[2])
            .unwrap()
            .recipient()
            .sigma_serialize_bytes()
            .unwrap(),
    );
    // Historical proxy's key and creation metadata at its authenticated payout
    // tree model the wallet key box consumed by creation, without fake box ids.
    let mut key = h.inputs[2].clone();
    key.ergo_tree = recipient.clone();
    key.additional_registers.clear();
    key.value = "200000000".into();
    reidentify(&mut key);
    (vec![key], vec![recipient])
}
fn request<'a>(
    h: &'a Historical,
    wallet: &'a [Eip12InputBox],
    trees: &'a [String],
) -> CreationRequest<'a> {
    CreationRequest {
        state: &h.inputs[0],
        stake: &h.inputs[1],
        wallet_inputs: wallet,
        wallet_trees: trees,
        recipient: &trees[0],
        height: h.inputs[2].creation_height,
        miner_fee: 1100000,
    }
}
#[test]
fn own_creation_reduces_exact_wallet_key_and_preflights_both_branches() {
    let h = Historical::load(UNSTAKE);
    let (wallet, trees) = creation_inputs(&h);
    let r = request(&h, &wallet, &trees);
    let tx = create(&r, &h.context).unwrap();
    assert_eq!(tx.outputs.len(), 4);
    assert_eq!(tx.outputs[0].assets[0].amount, "1");
    assert_eq!(tx.outputs[0].value, "104000000"); // 0.104 pinned + minimum payout - stake ERG
    assert!(tx.outputs[1].assets.is_empty());
    let unsigned = ergo_tx::chain::to_unsigned_transaction(&tx).unwrap();
    let reduced = ergo_lib::chain::transaction::reduced::reduce_tx(
        ergo_lib::wallet::tx_context::TransactionContext::new(
            unsigned,
            wallet
                .iter()
                .map(|b| stake_recovery::boxes::canonical_box(b).unwrap())
                .collect(),
            vec![],
        )
        .unwrap(),
        &h.context,
    )
    .unwrap();
    let expected =
        stake_recovery::contracts::tree_from_address(stake_recovery::direct::APP_FEE_ADDRESS)
            .unwrap();
    assert_ne!(
        hex::encode(expected.sigma_serialize_bytes().unwrap()),
        trees[0]
    );
    let reduced_inputs = reduced.reduced_inputs();
    let ergotree_ir::sigma_protocol::sigma_boolean::SigmaBoolean::ProofOfKnowledge(
        ergotree_ir::sigma_protocol::sigma_boolean::SigmaProofOfKnowledgeTree::ProveDlog(key),
    ) = &reduced_inputs.as_slice()[0].sigma_prop
    else {
        panic!("signature lost")
    };
    assert_eq!(
        format!(
            "0008cd{}",
            hex::encode(key.h.sigma_serialize_bytes().unwrap())
        ),
        trees[0]
    );
}
#[test]
fn refund_with_only_proxy_and_context_returns_key_and_erg_exactly() {
    let h = Historical::load(REFUND);
    assert_eq!(h.inputs.len(), 1);
    let proxy = h.inputs[0].clone();
    let context = h.context;
    drop(h.inputs);
    drop(h.boxes);
    let tx = refund(&proxy, proxy.creation_height).unwrap();
    validate_refund(&proxy, proxy.creation_height, &tx).unwrap();
    reduce(&tx, &context, true).unwrap();
    assert_eq!(tx.outputs[0].value, "112000000");
    assert_eq!(
        serde_json::to_value(&tx.outputs[0].assets).unwrap(),
        serde_json::to_value(&proxy.assets).unwrap()
    );
    let reduced = ergo_lib::chain::transaction::reduced::reduce_tx(
        ergo_lib::wallet::tx_context::TransactionContext::new(
            ergo_tx::chain::to_unsigned_transaction(&tx).unwrap(),
            vec![stake_recovery::boxes::canonical_box(&proxy).unwrap()],
            vec![],
        )
        .unwrap(),
        &context,
    )
    .unwrap();
    assert_eq!(
        reduced.reduced_inputs().as_slice()[0].sigma_prop,
        SigmaBoolean::TrivialProp(true)
    );
}
#[test]
fn output_edits_are_refused_by_rederivation() {
    let h = Historical::load(UNSTAKE);
    let (wallet, trees) = creation_inputs(&h);
    let r = request(&h, &wallet, &trees);
    let tx = create(&r, &h.context).unwrap();
    for n in 0..7 {
        let mut bad = tx.clone();
        match n {
            0 => bad.outputs.swap(0, 1),
            1 => {
                bad.outputs.pop();
            }
            2 => bad.outputs.push(tx.outputs[3].clone()),
            3 => bad.outputs[0].assets[0].amount = "2".into(),
            4 => bad.outputs[0]
                .additional_registers
                .insert(
                    "R4".into(),
                    hex::encode(Constant::from(vec![1i64]).sigma_serialize_bytes().unwrap()),
                )
                .map(|_| ())
                .unwrap(),
            5 => bad.outputs[0]
                .additional_registers
                .insert("R5".into(), "0e0100".into())
                .map(|_| ())
                .unwrap(),
            _ => bad.outputs[2].ergo_tree = trees[0].clone(),
        };
        assert!(validate_creation(&r, &bad).is_err(), "edit {n}");
    }
    let h = Historical::load(REFUND);
    let p = &h.inputs[0];
    let tx = refund(p, p.creation_height).unwrap();
    for n in 0..6 {
        let mut bad = tx.clone();
        match n {
            0 => bad.outputs.swap(0, 1),
            1 => bad.outputs.push(tx.outputs[1].clone()),
            2 => bad.outputs[0].assets.clear(),
            3 => bad.outputs[0].value = "111000000".into(),
            4 => bad.inputs.push(p.clone()),
            _ => bad.outputs[0].ergo_tree = trees[0].clone(),
        };
        assert!(validate_refund(p, p.creation_height, &bad).is_err());
    }
}
#[test]
fn actual_inputs_refuse_foreign_recipients_wrong_keys_duplicates_assets_and_boundaries() {
    let h = Historical::load(UNSTAKE);
    let (wallet, trees) = creation_inputs(&h);
    for n in 0..9 {
        let mut h = Historical::load(UNSTAKE);
        let mut wallet = wallet.clone();
        match n {
            0 => {
                wallet[0].assets[0].token_id = "12".repeat(32);
                reidentify(&mut wallet[0]);
            }
            1 => wallet.push(wallet[0].clone()),
            2 => {
                wallet[0].assets[0].amount = "2".into();
                reidentify(&mut wallet[0]);
            }
            3 => {
                h.inputs[1].assets.push(Eip12Asset::new("12".repeat(32), 1));
                reidentify(&mut h.inputs[1]);
            }
            4 => {
                h.inputs[1].additional_registers.insert(
                    "R4".into(),
                    hex::encode(
                        Constant::from(vec![i64::MAX, 0])
                            .sigma_serialize_bytes()
                            .unwrap(),
                    ),
                );
                reidentify(&mut h.inputs[1]);
            }
            5 => {
                wallet[0].value = "1000000".into();
                reidentify(&mut wallet[0]);
            }
            6 => wallet[0].value = "9223372036854775808".into(),
            7 => wallet[0]
                .extension
                .insert("0".into(), "0502".into())
                .map(|_| ())
                .unwrap_or(()),
            _ => {
                wallet[0].assets.push(Eip12Asset::new(
                    stake_recovery::Pool::Paideia.contracts().state_nft,
                    1,
                ));
                reidentify(&mut wallet[0]);
            }
        }
        assert!(
            create(&request(&h, &wallet, &trees), &h.context).is_err(),
            "case {n}"
        );
    }
    let mut r = request(&h, &wallet, &trees);
    r.height = i32::MAX;
    assert!(create(&r, &h.context).is_err());
    r.height = -1;
    assert!(create(&r, &h.context).is_err());
    r.height = h.inputs[2].creation_height;
    r.recipient = "00";
    assert!(create(&r, &h.context).is_err());
    let foreign = ergo_tx::address_to_ergo_tree(stake_recovery::direct::APP_FEE_ADDRESS).unwrap();
    r.recipient = &foreign;
    assert!(create(&r, &h.context).is_err());
    let h = Historical::load(REFUND);
    for value in ["1000000", "9223372036854775808", "-1"] {
        let mut p = h.inputs[0].clone();
        p.value = value.into();
        assert!(refund(&p, p.creation_height).is_err());
    }
}
#[test]
fn unrelated_funding_assets_survive_creation() {
    let h = Historical::load(UNSTAKE);
    let (mut wallet, trees) = creation_inputs(&h);
    wallet[0].assets.push(Eip12Asset::new("12".repeat(32), 7));
    reidentify(&mut wallet[0]);
    let tx = create(&request(&h, &wallet, &trees), &h.context).unwrap();
    assert_eq!(tx.outputs[1].assets[0].amount, "7");
    assert_eq!(tx.outputs[1].assets[0].token_id, "12".repeat(32));
}

#[test]
fn refund_refuses_extra_assets_malformed_registers_underfunding_and_context() {
    let h = Historical::load(REFUND);
    for case in 0..7 {
        let mut p = h.inputs[0].clone();
        match case {
            0 => p.assets.push(Eip12Asset::new("12".repeat(32), 1)),
            1 => p.assets[0].amount = "2".into(),
            2 => {
                p.additional_registers.insert(
                    "R4".into(),
                    hex::encode(Constant::from(vec![0i64]).sigma_serialize_bytes().unwrap()),
                );
            }
            3 => {
                p.additional_registers.insert(
                    "R4".into(),
                    hex::encode(Constant::from(vec![1i32]).sigma_serialize_bytes().unwrap()),
                );
            }
            4 => p.value = "1000000".into(),
            5 => {
                p.extension.insert("0".into(), "0502".into());
            }
            _ => p.creation_height += 1,
        }
        reidentify(&mut p);
        assert!(
            refund(&p, h.inputs[0].creation_height).is_err(),
            "refund case {case}"
        );
    }
}

#[test]
fn arithmetic_overflow_in_reserve_and_wallet_totals_is_refused() {
    let mut h = Historical::load(UNSTAKE);
    let (mut wallet, trees) = creation_inputs(&h);
    h.inputs[0].assets[1].amount = i64::MAX.to_string();
    reidentify(&mut h.inputs[0]);
    assert!(create(&request(&h, &wallet, &trees), &h.context).is_err());
    let h = Historical::load(UNSTAKE);
    wallet[0]
        .assets
        .push(Eip12Asset::new("12".repeat(32), i64::MAX));
    reidentify(&mut wallet[0]);
    let mut other = wallet[0].clone();
    other.index += 1;
    other.assets = vec![Eip12Asset::new("12".repeat(32), 1)];
    reidentify(&mut other);
    wallet.push(other);
    assert!(create(&request(&h, &wallet, &trees), &h.context).is_err());
}

#[test]
fn creation_uses_unmodified_historical_wallet_inputs_with_every_other_token_preserved() {
    let h = Historical::load(UNSTAKE);
    let creation = Historical::load(include_str!("fixtures/paideia-creation.json"));
    let key = h.inputs[2].assets[0].token_id.clone();
    let mut wallet = creation.inputs.clone();
    wallet.sort_by_key(|b| !b.assets.iter().any(|a| a.token_id == key));
    let trees = vec![wallet[0].ergo_tree.clone()];
    let tx = create(&request(&h, &wallet, &trees), &h.context).unwrap();
    assert_eq!(tx.inputs[0].box_id, creation.inputs[1].box_id);
    assert_eq!(tx.outputs[1].assets.len(), 10);
    assert_eq!(tx.outputs[0].assets[0].token_id, key);
    assert_eq!(tx.outputs[0].assets[0].amount, "1");
    for asset in wallet
        .iter()
        .flat_map(|b| &b.assets)
        .filter(|a| a.token_id != key)
    {
        let returned = tx.outputs[1]
            .assets
            .iter()
            .find(|a| a.token_id == asset.token_id)
            .unwrap();
        assert_eq!(returned.amount, asset.amount);
    }
    let reduced = ergo_lib::chain::transaction::reduced::reduce_tx(
        ergo_lib::wallet::tx_context::TransactionContext::new(
            ergo_tx::chain::to_unsigned_transaction(&tx).unwrap(),
            wallet
                .iter()
                .map(|b| stake_recovery::boxes::canonical_box(b).unwrap())
                .collect(),
            vec![],
        )
        .unwrap(),
        &h.context,
    )
    .unwrap();
    for input in reduced.reduced_inputs().iter() {
        let SigmaBoolean::ProofOfKnowledge(
            ergotree_ir::sigma_protocol::sigma_boolean::SigmaProofOfKnowledgeTree::ProveDlog(key),
        ) = &input.sigma_prop
        else {
            panic!("wallet signature lost")
        };
        assert_eq!(
            format!(
                "0008cd{}",
                hex::encode(key.h.sigma_serialize_bytes().unwrap())
            ),
            trees[0]
        );
    }
}
