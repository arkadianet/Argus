//! Spectrum AMM direct-swap integration for Argus mobile.
//!
//! Wraps the vendored Citadel `amm` protocol crate. Pool discovery and quotes
//! never touch the wallet handle; the build function reuses the existing
//! prepare → confirm → sign & broadcast flow.

use std::collections::HashMap;
use std::sync::RwLock;
use std::time::{Duration, Instant};

use amm::fetch::{discover_n2t_pools, discover_t2t_pools};
use amm::state::AmmPool;
use once_cell::sync::Lazy;

use crate::error::ArgusError;

#[derive(Clone, serde::Serialize)]
pub(crate) struct TokenMeta {
    pub name: String,
    pub decimals: u8,
}

impl TokenMeta {
    /// A node that cannot describe a token must not cause a wrong amount.
    /// Falling back to 0 decimals keeps raw units visible rather than scaling
    /// by a guess.
    fn fallback(token_id: &str) -> Self {
        let head: String = token_id.chars().take(8).collect();
        Self {
            name: format!("{head}…"),
            decimals: 0,
        }
    }
}

/// Token ids are immutable, so this cache only ever grows — no TTL.
static TOKEN_CACHE: Lazy<RwLock<HashMap<String, TokenMeta>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

pub(crate) async fn token_meta(
    client: &ergo_node_client::NodeClient,
    token_id: &str,
) -> TokenMeta {
    if let Some(hit) = recover(TOKEN_CACHE.read()).get(token_id) {
        return hit.clone();
    }
    let meta = match client.get_token_info(token_id).await {
        Ok(info) => TokenMeta {
            // Node returns Options; an unnamed or nonsense-decimals token
            // degrades to the safe fallback instead of a wrong amount.
            name: info
                .name
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| TokenMeta::fallback(token_id).name),
            decimals: info.decimals.and_then(|d| u8::try_from(d).ok()).unwrap_or(0),
        },
        Err(_) => TokenMeta::fallback(token_id),
    };
    recover(TOKEN_CACHE.write()).insert(token_id.to_string(), meta.clone());
    meta
}

/// Per-call cap inside `discover_*_pools`. Hitting it means pools were dropped.
const DISCOVERY_CAP: usize = 1000;

/// Pool reserves move every swap, so the cached set goes stale quickly.
pub(crate) const POOL_CACHE_TTL: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub(crate) struct PoolSet {
    pub pools: Vec<AmmPool>,
    pub truncated: bool,
    pub fetched_at: Instant,
}

static POOL_CACHE: Lazy<RwLock<Option<PoolSet>>> = Lazy::new(|| RwLock::new(None));

/// Poison-tolerant lock read, mirroring `api::recover`.
fn recover<T>(r: std::sync::LockResult<T>) -> T {
    r.unwrap_or_else(|p| p.into_inner())
}

fn is_truncated(n2t_count: usize, t2t_count: usize) -> bool {
    n2t_count >= DISCOVERY_CAP || t2t_count >= DISCOVERY_CAP
}

fn extra_index_error() -> String {
    ArgusError::Generic(
        "EXTRA_INDEX_REQUIRED: this node has no extra index, so Spectrum pools \
         cannot be discovered. Choose a node with extraIndex enabled in settings."
            .to_string(),
    )
    .to_json_string()
}

/// Discover every Spectrum pool, cached for [`POOL_CACHE_TTL`].
pub(crate) async fn load_pools(
    node_url: Option<String>,
    force_refresh: bool,
) -> Result<PoolSet, String> {
    if !force_refresh {
        if let Some(cached) = recover(POOL_CACHE.read()).clone() {
            if cached.fetched_at.elapsed() < POOL_CACHE_TTL {
                return Ok(cached);
            }
        }
    }

    let client = crate::api_dexy_impl::dexy_client(node_url).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    if caps.has_extra_index == Some(false) {
        return Err(extra_index_error());
    }

    let n2t = discover_n2t_pools(&client)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let t2t = discover_t2t_pools(&client)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;

    let truncated = is_truncated(n2t.len(), t2t.len());
    let mut pools = n2t;
    pools.extend(t2t);

    let set = PoolSet {
        pools,
        truncated,
        fetched_at: Instant::now(),
    };
    *recover(POOL_CACHE.write()) = Some(set.clone());
    Ok(set)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ErgoTree of the Citadel dev-fee P2PK (`ergo-tx/src/dev_fee.rs:29`).
    /// Argus must never pay it.
    const CITADEL_DEV_FEE_TREE: &str =
        "0008cd0224f3a8909d624e7c584f215956370278324c9b3bfc206a4605a27c952121e68c";

    /// `init_app` disables the inherited Citadel fee. This pins that guard:
    /// `resolved_dev_fee_config` caches into a process-global `OnceLock` on
    /// first call, so this must be the only test in the crate that resolves it.
    #[test]
    fn argus_never_levies_the_citadel_dev_fee() {
        crate::api::init_app();

        let cfg = ergo_tx::resolved_dev_fee_config();

        assert!(!cfg.enabled, "Citadel dev fee must stay disabled in Argus");
        assert_eq!(cfg.budget(), 0, "disabled fee must budget 0 nanoERG");
        assert_ne!(
            cfg.recipient_ergo_tree, CITADEL_DEV_FEE_TREE,
            "Argus must never target the Citadel fee address"
        );
    }

    #[test]
    fn truncation_is_flagged_at_the_discovery_cap() {
        // discover_n2t_pools / discover_t2t_pools cap at 1000 boxes each and
        // only tracing::warn on overflow. The UI must be able to say so.
        assert!(is_truncated(1000, 0));
        assert!(is_truncated(0, 1000));
        assert!(is_truncated(1000, 1000));
        assert!(!is_truncated(999, 999));
    }

    #[test]
    fn missing_extra_index_is_a_distinct_error() {
        let err = extra_index_error();
        assert!(
            err.contains("EXTRA_INDEX_REQUIRED"),
            "capability failure needs its own code, got: {err}"
        );
    }

    #[test]
    fn unknown_tokens_fall_back_to_a_short_id_label() {
        let meta = TokenMeta::fallback("a55b8735ed1a99e46c2c89f8994aacdf4b1109bdcf682f1e5b34479c6e392669");
        assert_eq!(meta.name, "a55b8735…");
        assert_eq!(meta.decimals, 0, "unknown decimals must not silently scale amounts");
    }
}
