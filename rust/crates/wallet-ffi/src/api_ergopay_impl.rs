//! ErgoPay (EIP-20) helpers: turn a reduced transaction into the summary the
//! confirm sheet shows. Pure classification lives in [`summarize_reduced`] so
//! it can be tested without a node; the FFI wrapper in `api.rs` fetches input
//! boxes and supplies ownership.

use ergo_lib::chain::transaction::reduced::ReducedTransaction;
use ergo_lib::ergotree_ir::chain::address::{Address, AddressEncoder, NetworkPrefix};
use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;

/// Base58 address for an ErgoTree (P2PK or P2S), or the tree hex when it
/// cannot be expressed as an address.
pub(crate) fn tree_to_address(tree: &ErgoTree) -> String {
    match Address::recreate_from_ergo_tree(tree) {
        Ok(addr) => AddressEncoder::new(NetworkPrefix::Mainnet).address_to_str(&addr),
        Err(_) => tree
            .sigma_serialize_bytes()
            .map(hex::encode)
            .unwrap_or_default(),
    }
}

fn tree_from_hex(hex_tree: &str) -> Option<ErgoTree> {
    let bytes = hex::decode(hex_tree).ok()?;
    ErgoTree::sigma_parse_bytes(&bytes).ok()
}

fn tokens_from_node_json(assets: Option<&serde_json::Value>) -> Vec<serde_json::Value> {
    assets
        .and_then(|a| a.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|t| {
                    let id = t.get("tokenId")?.as_str()?;
                    let amount = t.get("amount")?.as_u64()?;
                    Some(serde_json::json!({ "id": id, "amount": amount }))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Human summary of a reduced transaction.
///
/// `input_boxes` holds the node JSON for each input (same order as the
/// transaction's inputs), or `None` where the box could not be fetched.
/// `is_owned` answers whether an address belongs to the signing wallet.
pub(crate) fn summarize_reduced(
    reduced: &ReducedTransaction,
    is_owned: &dyn Fn(&str) -> bool,
    input_boxes: &[Option<serde_json::Value>],
) -> serde_json::Value {
    summarize_unsigned(&reduced.unsigned_tx, is_owned, input_boxes)
}

/// The same summary for any unsigned transaction, reduced or not: what a
/// wallet-built preparation shows in its confirm sheet's details.
pub(crate) fn summarize_unsigned(
    tx: &ergo_lib::chain::transaction::unsigned::UnsignedTransaction,
    is_owned: &dyn Fn(&str) -> bool,
    input_boxes: &[Option<serde_json::Value>],
) -> serde_json::Value {
    let fee_tree = ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS
        .script()
        .ok();
    let app_fee_tree = tree_from_hex(ergo_tx::DEFAULT_DEV_FEE_ERGO_TREE);

    let mut inputs = Vec::new();
    let mut inputs_known = true;
    let mut input_total: u64 = 0;
    let mut all_inputs_owned = true;
    for (i, input) in tx.inputs.iter().enumerate() {
        let box_id: String = input.box_id.clone().into();
        let json = input_boxes.get(i).and_then(|b| b.as_ref());
        match json {
            Some(b) => {
                let value = b.get("value").and_then(|v| v.as_u64());
                let address = b
                    .get("ergoTree")
                    .and_then(|t| t.as_str())
                    .and_then(tree_from_hex)
                    .map(|t| tree_to_address(&t));
                let owned = address.as_deref().map(is_owned).unwrap_or(false);
                if !owned {
                    all_inputs_owned = false;
                }
                match value {
                    Some(v) => input_total = input_total.saturating_add(v),
                    None => inputs_known = false,
                }
                inputs.push(serde_json::json!({
                    "box_id": box_id,
                    "value_nano_erg": value,
                    "tokens": tokens_from_node_json(b.get("assets")),
                    "address": address,
                    "owned": owned,
                }));
            }
            None => {
                inputs_known = false;
                all_inputs_owned = false;
                inputs.push(serde_json::json!({
                    "box_id": box_id,
                    "value_nano_erg": serde_json::Value::Null,
                    "tokens": [],
                    "address": serde_json::Value::Null,
                    "owned": false,
                }));
            }
        }
    }

    let mut outputs = Vec::new();
    let mut fee: u64 = 0;
    let mut app_fee: u64 = 0;
    let mut sent: u64 = 0;
    let mut change: u64 = 0;
    let mut tokens_out: std::collections::BTreeMap<String, u64> = Default::default();
    let mut tokens_back: std::collections::BTreeMap<String, u64> = Default::default();
    for out in tx.output_candidates.iter() {
        let value = *out.value.as_u64();
        let is_fee = fee_tree
            .as_ref()
            .map(|f| f == &out.ergo_tree)
            .unwrap_or(false);
        let address = tree_to_address(&out.ergo_tree);
        let kind = if is_fee {
            fee = fee.saturating_add(value);
            "fee"
        } else if app_fee_tree.as_ref().is_some_and(|t| *t == out.ergo_tree) {
            app_fee = app_fee.saturating_add(value);
            "app_fee"
        } else if is_owned(&address) {
            change = change.saturating_add(value);
            "change"
        } else {
            sent = sent.saturating_add(value);
            "recipient"
        };
        let tokens: Vec<serde_json::Value> = out
            .tokens
            .as_ref()
            .map(|ts| {
                ts.iter()
                    .map(|t| {
                        let id: String = t.token_id.into();
                        let amount = *t.amount.as_u64();
                        let bucket = match kind {
                            "change" => Some(&mut tokens_back),
                            "recipient" => Some(&mut tokens_out),
                            _ => None,
                        };
                        if let Some(b) = bucket {
                            *b.entry(id.clone()).or_insert(0) += amount;
                        }
                        serde_json::json!({ "id": id, "amount": amount })
                    })
                    .collect()
            })
            .unwrap_or_default();
        outputs.push(serde_json::json!({
            "address": address,
            "value_nano_erg": value,
            "tokens": tokens,
            "kind": kind,
        }));
    }

    let spend = if inputs_known {
        Some(input_total.saturating_sub(change))
    } else {
        None
    };
    let map_tokens = |m: &std::collections::BTreeMap<String, u64>| -> Vec<serde_json::Value> {
        m.iter()
            .map(|(id, amount)| serde_json::json!({ "id": id, "amount": amount }))
            .collect()
    };

    serde_json::json!({
        "tx_id": String::from(tx.id()),
        "inputs": inputs,
        "outputs": outputs,
        "fee_nano_erg": fee,
        "app_fee_nano_erg": app_fee,
        "sent_nano_erg": sent,
        "change_nano_erg": change,
        "spend_nano_erg": spend,
        "input_nano_erg": if inputs_known { Some(input_total) } else { None },
        "inputs_known": inputs_known,
        "all_inputs_owned": all_inputs_owned,
        "tokens_out": map_tokens(&tokens_out),
        "tokens_back": map_tokens(&tokens_back),
        "data_inputs": tx.data_inputs.as_ref().map(|d| d.len()).unwrap_or(0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_lib::chain::ergo_box::box_builder::ErgoBoxCandidateBuilder;
    use ergo_lib::chain::transaction::unsigned::UnsignedTransaction;
    use ergo_lib::chain::transaction::{DataInput, TxIoVec, UnsignedInput};
    use ergo_lib::ergotree_ir::chain::address::{AddressEncoder, NetworkPrefix};
    use ergo_lib::ergotree_ir::chain::context_extension::ContextExtension;
    use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
    use ergo_lib::ergotree_ir::chain::ergo_box::{ErgoBox, NonMandatoryRegisters};
    use ergo_lib::ergotree_ir::chain::token::{Token, TokenAmount, TokenId};
    use ergo_lib::ergotree_ir::chain::tx_id::TxId;
    use wallet_core::seed::MnemonicPhrase;
    use wallet_core::wallet::WalletHandle;

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";
    const STRANGER: &str = "9eYMpbGgBf42bCcnB2nG3wQdqPzpCCw5eB1YaWUUen9uCaW3wwm";

    fn tree(address: &str) -> ergo_lib::ergotree_ir::ergo_tree::ErgoTree {
        AddressEncoder::new(NetworkPrefix::Mainnet)
            .parse_address_from_str(address)
            .unwrap()
            .script()
            .unwrap()
    }

    fn token_id() -> TokenId {
        TokenId::from(ergo_lib::ergo_chain_types::Digest32::from([7u8; 32]))
    }

    /// One owned input of 2 ERG + 10 tokens; outputs: 1 ERG + 4 tokens to a
    /// stranger, change back to us with the remaining 6 tokens, miner fee.
    fn sample() -> (WalletHandle, ReducedTransaction, ErgoBox) {
        let handle = WalletHandle::create(MnemonicPhrase::parse(APPKIT).unwrap(), "").unwrap();
        let mine = handle.derive_address(0).unwrap();
        let tok = Token {
            token_id: token_id(),
            amount: TokenAmount::try_from(10u64).unwrap(),
        };
        let input = ErgoBox::new(
            BoxValue::try_from(2_000_000_000u64).unwrap(),
            tree(&mine),
            Some(vec![tok].try_into().unwrap()),
            NonMandatoryRegisters::empty(),
            1000,
            TxId::zero(),
            0,
        )
        .unwrap();
        let fee = 1_100_000u64;
        let send = 1_000_000_000u64;
        let change = 2_000_000_000u64 - send - fee;
        let mut to =
            ErgoBoxCandidateBuilder::new(BoxValue::try_from(send).unwrap(), tree(STRANGER), 2000);
        to.add_token(Token {
            token_id: token_id(),
            amount: TokenAmount::try_from(4u64).unwrap(),
        });
        let mut back =
            ErgoBoxCandidateBuilder::new(BoxValue::try_from(change).unwrap(), tree(&mine), 2000);
        back.add_token(Token {
            token_id: token_id(),
            amount: TokenAmount::try_from(6u64).unwrap(),
        });
        let fee_out = ErgoBoxCandidateBuilder::new(
            BoxValue::try_from(fee).unwrap(),
            ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS
                .script()
                .unwrap(),
            2000,
        );
        let unsigned = UnsignedTransaction::new(
            TxIoVec::from_vec(vec![UnsignedInput::new(
                input.box_id(),
                ContextExtension::empty(),
            )])
            .unwrap(),
            None::<TxIoVec<DataInput>>,
            TxIoVec::from_vec(vec![
                to.build().unwrap(),
                back.build().unwrap(),
                fee_out.build().unwrap(),
            ])
            .unwrap(),
        )
        .unwrap();
        let reduced = wallet_core::transaction::build_reduced_transaction(
            unsigned,
            vec![input.clone()],
            vec![],
            &wallet_net::client::make_state_context(2000),
        )
        .unwrap();
        (handle, reduced, input)
    }

    #[test]
    fn classifies_outputs_and_sums_totals_with_known_inputs() {
        let (handle, reduced, input) = sample();
        let input_json = serde_json::to_value(&input).unwrap();
        let s = summarize_reduced(
            &reduced,
            &|a| handle.owns_address(a).unwrap_or(false),
            &[Some(input_json)],
        );

        assert_eq!(s["fee_nano_erg"], 1_100_000u64);
        assert_eq!(s["sent_nano_erg"], 1_000_000_000u64);
        assert_eq!(
            s["change_nano_erg"],
            2_000_000_000u64 - 1_000_000_000 - 1_100_000
        );
        assert_eq!(s["spend_nano_erg"], 1_001_100_000u64);
        assert_eq!(s["inputs_known"], true);
        let kinds: Vec<&str> = s["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| o["kind"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["recipient", "change", "fee"]);
        assert_eq!(s["outputs"][0]["address"], STRANGER);
        assert_eq!(s["tokens_out"][0]["amount"], 4u64);
        assert_eq!(s["inputs"][0]["owned"], true);
        assert_eq!(s["inputs"][0]["value_nano_erg"], 2_000_000_000u64);
    }

    #[test]
    fn unknown_inputs_leave_spend_absent() {
        let (handle, reduced, _) = sample();
        let s = summarize_reduced(
            &reduced,
            &|a| handle.owns_address(a).unwrap_or(false),
            &[None],
        );

        assert_eq!(s["inputs_known"], false);
        assert!(s["spend_nano_erg"].is_null());
        assert_eq!(s["fee_nano_erg"], 1_100_000u64);
        assert!(s["inputs"][0]["value_nano_erg"].is_null());
    }
}

/// EIP-4 token media from an issuance box's registers: R7 marks the asset
/// type (`0e020101` picture, `0e020102` audio, `0e020103` video) and R9
/// carries a link as a serialised `Coll[Byte]`.
pub(crate) fn decode_coll_byte_register(hex_value: &str) -> Option<String> {
    let bytes = hex::decode(hex_value.trim()).ok()?;
    // 0x0e = SColl(SByte); then a VLQ length, then the bytes.
    if bytes.first() != Some(&0x0e) {
        return None;
    }
    let mut i = 1;
    let mut len: usize = 0;
    let mut shift = 0;
    loop {
        let b = *bytes.get(i)?;
        i += 1;
        len |= ((b & 0x7f) as usize) << shift;
        if b & 0x80 == 0 {
            break;
        }
        shift += 7;
        if shift > 28 {
            return None;
        }
    }
    let slice = bytes.get(i..i + len)?;
    String::from_utf8(slice.to_vec()).ok()
}

/// `picture` / `audio` / `video` for an EIP-4 R7 value, else None.
pub(crate) fn eip4_media_kind(r7_hex: &str) -> Option<&'static str> {
    match r7_hex.trim() {
        "0e020101" => Some("picture"),
        "0e020102" => Some("audio"),
        "0e020103" => Some("video"),
        _ => None,
    }
}

/// A usable media link: http(s) or ipfs.
pub(crate) fn is_media_link(s: &str) -> bool {
    let t = s.trim();
    t.starts_with("https://") || t.starts_with("http://") || t.starts_with("ipfs://")
}

#[cfg(test)]
mod media_tests {
    use super::*;

    #[test]
    fn decodes_a_coll_byte_link_register() {
        // 0e + len(0x1b = 27) + "ipfs://bafyexampleexample12"
        let link = "ipfs://bafyexampleexample12";
        let hex = format!("0e{:02x}{}", link.len(), hex::encode(link));
        assert_eq!(decode_coll_byte_register(&hex).as_deref(), Some(link));
    }

    #[test]
    fn rejects_non_coll_registers_and_bad_lengths() {
        assert!(decode_coll_byte_register("0402").is_none());
        assert!(decode_coll_byte_register("0eff").is_none());
        assert!(decode_coll_byte_register("zz").is_none());
    }

    #[test]
    fn classifies_eip4_media_kinds() {
        assert_eq!(eip4_media_kind("0e020101"), Some("picture"));
        assert_eq!(eip4_media_kind("0e020103"), Some("video"));
        assert_eq!(eip4_media_kind("0e020199"), None);
        assert!(is_media_link("ipfs://x"));
        assert!(!is_media_link("javascript:alert(1)"));
    }
}
