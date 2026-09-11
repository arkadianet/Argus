//! Stake recovery parsing and wallet ownership boundary.
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use serde_json::{json, Value};
use stake_recovery::{contracts::Pool, validation, StakeBox, StakeStateBox};

use crate::{api_sigmafi_impl::parse_box, error::ArgusError};

fn error(e: impl std::fmt::Display) -> String {
    ArgusError::SerializationError(e.to_string()).to_json_string()
}

fn pool(id: &str) -> Result<Pool, String> {
    match id {
        "ergopad" => Ok(Pool::Ergopad),
        "paideia" => Ok(Pool::Paideia),
        "egio" => Ok(Pool::Egio),
        _ => Err(error("unknown staking pool")),
    }
}

pub fn contracts_json() -> Result<String, String> {
    let pools = [Pool::Ergopad, Pool::Paideia, Pool::Egio]
        .into_iter()
        .map(|p| {
            let c = p.contracts();
            Ok(json!({
                "id": c.name.to_ascii_lowercase(), "name": c.name, "active": c.active,
                "stake_address": c.stake_address,
                "stake_tree": hex::encode(c.stake_tree().map_err(error)?.sigma_serialize_bytes().map_err(error)?),
                "state_nft": c.state_nft, "reward_token": c.reward_token,
                "reward_decimals": c.reward_decimals,
            }))
        })
        .collect::<Result<Vec<Value>, String>>()?;
    Ok(json!(pools).to_string())
}

pub fn state_json(pool_id: &str, box_json: &str) -> Result<String, String> {
    let state = StakeStateBox::parse(&parse_box(box_json)?, pool(pool_id)?).map_err(error)?;
    Ok(json!({
        "box_id": state.input().box_id, "checkpoint": state.checkpoint(),
        "total_staked": state.total_staked().to_string(), "stakers": state.stakers(),
        "last_checkpoint_ms": state.last_checkpoint_ms(), "cycle_duration_ms": state.cycle_duration_ms(),
        "stake_token_amount": state.stake_token_amount().to_string(),
    }).to_string())
}

/// Invalid boxes are reported, never silently interpreted as absence. The caller
/// also rejects ambiguity across pages. An optional current state supplies input
/// eligibility, not a promise that a future transaction can be built.
pub fn positions_json(
    pool_id: &str,
    boxes_json: &str,
    keys_json: &str,
    state_box_json: &str,
) -> Result<String, String> {
    let pool = pool(pool_id)?;
    let ids: Vec<String> = serde_json::from_str(keys_json).map_err(error)?;
    let keys = ids
        .iter()
        .map(|id| {
            hex::decode(id)
                .map_err(error)?
                .try_into()
                .map_err(|_| error("candidate key must be 32 bytes"))
        })
        .collect::<Result<std::collections::HashSet<[u8; 32]>, String>>()?;
    let items: Vec<Value> = serde_json::from_str(boxes_json).map_err(error)?;
    let state = if state_box_json.is_empty() {
        None
    } else {
        Some(StakeStateBox::parse(&parse_box(state_box_json)?, pool).map_err(error)?)
    };
    let mut positions = Vec::new();
    let mut rejected = Vec::new();
    for item in items {
        match parse_box(&item.to_string()).and_then(|b| StakeBox::parse(&b, pool).map_err(error)) {
            Ok(s) if keys.contains(s.key_id()) => positions.push(s),
            Ok(_) => {}
            Err(e) => rejected.push(e),
        }
    }
    let mut out = Vec::new();
    let mut ambiguous = Vec::new();
    for key in keys {
        match validation::unique_position(&positions, pool, &key) {
            Ok(Some(s)) => {
                let eligibility = state
                    .as_ref()
                    .map(|state| validation::validate_full_unstake(state, s));
                out.push(json!({
                    "box_id": s.input().box_id, "key_id": hex::encode(key),
                    "reward_amount": s.reward_amount().to_string(), "checkpoint": s.checkpoint(),
                    "stake_time_ms": s.stake_time_ms(),
                    "eligible": eligibility.as_ref().map(Result::is_ok),
                    "eligibility_error": eligibility.and_then(Result::err).map(|e| e.to_string()),
                }));
            }
            Ok(None) => {}
            Err(_) => ambiguous.push(hex::encode(key)),
        }
    }
    Ok(json!({"positions": out, "rejected": rejected, "ambiguous_keys": ambiguous}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    const ERGOPAD: &str =
        include_str!("../../vendor/protocols/stake-recovery/tests/fixtures/ergopad.json");
    const PAIDEIA: &str =
        include_str!("../../vendor/protocols/stake-recovery/tests/fixtures/paideia-unstake.json");

    #[test]
    fn historical_pages_state_and_candidate_matching() {
        for (id, fixture, reward) in [
            ("ergopad", ERGOPAD, "614682"),
            ("paideia", PAIDEIA, "850495800"),
        ] {
            let history: Value = serde_json::from_str(fixture).unwrap();
            let input = &history["inputs"][1];
            let parsed =
                StakeBox::parse(&parse_box(&input.to_string()).unwrap(), pool(id).unwrap())
                    .unwrap();
            let keys = json!([hex::encode(parsed.key_id())]).to_string();
            let state = history["inputs"][0].to_string();
            let snapshot: Value = serde_json::from_str(&state_json(id, &state).unwrap()).unwrap();
            assert_eq!(snapshot["checkpoint"], parsed.checkpoint());
            let result: Value = serde_json::from_str(
                &positions_json(id, &json!([input]).to_string(), &keys, &state).unwrap(),
            )
            .unwrap();
            assert_eq!(result["positions"][0]["reward_amount"], reward);
            assert_eq!(result["positions"][0]["eligible"], true);
            assert_eq!(result["rejected"], json!([]));
            let absent: Value = serde_json::from_str(
                &positions_json(
                    id,
                    &json!([input]).to_string(),
                    &json!(["00".repeat(32)]).to_string(),
                    "",
                )
                .unwrap(),
            )
            .unwrap();
            assert_eq!(absent["positions"], json!([]));
            let duplicate: Value = serde_json::from_str(
                &positions_json(id, &json!([input, input]).to_string(), &keys, "").unwrap(),
            )
            .unwrap();
            assert_eq!(duplicate["positions"], json!([]));
            assert_eq!(
                duplicate["ambiguous_keys"],
                serde_json::from_str::<Value>(&keys).unwrap()
            );
            let mut corrupt = input.clone();
            corrupt["assets"][0]["amount"] = json!(2);
            let rejected: Value = serde_json::from_str(
                &positions_json(id, &json!([corrupt, input]).to_string(), &keys, "").unwrap(),
            )
            .unwrap();
            assert_eq!(rejected["rejected"].as_array().unwrap().len(), 1);
            assert_eq!(rejected["positions"].as_array().unwrap().len(), 1);
        }
    }

    #[test]
    fn registry_and_bad_boundary_inputs() {
        let contracts: Value = serde_json::from_str(&contracts_json().unwrap()).unwrap();
        assert_eq!(contracts[2]["active"], false);
        assert_eq!(contracts[0]["stake_tree"].as_str().unwrap().len(), 856);
        assert_eq!(contracts[1]["stake_tree"].as_str().unwrap().len(), 1022);
        assert!(positions_json("ergopad", "{}", "[]", "").is_err());
        assert!(positions_json("ergopad", "[]", "[\"bad\"]", "").is_err());
        assert!(positions_json("unknown", "[]", "[]", "").is_err());
        assert!(state_json("ergopad", "{}").is_err());
    }

    /// Optional live evidence captured by the HTTP verification script; normal
    /// workspace tests remain offline. Also exports the actual Rust registry.
    #[test]
    fn captured_live_discovery() {
        let Ok(dir) = std::env::var("ARGUS_STAKE_EVIDENCE") else {
            return;
        };
        let dir = std::path::Path::new(&dir);
        std::fs::write(dir.join("contracts.json"), contracts_json().unwrap()).unwrap();
        for id in ["ergopad", "paideia"] {
            let path = dir.join(format!("{id}-boxes.json"));
            if !path.exists() {
                continue;
            }
            let boxes = std::fs::read_to_string(path).unwrap();
            let inputs = zerojoin::parse_explorer_boxes(&boxes).unwrap();
            let keys: Vec<String> = inputs
                .iter()
                .map(|b| hex::encode(StakeBox::parse(b, pool(id).unwrap()).unwrap().key_id()))
                .collect();
            std::fs::write(dir.join(format!("{id}-keys.json")), json!(keys).to_string()).unwrap();
            let state = std::fs::read_to_string(dir.join(format!("{id}-state.json"))).unwrap();
            state_json(id, &state).unwrap();
            let result: Value = serde_json::from_str(
                &positions_json(id, &boxes, &json!(keys).to_string(), &state).unwrap(),
            )
            .unwrap();
            assert_eq!(result["rejected"], json!([]));
            assert_eq!(result["ambiguous_keys"], json!([]));
            assert_eq!(result["positions"].as_array().unwrap().len(), inputs.len());
            println!(
                "{id}: {} live boxes decoded; {} eligible against current state",
                inputs.len(),
                result["positions"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|p| p["eligible"] == true)
                    .count()
            );
        }
    }
}

/// Test-executable adapter for running the actual Dart HTTP service and these
/// pure boundary functions together without building any native shared library.
#[cfg(test)]
#[test]
#[ignore = "invoked by the opt-in Dart live discovery test"]
fn json_bridge_cli() {
    let request =
        std::fs::read_to_string(std::env::var("ARGUS_STAKE_BRIDGE_REQUEST").unwrap()).unwrap();
    let request: Value = serde_json::from_str(&request).unwrap();
    let s = |key: &str| request[key].as_str().unwrap();
    let result = match s("method") {
        "contracts" => contracts_json(),
        "state" => state_json(s("pool"), s("box")),
        "positions" => positions_json(s("pool"), s("boxes"), s("keys"), s("state")),
        _ => panic!("unknown method"),
    };
    std::fs::write(
        std::env::var("ARGUS_STAKE_BRIDGE_RESPONSE").unwrap(),
        result.unwrap(),
    )
    .unwrap();
}

/// Wallet-authenticated trees are supplied only by the handle integration.
/// Refuse ambiguous key boxes before selecting any funding.
pub fn prepare_direct(
    protocol: (&str, &str),
    key_id: &str,
    wallet: &[ergo_tx::Eip12InputBox],
    trees: &[String],
    recipient: &str,
    height: i32,
    miner_fee: i64,
) -> Result<ergo_tx::Eip12UnsignedTx, String> {
    let key: [u8; 32] = hex::decode(key_id)
        .map_err(error)?
        .try_into()
        .map_err(|_| error("key must be 32 bytes"))?;
    let keys: Vec<_> = wallet
        .iter()
        .filter(|b| {
            b.assets
                .iter()
                .any(|a| a.token_id.eq_ignore_ascii_case(key_id))
        })
        .collect();
    if keys.len() != 1 {
        return Err(error(
            "Expected exactly one wallet box containing the stake key",
        ));
    }
    let mut inputs = vec![
        direct_input(protocol.0)?,
        direct_input(protocol.1)?,
        keys[0].clone(),
    ];
    let required = stake_recovery::direct::APP_FEE
        .checked_add(miner_fee)
        .and_then(|n| n.checked_add(2 * stake_recovery::direct::MIN_VALUE))
        .ok_or_else(|| error("fee overflow"))?;
    let mut available = inputs[1..].iter().try_fold(0i64, |sum, b| {
        sum.checked_add(b.value.parse::<i64>().map_err(error)?)
            .ok_or_else(|| error("funding overflow"))
    })?;
    for input in wallet {
        if available >= required {
            break;
        }
        if input.box_id == keys[0].box_id {
            continue;
        }
        // The builder preserves every asset in selected wallet funding.
        available = available
            .checked_add(input.value.parse::<i64>().map_err(error)?)
            .ok_or_else(|| error("funding overflow"))?;
        inputs.push(input.clone());
    }
    stake_recovery::direct::build(&stake_recovery::direct::DirectRequest {
        inputs: &inputs,
        key: &key,
        recipient,
        wallet_trees: trees,
        height,
        miner_fee,
    })
    .map_err(error)
}

/// The discovery adapter intentionally ignores spending extensions. A spend
/// must instead refuse supplied nonempty/malformed extensions, never drop them.
fn direct_input(raw: &str) -> Result<ergo_tx::Eip12InputBox, String> {
    let value: Value = serde_json::from_str(raw).map_err(error)?;
    for extension in [
        value.get("extension"),
        value.get("spendingProof").and_then(|p| p.get("extension")),
    ]
    .into_iter()
    .flatten()
    {
        if extension.as_object().is_none_or(|m| !m.is_empty()) {
            return Err(error("Direct recovery requires empty context extensions"));
        }
    }
    let input = parse_box(raw)?;
    stake_recovery::boxes::canonical_box(&input).map_err(error)?;
    Ok(input)
}

pub fn is_direct(tx: &ergo_tx::Eip12UnsignedTx) -> bool {
    tx.inputs.first().is_some_and(|b| {
        b.assets.iter().any(|a| {
            a.token_id
                .eq_ignore_ascii_case(Pool::Ergopad.contracts().state_nft)
        })
    })
}

pub fn owned_trees(
    handle: &wallet_core::wallet::WalletHandle,
    addresses: &[String],
) -> Result<Vec<String>, String> {
    addresses
        .iter()
        .map(|address| {
            if !handle.owns_address(address).map_err(error)? {
                return Err(error("recovery address must belong to this wallet"));
            }
            ergo_tx::address_to_ergo_tree(address).map_err(error)
        })
        .collect()
}

#[cfg(test)]
mod direct_tests {
    use super::*;
    #[test]
    fn wallet_handle_refuses_foreign_addresses_and_fee_matches_argus() {
        let handle = wallet_core::wallet::WalletHandle::create(
            wallet_core::seed::MnemonicPhrase::parse("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap(), "").unwrap();
        let address = handle.derive_address(0).unwrap();
        assert!(owned_trees(&handle, &[address]).is_ok());
        assert!(owned_trees(&handle, &[crate::api::ARGUS_FEE_ADDRESS.into()]).is_err());
        assert_eq!(stake_recovery::direct::APP_FEE, crate::api::ARGUS_FEE_NANO);
        assert_eq!(
            stake_recovery::direct::APP_FEE_ADDRESS,
            crate::api::ARGUS_FEE_ADDRESS
        );
    }

    #[test]
    fn boundary_refuses_ambiguous_keys_and_preserves_historical_wallet_assets() {
        let h: Value = serde_json::from_str(include_str!(
            "../../vendor/protocols/stake-recovery/tests/fixtures/ergopad.json"
        ))
        .unwrap();
        let state = h["inputs"][0].to_string();
        let stake = h["inputs"][1].to_string();
        let wallet = parse_box(&h["inputs"][2].to_string()).unwrap();
        let key = hex::encode(
            StakeBox::parse(&parse_box(&stake).unwrap(), Pool::Ergopad)
                .unwrap()
                .key_id(),
        );
        let trees = vec![wallet.ergo_tree.clone()];
        let build = |boxes: &[ergo_tx::Eip12InputBox]| {
            prepare_direct(
                (&state, &stake),
                &key,
                boxes,
                &trees,
                &trees[0],
                1765291,
                1_100_000,
            )
        };
        let tx = build(std::slice::from_ref(&wallet)).unwrap();
        assert_eq!(tx.inputs[2].box_id, wallet.box_id);
        assert!(build(&[wallet.clone(), wallet]).is_err());
        assert!(build(&[]).is_err());
    }
}

#[cfg(test)]
#[test]
fn direct_boundary_does_not_drop_malformed_extensions() {
    let h: Value = serde_json::from_str(include_str!(
        "../../vendor/protocols/stake-recovery/tests/fixtures/ergopad.json"
    ))
    .unwrap();
    for extension in [
        json!({"256": "0502"}),
        json!({"0": "zz"}),
        json!(null),
        json!({"0": "0502"}),
    ] {
        let mut b = h["inputs"][1].clone();
        b["extension"] = extension;
        assert!(direct_input(&b.to_string()).is_err());
    }
}

pub fn prepare_proxy(
    protocol: (&str, &str),
    wallet: &[ergo_tx::Eip12InputBox],
    trees: &[String],
    recipient: &str,
    height: i32,
    context: &ergo_lib::chain::ergo_state_context::ErgoStateContext,
) -> Result<ergo_tx::Eip12UnsignedTx, String> {
    let state = direct_input(protocol.0)?;
    let stake = direct_input(protocol.1)?;
    let decoded = StakeBox::parse(&stake, Pool::Paideia).map_err(error)?;
    let key_id = hex::encode(decoded.key_id());
    let keys: Vec<_> = wallet
        .iter()
        .filter(|b| {
            b.assets
                .iter()
                .any(|a| a.token_id.eq_ignore_ascii_case(&key_id))
        })
        .collect();
    if keys.len() != 1 {
        return Err(error("Expected exactly one wallet key box"));
    }
    let mut inputs = vec![keys[0].clone()];
    let required = stake_recovery::proxy::required_funding(&stake)
        .map_err(error)?
        .checked_add(
            stake_recovery::direct::APP_FEE + 1_100_000 + stake_recovery::direct::MIN_VALUE,
        )
        .ok_or_else(|| error("funding overflow"))?;
    let mut available = keys[0].value.parse::<i64>().map_err(error)?;
    for b in wallet {
        if available >= required {
            break;
        }
        if b.box_id == keys[0].box_id {
            continue;
        }
        available = available
            .checked_add(b.value.parse::<i64>().map_err(error)?)
            .ok_or_else(|| error("funding overflow"))?;
        inputs.push(b.clone());
    }
    stake_recovery::proxy::create(
        &stake_recovery::proxy::CreationRequest {
            state: &state,
            stake: &stake,
            wallet_inputs: &inputs,
            wallet_trees: trees,
            recipient,
            height,
            miner_fee: 1_100_000,
        },
        context,
    )
    .map_err(error)
}

/// The only ownership material is handle-derived. A foreign proxy that matches
/// a caller's key or R5 hint is insufficient; its actual decoded R5 must be ours.
pub fn prepare_refund(
    raw: &str,
    trees: &[String],
    height: i32,
) -> Result<ergo_tx::Eip12UnsignedTx, String> {
    let proxy = direct_input(raw)?;
    let parsed = stake_recovery::PaideiaProxyBox::parse(&proxy).map_err(error)?;
    let recipient = hex::encode(parsed.recipient().sigma_serialize_bytes().map_err(error)?);
    if !trees.contains(&recipient) {
        return Err(error(
            "Proxy refund recipient is not controlled by this wallet",
        ));
    }
    stake_recovery::proxy::refund(&proxy, height).map_err(error)
}

pub fn is_refund(tx: &ergo_tx::Eip12UnsignedTx) -> bool {
    tx.inputs
        .first()
        .is_some_and(|b| stake_recovery::PaideiaProxyBox::parse(b).is_ok())
}
pub fn is_proxy_creation(tx: &ergo_tx::Eip12UnsignedTx) -> bool {
    ergo_tx::address_to_ergo_tree(stake_recovery::contracts::PAIDEIA_PROXY_ADDRESS)
        .is_ok_and(|tree| tx.outputs.iter().any(|b| b.ergo_tree == tree))
}

#[cfg(test)]
mod proxy_tests {
    use super::*;
    use ergo_lib::ergotree_ir::{chain::ergo_box::ErgoBox, mir::constant::Constant};

    #[test]
    fn refund_boundary_authenticates_actual_r5_and_needs_no_pool_boxes() {
        let handle = wallet_core::wallet::WalletHandle::create(
            wallet_core::seed::MnemonicPhrase::parse("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap(), "").unwrap();
        let trees = owned_trees(&handle, &[handle.derive_address(0).unwrap()]).unwrap();
        let history: Value = serde_json::from_str(include_str!(
            "../../vendor/protocols/stake-recovery/tests/fixtures/paideia-refund.json"
        ))
        .unwrap();
        let mut proxy = parse_box(&history["inputs"][0].to_string()).unwrap();
        assert!(prepare_refund(
            &serde_json::to_string(&proxy).unwrap(),
            &trees,
            proxy.creation_height
        )
        .is_err());
        // Matching key and published proxy tree cannot authenticate a foreign R5.
        let key = proxy.assets[0].token_id.clone();
        proxy.additional_registers.insert(
            "R5".into(),
            hex::encode(
                Constant::from(hex::decode(&trees[0]).unwrap())
                    .sigma_serialize_bytes()
                    .unwrap(),
            ),
        );
        let mut json = serde_json::to_value(&proxy).unwrap();
        json.as_object_mut().unwrap().remove("boxId");
        let canonical: ErgoBox = serde_json::from_value(json).unwrap();
        proxy.box_id = canonical.box_id().to_string();
        let tx = prepare_refund(
            &serde_json::to_string(&proxy).unwrap(),
            &trees,
            proxy.creation_height,
        )
        .unwrap();
        assert_eq!(tx.inputs.len(), 1);
        assert_eq!(tx.outputs.len(), 2);
        assert_eq!(tx.outputs[0].assets[0].token_id, key);
        assert_eq!(tx.outputs[0].ergo_tree, trees[0]);
        assert!(owned_trees(&handle, &[crate::api::ARGUS_FEE_ADDRESS.into()]).is_err());
        assert!(owned_trees(&handle, &[trees[0].clone()]).is_err()); // hex is not a wallet address
        assert!(prepare_refund(
            &serde_json::to_string(&proxy).unwrap(),
            &[],
            proxy.creation_height
        )
        .is_err());
    }
}
