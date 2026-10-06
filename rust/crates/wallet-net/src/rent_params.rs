//! The chain state storage rent depends on, from one `/info` read of the
//! user's node: the tip height, and the miner-voted `storageFeeFactor` the
//! node reports under `parameters` for the current voting epoch.

use std::time::Duration;

/// Tip height and voted rent factor as the node reported them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RentParameters {
    /// `fullHeight`: the last block the node holds in full. The next block,
    /// one higher, is the earliest that can collect anything.
    pub height: u32,
    /// `parameters.storageFeeFactor`, or `None` when the node left it out;
    /// callers then fall back to the launch value and must say so.
    pub storage_fee_factor: Option<i32>,
}

/// Reads [`RentParameters`] from a node's `/info` JSON. A missing or
/// malformed factor is `None` rather than an error, because the height
/// alone still dates every box; a missing height is an error.
pub fn parse_rent_parameters(info: &serde_json::Value) -> Result<RentParameters, String> {
    let height = info
        .get("fullHeight")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| "node /info reports no fullHeight".to_string())?;
    let height = u32::try_from(height).map_err(|_| "node height out of range".to_string())?;
    let storage_fee_factor = info
        .get("parameters")
        .and_then(|p| p.get("storageFeeFactor"))
        .and_then(|v| v.as_i64())
        .and_then(|v| i32::try_from(v).ok())
        .filter(|v| *v >= 0);
    Ok(RentParameters {
        height,
        storage_fee_factor,
    })
}

/// `GET {node_url}/info`, parsed as [`RentParameters`].
///
/// `ErgoNodeClient::parameters` reads the same endpoint for transaction
/// reduction but keeps only the voted parameters; rent needs the tip from
/// the same response, so both come from this one read.
pub async fn fetch_rent_parameters(node_url: &str) -> Result<RentParameters, String> {
    let url = format!("{}/info", node_url.trim_end_matches('/'));
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| e.to_string())?;
    let text = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Node /info: {e}"))?
        .error_for_status()
        .map_err(|e| format!("Node /info: {e}"))?
        .text()
        .await
        .map_err(|e| format!("Node /info: {e}"))?;
    let info: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("Parse /info: {e}"))?;
    parse_rent_parameters(&info)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_tip_and_factor_from_a_mainnet_info() {
        // The fields that matter from a mainnet Scala node 6.1.7 `/info`
        // (arkadianet/ergo test-vectors/mode5/breadth/mainnet-1885600).
        // `parameters.height` is the voting epoch's start, not the tip.
        let info = serde_json::json!({
            "appVersion": "6.1.7",
            "network": "mainnet",
            "fullHeight": 1885661,
            "headersHeight": 1885661,
            "parameters": {
                "blockVersion": 4,
                "dataInputCost": 100,
                "height": 1885184,
                "inputCost": 2407,
                "maxBlockCost": 8001091,
                "maxBlockSize": 1271009,
                "minValuePerByte": 360,
                "outputCost": 298,
                "storageFeeFactor": 1250000,
                "subblocksPerBlock": 30,
                "tokenAccessCost": 100
            }
        });
        assert_eq!(
            parse_rent_parameters(&info).unwrap(),
            RentParameters {
                height: 1_885_661,
                storage_fee_factor: Some(1_250_000),
            }
        );
    }

    #[test]
    fn a_missing_factor_is_reported_not_guessed() {
        let info = serde_json::json!({ "fullHeight": 1_900_000 });
        assert_eq!(
            parse_rent_parameters(&info).unwrap().storage_fee_factor,
            None
        );
        let negative = serde_json::json!({
            "fullHeight": 1_900_000,
            "parameters": { "storageFeeFactor": -5 }
        });
        assert_eq!(
            parse_rent_parameters(&negative).unwrap().storage_fee_factor,
            None
        );
    }

    #[test]
    fn a_node_without_full_blocks_is_an_error() {
        let info = serde_json::json!({ "fullHeight": null, "headersHeight": 1_900_000 });
        assert!(parse_rent_parameters(&info).is_err());
    }
}
