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
/// Each tree is resolved against every identity in use, not just identity 0:
/// a box paid to a later identity is detected by that identity's key and must
/// be signed with it. Fails loudly if a tree belongs to none of them, rather
/// than producing a transaction that cannot be signed.
pub fn dht_secrets_for(
    handle: &WalletHandle,
    stealth_trees: &[String],
) -> Result<Vec<SecretKey>, String> {
    let secrets = handle
        .stealth_secrets_in_use()
        .map_err(|e| ArgusError::SigningFailed(e.to_string()).to_json_string())?;
    stealth_trees
        .iter()
        .map(|tree| {
            stealth::identity_for_tree(&secrets, tree)
                .ok_or_else(|| {
                    ArgusError::SigningFailed(
                        "a stealth input belongs to no identity of this wallet".into(),
                    )
                    .to_json_string()
                })?
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
        // The creating transaction: enough for the activity list to show a
        // stealth receipt without any further lookup.
        "transaction_id": b.transaction_id,
        "index": b.index,
        "value_nano_erg": b.value,
        "creation_height": b.creation_height,
        "ergo_tree": b.ergo_tree,
        "assets": b.assets.iter().map(|a| serde_json::json!({
            "token_id": a.token_id,
            "amount": a.amount,
        })).collect::<Vec<_>>(),
    })
}

/// The same box, tagged with the identity that owns it.
fn owned_box_json_with_identity(o: &stealth::OwnedStealthBox) -> serde_json::Value {
    let mut json = owned_box_json(&o.owned);
    json["identity"] = serde_json::json!(o.identity);
    json
}

fn token_totals_json(tokens: &std::collections::BTreeMap<String, u128>) -> serde_json::Value {
    serde_json::json!(tokens
        .iter()
        .map(|(id, amount)| serde_json::json!({
            "token_id": id,
            "amount": amount.to_string(),
        }))
        .collect::<Vec<_>>())
}

/// Scan a batch of explorer boxes and report the ones we can spend.
///
/// Totals are reported both as a wallet-wide figure — what the balance card
/// shows, unchanged from when there was one identity — and broken down per
/// identity, which is what the privacy settings list needs.
pub fn scan(secrets: &[stealth::StealthSecret], explorer_json: &str) -> Result<String, String> {
    let all = stealth::parse_explorer_boxes(explorer_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let owned = stealth::detect_owned_multi(secrets, &all);
    let flat: Vec<stealth::StealthBox> = owned.iter().map(|o| o.owned.clone()).collect();
    let (erg, tokens) = stealth::totals(&flat);

    // Every identity in use gets a row, funded or not: an identity with no
    // payments yet is exactly the case the UI has to be able to show.
    let per_identity = secrets.iter().map(|s| {
        let mine: Vec<stealth::StealthBox> = owned
            .iter()
            .filter(|o| o.identity == s.index())
            .map(|o| o.owned.clone())
            .collect();
        let (erg, tokens) = stealth::totals(&mine);
        serde_json::json!({
            "index": s.index(),
            "owned_count": mine.len(),
            "total_nano_erg": erg,
            "tokens": token_totals_json(&tokens),
        })
    });

    serde_json::to_string(&serde_json::json!({
        "scanned": all.len(),
        "owned_count": owned.len(),
        "total_nano_erg": erg,
        "tokens": token_totals_json(&tokens),
        "boxes": owned.iter().map(owned_box_json_with_identity).collect::<Vec<_>>(),
        "identities": per_identity.collect::<Vec<_>>(),
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
    // The Dart fetch de-duplicates, but this is a public FFI taking raw
    // JSON: a repeated box would be counted twice here and then rejected by
    // the node as a duplicate input, after the user had signed.
    let mut seen = std::collections::BTreeSet::new();
    for b in inputs {
        if !seen.insert(b.box_id.as_str()) {
            return Err(err(format!("box {} appears more than once", b.box_id)));
        }
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
            match token_totals
                .iter_mut()
                .find(|(id, _)| *id == asset.token_id)
            {
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

    fn root() -> ExtSecretKey {
        ExtSecretKey::derive_master(Mnemonic::to_seed(APPKIT, "")).unwrap()
    }

    fn secret() -> stealth::StealthSecret {
        stealth::StealthSecret::derive(&root()).unwrap()
    }

    fn identities(count: u32) -> Vec<stealth::StealthSecret> {
        stealth::StealthSecret::derive_range(&root(), count).unwrap()
    }

    fn box_for(
        who: &stealth::StealthSecret,
        value: i64,
        tokens: &[(&str, &str)],
    ) -> stealth::StealthBox {
        stealth::StealthBox {
            box_id: format!("{:064x}", value + who.index() as i64),
            transaction_id: "b".repeat(64),
            index: 0,
            value,
            ergo_tree: stealth::build_payment_tree_hex(who.public_key()).unwrap(),
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

    fn my_box(value: i64, tokens: &[(&str, &str)]) -> stealth::StealthBox {
        box_for(&secret(), value, tokens)
    }

    /// Boxes plus the fixture's strangers, as an explorer body.
    fn body_with(boxes: &[stealth::StealthBox]) -> String {
        let mut items: Vec<serde_json::Value> = serde_json::from_str::<serde_json::Value>(FIXTURE)
            .unwrap()["items"]
            .as_array()
            .unwrap()
            .clone();
        for b in boxes {
            items.push(b.to_node_json());
        }
        serde_json::json!({ "items": items }).to_string()
    }

    #[test]
    fn scan_reports_nothing_for_a_stranger_wallet() {
        let out = scan(&[secret()], FIXTURE).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["scanned"], 3);
        assert_eq!(v["owned_count"], 0);
        assert_eq!(v["total_nano_erg"], 0);
    }

    /// The wallet-wide totals must not change shape or meaning now that they
    /// are summed across identities — the balance card reads them.
    #[test]
    fn scan_totals_span_every_identity_and_each_box_names_its_owner() {
        let ids = identities(4);
        let body = body_with(&[
            box_for(&ids[0], 1_000_000, &[("aa", "2")]),
            box_for(&ids[2], 3_000_000, &[("aa", "5"), ("bb", "1")]),
            box_for(&ids[2], 500_000, &[]),
        ]);

        let v: serde_json::Value = serde_json::from_str(&scan(&ids, &body).unwrap()).unwrap();
        assert_eq!(v["scanned"], 6);
        assert_eq!(v["owned_count"], 3);
        assert_eq!(v["total_nano_erg"], 4_500_000);

        let owners: Vec<u64> = v["boxes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["identity"].as_u64().unwrap())
            .collect();
        assert_eq!(owners, vec![0, 2, 2]);

        // Every identity in use gets a row, funded or not.
        let rows = v["identities"].as_array().unwrap();
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0]["total_nano_erg"], 1_000_000);
        assert_eq!(rows[1]["total_nano_erg"], 0);
        assert_eq!(rows[1]["owned_count"], 0);
        assert_eq!(rows[2]["total_nano_erg"], 3_500_000);
        assert_eq!(rows[2]["owned_count"], 2);
        assert_eq!(rows[2]["tokens"][0]["token_id"], "aa");
        assert_eq!(rows[2]["tokens"][0]["amount"], "5");
        assert_eq!(rows[3]["owned_count"], 0);
    }

    /// A session that has not raised its frontier must not see, or claim,
    /// funds sitting on an identity it does not know about.
    #[test]
    fn a_narrower_identity_set_leaves_higher_identities_alone() {
        let ids = identities(4);
        let body = body_with(&[box_for(&ids[3], 9_000_000, &[])]);

        let narrow: serde_json::Value =
            serde_json::from_str(&scan(&ids[..1], &body).unwrap()).unwrap();
        assert_eq!(narrow["owned_count"], 0);
        assert_eq!(narrow["total_nano_erg"], 0);
        assert_eq!(narrow["identities"].as_array().unwrap().len(), 1);

        let wide: serde_json::Value = serde_json::from_str(&scan(&ids, &body).unwrap()).unwrap();
        assert_eq!(wide["owned_count"], 1);
        assert_eq!(wide["total_nano_erg"], 9_000_000);
    }

    #[test]
    fn scan_reports_our_own_boxes_with_totals() {
        let mine = my_box(1_500_000, &[("aa", "7")]);
        let json = body_with(&[mine.clone()]);

        let v: serde_json::Value = serde_json::from_str(&scan(&[secret()], &json).unwrap()).unwrap();
        assert_eq!(v["scanned"], 4);
        assert_eq!(v["owned_count"], 1);
        assert_eq!(v["total_nano_erg"], 1_500_000);
        assert_eq!(v["tokens"][0]["token_id"], "aa");
        assert_eq!(v["tokens"][0]["amount"], "7");
        assert_eq!(v["boxes"][0]["box_id"], mine.box_id);
        assert_eq!(v["boxes"][0]["transaction_id"], mine.transaction_id);
    }

    #[test]
    fn scan_of_an_unreachable_explorer_body_is_an_error_not_a_panic() {
        assert!(scan(&[secret()], "<html>502 Bad Gateway</html>").is_err());
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

    /// The bug this guards: detection finds a box paid to identity 2, but
    /// signing derives identity 0's key, so the transaction cannot be signed
    /// and the funds are stuck. Every identity in use must be tried.
    #[test]
    fn signing_resolves_a_box_to_the_identity_that_owns_it() {
        use wallet_core::seed::MnemonicPhrase;

        let handle = WalletHandle::create(MnemonicPhrase::parse(APPKIT).unwrap(), "").unwrap();
        let ids = identities(3);
        let trees: Vec<String> = ids
            .iter()
            .map(|s| stealth::build_payment_tree_hex(s.public_key()).unwrap())
            .collect();

        // Only identity 0 is in use: its own box signs, the others do not.
        assert_eq!(dht_secrets_for(&handle, &trees[..1]).unwrap().len(), 1);
        let err = dht_secrets_for(&handle, &trees).unwrap_err();
        assert!(err.contains("no identity of this wallet"), "{err}");

        // Once the frontier covers them, all three sign.
        handle.ensure_stealth_identity(2).unwrap();
        assert_eq!(dht_secrets_for(&handle, &trees).unwrap().len(), 3);

        // A stranger's box is still refused, loudly, at build time.
        let stranger = stealth::StealthSecret::derive(
            &ExtSecretKey::derive_master(Mnemonic::to_seed(
                "race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty",
                "",
            ))
            .unwrap(),
        )
        .unwrap();
        let theirs = stealth::build_payment_tree_hex(stranger.public_key()).unwrap();
        assert!(dht_secrets_for(&handle, &[theirs]).is_err());
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

#[cfg(test)]
mod sweep_input_tests {
    use ergo_tx::Eip12InputBox;

    fn boxx(id: &str, value: &str) -> Eip12InputBox {
        Eip12InputBox {
            box_id: id.to_string(),
            transaction_id: "0".repeat(64),
            index: 0,
            ergo_tree: "10040e21".to_string(),
            creation_height: 1,
            value: value.to_string(),
            assets: vec![],
            additional_registers: Default::default(),
            extension: Default::default(),
        }
    }

    /// A repeated box would be counted twice and then rejected by the node
    /// as a duplicate input, after the user had already signed.
    #[test]
    fn a_repeated_box_is_refused_before_signing() {
        let err = super::build_sweep(
            &[boxx("aa", "1000000000"), boxx("aa", "1000000000")],
            "0008cd0281a2e429779249d99048aa63152838b735174a4302d0f38dfbacbcb78524beb3",
            1,
            None,
        )
        .err()
        .expect("duplicate box must be refused");
        assert!(err.contains("more than once"), "{err}");
    }

    /// Attacker-supplied values must not wrap the total.
    #[test]
    fn an_overflowing_total_is_refused() {
        let err = super::build_sweep(
            &[
                boxx("aa", &i64::MAX.to_string()),
                boxx("bb", &i64::MAX.to_string()),
            ],
            "0008cd0281a2e429779249d99048aa63152838b735174a4302d0f38dfbacbcb78524beb3",
            1,
            None,
        )
        .err()
        .expect("overflowing total must be refused");
        assert!(err.contains("out of range"), "{err}");
    }
}
