//! Stealth-address helpers behind the FFI surface in `api.rs`.
//!
//! Everything here is pure or takes an unlocked `WalletHandle`; no network
//! calls, so it is unit-testable. The stealth secret `x` is derived on demand
//! and dropped with the value it produced — it is never cached, logged or
//! serialized.

use std::collections::HashMap;

use ergo_lib::wallet::secret_key::SecretKey;
use ergo_tx::{
    append_dev_fee_output, resolved_dev_fee_config, Eip12Asset, Eip12InputBox, Eip12Output,
    Eip12UnsignedTx,
};
use wallet_core::wallet::WalletHandle;

use crate::error::ArgusError;

use citadel_core::constants::{MIN_BOX_VALUE_NANO, TX_FEE_NANO};

fn err(e: impl std::fmt::Display) -> String {
    ArgusError::TxBuildFailed(e.to_string()).to_json_string()
}

/// Derive one DH-tuple secret per stealth input.
///
/// Fails loudly if a tree is not ours, rather than producing a transaction
/// that cannot be signed.
pub fn dht_secrets_for(
    handle: &WalletHandle,
    stealth_trees: &[String],
) -> Result<Vec<SecretKey>, String> {
    let secret = handle
        .stealth_secret()
        .map_err(|e| ArgusError::SigningFailed(e.to_string()).to_json_string())?;
    stealth_trees
        .iter()
        .map(|tree| {
            secret
                .dht_prover_input_for_tree(tree)
                .map(SecretKey::DhtSecretKey)
                .map_err(|e| ArgusError::SigningFailed(e.to_string()).to_json_string())
        })
        .collect()
}

/// A stealth box as the Dart side sees it.
pub fn owned_box_json(b: &stealth::StealthBox) -> serde_json::Value {
    serde_json::json!({
        "box_id": b.box_id,
        "value_nano_erg": b.value,
        "creation_height": b.creation_height,
        "ergo_tree": b.ergo_tree,
        "assets": b.assets.iter().map(|a| serde_json::json!({
            "token_id": a.token_id,
            "amount": a.amount,
        })).collect::<Vec<_>>(),
    })
}

/// Scan a batch of explorer boxes and report the ones we can spend.
pub fn scan(secret: &stealth::StealthSecret, explorer_json: &str) -> Result<String, String> {
    let all = stealth::parse_explorer_boxes(explorer_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let owned = stealth::detect_owned(secret, &all);
    let (erg, tokens) = stealth::totals(&owned);
    serde_json::to_string(&serde_json::json!({
        "scanned": all.len(),
        "owned_count": owned.len(),
        "total_nano_erg": erg,
        "tokens": tokens.iter().map(|(id, amount)| serde_json::json!({
            "token_id": id,
            "amount": amount.to_string(),
        })).collect::<Vec<_>>(),
        "boxes": owned.iter().map(owned_box_json).collect::<Vec<_>>(),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Convert a detected stealth box into the EIP-12 input shape the builders use.
pub fn to_input(b: &stealth::StealthBox) -> Eip12InputBox {
    Eip12InputBox {
        box_id: b.box_id.clone(),
        transaction_id: b.transaction_id.clone(),
        index: b.index,
        value: b.value.to_string(),
        ergo_tree: b.ergo_tree.clone(),
        assets: b
            .assets
            .iter()
            .map(|a| Eip12Asset {
                token_id: a.token_id.clone(),
                amount: a.amount.clone(),
            })
            .collect(),
        creation_height: b.creation_height,
        additional_registers: b.additional_registers.clone().into_iter().collect(),
        extension: HashMap::new(),
    }
}

pub struct SweepBuild {
    pub unsigned_tx: Eip12UnsignedTx,
    pub swept_erg: i64,
    pub miner_fee: i64,
    pub app_fee_nano: i64,
    pub input_count: usize,
    pub token_count: usize,
}

/// Build a "move everything to one of my own addresses" transaction.
///
/// Unlike consolidation this accepts a single input: one stealth receipt is
/// the common case. Every token in every swept box lands in the one output.
pub fn build_sweep(
    inputs: &[Eip12InputBox],
    destination_ergo_tree: &str,
    height: i32,
    fee_nano: Option<i64>,
) -> Result<SweepBuild, String> {
    if inputs.is_empty() {
        return Err(ArgusError::NoUtxos("no stealth boxes to sweep".into()).to_json_string());
    }
    let miner_fee = fee_nano.unwrap_or(TX_FEE_NANO);
    if miner_fee < TX_FEE_NANO {
        return Err(err(format!(
            "custom fee {miner_fee} nanoERG is below minimum {TX_FEE_NANO}"
        )));
    }

    // Box values are attacker-influenced (anyone can pay a stealth address),
    // so the sum is checked rather than allowed to wrap.
    let mut total_erg: i64 = 0;
    for b in inputs {
        let v = b
            .value
            .parse::<i64>()
            .map_err(|_| err(format!("box {} has an unparsable value", b.box_id)))?;
        total_erg = total_erg
            .checked_add(v)
            .ok_or_else(|| err("stealth box total is out of range"))?;
    }
    let fee_cfg = resolved_dev_fee_config();
    let app_fee = fee_cfg.budget();
    let needed = miner_fee
        .checked_add(app_fee)
        .and_then(|v| v.checked_add(MIN_BOX_VALUE_NANO))
        .ok_or_else(|| err("sweep amount out of range"))?;
    if total_erg < needed {
        return Err(err(format!(
            "stealth boxes hold {total_erg} nanoERG, a sweep needs at least {needed}"
        )));
    }

    let mut token_totals: Vec<(String, u128)> = Vec::new();
    for input in inputs {
        for asset in &input.assets {
            let amount = asset.amount.parse::<u128>().unwrap_or(0);
            match token_totals.iter_mut().find(|(id, _)| *id == asset.token_id) {
                Some((_, total)) => *total += amount,
                None => token_totals.push((asset.token_id.clone(), amount)),
            }
        }
    }
    if token_totals.len() > 255 {
        return Err(err(format!(
            "{} distinct tokens exceeds the 255 per box limit; sweep fewer boxes",
            token_totals.len()
        )));
    }

    let swept_erg = total_erg - miner_fee - app_fee;
    let destination = Eip12Output {
        value: swept_erg.to_string(),
        ergo_tree: destination_ergo_tree.to_string(),
        assets: token_totals
            .iter()
            .map(|(id, amount)| Eip12Asset {
                token_id: id.clone(),
                amount: amount.to_string(),
            })
            .collect(),
        creation_height: height,
        additional_registers: HashMap::new(),
    };

    let mut outputs = vec![destination];
    append_dev_fee_output(&mut outputs, &fee_cfg, height).map_err(err)?;
    outputs.push(Eip12Output::fee(miner_fee, height));

    Ok(SweepBuild {
        unsigned_tx: Eip12UnsignedTx {
            inputs: inputs.to_vec(),
            data_inputs: vec![],
            outputs,
        },
        swept_erg,
        miner_fee,
        app_fee_nano: app_fee,
        input_count: inputs.len(),
        token_count: token_totals.len(),
    })
}

/// Rebuild an `ErgoBox` from a detected stealth box.
///
/// The explorer is the only source for these boxes, so the node cannot be
/// asked for them; the JSON carries every field `ErgoBox` needs.
pub fn to_ergo_box(
    b: &stealth::StealthBox,
) -> Result<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox, String> {
    let parsed: ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox =
        serde_json::from_value(b.to_node_json()).map_err(|e| {
            ArgusError::SerializationError(format!("stealth box {}: {e}", b.box_id))
                .to_json_string()
        })?;
    if parsed.box_id().to_string() != b.box_id {
        return Err(err(format!(
            "stealth box {} did not round-trip to the same box id",
            b.box_id
        )));
    }
    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
    use ergo_lib::wallet::mnemonic::Mnemonic;

    const FIXTURE: &str =
        include_str!("../../vendor/protocols/stealth/test/fixtures/unspent_stealth_boxes.json");
    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    fn secret() -> stealth::StealthSecret {
        let seed = Mnemonic::to_seed(APPKIT, "");
        stealth::StealthSecret::derive(&ExtSecretKey::derive_master(seed).unwrap()).unwrap()
    }

    fn my_box(value: i64, tokens: &[(&str, &str)]) -> stealth::StealthBox {
        stealth::StealthBox {
            box_id: format!("{:064x}", value),
            transaction_id: "b".repeat(64),
            index: 0,
            value,
            ergo_tree: stealth::build_payment_tree_hex(secret().public_key()).unwrap(),
            creation_height: 1_000_000,
            assets: tokens
                .iter()
                .map(|(id, amount)| stealth::StealthAsset {
                    token_id: (*id).to_string(),
                    amount: (*amount).to_string(),
                })
                .collect(),
            additional_registers: Default::default(),
        }
    }

    #[test]
    fn scan_reports_nothing_for_a_stranger_wallet() {
        let out = scan(&secret(), FIXTURE).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["scanned"], 3);
        assert_eq!(v["owned_count"], 0);
        assert_eq!(v["total_nano_erg"], 0);
    }

    #[test]
    fn scan_reports_our_own_boxes_with_totals() {
        let mut items: Vec<serde_json::Value> =
            serde_json::from_str::<serde_json::Value>(FIXTURE).unwrap()["items"]
                .as_array()
                .unwrap()
                .clone();
        let mine = my_box(1_500_000, &[("aa", "7")]);
        items.push(serde_json::from_str(&serde_json::to_string(&mine.to_node_json()).unwrap()).unwrap());
        let json = serde_json::json!({ "items": items }).to_string();

        let v: serde_json::Value = serde_json::from_str(&scan(&secret(), &json).unwrap()).unwrap();
        assert_eq!(v["scanned"], 4);
        assert_eq!(v["owned_count"], 1);
        assert_eq!(v["total_nano_erg"], 1_500_000);
        assert_eq!(v["tokens"][0]["token_id"], "aa");
        assert_eq!(v["tokens"][0]["amount"], "7");
        assert_eq!(v["boxes"][0]["box_id"], mine.box_id);
    }

    #[test]
    fn scan_of_an_unreachable_explorer_body_is_an_error_not_a_panic() {
        assert!(scan(&secret(), "<html>502 Bad Gateway</html>").is_err());
    }

    #[test]
    fn sweep_moves_erg_and_every_token_into_one_output() {
        let inputs = vec![
            to_input(&my_box(1_000_000_000, &[("aa", "3")])),
            to_input(&my_box(500_000_000, &[("aa", "4"), ("bb", "1")])),
        ];
        let dest = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let built = build_sweep(&inputs, dest, 1_000_000, None).unwrap();

        assert_eq!(built.input_count, 2);
        assert_eq!(built.token_count, 2);
        let out = &built.unsigned_tx.outputs[0];
        assert_eq!(out.ergo_tree, dest);
        assert_eq!(
            out.value.parse::<i64>().unwrap(),
            1_500_000_000 - built.miner_fee - built.app_fee_nano
        );
        let aa = out.assets.iter().find(|a| a.token_id == "aa").unwrap();
        assert_eq!(aa.amount, "7");
        // Miner fee is the last output.
        let fee_out = built.unsigned_tx.outputs.last().unwrap();
        assert_eq!(fee_out.value.parse::<i64>().unwrap(), built.miner_fee);
    }

    #[test]
    fn sweep_accepts_a_single_box() {
        let inputs = vec![to_input(&my_box(10_000_000, &[]))];
        let built = build_sweep(
            &inputs,
            "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            1,
            None,
        )
        .unwrap();
        assert_eq!(built.input_count, 1);
        assert_eq!(built.token_count, 0);
    }

    #[test]
    fn sweep_refuses_dust_and_empty_sets() {
        assert!(build_sweep(&[], "00", 1, None).is_err());
        let inputs = vec![to_input(&my_box(100_000, &[]))];
        assert!(build_sweep(&inputs, "00", 1, None).is_err());
    }

    #[test]
    fn sweep_refuses_a_fee_below_the_protocol_minimum() {
        let inputs = vec![to_input(&my_box(10_000_000, &[]))];
        assert!(build_sweep(&inputs, "00", 1, Some(1)).is_err());
    }

    #[test]
    fn detected_boxes_rebuild_into_ergo_boxes_with_matching_ids() {
        let boxes = stealth::parse_explorer_boxes(FIXTURE).unwrap();
        for b in &boxes {
            let ergo_box = to_ergo_box(b).unwrap();
            assert_eq!(ergo_box.box_id().to_string(), b.box_id);
        }
    }
}
