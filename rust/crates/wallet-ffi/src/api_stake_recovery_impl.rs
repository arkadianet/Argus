//! Read-only stake recovery boundary. HTTP and wallet ownership stay in Dart.
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
