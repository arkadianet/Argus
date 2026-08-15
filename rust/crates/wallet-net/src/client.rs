use citadel_core::NodeConfig;
use ergo_lib::chain::ergo_state_context::ErgoStateContext;
use ergo_lib::chain::parameters::Parameters;
use ergo_lib::ergo_chain_types::{Header, PreHeader};
use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_lib::ergotree_ir::chain::address::{AddressEncoder, NetworkPrefix};
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_node_interface::NodeInterface;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

const HEADERS_COUNT: usize = 10;
const UNSPENT_PAGE_SIZE: u64 = 500;
const UNSPENT_MAX_BOXES: usize = 10_000;

/// Default public Ergo node URL (mainnet).
pub const DEFAULT_NODE_URL: &str = "https://ergo-explorer-01.ergonode.net";

/// Public nodes tried after the preferred URL.
pub const NODE_CANDIDATES: &[&str] = &[
    DEFAULT_NODE_URL,
    "https://node.ergo.watch",
];

pub const DEFAULT_EXPLORER_URL: &str = "https://api.ergoplatform.com";

/// Preferred URL first, then public fallbacks (no duplicates).
pub fn node_urls(preferred: Option<String>) -> Vec<String> {
    let mut urls = Vec::new();
    if let Some(url) = preferred.filter(|s| !s.is_empty()) {
        urls.push(url);
    }
    for candidate in NODE_CANDIDATES {
        if !urls.iter().any(|u| u == candidate) {
            urls.push((*candidate).to_string());
        }
    }
    urls
}

fn join_url(base: &str, path: &str) -> String {
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

/// Create a default mainnet NodeConfig.
pub fn default_node_config() -> NodeConfig {
    NodeConfig {
        url: DEFAULT_NODE_URL.to_string(),
        api_key: String::new(),
    }
}

pub fn parse_parameters(value: &serde_json::Value) -> Result<Parameters, String> {
    let req = |key: &str| -> Result<i32, String> {
        value
            .get(key)
            .and_then(|v| v.as_i64())
            .map(|n| n as i32)
            .ok_or_else(|| format!("missing parameter {key}"))
    };
    Ok(Parameters::new(
        req("blockVersion")?,
        req("storageFeeFactor")?,
        req("minValuePerByte")?,
        req("maxBlockSize")?,
        req("maxBlockCost")?,
        req("tokenAccessCost")?,
        req("inputCost")?,
        req("dataInputCost")?,
        req("outputCost")?,
    ))
}

/// Convert an Ergo base58 address to an ErgoTree hex string.
pub fn address_to_ergo_tree(address: &str) -> Result<String, String> {
    let encoder = AddressEncoder::new(NetworkPrefix::Mainnet);
    let addr = encoder.parse_address_from_str(address)
        .map_err(|e| format!("Invalid address: {}", e))?;
    let tree = addr.script()
        .map_err(|e| format!("Address script error: {}", e))?;
    let bytes = tree.sigma_serialize_bytes()
        .map_err(|e| format!("Serialization error: {}", e))?;
    Ok(base16::encode_lower(&bytes))
}

#[derive(Clone)]
pub struct ErgoNodeClient {
    inner: Arc<NodeInterface>,
    url: String,
}

/// A parsed transaction summary from the explorer API.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxSummary {
    pub tx_id: String,
    pub height: u64,
    pub timestamp: u64,
    /// Total nanoERG value sent (inputs - outputs to self)
    pub value_nano_erg: i64,
    pub token_ids: Vec<String>,
    pub num_inputs: u32,
    pub num_outputs: u32,
}

impl ErgoNodeClient {
    pub async fn new(config: NodeConfig) -> Result<Self, String> {
        let node = NodeInterface::from_url_str(&config.api_key, &config.url)
            .await
            .map_err(|e| format!("Failed to connect to node: {}", e))?;
        Ok(ErgoNodeClient {
            inner: Arc::new(node),
            url: config.url,
        })
    }

    /// Connect to the preferred node, then public fallbacks.
    pub async fn connect(preferred: Option<String>) -> Result<Self, String> {
        let mut last = "no node candidates".to_string();
        for url in node_urls(preferred) {
            match Self::new(NodeConfig {
                url: url.clone(),
                api_key: String::new(),
            })
            .await
            {
                Ok(client) => {
                    if client.current_height().await.is_ok() {
                        return Ok(client);
                    }
                    last = format!("node {url} did not return height");
                }
                Err(e) => last = e,
            }
        }
        Err(last)
    }

    pub async fn current_height(&self) -> Result<u64, String> {
        self.inner
            .current_block_height()
            .await
            .map_err(|e| format!("Failed to get height: {}", e))
    }

    pub async fn unspent_boxes_by_address(
        &self,
        address: &str,
        offset: u64,
        limit: u64,
    ) -> Result<Vec<ErgoBox>, String> {
        let endpoint = format!(
            "/blockchain/box/unspent/byAddress?offset={}&limit={}",
            offset, limit
        );
        let body =
            serde_json::to_string(address).map_err(|e| format!("JSON serialize: {}", e))?;
        let response = self
            .inner
            .send_post_req(&endpoint, body)
            .await
            .map_err(|e| format!("Node request: {}", e))?;
        let text = response
            .text()
            .await
            .map_err(|e| format!("Read: {}", e))?;
        if text.is_empty() {
            return Ok(Vec::new());
        }
        let value: serde_json::Value =
            serde_json::from_str(&text).map_err(|e| format!("Parse: {}", e))?;
        let items = match value {
            serde_json::Value::Array(arr) => arr,
            serde_json::Value::Object(ref map) => map
                .get("items")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        let mut boxes = Vec::with_capacity(items.len());
        for item in items {
            if !item["spentTransactionId"].is_null() {
                continue;
            }
            match serde_json::from_value::<ErgoBox>(item) {
                Ok(b) => boxes.push(b),
                Err(e) => tracing::debug!("Skipping unparseable box: {}", e),
            }
        }
        Ok(boxes)
    }

    /// Build an ErgoStateContext by fetching the last 10 block headers from the node.
    pub async fn get_state_context(&self) -> Result<ErgoStateContext, String> {
        let inner = &self.inner;
        let headers: Vec<Header> = inner
            .get_last_block_headers(HEADERS_COUNT as u32)
            .await
            .map_err(|e| format!("Failed to get headers: {}", e))?;

        if headers.is_empty() {
            return Err("No headers returned from node".to_string());
        }

        let pre_header = PreHeader::from(headers[0].clone());

        let mut arr: [Header; HEADERS_COUNT] =
            core::array::from_fn(|_| headers[0].clone());
        for (i, h) in headers.iter().enumerate().take(HEADERS_COUNT) {
            arr[i] = h.clone();
        }

        let params = self.parameters().await.unwrap_or_else(|_| Parameters::default());
        Ok(ErgoStateContext::new(pre_header, arr, params))
    }

    pub async fn parameters(&self) -> Result<Parameters, String> {
        let url = join_url(&self.url, "info");
        let text = reqwest::Client::new()
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
        let params = info.get("parameters").unwrap_or(&info);
        parse_parameters(params)
    }

    async fn all_unspent_boxes(&self, address: &str) -> Result<Vec<ErgoBox>, String> {
        let mut all = Vec::new();
        let mut offset = 0u64;
        loop {
            let page = self
                .unspent_boxes_by_address(address, offset, UNSPENT_PAGE_SIZE)
                .await?;
            let n = page.len();
            all.extend(page);
            if all.len() >= UNSPENT_MAX_BOXES {
                all.truncate(UNSPENT_MAX_BOXES);
                break;
            }
            if n < UNSPENT_PAGE_SIZE as usize {
                break;
            }
            offset += UNSPENT_PAGE_SIZE;
        }
        Ok(all)
    }

    /// Unspent boxes plus EIP-12 views (real txId, index, registers).
    pub async fn get_unspent(
        &self,
        address: &str,
    ) -> Result<(Vec<ErgoBox>, Vec<ergo_tx::Eip12InputBox>), String> {
        let boxes = self.all_unspent_boxes(address).await?;
        let eip12 = boxes
            .iter()
            .map(|b| {
                ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index)
            })
            .collect();
        Ok((boxes, eip12))
    }

    pub async fn get_eip12_utxos(
        &self,
        address: &str,
    ) -> Result<Vec<ergo_tx::Eip12InputBox>, String> {
        Ok(self.get_unspent(address).await?.1)
    }

    pub async fn address_has_transactions(&self, address: &str) -> Result<bool, String> {
        Ok(!self.get_transaction_history(address, 1).await?.is_empty())
    }

    /// Fetch total nanoERG and per-token amounts for an address.
    pub async fn get_address_balances(
        &self,
        address: &str,
    ) -> Result<(u64, Vec<(String, u64)>), String> {
        use std::collections::HashMap;
        let boxes = self.all_unspent_boxes(address).await?;
        let erg_total: u64 = boxes.iter().map(|b| *b.value.as_u64()).sum();
        let mut tokens: HashMap<String, u64> = HashMap::new();
        for b in &boxes {
            if let Some(held) = b.tokens.as_ref() {
                for t in held.iter() {
                    let id: String = t.token_id.clone().into();
                    *tokens.entry(id).or_insert(0) += *t.amount.as_u64();
                }
            }
        }
        Ok((erg_total, tokens.into_iter().collect()))
    }

    /// Fetch transaction history for an address (paginated, max 50).
    pub async fn get_transaction_history(&self, address: &str, limit: u64) -> Result<Vec<TxSummary>, String> {
        let endpoint = format!(
            "/blockchain/transaction/byAddress?offset=0&limit={}",
            limit.min(100)
        );
        let body = serde_json::to_string(address)
            .map_err(|e| format!("JSON serialize: {}", e))?;
        let response = self
            .inner
            .send_post_req(&endpoint, body)
            .await
            .map_err(|e| format!("Node request: {}", e))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| format!("Read: {}", e))?;
        if status.as_u16() == 404 || text.is_empty() {
            return Ok(Vec::new());
        }
        if !status.is_success() {
            return Err(format!("Tx history failed ({}): {}", status, text));
        }
        let value: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("Parse: {}", e))?;
        let items = value["items"].as_array().cloned().unwrap_or_default();
        let summaries = items.into_iter().filter_map(|tx| {
            let tx_id = tx["id"].as_str()?.to_string();
            let height = tx["inclusionHeight"].as_u64().unwrap_or(0);
            let timestamp = tx["timestamp"].as_u64().unwrap_or(0);
            let num_inputs = tx["inputs"].as_array().map(|a| a.len() as u32).unwrap_or(0);
            let num_outputs = tx["outputs"].as_array().map(|a| a.len() as u32).unwrap_or(0);

            let value_nano_erg = net_value_for_address(&tx, address);

            let token_ids: Vec<String> = tx["outputs"]
                .as_array()
                .map(|outs| {
                    outs.iter()
                        .filter_map(|o| o["assets"].as_array())
                        .flatten()
                        .filter_map(|a| a["tokenId"].as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default();

            Some(TxSummary {
                tx_id,
                height,
                timestamp,
                value_nano_erg,
                token_ids,
                num_inputs,
                num_outputs,
            })
        }).collect();
        Ok(summaries)
    }

    pub async fn submit_transaction(&self, tx_json: &serde_json::Value) -> Result<String, String> {
        let body =
            serde_json::to_string(tx_json).map_err(|e| format!("Serialize tx: {}", e))?;
        let response = self
            .inner
            .send_post_req("/transactions", body)
            .await
            .map_err(|e| format!("Submit: {}", e))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| format!("Read: {}", e))?;
        if status.is_success() {
            Ok(text.trim().trim_matches('"').to_string())
        } else {
            Err(format!("Tx rejected ({}): {}", status, text))
        }
    }
}

/// Build a minimal state context at a given height (for test/local reduction).
/// Uses dummy header data that is sufficient for signature generation (not consensus checks).
pub fn make_state_context(height: u32) -> ErgoStateContext {
    use ergo_lib::ergo_chain_types::EcPoint;
    use ergo_lib::ergo_chain_types::{AutolykosSolution, BlockId, Digest32, ADDigest, Votes};

    let dummy32 = Digest32::from([0u8; 32]);
    let dummy_ad = ADDigest::from([0u8; 33]);
    let dummy_pk = Box::new(EcPoint::from_base16_str(
        "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".to_string(),
    ).unwrap());

    let pre_header = PreHeader {
        version: 1,
        parent_id: BlockId(dummy32),
        timestamp: 0,
        n_bits: 16842752,
        height,
        miner_pk: dummy_pk.clone(),
        votes: Votes([0u8, 0u8, 0u8]),
    };

    let header = Header {
        version: 1,
        id: BlockId(dummy32),
        parent_id: BlockId(dummy32),
        ad_proofs_root: dummy32,
        state_root: dummy_ad,
        transaction_root: dummy32,
        timestamp: 0,
        n_bits: 16842752,
        height,
        extension_root: dummy32,
        autolykos_solution: AutolykosSolution {
            miner_pk: dummy_pk,
            pow_onetime_pk: None,
            nonce: vec![0u8; 8],
            pow_distance: Some(num_bigint::BigUint::from(0u32)),
        },
        votes: Votes([0u8, 0u8, 0u8]),
        unparsed_bytes: Box::new([]),
    };

    let headers: [Header; HEADERS_COUNT] = core::array::from_fn(|_| header.clone());

    ErgoStateContext::new(pre_header, headers, Parameters::default())
}

pub async fn get_token_info(
    token_id: &str,
    explorer_url: Option<&str>,
) -> Result<serde_json::Value, String> {
    if token_id.len() != 64 || !token_id.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("invalid token id".into());
    }
    let url = format!(
        "{}/api/v1/tokens/{}",
        explorer_url.unwrap_or(DEFAULT_EXPLORER_URL).trim_end_matches('/'),
        token_id
    );
    let text = reqwest::Client::new()
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Explorer token: {e}"))?
        .error_for_status()
        .map_err(|e| format!("Explorer token: {e}"))?
        .text()
        .await
        .map_err(|e| format!("Explorer token: {e}"))?;
    serde_json::from_str(&text).map_err(|e| format!("Parse token: {e}"))
}

fn net_value_for_address(tx: &serde_json::Value, address: &str) -> i64 {
    let outs = tx["outputs"].as_array().map(|a| a.as_slice()).unwrap_or(&[]);
    let ins = tx["inputs"].as_array().map(|a| a.as_slice()).unwrap_or(&[]);
    let to_self: i64 = outs
        .iter()
        .filter(|o| o["address"].as_str() == Some(address))
        .map(|o| o["value"].as_i64().unwrap_or(0))
        .sum();
    let from_self: i64 = ins
        .iter()
        .filter(|i| i["address"].as_str() == Some(address))
        .map(|i| i["value"].as_i64().unwrap_or(0))
        .sum();
    to_self - from_self
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preferred_node_is_first() {
        let urls = node_urls(Some("https://custom.node".into()));
        assert_eq!(urls[0], "https://custom.node");
        assert!(urls.contains(&DEFAULT_NODE_URL.to_string()));
    }

    #[test]
    fn default_list_has_no_duplicates() {
        let urls = node_urls(Some(DEFAULT_NODE_URL.into()));
        assert_eq!(urls.iter().filter(|u| *u == DEFAULT_NODE_URL).count(), 1);
    }

    #[test]
    fn parses_node_parameters() {
        let json = serde_json::json!({
            "outputCost": 194,
            "tokenAccessCost": 100,
            "maxBlockCost": 8001091,
            "maxBlockSize": 1271009,
            "dataInputCost": 100,
            "blockVersion": 3,
            "inputCost": 2407,
            "storageFeeFactor": 1250000,
            "minValuePerByte": 360
        });
        let params = parse_parameters(&json).unwrap();
        assert_eq!(params.block_version(), 3);
        assert_eq!(params.min_value_per_byte(), 360);
        assert_eq!(params.max_block_cost(), 8001091);
    }

    #[test]
    fn rejects_incomplete_parameters() {
        assert!(parse_parameters(&serde_json::json!({"blockVersion": 3})).is_err());
    }
}