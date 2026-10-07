//! An input whose context extension has five or more entries must be signed
//! over the entries in the order the Ergo node serializes them (Scala 2.12
//! HashMap iteration order); any other order changes the bytes to sign and
//! the node rejects the signature. sigma-rust fixed this after 0.28 (#843);
//! this pins the fix through Argus's EIP-12 conversion, which inserts the
//! entries in HashMap order.

use std::collections::HashMap;

use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_tx::{Eip12InputBox, Eip12Output, Eip12UnsignedTx};

fn tx_with_extension(keys: &[u8]) -> Eip12UnsignedTx {
    // SInt constants: type 0x04, then the zigzag-VLQ value (2 * key).
    let extension: HashMap<String, String> = keys
        .iter()
        .map(|k| (k.to_string(), format!("04{:02x}", 2 * k)))
        .collect();
    let tree = ergo_tx::address_to_ergo_tree("9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ")
        .unwrap();
    Eip12UnsignedTx {
        inputs: vec![Eip12InputBox {
            box_id: "11".repeat(32),
            transaction_id: "22".repeat(32),
            index: 0,
            value: "2000000".into(),
            ergo_tree: tree.clone(),
            assets: vec![],
            creation_height: 100,
            additional_registers: HashMap::new(),
            extension,
        }],
        data_inputs: vec![],
        outputs: vec![Eip12Output::simple(1_000_000, tree, 100)],
    }
}

/// Keys in the order they are serialized inside the bytes to sign.
fn signed_key_order(keys: &[u8]) -> Vec<u8> {
    let unsigned = ergo_tx::chain::to_unsigned_transaction(&tx_with_extension(keys)).unwrap();
    let extension = unsigned
        .inputs
        .first()
        .extension
        .sigma_serialize_bytes()
        .unwrap();
    let message = unsigned.bytes_to_sign().unwrap();
    assert!(
        message
            .windows(extension.len())
            .any(|w| w == extension.as_slice()),
        "the extension is signed as serialized"
    );
    assert_eq!(usize::from(extension[0]), keys.len());
    // Each entry is the key byte followed by a two-byte SInt constant.
    extension[1..].chunks(3).map(|entry| entry[0]).collect()
}

#[test]
fn five_or_more_entries_follow_the_node_order() {
    for _ in 0..20 {
        assert_eq!(signed_key_order(&[0, 1, 2, 3, 4, 5]), [0, 5, 1, 2, 3, 4]);
        assert_eq!(signed_key_order(&[0, 1, 2, 3, 4]), [0, 1, 2, 3, 4]);
    }
}
