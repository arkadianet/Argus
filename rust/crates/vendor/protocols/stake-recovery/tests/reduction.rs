mod common;

use common::{Historical, ERGOPAD, REFUND, UNSTAKE};
use ergo_lib::{
    chain::transaction::{reduced::reduce_tx, unsigned::UnsignedTransaction},
    wallet::tx_context::TransactionContext,
};
use ergotree_ir::{
    serialization::SigmaSerializable,
    sigma_protocol::sigma_boolean::{SigmaBoolean, SigmaProofOfKnowledgeTree},
};

#[test]
fn ergopad_protocol_inputs_are_true_and_wallet_still_requires_its_exact_key() {
    let h = Historical::load(ERGOPAD);
    let reduced = h.reduce().reduced_inputs().to_vec();
    assert_eq!(reduced.len(), 3);
    assert_eq!(reduced[0].sigma_prop, SigmaBoolean::TrivialProp(true));
    assert_eq!(reduced[1].sigma_prop, SigmaBoolean::TrivialProp(true));
    let SigmaBoolean::ProofOfKnowledge(SigmaProofOfKnowledgeTree::ProveDlog(ref key)) =
        reduced[2].sigma_prop
    else {
        panic!(
            "wallet input lost its signature requirement: {:?}",
            reduced[2].sigma_prop
        );
    };
    // P2PK's serialized tree is 0008cd followed by the actual compressed public key.
    let tree = hex::decode(&h.inputs[2].ergo_tree).unwrap();
    assert_eq!(&tree[..3], &[0, 8, 0xcd]);
    assert_eq!(key.h.sigma_serialize_bytes().unwrap(), tree[3..]);
}

#[test]
fn paideia_unstake_reduces_all_three_inputs_to_true() {
    let h = Historical::load(UNSTAKE);
    let reduced = h.reduce().reduced_inputs().to_vec();
    assert_eq!(reduced.len(), 3);
    for input in reduced {
        assert_eq!(input.sigma_prop, SigmaBoolean::TrivialProp(true));
    }
}

#[test]
fn paideia_refund_reduces_to_true_without_state_or_stake() {
    let h = Historical::load(REFUND);
    assert_eq!(h.boxes.len(), 1);
    let reduced = h.reduce().reduced_inputs().to_vec();
    assert_eq!(reduced.len(), 1);
    assert_eq!(reduced[0].sigma_prop, SigmaBoolean::TrivialProp(true));
}

#[test]
fn contract_rejects_reordered_paideia_outputs() {
    let h = Historical::load(UNSTAKE);
    let mut outputs = h.unsigned.output_candidates.to_vec();
    outputs.swap(1, 2);
    let tx =
        UnsignedTransaction::new_from_vec(h.unsigned.inputs.to_vec(), vec![], outputs).unwrap();
    let result = reduce_tx(
        TransactionContext::new(tx, h.boxes, h.data_boxes).unwrap(),
        &h.context,
    );
    match result {
        Err(_) => {} // Evaluation errors also make an input unspendable.
        Ok(reduced) => assert!(reduced
            .reduced_inputs()
            .iter()
            .any(|i| i.sigma_prop == SigmaBoolean::TrivialProp(false))),
    }
}

#[test]
fn changed_refund_recipient_can_be_contract_valid_but_fails_wallet_policy() {
    use common::reidentify;
    use ergotree_ir::mir::constant::Constant;
    use stake_recovery::{boxes::canonical_box, PaideiaProxyBox};
    let h = Historical::load(REFUND);
    let original = PaideiaProxyBox::parse(&h.inputs[0]).unwrap();
    let other = PaideiaProxyBox::parse(&Historical::load(UNSTAKE).inputs[2]).unwrap();
    let mut input = h.inputs[0].clone();
    input.additional_registers.insert(
        "R5".into(),
        hex::encode(
            Constant::from(other.recipient().sigma_serialize_bytes().unwrap())
                .sigma_serialize_bytes()
                .unwrap(),
        ),
    );
    reidentify(&mut input);
    let changed = PaideiaProxyBox::parse(&input).unwrap();
    assert!(changed.validate_recipient(original.recipient()).is_err());
    let box_ = canonical_box(&input).unwrap();
    let mut outputs = h.unsigned.output_candidates.to_vec();
    outputs[0].ergo_tree = other.recipient().clone();
    let tx = UnsignedTransaction::new_from_vec(
        vec![ergo_lib::chain::transaction::UnsignedInput::new(
            box_.box_id(),
            h.unsigned.inputs.as_slice()[0].extension.clone(),
        )],
        vec![],
        outputs,
    )
    .unwrap();
    let reduced = reduce_tx(
        TransactionContext::new(tx, vec![box_], vec![]).unwrap(),
        &h.context,
    )
    .unwrap();
    assert_eq!(
        reduced.reduced_inputs().as_slice()[0].sigma_prop,
        SigmaBoolean::TrivialProp(true)
    );
}
