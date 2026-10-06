//! Storage rent against the user's own node: the tip and voted fee factor
//! (`/info`), the rent position of every confirmed box at the wallet's
//! addresses, and what a token-carrying output will owe if it is never
//! moved. The arithmetic is [`wallet_core::rent`]; this module fetches and
//! serializes. Nothing here leaves the configured node list.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use futures::stream::{self, StreamExt, TryStreamExt};
use std::collections::HashSet;
use wallet_core::rent;
use wallet_net::client::{address_to_ergo_tree, ErgoNodeClient};
use wallet_net::rent_params::{fetch_rent_parameters, RentParameters};

use super::node_client;
use crate::error::ArgusError;

/// Boxes per page, as the UTXO screen pages the same endpoint.
const PAGE: u64 = 100;

/// The UTXO screen lists at most this many boxes (`maxUnspentBoxesTotal`),
/// so rent is reported for the same set.
const MAX_BOXES: usize = 2_000;

/// Addresses read at once: overlaps latency without unbounded load on the
/// user's node.
const ADDRESS_CONCURRENCY: usize = 4;

/// Chain state a report is judged against, with the fallback applied.
struct Basis {
    height: u32,
    factor: i32,
    factor_from_node: bool,
}

impl From<RentParameters> for Basis {
    fn from(p: RentParameters) -> Self {
        Basis {
            height: p.height,
            factor: p
                .storage_fee_factor
                .unwrap_or(rent::FALLBACK_STORAGE_FEE_FACTOR),
            factor_from_node: p.storage_fee_factor.is_some(),
        }
    }
}

impl Basis {
    fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "height": self.height,
            "storage_fee_factor": self.factor,
            "factor_from_node": self.factor_from_node,
            "storage_period": rent::STORAGE_PERIOD,
            "target_block_secs": rent::TARGET_BLOCK_SECS,
        })
    }
}

async fn basis(client: &ErgoNodeClient) -> Result<Basis, String> {
    fetch_rent_parameters(client.url())
        .await
        .map(Basis::from)
        .map_err(|e| ArgusError::NodeError(e).to_json_string())
}

/// The chain tip and the storage fee factor to judge rent by, from the
/// node's `/info`: `{height, storage_fee_factor, factor_from_node,
/// storage_period, target_block_secs}`. `factor_from_node` is false when
/// the node did not report the factor and the launch value stands in.
#[flutter_rust_bridge::frb]
pub async fn rent_parameters(node_url: Option<String>) -> Result<String, String> {
    let client = node_client(node_url).await?;
    Ok(basis(&client).await?.json().to_string())
}

/// Rent position of every confirmed unspent box at `addresses`, judged at
/// the node's tip: the [`rent_parameters`] fields plus `boxes`, one entry
/// per box with its exact serialized size, the node's fee, what a collector
/// could take (`charge`: `fee`, `whole_box` or `none`) and when.
#[flutter_rust_bridge::frb]
pub async fn box_rent_report(
    addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let basis = basis(&client).await?;
    let per_address: Vec<Vec<ErgoBox>> = stream::iter(addresses.iter().filter(|a| !a.is_empty()))
        .map(|address| unspent_at(&client, address))
        .buffered(ADDRESS_CONCURRENCY)
        .try_collect()
        .await?;
    let mut seen = HashSet::new();
    let mut rows = Vec::new();
    for ergo_box in per_address.into_iter().flatten() {
        if rows.len() >= MAX_BOXES {
            break;
        }
        if seen.insert(ergo_box.box_id()) {
            rows.push(report_row(&ergo_box, &basis)?);
        }
    }
    let mut out = basis.json();
    out["boxes"] = serde_json::Value::Array(rows);
    Ok(out.to_string())
}

/// What a recipient output carrying `tokens_json` (`[{"token_id", "amount"}]`)
/// will owe in rent if it is created at `height` with `value_nano` and never
/// moved: `{value_nano_erg, due_height, suggested_nano_erg, boxes}`.
/// `value_nano_erg` is the amount after the builders' size floor; `boxes`
/// follows their token layout (usually one box). `suggested_nano_erg` is the
/// recipient amount that lets the first box pay one charge and keep the
/// minimum box value, or null when the protocol cannot charge it.
///
/// A published stealth address is measured through a fresh one-time
/// script, which every payment to it uses in the same length.
#[flutter_rust_bridge::frb(sync)]
pub fn output_rent_estimate(
    address: String,
    value_nano: i64,
    tokens_json: String,
    height: u32,
    storage_fee_factor: i32,
) -> Result<String, String> {
    let tree = recipient_tree(address.trim())?;
    let tokens = parse_tokens(&tokens_json)?;
    let value = u64::try_from(value_nano.max(0)).unwrap_or(0);
    let estimate = rent::recipient_rent(&tree, value, &tokens, height, storage_fee_factor)
        .map_err(|e| ArgusError::from(e).to_json_string())?;
    Ok(serde_json::json!({
        "value_nano_erg": estimate.value_nano,
        "due_height": rent::due_height(height),
        "suggested_nano_erg": estimate.suggested_nano,
        "boxes": estimate.boxes,
    })
    .to_string())
}

/// Every confirmed unspent box at `address`, page by page.
async fn unspent_at(client: &ErgoNodeClient, address: &str) -> Result<Vec<ErgoBox>, String> {
    let mut all = Vec::new();
    let mut offset = 0u64;
    loop {
        let page = client
            .unspent_boxes_by_address(address, offset, PAGE)
            .await
            .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
        let n = page.len();
        all.extend(page);
        if n < PAGE as usize || all.len() >= MAX_BOXES {
            return Ok(all);
        }
        offset += PAGE;
    }
}

fn report_row(ergo_box: &ErgoBox, basis: &Basis) -> Result<serde_json::Value, String> {
    let size = rent::box_size(ergo_box).map_err(|e| ArgusError::from(e).to_json_string())?;
    let value = *ergo_box.value.as_u64();
    let assessed = rent::assess(
        value,
        size,
        ergo_box.creation_height,
        basis.factor,
        basis.height,
    );
    let mut row = serde_json::to_value(&assessed)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    row["box_id"] = ergo_box.box_id().to_string().into();
    row["value_nano_erg"] = value.into();
    row["creation_height"] = ergo_box.creation_height.into();
    Ok(row)
}

fn recipient_tree(address: &str) -> Result<String, String> {
    if let Ok(tree) = address_to_ergo_tree(address) {
        return Ok(tree);
    }
    let one_time = stealth::payment_address_for_stealth_address(address)
        .map_err(|e| ArgusError::InvalidAddress(e.to_string()).to_json_string())?;
    address_to_ergo_tree(&one_time).map_err(|e| ArgusError::InvalidAddress(e).to_json_string())
}

fn parse_tokens(tokens_json: &str) -> Result<Vec<(String, u64)>, String> {
    let bad = |m: &str| ArgusError::SerializationError(m.to_string()).to_json_string();
    let list: Vec<serde_json::Value> =
        serde_json::from_str(tokens_json).map_err(|e| bad(&format!("tokens: {e}")))?;
    list.iter()
        .map(|t| {
            let id = t["token_id"]
                .as_str()
                .or_else(|| t["id"].as_str())
                .ok_or_else(|| bad("token without id"))?;
            let amount = t["amount"]
                .as_u64()
                .filter(|a| *a > 0)
                .ok_or_else(|| bad("token amount must be a positive integer"))?;
            Ok((id.to_string(), amount))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const P2PK: &str = crate::api::ARGUS_FEE_ADDRESS;

    fn estimate(address: &str, value: i64, tokens: &str) -> serde_json::Value {
        serde_json::from_str(
            &output_rent_estimate(address.into(), value, tokens.into(), 1_600_000, 1_250_000)
                .unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn nft_to_an_ordinary_address() {
        let tokens = format!(r#"[{{"token_id":"{}","amount":1}}]"#, "07".repeat(32));
        let e = estimate(P2PK, 1_000_000, &tokens);
        assert_eq!(e["value_nano_erg"], 1_000_000);
        assert_eq!(e["due_height"], 2_651_200);
        assert_eq!(e["suggested_nano_erg"], 140_000_000);
        let first = &e["boxes"][0];
        assert_eq!(first["size_bytes"], 110);
        assert_eq!(first["fee_nano"], 137_500_000);
        assert_eq!(first["charge"], "whole_box");
        assert_eq!(first["token_count"], 1);
    }

    #[test]
    fn stealth_recipients_are_measured_through_a_one_time_script() {
        let g = ergo_lib::ergo_chain_types::EcPoint::from_base16_str(
            "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".into(),
        )
        .unwrap();
        let published = stealth::encode_stealth_address(&g).unwrap();
        let tokens = format!(r#"[{{"id":"{}","amount":5}}]"#, "08".repeat(32));
        let a = estimate(&published, 1_000_000, &tokens);
        let b = estimate(&published, 1_000_000, &tokens);
        // A fresh script each time, but always the same size.
        assert_eq!(a["boxes"][0]["size_bytes"], b["boxes"][0]["size_bytes"]);
        assert!(a["boxes"][0]["size_bytes"].as_u64().unwrap() > 110);
    }

    #[test]
    fn rejects_bad_input() {
        assert!(output_rent_estimate("nope".into(), 1, "[]".into(), 1, 1).is_err());
        let zero = format!(r#"[{{"token_id":"{}","amount":0}}]"#, "07".repeat(32));
        assert!(output_rent_estimate(P2PK.into(), 1, zero, 1, 1).is_err());
    }

    #[test]
    fn report_rows_carry_size_fee_and_due_height() {
        let json = r#"{"boxId":"79b67d3adc64450e2b3c836d4a0d4f375205e09aa16e45325f922a2af9fe6608","value":10000000,"ergoTree":"100a040004000580dac409040004000e20f7f008ad8fcaad4490d8e78ab6d3f11efe7213a13f7b243795818b155e1acc920402040204020402d804d601b2a5e4e3000400d602db63087201d603db6308a7d604e4c6a70407ea02d1ededed93b27202730000b2720373010093c27201c2a7e6c67201040792c172017302eb02cd7204d1ededededed938cb2db6308b2a4730300730400017305938cb27202730600018cb2720373070001918cb27202730800028cb272037309000293e4c672010407720492c17201c1a7efe6c672010561","assets":[{"tokenId":"e5abaf1f0a9442123104cdf4d2d56ddd8065803e842bc6d433e712601133a9bc","amount":1},{"tokenId":"05965018a4525add81bdf6feb6dc4621dcef6789802fa53cebe39505a3b8588d","amount":15835}],"creationHeight":1865321,"additionalRegisters":{"R4":"0703bda2691a9f1a2adf122741390847e7dae2c75bd2eb3a0dc896388d4ec3e9577b","R5":"04fada01","R6":"1115a0d98ad91280eee7c2de04e0b19cb205f6f30af68c1bea378c10a0e5b901f8b406e0efcade39e0a389f08f03c0d0b44080baae06e0ca995bc099ab57c0fae30280dfd41196b4208a83dcae22f2b05100"},"transactionId":"441dc8526ac98cca5d83af1ba6166d56c4f47126a90ac5720881f9680f74a267","index":3}"#;
        let ergo_box: ErgoBox = serde_json::from_str(json).unwrap();
        let basis = Basis::from(RentParameters {
            height: 2_916_520,
            storage_fee_factor: None,
        });
        assert!(!basis.factor_from_node);
        let row = report_row(&ergo_box, &basis).unwrap();
        assert_eq!(
            row["box_id"],
            "79b67d3adc64450e2b3c836d4a0d4f375205e09aa16e45325f922a2af9fe6608"
        );
        assert_eq!(row["value_nano_erg"], 10_000_000);
        assert_eq!(row["creation_height"], 1_865_321);
        assert_eq!(row["size_bytes"], 438);
        assert_eq!(row["fee_nano"], 547_500_000);
        assert_eq!(row["charge"], "whole_box");
        assert_eq!(row["charge_nano"], 10_000_000);
        assert_eq!(row["due_height"], 2_916_521);
        assert_eq!(row["blocks_until_due"], 1);
        assert_eq!(row["collectable_now"], true);
    }
}
