//! Trusted preparation export and a fail-closed EIP-19 return gate for P2PK inputs.
//! Request preflight lives in `cold_request`; application sessions own approval.
use crate::cold_transport::{decode_response, invalid, ColdError, RequestBytes, MAX_INNER_BYTES};
use ergo_lib::chain::transaction::{reduced::ReducedTransaction, Transaction};
use ergo_lib::ergotree_ir::{
    chain::{address::Address, ergo_box::ErgoBox},
    serialization::SigmaSerializable,
};
use std::collections::HashSet;

/// Immutable binding to a locally built transaction. Not an application session:
/// callers still need network, expiry, ownership/derivation and spendability policy.
/// Construct only from the existing local builder/reducer, never scanned bytes.
pub struct PreparedColdTransaction {
    reduced: ReducedTransaction,
    boxes: Vec<ErgoBox>,
    message: Vec<u8>,
}
impl PreparedColdTransaction {
    pub fn new(reduced: ReducedTransaction, boxes: Vec<ErgoBox>) -> Result<Self, ColdError> {
        if boxes.len() != reduced.unsigned_tx.inputs.len() {
            return Err(invalid(
                "all spending input boxes are required, in transaction order",
            ));
        }
        let reductions = reduced.reduced_inputs();
        if reductions.len() != boxes.len() {
            return Err(invalid(
                "one reduction is required for every spending input",
            ));
        }
        let mut ids = HashSet::new();
        for ((input, b), reduction) in reduced
            .unsigned_tx
            .inputs
            .iter()
            .zip(&boxes)
            .zip(reductions.iter())
        {
            if input.box_id != b.box_id() || !ids.insert(b.box_id()) {
                return Err(invalid("input box ID/order mismatch or duplicate input"));
            }
            let Address::P2Pk(pk) =
                Address::recreate_from_ergo_tree(&b.ergo_tree).map_err(invalid)?
            else {
                return Err(invalid("cold export supports P2PK spending inputs only"));
            };
            if reduction.sigma_prop != pk.into() || reduction.extension != input.extension {
                return Err(invalid(
                    "P2PK reduction does not match the input script/extension",
                ));
            }
        }
        let message = reduced.unsigned_tx.bytes_to_sign().map_err(invalid)?;
        if message.len() > MAX_INNER_BYTES {
            return Err(ColdError::Limit);
        }
        Ok(Self {
            reduced,
            boxes,
            message,
        })
    }
    /// Exact outputs for offline review. Ownership must come from local keys,
    /// never from the optional sender or a label supplied by the hot device.
    pub fn review(
        &self,
        mut owns: impl FnMut(&str) -> Result<bool, ColdError>,
    ) -> Result<ColdReview, ColdError> {
        use ergo_lib::ergotree_ir::chain::address::{NetworkAddress, NetworkPrefix};
        use std::collections::BTreeMap;
        let fee_tree = ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS
            .script()
            .map_err(invalid)?;
        let mut input_erg = 0u128;
        let mut output_erg = 0u128;
        let mut assets: BTreeMap<String, i128> = BTreeMap::new();
        for b in &self.boxes {
            let address = Address::recreate_from_ergo_tree(&b.ergo_tree).map_err(invalid)?;
            let address = NetworkAddress::new(NetworkPrefix::Mainnet, &address).to_base58();
            if !owns(&address)? {
                return Err(invalid(
                    "a spending input does not belong to this cold wallet",
                ));
            }
            input_erg += u64::from(b.value) as u128;
            if let Some(tokens) = &b.tokens {
                for t in tokens.iter() {
                    *assets.entry(hex::encode(t.token_id.as_ref())).or_default() +=
                        u64::from(t.amount) as i128;
                }
            }
        }
        let mut outputs = Vec::new();
        let mut fee_count = 0;
        let mut fee_nano = 0;
        for b in self.reduced.unsigned_tx.output_candidates.iter() {
            let is_fee = b.ergo_tree == fee_tree;
            let (address, owned) = if is_fee {
                fee_count += 1;
                fee_nano = u64::from(b.value);
                if b.tokens.is_some() {
                    return Err(invalid("miner fee must not carry tokens"));
                }
                (None, false)
            } else {
                let address = Address::recreate_from_ergo_tree(&b.ergo_tree).map_err(invalid)?;
                if !matches!(address, Address::P2Pk(_)) {
                    return Err(invalid("unsupported output script"));
                }
                let address = NetworkAddress::new(NetworkPrefix::Mainnet, &address).to_base58();
                let owned = owns(&address)?;
                (Some(address), owned)
            };
            if !b.additional_registers.is_empty() {
                return Err(invalid("unsupported output registers"));
            }
            output_erg += u64::from(b.value) as u128;
            let mut tokens = Vec::new();
            if let Some(ts) = &b.tokens {
                for t in ts.iter() {
                    let id = hex::encode(t.token_id.as_ref());
                    let amount = u64::from(t.amount);
                    *assets.entry(id.clone()).or_default() -= amount as i128;
                    tokens.push(ColdToken {
                        id,
                        amount: amount.to_string(),
                    });
                }
            }
            outputs.push(ColdOutput {
                address,
                owned,
                is_fee,
                nano_erg: u64::from(b.value).to_string(),
                tokens,
            });
        }
        if input_erg != output_erg || fee_count != 1 || fee_nano == 0 {
            return Err(invalid("unbalanced ERG or missing/ambiguous miner fee"));
        }
        let mut burns = Vec::new();
        let mut mints = Vec::new();
        for (id, delta) in assets {
            if delta > 0 {
                burns.push(ColdToken {
                    id,
                    amount: delta.to_string(),
                });
            } else if delta < 0 {
                if id != self.boxes[0].box_id().to_string() {
                    return Err(invalid("invalid token creation"));
                }
                mints.push(ColdToken {
                    id,
                    amount: (-delta).to_string(),
                });
            }
        }
        Ok(ColdReview {
            network: "Mainnet".into(),
            outputs,
            fee_nano: fee_nano.to_string(),
            burns,
            mints,
        })
    }
    /// Caller must show the immutable review and obtain explicit approval first.
    /// Rechecks local ownership and unlocked state; watch accounts have no handle.
    pub fn sign_reviewed(&self, handle: &crate::WalletHandle) -> Result<Vec<u8>, ColdError> {
        self.review(|address| handle.owns_address(address).map_err(invalid))?;
        let signed = handle.sign_reduced(self.reduced.clone()).map_err(invalid)?;
        let bytes = signed.sigma_serialize_bytes().map_err(invalid)?;
        self.verify_bytes(&bytes)?;
        Ok(bytes)
    }
    /// Sender is only an optional EIP-19 display hint, never proof of ownership.
    pub fn request(&self, sender: Option<String>) -> Result<RequestBytes, ColdError> {
        Ok(RequestBytes {
            reduced_tx: self.reduced.sigma_serialize_bytes().map_err(invalid)?,
            sender,
            inputs: self
                .boxes
                .iter()
                .map(|b| b.sigma_serialize_bytes().map_err(invalid))
                .collect::<Result<_, _>>()?,
        })
    }
    pub fn verify_response(&self, json: &str) -> Result<VerifiedColdTransaction, ColdError> {
        self.verify_bytes(&decode_response(json)?)
    }
    pub fn verify_bytes(&self, bytes: &[u8]) -> Result<VerifiedColdTransaction, ColdError> {
        if bytes.len() > MAX_INNER_BYTES {
            return Err(ColdError::Limit);
        }
        // Compare every non-proof byte before allowing the general transaction parser
        // to inspect attacker-controlled length fields, extensions or output scripts.
        // Only the 56-byte Schnorr proofs may differ from trusted preparation bytes.
        let mut returned = bytes;
        let mut expected = self.message.as_slice();
        let count = vlq(self.boxes.len());
        match_prefix(&mut returned, &count)?;
        match_prefix(&mut expected, &count)?;
        for input in self.reduced.unsigned_tx.inputs.iter() {
            let id = input.box_id.sigma_serialize_bytes().map_err(invalid)?;
            match_prefix(&mut returned, &id)?;
            match_prefix(&mut expected, &id)?;
            match_prefix(&mut expected, &[0])?; // unsigned message has an empty proof
            match_prefix(&mut returned, &[56])?; // canonical VLQ length of a P2PK proof
            if returned.len() < 56 {
                return Err(invalid("truncated P2PK proof"));
            }
            returned = &returned[56..];
            let extension = input.extension.sigma_serialize_bytes().map_err(invalid)?;
            match_prefix(&mut returned, &extension)?;
            match_prefix(&mut expected, &extension)?;
        }
        // Includes data inputs, token dictionary, outputs, trees, values, registers,
        // heights and their order. Also rejects trailing bytes and noncanonical VLQs.
        if returned != expected {
            return Err(ColdError::Mismatch);
        }
        let tx = Transaction::sigma_parse_bytes(bytes).map_err(invalid)?;
        if tx.sigma_serialize_bytes().map_err(invalid)? != bytes
            || tx.bytes_to_sign().map_err(invalid)? != self.message
        {
            return Err(ColdError::Mismatch);
        }
        for (i, b) in self.boxes.iter().enumerate() {
            if !tx
                .verify_p2pk_input(b.clone())
                .map_err(|_| ColdError::InvalidProof(i))?
            {
                return Err(ColdError::InvalidProof(i));
            }
        }
        Ok(VerifiedColdTransaction {
            tx,
            bytes: bytes.to_vec(),
        })
    }
}
fn match_prefix(bytes: &mut &[u8], prefix: &[u8]) -> Result<(), ColdError> {
    *bytes = bytes.strip_prefix(prefix).ok_or(ColdError::Mismatch)?;
    Ok(())
}
fn vlq(mut n: usize) -> Vec<u8> {
    let mut result = Vec::new();
    loop {
        let b = (n & 127) as u8;
        n >>= 7;
        result.push(if n == 0 { b } else { b | 128 });
        if n == 0 {
            break;
        }
    }
    result
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ColdToken {
    pub id: String,
    pub amount: String,
}
#[derive(Debug, Clone, serde::Serialize)]
pub struct ColdOutput {
    pub address: Option<String>,
    pub owned: bool,
    pub is_fee: bool,
    pub nano_erg: String,
    pub tokens: Vec<ColdToken>,
}
#[derive(Debug, Clone, serde::Serialize)]
pub struct ColdReview {
    pub network: String,
    pub outputs: Vec<ColdOutput>,
    pub fee_nano: String,
    pub burns: Vec<ColdToken>,
    pub mints: Vec<ColdToken>,
}

/// The only node-JSON conversion exposed here requires successful matching and proofs.
/// This does not imply node acceptance, unspent inputs or permission to broadcast.
pub struct VerifiedColdTransaction {
    tx: Transaction,
    bytes: Vec<u8>,
}
impl VerifiedColdTransaction {
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub fn id(&self) -> String {
        self.tx.id().to_string()
    }
    pub fn node_json(&self) -> Result<String, ColdError> {
        serde_json::to_string(&self.tx).map_err(invalid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        cold_transport::{encode_response, pages, Collector, Density, Direction},
        seed::MnemonicPhrase,
        transaction::{build_reduced_transaction, dummy_state_context},
        wallet::WalletHandle,
    };
    use ergo_lib::{
        chain::{
            ergo_box::box_builder::ErgoBoxCandidateBuilder,
            transaction::{unsigned::UnsignedTransaction, UnsignedInput},
        },
        ergotree_ir::chain::{
            address::{AddressEncoder, NetworkPrefix},
            context_extension::ContextExtension,
            ergo_box::{box_value::BoxValue, NonMandatoryRegisters},
            tx_id::TxId,
        },
    };
    const PHRASE: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";
    fn tree(handle: &WalletHandle, index: u32) -> ergo_lib::ergotree_ir::ergo_tree::ErgoTree {
        AddressEncoder::new(NetworkPrefix::Mainnet)
            .parse_address_from_str(&handle.derive_address(index).unwrap())
            .unwrap()
            .script()
            .unwrap()
    }
    fn preparation(handle: &WalletHandle, recipient: u32) -> (ReducedTransaction, Vec<ErgoBox>) {
        let boxes: Vec<_> = [0, 3, 20]
            .iter()
            .enumerate()
            .map(|(i, index)| {
                ErgoBox::new(
                    BoxValue::try_from(1_000_000_000u64).unwrap(),
                    tree(handle, *index),
                    None,
                    NonMandatoryRegisters::empty(),
                    1000,
                    TxId::zero(),
                    i as u16,
                )
                .unwrap()
            })
            .collect();
        let outputs = vec![
            ErgoBoxCandidateBuilder::new(
                BoxValue::try_from(2_998_900_000u64).unwrap(),
                tree(handle, recipient),
                2000,
            )
            .build()
            .unwrap(),
            ErgoBoxCandidateBuilder::new(
                BoxValue::try_from(1_100_000u64).unwrap(),
                ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS
                    .script()
                    .unwrap(),
                2000,
            )
            .build()
            .unwrap(),
        ];
        let unsigned = UnsignedTransaction::new_from_vec(
            boxes
                .iter()
                .map(|b| UnsignedInput::new(b.box_id(), ContextExtension::empty()))
                .collect(),
            vec![],
            outputs,
        )
        .unwrap();
        (
            build_reduced_transaction(unsigned, boxes.clone(), vec![], &dummy_state_context(2000))
                .unwrap(),
            boxes,
        )
    }
    fn collect(json: &str, direction: Direction) -> String {
        let ps = pages(json, direction, Density::Low).unwrap();
        assert!(ps.len() > 1);
        let mut c = Collector::new(direction);
        for p in ps.iter().rev() {
            c.add(p).unwrap();
            c.add(p).unwrap();
        }
        c.finish().unwrap()
    }
    #[test]
    fn prepare_request_sign_response_verify_across_indices() {
        let handle = WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap();
        let (reduced, boxes) = preparation(&handle, 1);
        let binding = PreparedColdTransaction::new(reduced.clone(), boxes.clone()).unwrap();
        let request = binding
            .request(Some(handle.derive_address(0).unwrap()))
            .unwrap();
        let received =
            RequestBytes::decode(&collect(&request.encode().unwrap(), Direction::Request)).unwrap();
        assert_eq!(received, request);
        // Test-only decoding of our own trusted fixture; no production cold parser/signing API.
        let parsed = ReducedTransaction::sigma_parse_bytes(&received.reduced_tx).unwrap();
        assert_eq!(parsed.sigma_serialize_bytes().unwrap(), received.reduced_tx);
        assert_eq!(parsed.unsigned_tx.bytes_to_sign().unwrap(), binding.message);
        for (bytes, b) in received.inputs.iter().zip(boxes.iter()) {
            assert_eq!(
                ErgoBox::sigma_parse_bytes(bytes)
                    .unwrap()
                    .sigma_serialize_bytes()
                    .unwrap(),
                *bytes
            );
            assert_eq!(b.sigma_serialize_bytes().unwrap(), *bytes);
        }
        let signed = handle.sign_reduced(parsed).unwrap();
        let bytes = signed.sigma_serialize_bytes().unwrap();
        assert_eq!(signed.bytes_to_sign().unwrap(), binding.message);
        let response = collect(&encode_response(&bytes).unwrap(), Direction::Response);
        assert_eq!(decode_response(&response).unwrap(), bytes);
        let verified = binding.verify_response(&response).unwrap();
        assert_eq!(verified.bytes(), bytes);
        let node: Transaction = serde_json::from_str(&verified.node_json().unwrap()).unwrap();
        assert_eq!(node.sigma_serialize_bytes().unwrap(), bytes);
        assert_eq!(verified.id(), signed.id().to_string());
        let (other, _) = preparation(&handle, 2);
        assert!(binding
            .verify_bytes(
                &handle
                    .sign_reduced(other)
                    .unwrap()
                    .sigma_serialize_bytes()
                    .unwrap()
            )
            .is_err());
        let mut corrupt = bytes.clone();
        corrupt[34] ^= 1;
        assert!(matches!(
            binding.verify_bytes(&corrupt),
            Err(ColdError::InvalidProof(0))
        ));
        for n in 0..bytes.len() {
            assert!(binding.verify_bytes(&bytes[..n]).is_err());
        }
        let mut trailing = bytes.clone();
        trailing.push(0);
        assert!(binding.verify_bytes(&trailing).is_err());
        // Each non-proof byte is bound, including recipients, fees and input order.
        for i in 0..bytes.len() {
            let mut changed = bytes.clone();
            changed[i] ^= 1;
            assert!(binding.verify_bytes(&changed).is_err(), "byte {i}");
        }
        handle.lock();
        assert!(handle.sign_reduced(reduced).is_err());
    }
    #[test]
    fn rejects_missing_reordered_duplicate_and_non_p2pk_boxes() {
        let h = WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap();
        let (r, mut boxes) = preparation(&h, 1);
        assert!(PreparedColdTransaction::new(r.clone(), vec![]).is_err());
        boxes.swap(0, 1);
        assert!(PreparedColdTransaction::new(r.clone(), boxes.clone()).is_err());
        boxes.swap(0, 1);
        boxes[1] = boxes[0].clone();
        assert!(PreparedColdTransaction::new(r, boxes).is_err());
        let b = ErgoBox::new(
            BoxValue::try_from(3_000_000u64).unwrap(),
            ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS
                .script()
                .unwrap(),
            None,
            NonMandatoryRegisters::empty(),
            1,
            TxId::zero(),
            0,
        )
        .unwrap();
        let unsigned = UnsignedTransaction::new_from_vec(
            vec![UnsignedInput::new(b.box_id(), ContextExtension::empty())],
            vec![],
            vec![ErgoBoxCandidateBuilder::new(
                BoxValue::try_from(3_000_000u64).unwrap(),
                tree(&h, 0),
                2000,
            )
            .build()
            .unwrap()],
        )
        .unwrap();
        let r = build_reduced_transaction(
            unsigned,
            vec![b.clone()],
            vec![],
            &dummy_state_context(2000),
        )
        .unwrap();
        assert!(PreparedColdTransaction::new(r, vec![b]).is_err());
    }
    #[test]
    fn tokens_registers_extensions_and_data_inputs_are_bound() {
        use ergo_lib::chain::transaction::DataInput;
        use ergo_lib::ergotree_ir::chain::{
            ergo_box::NonMandatoryRegisterId,
            token::{Token, TokenId},
        };
        let h = WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap();
        let (_, mut boxes) = preparation(&h, 1);
        let token = Token {
            token_id: TokenId::from(boxes[0].box_id()),
            amount: 42u64.try_into().unwrap(),
        };
        boxes[0] = ErgoBox::new(
            boxes[0].value,
            boxes[0].ergo_tree.clone(),
            Some(vec![token.clone()].try_into().unwrap()),
            NonMandatoryRegisters::empty(),
            1000,
            TxId::zero(),
            0,
        )
        .unwrap();
        let data = ErgoBox::new(
            boxes[1].value,
            tree(&h, 4),
            None,
            NonMandatoryRegisters::empty(),
            999,
            TxId::zero(),
            7,
        )
        .unwrap();
        let make = |amount: u64, register: i32, ext: i32, reverse: bool, with_data: bool| {
            let mut out = ErgoBoxCandidateBuilder::new(
                BoxValue::try_from(2_998_900_000u64).unwrap(),
                tree(&h, 1),
                2000,
            );
            out.add_token(Token {
                token_id: token.token_id,
                amount: amount.try_into().unwrap(),
            });
            out.set_register_value(NonMandatoryRegisterId::R4, register.into());
            let fee = ErgoBoxCandidateBuilder::new(
                BoxValue::try_from(1_100_000u64).unwrap(),
                ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS
                    .script()
                    .unwrap(),
                2000,
            )
            .build()
            .unwrap();
            let mut inputs: Vec<_> = boxes
                .iter()
                .map(|b| {
                    let mut extension = ContextExtension::empty();
                    extension.values.insert(0, ext.into());
                    UnsignedInput::new(b.box_id(), extension)
                })
                .collect();
            if reverse {
                inputs.reverse();
            }
            let unsigned = UnsignedTransaction::new_from_vec(
                inputs,
                if with_data {
                    vec![DataInput::from(data.box_id())]
                } else {
                    vec![]
                },
                vec![out.build().unwrap(), fee],
            )
            .unwrap();
            build_reduced_transaction(
                unsigned,
                boxes.clone(),
                if with_data {
                    vec![data.clone()]
                } else {
                    vec![]
                },
                &dummy_state_context(2000),
            )
            .unwrap()
        };
        let r = make(42, 123, 456, false, true);
        let binding = PreparedColdTransaction::new(r.clone(), boxes.clone()).unwrap();
        let bytes = h.sign_reduced(r).unwrap().sigma_serialize_bytes().unwrap();
        assert_eq!(
            binding
                .verify_response(&collect(
                    &encode_response(&bytes).unwrap(),
                    Direction::Response
                ))
                .unwrap()
                .bytes(),
            bytes
        );
        for altered in [
            make(41, 123, 456, false, true),
            make(42, 124, 456, false, true),
            make(42, 123, 457, false, true),
            make(42, 123, 456, true, true),
            make(42, 123, 456, false, false),
        ] {
            let signed = h
                .sign_reduced(altered)
                .unwrap()
                .sigma_serialize_bytes()
                .unwrap();
            assert!(matches!(
                binding.verify_bytes(&signed),
                Err(ColdError::Mismatch)
            ));
        }
        // Replacing the unsigned message must not let a reduction for different keys through.
        let other = WalletHandle::create(
            MnemonicPhrase::parse(PHRASE).unwrap(),
            "different passphrase",
        )
        .unwrap();
        let (mut wrong_reduction, _) = preparation(&other, 1);
        wrong_reduction.unsigned_tx = make(42, 123, 456, false, true).unsigned_tx;
        assert!(PreparedColdTransaction::new(wrong_reduction, boxes).is_err());
    }

    #[test]
    fn bounded_request_review_and_sign() {
        let h = WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap();
        let (r, boxes) = preparation(&h, 1);
        let request = PreparedColdTransaction::new(r, boxes)
            .unwrap()
            .request(None)
            .unwrap();
        let json = request.encode().unwrap();
        let parsed = crate::cold_request::parse_request(&json).unwrap();
        let review = parsed
            .review(|a| h.owns_address(a).map_err(invalid))
            .unwrap();
        assert_eq!(review.outputs.len(), 2);
        assert_eq!(
            review.outputs[0].address,
            Some(h.derive_address(1).unwrap())
        );
        assert_eq!(review.outputs[0].nano_erg, "2998900000");
        assert!(review.outputs[0].owned);
        assert_eq!(review.fee_nano, "1100000");
        assert!(parsed.review(|_| Ok(false)).is_err());
        // The line above proves review honours its callback. This proves
        // sign_reviewed actually passes ownership as that callback: a wallet
        // that does not own the inputs must refuse before signing, and
        // swapping the callback for a constant true makes this fail.
        let stranger = WalletHandle::create(
            MnemonicPhrase::parse(PHRASE).unwrap(),
            "not this wallet",
        )
        .unwrap();
        assert!(!stranger.owns_address(&h.derive_address(1).unwrap()).unwrap());
        // is_err() alone would also pass if signing merely failed for a
        // missing key, so assert the refusal is the ownership one.
        assert!(matches!(
            parsed.sign_reviewed(&stranger),
            Err(ColdError::Invalid(ref m)) if m.contains("does not belong to this cold wallet")
        ));
        parsed
            .verify_bytes(&parsed.sign_reviewed(&h).unwrap())
            .unwrap();
        // Every truncation, every single-byte mutation, and oversized declared
        // message lengths exercise the untrusted entry point (no panic catcher).
        for n in 0..request.reduced_tx.len() {
            let mut raw = RequestBytes::decode(&json).unwrap();
            raw.reduced_tx.truncate(n);
            assert!(crate::cold_request::parse_request(&raw.encode().unwrap()).is_err());
        }
        for i in 0..request.reduced_tx.len() {
            let mut raw = RequestBytes::decode(&json).unwrap();
            raw.reduced_tx[i] ^= 255;
            let _ = crate::cold_request::parse_request(&raw.encode().unwrap());
        }
        for b in 0..request.inputs.len() {
            for n in 0..request.inputs[b].len() {
                let mut raw = RequestBytes::decode(&json).unwrap();
                raw.inputs[b].truncate(n);
                assert!(crate::cold_request::parse_request(&raw.encode().unwrap()).is_err());
            }
        }
        for bytes in [vec![255; 10], vec![255, 255, 255, 255, 15], vec![128, 0]] {
            let mut raw = RequestBytes::decode(&json).unwrap();
            raw.reduced_tx = bytes;
            assert!(crate::cold_request::parse_request(&raw.encode().unwrap()).is_err());
        }
        h.lock();
        assert!(parsed.sign_reviewed(&h).is_err());
    }

    #[test]
    fn bounded_policy_tokens_burns_and_external_recipients() {
        use ergo_lib::ergotree_ir::chain::token::{Token, TokenId};
        let h = WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap();
        let foreign =
            WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "other").unwrap();
        let (r, mut boxes) = preparation(&h, 1);
        let id = TokenId::from(boxes[0].box_id());
        boxes[0] = ErgoBox::new(
            boxes[0].value,
            tree(&h, 0),
            Some(
                vec![Token {
                    token_id: id,
                    amount: 42u64.try_into().unwrap(),
                }]
                .try_into()
                .unwrap(),
            ),
            NonMandatoryRegisters::empty(),
            1000,
            TxId::zero(),
            0,
        )
        .unwrap();
        let mut output = ErgoBoxCandidateBuilder::new(
            BoxValue::try_from(2_998_900_000u64).unwrap(),
            tree(&foreign, 1),
            2000,
        );
        output.add_token(Token {
            token_id: id,
            amount: 40u64.try_into().unwrap(),
        });
        let unsigned = UnsignedTransaction::new_from_vec(
            boxes
                .iter()
                .map(|b| UnsignedInput::new(b.box_id(), ContextExtension::empty()))
                .collect(),
            vec![],
            vec![
                output.build().unwrap(),
                r.unsigned_tx.output_candidates.get(1).unwrap().clone(),
            ],
        )
        .unwrap();
        let reduced =
            build_reduced_transaction(unsigned, boxes.clone(), vec![], &dummy_state_context(2000))
                .unwrap();
        let json = PreparedColdTransaction::new(reduced, boxes)
            .unwrap()
            .request(None)
            .unwrap()
            .encode()
            .unwrap();
        let p = crate::cold_request::parse_request(&json).unwrap();
        let review = p.review(|a| h.owns_address(a).map_err(invalid)).unwrap();
        assert!(!review.outputs[0].owned);
        assert_eq!(
            review.outputs[0].address,
            Some(foreign.derive_address(1).unwrap())
        );
        assert_eq!(review.outputs[0].tokens[0].id, hex::encode(id.as_ref()));
        assert_eq!(review.outputs[0].tokens[0].amount, "40");
        assert_eq!(review.burns[0].amount, "2");
        assert!(review.mints.is_empty());
        p.verify_bytes(&p.sign_reviewed(&h).unwrap()).unwrap();
    }

    #[test]
    fn bounded_policy_rejects_unsupported_appkit_and_hostile_bytes() {
        // The first upstream test uses a non-default miner delay (72, not
        // mainnet's 720). Keep format parity tests, but refuse that fee policy.
        assert!(crate::cold_request::parse_request(include_str!(
            "../tests/fixtures/eip19/appkit-request-1.json"
        ))
        .is_err());
        // This pinned fixture carries registers: transport-compatible, explicitly
        // outside the initial offline policy rather than partially summarized.
        let json = include_str!("../tests/fixtures/eip19/appkit-request-2.json");
        assert!(crate::cold_request::parse_request(json).is_err());
        let h = WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap();
        let (r, boxes) = preparation(&h, 1);
        let json = PreparedColdTransaction::new(r, boxes)
            .unwrap()
            .request(None)
            .unwrap()
            .encode()
            .unwrap();
        let mut raw = RequestBytes::decode(&json).unwrap();
        raw.reduced_tx.push(0);
        assert!(crate::cold_request::parse_request(&raw.encode().unwrap()).is_err());
        let mut raw = RequestBytes::decode(&json).unwrap();
        raw.inputs.swap(0, 1);
        assert!(crate::cold_request::parse_request(&raw.encode().unwrap()).is_err());
        for index in 0..3 {
            let original = RequestBytes::decode(&json).unwrap();
            for byte in 0..original.inputs[index].len() {
                let mut raw = RequestBytes::decode(&json).unwrap();
                raw.inputs[index][byte] ^= 255;
                assert!(crate::cold_request::parse_request(&raw.encode().unwrap()).is_err());
            }
        }
        // Deterministic malformed corpus; no catch_unwind can disguise a panic.
        let mut n = 1234567u64;
        for size in 0..1024 {
            let mut raw = RequestBytes::decode(&json).unwrap();
            raw.reduced_tx = (0..size)
                .map(|_| {
                    n ^= n << 13;
                    n ^= n >> 7;
                    n ^= n << 17;
                    n as u8
                })
                .collect();
            assert!(crate::cold_request::parse_request(&raw.encode().unwrap()).is_err());
        }
    }

    #[test]
    fn appkit_request_binary_parity() {
        for json in [
            include_str!("../tests/fixtures/eip19/appkit-request-1.json"),
            include_str!("../tests/fixtures/eip19/appkit-request-2.json"),
        ] {
            let request = RequestBytes::decode(json).unwrap();
            let reduced = ReducedTransaction::sigma_parse_bytes(&request.reduced_tx).unwrap();
            assert_eq!(reduced.sigma_serialize_bytes().unwrap(), request.reduced_tx);
            let boxes = request
                .inputs
                .iter()
                .map(|b| {
                    let parsed = ErgoBox::sigma_parse_bytes(b).unwrap();
                    assert_eq!(parsed.sigma_serialize_bytes().unwrap(), *b);
                    parsed
                })
                .collect();
            let prepared = PreparedColdTransaction::new(reduced, boxes).unwrap();
            assert_eq!(prepared.request(request.sender.clone()).unwrap(), request);
        }
    }
}
