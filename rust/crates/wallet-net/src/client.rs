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

/// Create a default mainnet NodeConfig.
pub fn default_node_config() -> NodeConfig {
    NodeConfig {
        url: DEFAULT_NODE_URL.to_string(),
        api_key: String::new(),
    }
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
        })
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

        Ok(ErgoStateContext::new(pre_header, arr, Parameters::default()))
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

    /// Fetch total nanoERG balance for an address.
    pub async fn get_address_balances(&self, address: &str) -> Result<(u64, Vec<String>), String> {
        use std::collections::HashSet;
        let boxes = self.all_unspent_boxes(address).await?;
        let erg_total: u64 = boxes.iter().map(|b| *b.value.as_u64()).sum();
        let mut token_ids = HashSet::new();
        for b in &boxes {
            if let Some(tokens) = b.tokens.as_ref() {
                for t in tokens.iter() {
                    token_ids.insert(t.token_id.clone().into());
                }
            }
        }
        Ok((erg_total, token_ids.into_iter().collect()))
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