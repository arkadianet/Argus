//! The part of `ergo-node-interface` Argus uses, ported from the
//! arkadianet/ergo-node-interface-rust fork at 0264f6f (MIT) onto Argus's own
//! HTTP stack ([`crate::http`]: rustls with ring and webpki-roots, no system
//! proxy lookup).
//!
//! Behaviour is kept as the fork had it, because signing depends on some of it
//! (`get_state_context`) and callers match on the rest: the same endpoints,
//! request headers, `Url::join` resolution, 30 s timeout, capability probing,
//! response parsing (no status check unless noted) and error messages.

use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use std::time::Duration;

use ergo_lib::chain::ergo_state_context::{ErgoStateContext, Headers};
use ergo_lib::chain::parameters::Parameters;
use ergo_lib::ergo_chain_types::{Header, PreHeader};
use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_lib::ergotree_ir::chain::token::TokenId;
use reqwest::header::{HeaderValue, CONTENT_TYPE};
use reqwest::{RequestBuilder, Response, Url};
use serde_json::from_str;

/// Capability encoding for the `AtomicU8`: 0 = unknown, 1 = disabled, 2 = enabled.
const CAP_UNKNOWN: u8 = 0;
const CAP_FALSE: u8 = 1;
const CAP_TRUE: u8 = 2;

pub type BlockHeight = u64;
pub type JsonValue = serde_json::Value;
pub type Result<T> = std::result::Result<T, NodeError>;

#[derive(thiserror::Error, Debug)]
pub enum NodeError {
    #[error("The configured node is unreachable. Please ensure your config is correctly filled out and the node is running.")]
    NodeUnreachable,
    #[error("Failed reading response from node: {0}")]
    FailedParsingNodeResponse(String),
    #[error("Failed parsing JSON box from node: {0}")]
    FailedParsingBox(String),
    #[error("The node is still syncing.")]
    NodeSyncing,
    #[error("{0}")]
    Other(String),
    #[error("Failed to parse URL: {0}")]
    InvalidUrl(String),
    #[error("This operation requires a node with extraIndex enabled. Configure the node with `extraIndex = true` or use a different endpoint.")]
    ExtraIndexRequired,
}

/// Height of the node's extra index (`/blockchain/indexedHeight`).
#[derive(Debug, Clone)]
pub struct IndexedHeight {
    pub indexed_height: u32,
    pub full_height: u32,
}

/// A REST client for one Ergo node.
#[derive(Debug, Clone)]
pub struct NodeInterface {
    pub api_key: String,
    pub url: Url,
    client: reqwest::Client,
    /// Unknown, disabled or enabled extraIndex; shared by clones.
    has_extra_index: Arc<AtomicU8>,
}

impl NodeInterface {
    fn capability_to_option(cap: u8) -> Option<bool> {
        match cap {
            CAP_TRUE => Some(true),
            CAP_FALSE => Some(false),
            _ => None,
        }
    }

    fn option_to_capability(opt: Option<bool>) -> u8 {
        match opt {
            Some(true) => CAP_TRUE,
            Some(false) => CAP_FALSE,
            None => CAP_UNKNOWN,
        }
    }

    fn create_client() -> Result<reqwest::Client> {
        crate::http::client_builder()
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| NodeError::Other(format!("Failed to create HTTP client: {}", e)))
    }

    /// Connect to `url` and probe whether the node has extraIndex enabled.
    /// Fails only on an unparseable URL; an unreachable node leaves the
    /// capability unknown.
    pub async fn from_url_str(api_key: &str, url: &str) -> Result<Self> {
        let url = Url::parse(url).map_err(|e| NodeError::InvalidUrl(e.to_string()))?;
        Self::from_url_with_probe(api_key, url).await
    }

    /// `http://{ip}:{port}/` without probing; the capability starts unknown.
    pub fn new_without_probe(api_key: &str, ip: &str, port: &str) -> Result<Self> {
        let url = Url::parse(&format!("http://{}:{}/", ip, port))
            .map_err(|e| NodeError::InvalidUrl(e.to_string()))?;
        Self::from_url_without_probe(api_key, url)
    }

    fn from_url_without_probe(api_key: &str, url: Url) -> Result<Self> {
        let client = Self::create_client()?;
        Ok(NodeInterface {
            api_key: api_key.to_string(),
            url,
            client,
            has_extra_index: Arc::new(AtomicU8::new(CAP_UNKNOWN)),
        })
    }

    async fn from_url_with_probe(api_key: &str, url: Url) -> Result<Self> {
        let client = Self::create_client()?;
        let probed = Self::probe_extra_index(&client, &url, api_key).await;
        let cap = Self::option_to_capability(probed);
        Ok(NodeInterface {
            api_key: api_key.to_string(),
            url,
            client,
            has_extra_index: Arc::new(AtomicU8::new(cap)),
        })
    }

    /// `GET /blockchain/indexedHeight`: a 2xx means enabled, 404 disabled,
    /// anything else (other statuses, network errors) unknown.
    async fn probe_extra_index(
        client: &reqwest::Client,
        base_url: &Url,
        api_key: &str,
    ) -> Option<bool> {
        let url = match base_url.join("/blockchain/indexedHeight") {
            Ok(u) => u,
            Err(_) => return None,
        };
        match client
            .get(url)
            .header("accept", "application/json")
            .header("api_key", api_key)
            .send()
            .await
        {
            Ok(resp) => {
                if resp.status().is_success() {
                    Some(true)
                } else if resp.status() == reqwest::StatusCode::NOT_FOUND {
                    Some(false)
                } else {
                    None
                }
            }
            Err(_) => None,
        }
    }

    /// `Some(true)`/`Some(false)` once a probe was conclusive, `None` before.
    pub fn has_extra_index(&self) -> Option<bool> {
        Self::capability_to_option(self.has_extra_index.load(Ordering::Relaxed))
    }

    /// Probe again. Only a conclusive answer (2xx or 404) replaces the stored
    /// capability; an inconclusive probe keeps the previous value.
    pub async fn refresh_capabilities(&self) {
        let probed = Self::probe_extra_index(&self.client, &self.url, &self.api_key).await;
        if let Some(result) = probed {
            let cap = Self::option_to_capability(Some(result));
            self.has_extra_index.store(cap, Ordering::Relaxed);
        }
    }

    /// Refuse only when extraIndex is known to be disabled.
    fn require_extra_index(&self) -> Result<()> {
        if self.has_extra_index.load(Ordering::Relaxed) == CAP_FALSE {
            Err(NodeError::ExtraIndexRequired)
        } else {
            Ok(())
        }
    }

    // ==================== Requests ====================

    /// The api key as a header value; "None" if it is not a valid header value.
    fn get_node_api_header(&self) -> HeaderValue {
        match HeaderValue::from_str(&self.api_key) {
            Ok(k) => k,
            _ => HeaderValue::from_static("None"),
        }
    }

    fn set_req_headers(&self, rb: RequestBuilder) -> RequestBuilder {
        rb.header("accept", "application/json")
            .header("api_key", self.get_node_api_header())
            .header(CONTENT_TYPE, "application/json")
    }

    /// GET `endpoint`, resolved with `Url::join` against the node URL (an
    /// absolute endpoint path replaces any path in the node URL). Any status
    /// is returned; a transport failure is `NodeUnreachable`.
    pub async fn send_get_req(&self, endpoint: &str) -> Result<Response> {
        let url = self
            .url
            .join(endpoint)
            .map_err(|e| NodeError::InvalidUrl(e.to_string()))?;
        self.set_req_headers(self.client.get(url))
            .send()
            .await
            .map_err(|_| NodeError::NodeUnreachable)
    }

    /// POST `body` to `endpoint`; see [`Self::send_get_req`].
    pub async fn send_post_req(&self, endpoint: &str, body: String) -> Result<Response> {
        let url = self
            .url
            .join(endpoint)
            .map_err(|e| NodeError::InvalidUrl(e.to_string()))?;
        self.set_req_headers(self.client.post(url))
            .body(body)
            .send()
            .await
            .map_err(|_| NodeError::NodeUnreachable)
    }

    /// Body as JSON, whatever the status.
    async fn parse_response_to_json(&self, resp: Result<Response>) -> Result<JsonValue> {
        let text = resp?.text().await.map_err(|_| {
            NodeError::FailedParsingNodeResponse(
                "Node Response Not Parseable into Text.".to_string(),
            )
        })?;
        let json =
            serde_json::from_str(&text).map_err(|_| NodeError::FailedParsingNodeResponse(text))?;
        Ok(json)
    }

    // ==================== Standard endpoints ====================

    /// `fullHeight` from `/info`; `NodeSyncing` when it is null.
    pub async fn current_block_height(&self) -> Result<BlockHeight> {
        let endpoint = "/info";
        let res = self.send_get_req(endpoint).await;
        let res_json = self.parse_response_to_json(res).await?;

        let height_json = res_json["fullHeight"].clone();

        if height_json.is_null() {
            Err(NodeError::NodeSyncing)
        } else {
            height_json
                .to_string()
                .parse()
                .map_err(|_| NodeError::FailedParsingNodeResponse(res_json.to_string()))
        }
    }

    /// `/info`; `NodeSyncing` when `fullHeight` is null.
    pub async fn node_info(&self) -> Result<JsonValue> {
        let endpoint = "/info";
        let res = self.send_get_req(endpoint).await;
        let res_json = self.parse_response_to_json(res).await?;

        if res_json["fullHeight"].is_null() {
            Err(NodeError::NodeSyncing)
        } else {
            Ok(res_json)
        }
    }

    /// State context from the last 10 headers, newest first. The pre-header
    /// is the newest header itself (same height as the tip), and the
    /// parameters are `Parameters::default()`, not the node's.
    pub async fn get_state_context(&self) -> Result<ErgoStateContext> {
        let mut vec_headers = self.get_last_block_headers(10).await?;
        if vec_headers.len() < 10 {
            return Err(NodeError::Other(format!(
                "Expected 10 block headers, got {}",
                vec_headers.len()
            )));
        }
        vec_headers.reverse();
        let ten_headers: [Header; 10] = vec_headers
            .try_into()
            .map_err(|_| NodeError::Other("Failed to convert headers to array".to_string()))?;
        let headers = Headers::from(ten_headers);
        let pre_header = PreHeader::from(
            headers
                .first()
                .ok_or_else(|| NodeError::Other("Headers array is empty".to_string()))?
                .clone(),
        );
        let state_context = ErgoStateContext::new(pre_header, headers, Parameters::default());

        Ok(state_context)
    }

    /// `/blocks/lastHeaders/{number}`, oldest first as the node returns them.
    /// Elements that do not parse as a header are skipped; a non-array body
    /// yields no headers.
    pub async fn get_last_block_headers(&self, number: u32) -> Result<Vec<Header>> {
        let endpoint = format!("/blocks/lastHeaders/{}", number);
        let res = self.send_get_req(endpoint.as_str()).await;
        let res_json = self.parse_response_to_json(res).await?;

        let mut headers: Vec<Header> = vec![];

        for i in 0.. {
            let header_json = &res_json[i];
            if header_json.is_null() {
                break;
            } else if let Ok(header) = from_str(&header_json.to_string()) {
                headers.push(header);
            }
        }
        Ok(headers)
    }

    /// A box from the UTXO set or the mempool (`/utxo/withPool/byId`).
    pub async fn box_from_id_with_pool(&self, box_id: impl AsRef<str>) -> Result<ErgoBox> {
        let endpoint = format!("/utxo/withPool/byId/{}", box_id.as_ref());
        let res = self.send_get_req(&endpoint).await;
        let res_json = self.parse_response_to_json(res).await?;
        from_str(&res_json.to_string())
            .map_err(|_| NodeError::FailedParsingBox(res_json.to_string()))
    }

    /// Header ids at `height` (more than one on a fork).
    pub async fn block_ids_at_height(&self, height: u64) -> Result<Vec<String>> {
        let endpoint = format!("/blocks/at/{}", height);
        let res = self.send_get_req(&endpoint).await;
        let res_json = self.parse_response_to_json(res).await?;
        serde_json::from_value(res_json.clone())
            .map_err(|e| NodeError::FailedParsingNodeResponse(e.to_string()))
    }

    pub async fn get_block(&self, header_id: impl AsRef<str>) -> Result<JsonValue> {
        let endpoint = format!("/blocks/{}", header_id.as_ref());
        let res = self.send_get_req(&endpoint).await;
        self.parse_response_to_json(res).await
    }

    pub async fn get_block_header(&self, header_id: impl AsRef<str>) -> Result<JsonValue> {
        let endpoint = format!("/blocks/{}/header", header_id.as_ref());
        let res = self.send_get_req(&endpoint).await;
        self.parse_response_to_json(res).await
    }

    pub async fn get_block_transactions(&self, header_id: impl AsRef<str>) -> Result<JsonValue> {
        let endpoint = format!("/blocks/{}/transactions", header_id.as_ref());
        let res = self.send_get_req(&endpoint).await;
        self.parse_response_to_json(res).await
    }

    // ==================== ExtraIndex endpoints ====================

    /// Requires extraIndex unless the capability is still unknown.
    pub async fn get_indexed_height(&self) -> Result<IndexedHeight> {
        self.require_extra_index()?;
        let endpoint = "/blockchain/indexedHeight";
        let res = self.send_get_req(endpoint).await;
        let res_json = self.parse_response_to_json(res).await?;
        Ok(IndexedHeight {
            indexed_height: res_json["indexedHeight"]
                .as_u64()
                .ok_or_else(|| NodeError::FailedParsingNodeResponse(res_json.to_string()))?
                as u32,
            full_height: res_json["fullHeight"]
                .as_u64()
                .ok_or_else(|| NodeError::FailedParsingNodeResponse(res_json.to_string()))?
                as u32,
        })
    }

    /// Unspent boxes holding `token_id`. Unparseable elements are skipped, and
    /// so are boxes that still carry a `spentTransactionId` (an indexer bug).
    pub async fn unspent_boxes_by_token_id(
        &self,
        token_id: &TokenId,
        offset: u64,
        limit: u64,
    ) -> Result<Vec<ErgoBox>> {
        self.require_extra_index()?;
        let id: String = (*token_id).into();
        let endpoint = format!(
            "/blockchain/box/unspent/byTokenId/{}?offset={}&limit={}",
            id, offset, limit
        );
        let res = self.send_get_req(endpoint.as_str()).await;
        let res_json = self.parse_response_to_json(res).await?;

        let mut box_list = vec![];

        for i in 0.. {
            let box_json = &res_json[i];
            if box_json.is_null() {
                break;
            } else if let Ok(ergo_box) = from_str(&box_json.to_string()) {
                if box_json["spentTransactionId"].is_null() {
                    box_list.push(ergo_box);
                }
            }
        }
        Ok(box_list)
    }

    pub async fn blockchain_transaction_from_id(&self, tx_id: &str) -> Result<JsonValue> {
        self.require_extra_index()?;
        let endpoint = "/blockchain/transaction/byId/".to_string() + tx_id;
        let res = self.send_get_req(&endpoint).await;
        self.parse_response_to_json(res).await
    }

    // ==================== Mempool ====================

    /// `/transactions/unconfirmed`; a non-array body yields no transactions.
    pub async fn mempool_transactions(&self) -> Result<Vec<JsonValue>> {
        let endpoint = "/transactions/unconfirmed";
        let res = self.send_get_req(endpoint).await;
        let res_json = self.parse_response_to_json(res).await?;

        let mut transactions = vec![];
        for i in 0.. {
            let tx_json = &res_json[i];
            if tx_json.is_null() {
                break;
            } else {
                transactions.push(tx_json.clone());
            }
        }
        Ok(transactions)
    }

    pub async fn unconfirmed_transaction_by_id(&self, tx_id: &str) -> Result<JsonValue> {
        let endpoint = format!("/transactions/unconfirmed/byTransactionId/{}", tx_id);
        let res = self.send_get_req(&endpoint).await;
        let res_json = self.parse_response_to_json(res).await?;

        Ok(res_json)
    }
}
