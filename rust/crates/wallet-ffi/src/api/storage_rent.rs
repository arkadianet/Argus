//! Storage rent against the user's own node: the tip and voted fee factor
//! (`/info`), the rent position of each box the wallet lists, and what a
//! token-carrying output will owe if it is never moved. The arithmetic is
//! [`wallet_core::rent`]; this module fetches and serializes. Nothing here
//! leaves the configured node list.

use std::collections::HashSet;
use wallet_core::rent;
use wallet_net::client::{address_to_ergo_tree, ErgoNodeClient};
use wallet_net::rent_params::{fetch_rent_parameters, RentParameters};

use super::node_client;
use crate::error::ArgusError;

/// The UTXO screen lists at most this many boxes (`maxUnspentBoxesTotal`),
/// so rent is reported for the same set.
const MAX_BOXES: usize = 2_000;

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

/// Rent position of the boxes the wallet lists, judged at the node's tip:
/// the [`rent_parameters`] fields plus `boxes`, one row per box with its
/// exact serialized size, the node's fee, what a collector could take
/// (`charge`: `fee`, `whole_box` or `none`) and when, and `unmeasured`, the
/// listed boxes that came without a size.
///
/// `boxes_json` is the listing the UTXO tools already hold
/// ([`super::mempool::list_spendable_boxes`]): `box_id`, `value_nano_erg`,
/// `creation_height` and `size_bytes` per box. The boxes are read once,
/// through the mempool-aware gathering, so a box a pending transaction
/// already spends is never judged or offered for cleanup, and the only
/// read here is `/info`.
#[flutter_rust_bridge::frb]
pub async fn box_rent_report(
    boxes_json: String,
    node_url: Option<String>,
) -> Result<String, String> {
    let listed = parse_listing(&boxes_json)?;
    let client = node_client(node_url).await?;
    let basis = basis(&client).await?;
    Ok(report_json(&listed, &basis).to_string())
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

/// One box of the wallet's listing, as rent needs it.
#[derive(Debug)]
struct ListedBox {
    box_id: String,
    value: u64,
    creation_height: u32,
    /// None when the listing could not measure it.
    size_bytes: Option<usize>,
}

/// The listing's boxes, in order. Amounts arrive as strings (the listing's
/// EIP-12 form) or numbers.
fn parse_listing(boxes_json: &str) -> Result<Vec<ListedBox>, String> {
    let bad = |m: String| ArgusError::SerializationError(m).to_json_string();
    let list: Vec<serde_json::Value> =
        serde_json::from_str(boxes_json).map_err(|e| bad(format!("boxes: {e}")))?;
    let number = |v: &serde_json::Value| {
        v.as_u64()
            .or_else(|| v.as_str().and_then(|s| s.parse::<u64>().ok()))
    };
    list.iter()
        .map(|b| {
            let box_id = b["box_id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .ok_or_else(|| bad("box without box_id".into()))?;
            let value = number(&b["value_nano_erg"])
                .ok_or_else(|| bad(format!("box {box_id}: value_nano_erg")))?;
            let creation_height = number(&b["creation_height"])
                .and_then(|h| u32::try_from(h).ok())
                .ok_or_else(|| bad(format!("box {box_id}: creation_height")))?;
            Ok(ListedBox {
                box_id: box_id.to_string(),
                value,
                creation_height,
                size_bytes: number(&b["size_bytes"])
                    .and_then(|n| usize::try_from(n).ok())
                    .filter(|n| *n > 0),
            })
        })
        .collect()
}

/// The report for `listed` at `basis`: each box once, at most
/// [`MAX_BOXES`], those without a size counted as unmeasured.
fn report_json(listed: &[ListedBox], basis: &Basis) -> serde_json::Value {
    let mut seen = HashSet::new();
    let mut rows = Vec::new();
    let mut unmeasured = 0usize;
    for b in listed {
        if rows.len() + unmeasured >= MAX_BOXES {
            break;
        }
        if !seen.insert(b.box_id.as_str()) {
            continue;
        }
        match b.size_bytes {
            Some(size) => rows.push(report_row(b, size, basis)),
            None => unmeasured += 1,
        }
    }
    let mut out = basis.json();
    out["boxes"] = serde_json::Value::Array(rows);
    out["unmeasured"] = unmeasured.into();
    out
}

fn report_row(b: &ListedBox, size: usize, basis: &Basis) -> serde_json::Value {
    let assessed = rent::assess(b.value, size, b.creation_height, basis.factor, basis.height);
    // `BoxRent` is plain numbers and an enum: it always serializes.
    let mut row = serde_json::to_value(&assessed).unwrap_or_default();
    row["box_id"] = b.box_id.clone().into();
    row["value_nano_erg"] = b.value.into();
    row["creation_height"] = b.creation_height.into();
    row
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

    /// A mainnet oracle box as the node returns it (438 bytes; see
    /// `wallet_core::rent` tests).
    const ORACLE_BOX: &str = r#"{"boxId":"79b67d3adc64450e2b3c836d4a0d4f375205e09aa16e45325f922a2af9fe6608","value":10000000,"ergoTree":"100a040004000580dac409040004000e20f7f008ad8fcaad4490d8e78ab6d3f11efe7213a13f7b243795818b155e1acc920402040204020402d804d601b2a5e4e3000400d602db63087201d603db6308a7d604e4c6a70407ea02d1ededed93b27202730000b2720373010093c27201c2a7e6c67201040792c172017302eb02cd7204d1ededededed938cb2db6308b2a4730300730400017305938cb27202730600018cb2720373070001918cb27202730800028cb272037309000293e4c672010407720492c17201c1a7efe6c672010561","assets":[{"tokenId":"e5abaf1f0a9442123104cdf4d2d56ddd8065803e842bc6d433e712601133a9bc","amount":1},{"tokenId":"05965018a4525add81bdf6feb6dc4621dcef6789802fa53cebe39505a3b8588d","amount":15835}],"creationHeight":1865321,"additionalRegisters":{"R4":"0703bda2691a9f1a2adf122741390847e7dae2c75bd2eb3a0dc896388d4ec3e9577b","R5":"04fada01","R6":"1115a0d98ad91280eee7c2de04e0b19cb205f6f30af68c1bea378c10a0e5b901f8b406e0efcade39e0a389f08f03c0d0b44080baae06e0ca995bc099ab57c0fae30280dfd41196b4208a83dcae22f2b05100"},"transactionId":"441dc8526ac98cca5d83af1ba6166d56c4f47126a90ac5720881f9680f74a267","index":3}"#;

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

    /// The oracle box as the wallet's listing carries it: the size measured
    /// from the node's JSON, as `list_spendable_boxes` measures it.
    fn oracle_listed() -> serde_json::Value {
        let ergo_box: ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox =
            serde_json::from_str(ORACLE_BOX).unwrap();
        serde_json::json!({
            "box_id": ergo_box.box_id().to_string(),
            "value_nano_erg": ergo_box.value.as_u64().to_string(),
            "creation_height": ergo_box.creation_height,
            "size_bytes": rent::box_size(&ergo_box).unwrap(),
        })
    }

    #[test]
    fn report_rows_carry_size_fee_and_due_height() {
        let basis = Basis::from(RentParameters {
            height: 2_916_520,
            storage_fee_factor: None,
        });
        assert!(!basis.factor_from_node);
        let listed = parse_listing(&serde_json::json!([oracle_listed()]).to_string()).unwrap();
        let report = report_json(&listed, &basis);
        let row = &report["boxes"][0];
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
        assert_eq!(report["unmeasured"], 0);
    }

    #[test]
    fn a_listing_without_sizes_is_counted_not_guessed() {
        let basis = Basis::from(RentParameters {
            height: 2_916_520,
            storage_fee_factor: Some(1_250_000),
        });
        let mut no_size = oracle_listed();
        no_size["box_id"] = "aa".repeat(32).into();
        no_size["size_bytes"] = serde_json::Value::Null;
        let listing = serde_json::json!([oracle_listed(), no_size, oracle_listed()]);
        let report = report_json(&parse_listing(&listing.to_string()).unwrap(), &basis);
        assert_eq!(report["boxes"].as_array().unwrap().len(), 1, "each box once");
        assert_eq!(report["unmeasured"], 1);
        assert!(parse_listing(r#"[{"box_id":"x"}]"#).is_err());
        assert!(parse_listing("{}").is_err());
    }

    /// A node that answers `/info`, and records every request it is sent.
    fn replay_node() -> (
        String,
        std::sync::Arc<std::sync::atomic::AtomicBool>,
        std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    ) {
        use std::io::{Read, Write};
        use std::sync::atomic::Ordering;
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopped = stop.clone();
        let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen = requests.clone();
        std::thread::spawn(move || {
            while !stopped.load(Ordering::Relaxed) {
                let Ok((mut stream, _)) = listener.accept() else {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                    continue;
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let mut buffer = [0; 8192];
                let n = stream.read(&mut buffer).unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..n]);
                seen.lock()
                    .unwrap()
                    .push(request.lines().next().unwrap_or_default().to_string());
                let reply = r#"{"fullHeight":2916520,"headersHeight":2916520,"parameters":{"storageFeeFactor":1250000}}"#;
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                    reply.len()
                );
            }
        });
        (url, stop, requests)
    }

    #[tokio::test]
    async fn the_report_judges_the_listing_and_reads_only_the_tip() {
        let (url, stop, requests) = replay_node();
        let listing = serde_json::json!([oracle_listed()]).to_string();
        let raw = box_rent_report(listing, Some(url)).await.unwrap();
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let report: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(report["height"], 2_916_520);
        assert_eq!(report["storage_fee_factor"], 1_250_000);
        assert_eq!(report["factor_from_node"], true);
        assert_eq!(report["unmeasured"], 0);
        let boxes = report["boxes"].as_array().unwrap();
        assert_eq!(boxes.len(), 1);
        assert_eq!(boxes[0]["size_bytes"], 438);
        assert_eq!(boxes[0]["charge"], "whole_box");
        assert_eq!(boxes[0]["collectable_now"], true);
        // The boxes came from the listing: the node was asked for its tip
        // and parameters, never for boxes.
        let asked = requests.lock().unwrap().clone();
        assert!(!asked.is_empty());
        assert!(
            asked.iter().all(|r| !r.contains("/blockchain/box")),
            "{asked:?}"
        );
    }
}
