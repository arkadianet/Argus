//! Batch 4 blocker: the deployed refund layout cannot pay the D10 app fee.
//! These are contract experiments, NOT production builders or a fee exemption.
mod common;

use common::{reidentify, Historical, REFUND, UNSTAKE};
use ergo_lib::{chain::transaction::reduced::reduce_tx, wallet::tx_context::TransactionContext};
use ergo_tx::{Eip12InputBox, Eip12Output, Eip12UnsignedTx};
use ergotree_ir::{serialization::SigmaSerializable, sigma_protocol::sigma_boolean::SigmaBoolean};
use stake_recovery::{
    boxes::canonical_box,
    contracts::REFUND_FEE,
    direct::{APP_FEE, APP_FEE_ADDRESS},
    PaideiaProxyBox,
};

/// Construct from the proxy alone. No state, stake or executor is available.
fn contract_refund(proxy: &Eip12InputBox, height: i32) -> Eip12UnsignedTx {
    let parsed = PaideiaProxyBox::parse(proxy).unwrap();
    let recipient = hex::encode(parsed.recipient().sigma_serialize_bytes().unwrap());
    Eip12UnsignedTx {
        inputs: vec![proxy.clone()],
        data_inputs: vec![],
        outputs: vec![
            Eip12Output::change(
                proxy
                    .value
                    .parse::<i64>()
                    .unwrap()
                    .checked_sub(REFUND_FEE)
                    .unwrap(),
                recipient,
                proxy.assets.clone(),
                height,
            ),
            Eip12Output::fee(REFUND_FEE, height),
        ],
    }
}

fn props(tx: &Eip12UnsignedTx, h: &Historical) -> Vec<SigmaBoolean> {
    let unsigned = ergo_tx::chain::to_unsigned_transaction(tx).unwrap();
    let inputs = tx
        .inputs
        .iter()
        .map(|b| canonical_box(b).unwrap())
        .collect();
    reduce_tx(
        TransactionContext::new(unsigned, inputs, vec![]).unwrap(),
        &h.context,
    )
    .unwrap()
    .reduced_inputs()
    .iter()
    .map(|i| i.sigma_prop.clone())
    .collect()
}

fn assert_conserved(tx: &Eip12UnsignedTx) {
    let incoming: i64 = tx
        .inputs
        .iter()
        .map(|b| b.value.parse::<i64>().unwrap())
        .sum();
    let outgoing: i64 = tx
        .outputs
        .iter()
        .map(|b| b.value.parse::<i64>().unwrap())
        .sum();
    assert_eq!(incoming, outgoing);
    assert_eq!(tx.inputs.len(), 1);
    assert_eq!(tx.inputs[0].assets.len(), 1);
    assert_eq!(tx.inputs[0].assets[0].amount, "1");
    assert_eq!(
        serde_json::to_value(&tx.inputs[0].assets).unwrap(),
        serde_json::to_value(&tx.outputs[0].assets).unwrap()
    );
    assert!(tx.outputs[1..].iter().all(|b| b.assets.is_empty()));
}

#[test]
fn independently_assembled_contract_refund_returns_key_and_exact_erg_and_reduces_true() {
    let h = Historical::load(REFUND);
    assert_eq!(h.inputs.len(), 1);
    let tx = contract_refund(&h.inputs[0], h.inputs[0].creation_height);
    assert_conserved(&tx);
    assert_eq!(tx.outputs[0].value, "112000000");
    assert_eq!(props(&tx, &h), vec![SigmaBoolean::TrivialProp(true)]);
}

#[test]
fn adding_standard_argus_fee_with_conservation_reduces_false() {
    let h = Historical::load(REFUND);
    let height = h.inputs[0].creation_height;
    let mut tx = contract_refund(&h.inputs[0], height);
    tx.outputs[0].value = (112_000_000 - APP_FEE).to_string();
    tx.outputs.insert(
        1,
        Eip12Output::simple(
            APP_FEE,
            ergo_tx::address_to_ergo_tree(APP_FEE_ADDRESS).unwrap(),
            height,
        ),
    );
    assert_conserved(&tx);
    assert_eq!(props(&tx, &h), vec![SigmaBoolean::TrivialProp(false)]);
}

#[test]
fn third_output_is_rejected_even_when_recipient_value_stays_exact() {
    let h = Historical::load(REFUND);
    let height = h.inputs[0].creation_height;
    let mut tx = contract_refund(&h.inputs[0], height);
    // Deliberately not conserved: isolate the script's output-count restriction
    // independently of its exact recipient-value requirement.
    tx.outputs.push(Eip12Output::simple(
        APP_FEE,
        ergo_tx::address_to_ergo_tree(APP_FEE_ADDRESS).unwrap(),
        height,
    ));
    assert_eq!(props(&tx, &h), vec![SigmaBoolean::TrivialProp(false)]);
}

#[test]
fn larger_refund_deduction_is_rejected_even_with_only_two_outputs() {
    let h = Historical::load(REFUND);
    let mut tx = contract_refund(&h.inputs[0], h.inputs[0].creation_height);
    tx.outputs[0].value = (113_000_000 - REFUND_FEE - APP_FEE).to_string();
    tx.outputs[1].value = (REFUND_FEE + APP_FEE).to_string();
    assert_conserved(&tx);
    assert_eq!(props(&tx, &h), vec![SigmaBoolean::TrivialProp(false)]);
}

#[test]
fn increased_proxy_funding_cannot_make_room_for_standard_argus_fee() {
    let h = Historical::load(REFUND);
    for value in [114_100_000i64, 1_000_000_000] {
        let mut proxy = h.inputs[0].clone();
        proxy.value = value.to_string();
        reidentify(&mut proxy);
        let mut tx = contract_refund(&proxy, proxy.creation_height);
        assert_conserved(&tx);
        assert_eq!(props(&tx, &h), vec![SigmaBoolean::TrivialProp(true)]);
        tx.outputs[0].value = (value - REFUND_FEE - APP_FEE).to_string();
        tx.outputs.insert(
            1,
            Eip12Output::simple(
                APP_FEE,
                ergo_tx::address_to_ergo_tree(APP_FEE_ADDRESS).unwrap(),
                proxy.creation_height,
            ),
        );
        assert_conserved(&tx);
        assert_eq!(props(&tx, &h), vec![SigmaBoolean::TrivialProp(false)]);
    }
}

#[test]
fn refund_output_order_recipient_and_key_are_pinned_by_the_contract() {
    let h = Historical::load(REFUND);
    let tx = contract_refund(&h.inputs[0], h.inputs[0].creation_height);
    let mut reordered = tx.clone();
    reordered.outputs.swap(0, 1);
    assert_eq!(
        props(&reordered, &h),
        vec![SigmaBoolean::TrivialProp(false)]
    );
    let mut foreign = tx.clone();
    foreign.outputs[0].ergo_tree = ergo_tx::address_to_ergo_tree(APP_FEE_ADDRESS).unwrap();
    assert_eq!(props(&foreign, &h), vec![SigmaBoolean::TrivialProp(false)]);
    let mut burned = tx;
    burned.outputs[0].assets.clear();
    assert_eq!(props(&burned, &h), vec![SigmaBoolean::TrivialProp(false)]);
}

#[test]
fn execution_also_rejects_an_added_app_fee_output() {
    // Historical executor only: this batch does not implement its builder.
    let h = Historical::load(UNSTAKE);
    let mut outputs = h.unsigned.output_candidates.to_vec();
    let height = i32::try_from(outputs[1].creation_height).unwrap();
    outputs[1].value = (10_000_000u64 - u64::try_from(APP_FEE).unwrap())
        .try_into()
        .unwrap();
    let fee = Eip12Output::simple(
        APP_FEE,
        ergo_tx::address_to_ergo_tree(APP_FEE_ADDRESS).unwrap(),
        height,
    );
    let fee_tx = Eip12UnsignedTx {
        inputs: h.inputs.clone(),
        data_inputs: vec![],
        outputs: vec![fee],
    };
    outputs.push(
        ergo_tx::chain::to_unsigned_transaction(&fee_tx)
            .unwrap()
            .output_candidates
            .as_slice()[0]
            .clone(),
    );
    let unsigned = ergo_lib::chain::transaction::unsigned::UnsignedTransaction::new_from_vec(
        h.unsigned.inputs.to_vec(),
        vec![],
        outputs,
    )
    .unwrap();
    let reduced = reduce_tx(
        TransactionContext::new(unsigned, h.boxes, vec![]).unwrap(),
        &h.context,
    )
    .unwrap();
    assert_eq!(
        reduced.reduced_inputs().as_slice()[2].sigma_prop,
        SigmaBoolean::TrivialProp(false)
    );
}
