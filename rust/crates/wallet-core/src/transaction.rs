use ergo_lib::chain::ergo_state_context::ErgoStateContext;
use ergo_lib::chain::transaction::reduced::reduce_tx;
use ergo_lib::chain::transaction::reduced::ReducedTransaction;
use ergo_lib::chain::transaction::unsigned::UnsignedTransaction;
use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_lib::wallet::tx_context::TransactionContext;

use crate::CoreError;

pub fn build_reduced_transaction(
    unsigned_tx: UnsignedTransaction,
    input_boxes: Vec<ErgoBox>,
    data_input_boxes: Vec<ErgoBox>,
    state_context: &ErgoStateContext,
) -> Result<ReducedTransaction, CoreError> {
    let tx_context = TransactionContext::new(unsigned_tx, input_boxes, data_input_boxes)
        .map_err(|e| CoreError::Reduction(e.to_string()))?;
    reduce_tx(tx_context, state_context).map_err(|e| CoreError::Reduction(e.to_string()))
}

pub fn serialize_reduced(reduced: &ReducedTransaction) -> Result<Vec<u8>, CoreError> {
    reduced
        .sigma_serialize_bytes()
        .map_err(|e| CoreError::Serialization(e.to_string()))
}

pub fn deserialize_reduced(bytes: &[u8]) -> Result<ReducedTransaction, CoreError> {
    ReducedTransaction::sigma_parse_bytes(bytes)
        .map_err(|e| CoreError::Serialization(e.to_string()))
}

/// Dummy headers sufficient for P2PK proof generation in tests.
#[cfg(test)]
pub(crate) fn dummy_state_context(height: u32) -> ErgoStateContext {
    use ergo_lib::chain::parameters::Parameters;
    use ergo_lib::ergo_chain_types::EcPoint;
    use ergo_lib::ergo_chain_types::{
        ADDigest, AutolykosSolution, BlockId, Digest32, Header, PreHeader, Votes,
    };

    let dummy32 = Digest32::from([0u8; 32]);
    let dummy_ad = ADDigest::from([0u8; 33]);
    let dummy_pk = Box::new(
        EcPoint::from_base16_str(
            "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".to_string(),
        )
        .expect("secp256k1 G"),
    );

    let pre_header = PreHeader {
        version: 1,
        parent_id: BlockId(dummy32),
        timestamp: 0,
        n_bits: 16842752,
        height,
        miner_pk: dummy_pk.clone(),
        votes: Votes([0u8, 0u8, 0u8]),
    };

    let header = Header {
        version: 1,
        id: BlockId(dummy32),
        parent_id: BlockId(dummy32),
        ad_proofs_root: dummy32,
        state_root: dummy_ad,
        transaction_root: dummy32,
        timestamp: 0,
        n_bits: 16842752,
        height,
        extension_root: dummy32,
        autolykos_solution: AutolykosSolution {
            miner_pk: dummy_pk,
            pow_onetime_pk: None,
            nonce: vec![0u8; 8],
            pow_distance: Some(num_bigint::BigUint::from(0u32)),
        },
        votes: Votes([0u8, 0u8, 0u8]),
        unparsed_bytes: Box::new([]),
    };

    let headers = core::array::from_fn(|_| header.clone());
    ErgoStateContext::new(pre_header, headers, Parameters::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seed::MnemonicPhrase;
    use crate::wallet::WalletHandle;
    use ergo_lib::chain::ergo_box::box_builder::ErgoBoxCandidateBuilder;
    use ergo_lib::chain::transaction::unsigned::UnsignedTransaction;
    use ergo_lib::chain::transaction::UnsignedInput;
    use ergo_lib::chain::transaction::{DataInput, TxIoVec};
    use ergo_lib::ergotree_ir::chain::address::{AddressEncoder, NetworkPrefix};
    use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
    use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
    use ergo_lib::ergotree_ir::chain::ergo_box::NonMandatoryRegisters;
    use ergo_lib::ergotree_ir::chain::tx_id::TxId;
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    fn p2pk_tree(address: &str) -> ergo_lib::ergotree_ir::ergo_tree::ErgoTree {
        let encoder = AddressEncoder::new(NetworkPrefix::Mainnet);
        let addr = encoder.parse_address_from_str(address).unwrap();
        addr.script().unwrap()
    }

    #[test]
    fn signs_eip3_p2pk_input() {
        let phrase = MnemonicPhrase::parse(APPKIT).unwrap();
        let handle = WalletHandle::create(phrase, "").unwrap();
        let sender = handle.derive_address(0).unwrap();
        let recipient = handle.derive_address(1).unwrap();

        let value = BoxValue::try_from(2_000_000_000u64).unwrap();
        let input_box = ErgoBox::new(
            value,
            p2pk_tree(&sender),
            None,
            NonMandatoryRegisters::empty(),
            1000,
            TxId::zero(),
            0,
        )
        .unwrap();

        let fee = 1_100_000u64;
        let send = 1_000_000u64;
        let change = *value.as_u64() - send - fee;

        let send_out = ErgoBoxCandidateBuilder::new(BoxValue::try_from(send).unwrap(), p2pk_tree(&recipient), 2000);
        let send_out = send_out.build().unwrap();
        let change_out =
            ErgoBoxCandidateBuilder::new(BoxValue::try_from(change).unwrap(), p2pk_tree(&sender), 2000);
        let change_out = change_out.build().unwrap();
        let fee_out = ErgoBoxCandidateBuilder::new(
            BoxValue::try_from(fee).unwrap(),
            ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS.script().unwrap(),
            2000,
        );
        let fee_out = fee_out.build().unwrap();

        let inputs = TxIoVec::from_vec(vec![UnsignedInput::new(
            input_box.box_id(),
            ergo_lib::ergotree_ir::chain::context_extension::ContextExtension::empty(),
        )])
        .unwrap();
        let outputs = TxIoVec::from_vec(vec![send_out, change_out, fee_out]).unwrap();
        let unsigned = UnsignedTransaction::new(inputs, None::<TxIoVec<DataInput>>, outputs).unwrap();

        let reduced = build_reduced_transaction(
            unsigned,
            vec![input_box],
            vec![],
            &dummy_state_context(2000),
        )
        .unwrap();
        let signed = handle.sign_reduced(reduced).unwrap();
        assert_eq!(signed.inputs.len(), 1);
        assert!(!signed.sigma_serialize_bytes().unwrap().is_empty());
    }

    /// A stealth box can only be spent with the DH-tuple secret derived from
    /// the wallet's stealth branch — and the wallet's ordinary P2PK keys are
    /// not enough.
    #[test]
    fn signs_stealth_input_only_with_the_dht_secret() {
        use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
        use ergo_lib::wallet::secret_key::SecretKey;

        let phrase = MnemonicPhrase::parse(APPKIT).unwrap();
        let handle = WalletHandle::create(phrase, "").unwrap();
        let me = handle.stealth_secret().unwrap();
        let sweep_to = handle.derive_address(0).unwrap();

        // Someone pays our published stealth address.
        let tree_hex = stealth::build_payment_tree_hex(me.public_key()).unwrap();
        let stealth_tree =
            ErgoTree::sigma_parse_bytes(&hex::decode(&tree_hex).unwrap()).unwrap();

        let value = BoxValue::try_from(2_000_000_000u64).unwrap();
        let input_box = ErgoBox::new(
            value,
            stealth_tree,
            None,
            NonMandatoryRegisters::empty(),
            1000,
            TxId::zero(),
            0,
        )
        .unwrap();

        let fee = 1_100_000u64;
        let out_value = *value.as_u64() - fee;
        let sweep_out = ErgoBoxCandidateBuilder::new(
            BoxValue::try_from(out_value).unwrap(),
            p2pk_tree(&sweep_to),
            2000,
        )
        .build()
        .unwrap();
        let fee_out = ErgoBoxCandidateBuilder::new(
            BoxValue::try_from(fee).unwrap(),
            ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS.script().unwrap(),
            2000,
        )
        .build()
        .unwrap();

        let inputs = TxIoVec::from_vec(vec![UnsignedInput::new(
            input_box.box_id(),
            ergo_lib::ergotree_ir::chain::context_extension::ContextExtension::empty(),
        )])
        .unwrap();
        let outputs = TxIoVec::from_vec(vec![sweep_out, fee_out]).unwrap();
        let unsigned =
            UnsignedTransaction::new(inputs, None::<TxIoVec<DataInput>>, outputs).unwrap();

        let reduced = build_reduced_transaction(
            unsigned,
            vec![input_box],
            vec![],
            &dummy_state_context(2000),
        )
        .unwrap();

        // Without the DHT secret the wallet cannot prove the tuple.
        assert!(handle.sign_reduced(reduced.clone()).is_err());

        let dht = me.dht_prover_input_for_tree(&tree_hex).unwrap();
        let signed = handle
            .sign_reduced_with_secrets(reduced, vec![SecretKey::DhtSecretKey(dht)])
            .unwrap();
        assert_eq!(signed.inputs.len(), 1);
        assert!(matches!(
            signed.inputs.first().spending_proof.proof,
            ergo_lib::ergotree_interpreter::sigma_protocol::prover::ProofBytes::Some(_)
        ));
    }
}
