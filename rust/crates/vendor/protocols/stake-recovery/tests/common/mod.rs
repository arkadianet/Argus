#![allow(dead_code)]

use ergo_chain_types::Header;
use ergo_lib::{
    chain::{
        ergo_state_context::ErgoStateContext,
        parameters::Parameters,
        transaction::{
            reduced::{reduce_tx, ReducedTransaction},
            unsigned::UnsignedTransaction,
            Transaction, UnsignedInput,
        },
    },
    wallet::tx_context::TransactionContext,
};
use ergo_tx::Eip12InputBox;
use ergotree_ir::chain::ergo_box::ErgoBox;
use serde_json::Value;
use stake_recovery::boxes::canonical_box;

pub const ERGOPAD: &str = include_str!("../fixtures/ergopad.json");
pub const UNSTAKE: &str = include_str!("../fixtures/paideia-unstake.json");
pub const REFUND: &str = include_str!("../fixtures/paideia-refund.json");

pub struct Historical {
    pub evidence: Value,
    pub inputs: Vec<Eip12InputBox>,
    pub boxes: Vec<ErgoBox>,
    pub data_boxes: Vec<ErgoBox>,
    pub unsigned: UnsignedTransaction,
    pub context: ErgoStateContext,
}

impl Historical {
    pub fn load(json: &str) -> Self {
        let evidence: Value = serde_json::from_str(json).unwrap();
        let signed: Transaction = serde_json::from_value(evidence["transaction"].clone()).unwrap();
        let unsigned = UnsignedTransaction::new_from_vec(
            signed
                .inputs
                .iter()
                .map(|i| UnsignedInput::new(i.box_id, i.spending_proof.extension.clone()))
                .collect(),
            signed
                .data_inputs
                .clone()
                .map(|d| d.to_vec())
                .unwrap_or_default(),
            signed.output_candidates.clone().to_vec(),
        )
        .unwrap();
        assert_eq!(
            unsigned.id().to_string(),
            evidence["explorer"]["id"].as_str().unwrap()
        );
        assert_eq!(unsigned.id(), signed.id());
        let boxes: Vec<ErgoBox> = serde_json::from_value(evidence["inputs"].clone()).unwrap();
        let inputs = boxes
            .iter()
            .enumerate()
            .map(|(i, b)| {
                let raw = &evidence["inputs"][i];
                let mut input = Eip12InputBox::from_ergo_box(
                    b,
                    raw["transactionId"].as_str().unwrap().into(),
                    raw["index"].as_u64().unwrap().try_into().unwrap(),
                );
                input.extension =
                    serde_json::from_value(raw["spendingProof"]["extension"].clone()).unwrap();
                assert_eq!(canonical_box(&input).unwrap(), *b);
                assert_eq!(b.box_id(), signed.inputs.as_slice()[i].box_id);
                assert_eq!(
                    raw["spendingProof"],
                    evidence["transaction"]["inputs"][i]["spendingProof"]
                );
                let explorer = &evidence["explorer"]["inputs"][i];
                assert_eq!(raw["transactionId"], explorer["outputTransactionId"]);
                assert_eq!(raw["index"], explorer["outputIndex"]);
                assert_eq!(raw["creationHeight"], explorer["outputCreatedAt"]);
                assert_eq!(raw["ergoTree"], explorer["ergoTree"]);
                input
            })
            .collect();
        let data_boxes: Vec<ErgoBox> =
            serde_json::from_value(evidence["dataInputBoxes"].clone()).unwrap();
        assert_eq!(
            data_boxes.len(),
            evidence["transaction"]["dataInputs"]
                .as_array()
                .unwrap()
                .len()
        );
        let inclusion: Header =
            serde_json::from_value(evidence["inclusionHeader"].clone()).unwrap();
        let headers: [Header; 10] = serde_json::from_value(evidence["headers"].clone()).unwrap();
        assert_eq!(
            inclusion.id.to_string(),
            evidence["explorer"]["blockId"].as_str().unwrap()
        );
        assert_eq!(
            u64::from(inclusion.height),
            evidence["explorer"]["inclusionHeight"].as_u64().unwrap()
        );
        assert_eq!(inclusion.parent_id, headers[0].id);
        for pair in headers.windows(2) {
            assert_eq!(pair[0].parent_id, pair[1].id);
        }
        let context = ErgoStateContext::new(inclusion.into(), headers, Parameters::default());
        Self {
            evidence,
            inputs,
            boxes,
            data_boxes,
            unsigned,
            context,
        }
    }

    pub fn reduce(&self) -> ReducedTransaction {
        reduce_tx(
            TransactionContext::new(
                self.unsigned.clone(),
                self.boxes.clone(),
                self.data_boxes.clone(),
            )
            .unwrap(),
            &self.context,
        )
        .unwrap()
    }
}

/// Adversarial fixtures are real boxes with edited contents and newly calculated
/// ids. Validation failures must not be accidental failures of the old id.
pub fn reidentify(input: &mut Eip12InputBox) {
    let mut json = serde_json::to_value(&*input).unwrap();
    json.as_object_mut().unwrap().remove("boxId");
    let b: ErgoBox = serde_json::from_value(json).unwrap();
    input.box_id = b.box_id().to_string();
}
