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
    /// Node the pools were discovered from. Box ids and reserves are only
    /// meaningful for that node, so a cache entry cannot outlive a node switch.
    pub node_url: String,
}

impl PoolSet {
    fn is_fresh_for(&self, node_url: &str) -> bool {
        self.node_url == node_url && self.fetched_at.elapsed() < POOL_CACHE_TTL
    }
}

static POOL_CACHE: Lazy<RwLock<Option<PoolSet>>> = Lazy::new(|| RwLock::new(None));

/// Poison-tolerant lock read, mirroring `api::recover`.
fn recover<T>(r: std::sync::LockResult<T>) -> T {
    r.unwrap_or_else(|p| p.into_inner())
}

/// Tolerance absorbing pool movement between the cached quote and the
/// force-refreshed build.
///
/// This is **not** slippage protection. A direct swap fixes the output amount
/// in the transaction it builds and references the pool box by id, so the swap
/// either executes at exactly the quoted price or the transaction is invalid —
/// there is no path to a worse on-chain fill. `min_output` is never written to
/// an output or read by any contract; the builders only compare against it at
/// build time (`direct_swap/n2t.rs:87`, `t2t.rs:95`). It exists so a quote
/// served from the TTL cache cannot silently become a smaller build.
///
/// Fixed deliberately: there is nothing here a user could meaningfully tune.
pub(crate) const QUOTE_TOLERANCE_PCT: f64 = 0.5;

/// Floor, so the built minimum is never above what was quoted.
pub(crate) fn min_output_for(output: u64) -> u64 {
    let keep = (100.0 - QUOTE_TOLERANCE_PCT) / 100.0;
    (output as f64 * keep).floor() as u64
}

/// Which parser a pool box needs, from its token layout: N2T boxes carry
/// [NFT, LP, Y], T2T boxes [NFT, LP, X, Y].
pub(crate) fn pool_kind_for_token_count(n: usize) -> Option<amm::PoolType> {
    match n {
        3 => Some(amm::PoolType::N2T),
        n if n >= 4 => Some(amm::PoolType::T2T),
        _ => None,
    }
}

pub(crate) fn parse_pool_box(
    ergo_box: &ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox,
) -> Result<AmmPool, String> {
    let n = ergo_box.tokens.as_ref().map(|t| t.len()).unwrap_or(0);
    match pool_kind_for_token_count(n) {
        Some(amm::PoolType::N2T) => amm::fetch::parse_n2t_pool(ergo_box),
        Some(amm::PoolType::T2T) => amm::fetch::parse_t2t_pool(ergo_box),
        None => return Err("box does not have a pool token layout".into()),
    }
    .map_err(|e| e.to_string())
}

/// The current box of one pool by its pool NFT: one indexed request instead
/// of re-downloading every Spectrum pool to find it.
pub(crate) async fn fetch_pool(
    client: &ergo_node_client::NodeClient,
    pool_id: &str,
) -> Result<(AmmPool, ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox), String> {
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    if caps.has_extra_index == Some(false) {
        return Err(extra_index_error());
    }
    let ergo_box = client
        .get_box_by_token_id(&caps, &citadel_core::TokenId::new(pool_id))
        .await
        .map_err(|_| {
            ArgusError::Generic("POOL_MOVED: pool no longer available, re-quote".into())
                .to_json_string()
        })?;
    let pool = parse_pool_box(&ergo_box)
        .map_err(|e| ArgusError::Generic(format!("POOL_MOVED: {e}")).to_json_string())?;
    if pool.pool_id != pool_id {
        return Err(
            ArgusError::Generic("POOL_MOVED: pool box did not match, re-quote".into())
                .to_json_string(),
        );
    }
    Ok((pool, ergo_box))
}

/// Seeds the token cache from metadata the app persisted on a previous
/// launch, so a fresh process does not re-ask the node for every token.
pub(crate) fn seed_token_cache(known_tokens_json: &str) {
    let parsed: serde_json::Value = match serde_json::from_str(known_tokens_json) {
        Ok(v) => v,
        Err(_) => return,
    };
    let Some(map) = parsed.as_object() else { return };
    let mut cache = recover(TOKEN_CACHE.write());
    for (id, v) in map {
        let Some(name) = v.get("name").and_then(|n| n.as_str()) else { continue };
        if name.is_empty() {
            continue;
        }
        let decimals = v
            .get("decimals")
            .and_then(|d| d.as_u64())
            .and_then(|d| u8::try_from(d).ok())
            .unwrap_or(0);
        cache
            .entry(id.clone())
            .or_insert(TokenMeta { name: name.to_string(), decimals });
    }
}

/// Metadata for many tokens with bounded concurrency; cache hits are free.
pub(crate) async fn token_meta_many(
    client: &ergo_node_client::NodeClient,
    ids: Vec<String>,
) -> Vec<(String, TokenMeta)> {
    const CONCURRENCY: usize = 8;
    let mut out = Vec::with_capacity(ids.len());
    for chunk in ids.chunks(CONCURRENCY) {
        let futs = chunk.iter().map(|id| {
            let id = id.clone();
            async move {
                let meta = token_meta(client, &id).await;
                (id, meta)
            }
        });
        out.extend(futures::future::join_all(futs).await);
    }
    out
}

/// Every token id a pool references, for metadata prefetch.
pub(crate) fn pool_token_ids(pool: &AmmPool) -> Vec<String> {
    let mut ids = vec![pool.token_y.token_id.clone()];
    if let Some(x) = &pool.token_x {
        ids.push(x.token_id.clone());
    }
    ids
}

/// Pick the pool returning the most output for `amount`, with its quote.
///
/// Ranks by quoted output rather than reserve depth. Depth is not comparable
/// across T2T candidates — `token_y` holds whichever token that pool put in the
/// slot, so comparing raw amounts compares different tokens with different
/// decimals. Quoted output is the same token for every candidate of a pair, and
/// it also folds in each pool's own fee tier (`fee_num`/`fee_denom`), which a
/// reserve comparison ignores entirely.
///
/// Quoting during selection also means a candidate that cannot serve the swap
/// is skipped rather than chosen and then failed on, which previously reported
/// tradeable pairs as untradeable.
pub(crate) fn best_pool_for<'a>(
    pools: &'a [AmmPool],
    from_token: Option<&str>,
    to_token: Option<&str>,
    amount: u64,
) -> Option<(&'a AmmPool, amm::state::SwapQuote)> {
    let input = swap_input(from_token, amount);
    pools
        .iter()
        .filter(|p| pool_supports(p, from_token, to_token))
        .filter_map(|p| amm::calculator::quote_swap(p, &input).map(|q| (p, q)))
        .max_by_key(|(_, q)| q.output.amount)
}

pub(crate) fn pool_supports(pool: &AmmPool, from_token: Option<&str>, to_token: Option<&str>) -> bool {
    let ids: Vec<&str> = match pool.pool_type {
        amm::state::PoolType::N2T => vec![pool.token_y.token_id.as_str()],
        amm::state::PoolType::T2T => pool
            .token_x
            .iter()
            .map(|t| t.token_id.as_str())
            .chain(std::iter::once(pool.token_y.token_id.as_str()))
            .collect(),
    };
    let side = |t: Option<&str>| match t {
        None => matches!(pool.pool_type, amm::state::PoolType::N2T),
        Some(id) => ids.contains(&id),
    };
    side(from_token) && side(to_token)
}

pub(crate) fn swap_input(from_token: Option<&str>, amount: u64) -> amm::state::SwapInput {
    match from_token {
        None => amm::state::SwapInput::Erg { amount },
        Some(id) => amm::state::SwapInput::Token {
            token_id: id.to_string(),
            amount,
        },
    }
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
    let resolved = crate::api_dexy_impl::resolve_node_url(node_url.clone());
    if !force_refresh {
        if let Some(cached) = recover(POOL_CACHE.read()).clone() {
            if cached.is_fresh_for(&resolved) {
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

    // Dexy's pools copy the Spectrum AMM box layout, so discovery picks them
    // up — but they are a separate protocol with its own oracle/fee rules and
    // the direct-swap builder cannot fill against them. Exclude them here so
    // the picker never lists Dexy tokens AND `best_pool_for` never routes a
    // quote through a Dexy pool (which would fail at broadcast).
    pools.retain(|pool| keep_pool(&pool.pool_id));

    let set = PoolSet {
        pools,
        truncated,
        fetched_at: Instant::now(),
        node_url: resolved,
    };
    *recover(POOL_CACHE.write()) = Some(set.clone());
    Ok(set)
}

/// ErgoTree of the Citadel dev-fee P2PK (`ergo-tx/src/dev_fee.rs:29`).
pub(crate) const CITADEL_DEV_FEE_TREE: &str =
    "0008cd0224f3a8909d624e7c584f215956370278324c9b3bfc206a4605a27c952121e68c";

/// Dexy protocol pool NFTs (gold + USD, `protocols/dexy/src/constants.rs`).
/// Their pools mirror the Spectrum layout and must never be traded here.
const DEXY_POOL_NFTS: [&str; 2] = [
    "905ecdef97381b92c2f0ea9b516f312bfb18082c61b24b40affa6a55555c77c7",
    "4ecaa1aac9846b1454563ae51746db95a3a40ee9f8c5f5301afbe348ae803d41",
];

fn keep_pool(pool_id: &str) -> bool {
    !DEXY_POOL_NFTS.contains(&pool_id)
}

/// True when any output pays the inherited Citadel dev fee. Argus levies no
/// app fee, so a built transaction must never contain such an output.
pub(crate) fn pays_citadel_dev_fee(output_trees: &[String]) -> bool {
    output_trees.iter().any(|t| t == CITADEL_DEV_FEE_TREE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pool_kind_follows_the_token_layout() {
        // N2T boxes carry [NFT, LP, Y]; T2T boxes carry [NFT, LP, X, Y].
        assert_eq!(pool_kind_for_token_count(3), Some(amm::PoolType::N2T));
        assert_eq!(pool_kind_for_token_count(4), Some(amm::PoolType::T2T));
        assert_eq!(pool_kind_for_token_count(2), None);
        assert_eq!(pool_kind_for_token_count(5), Some(amm::PoolType::T2T));
    }

    #[test]
    fn known_tokens_seed_the_cache_without_a_node() {
        seed_token_cache(r#"{"abc":{"name":"ABC","decimals":3},"bad":"x"}"#);
        let hit = recover(TOKEN_CACHE.read()).get("abc").cloned().expect("seeded");
        assert_eq!(hit.name, "ABC");
        assert_eq!(hit.decimals, 3);
        assert!(recover(TOKEN_CACHE.read()).get("bad").is_none());
    }

    #[test]
    fn dexy_pools_are_excluded_from_spectrum_discovery() {
        // Dexy gold + USD pool NFTs mirror the Spectrum layout and must be
        // filtered; a real Spectrum pool id passes.
        assert!(!keep_pool(
            "905ecdef97381b92c2f0ea9b516f312bfb18082c61b24b40affa6a55555c77c7"
        ));
        assert!(!keep_pool(
            "4ecaa1aac9846b1454563ae51746db95a3a40ee9f8c5f5301afbe348ae803d41"
        ));
        assert!(keep_pool(
            "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        ));
    }

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

    #[test]
    fn quote_tolerance_is_fixed_and_not_caller_supplied() {
        // A direct swap fixes the output in the tx it builds and references the
        // pool box by id, so there is no on-chain slippage exposure and nothing
        // for a user to tune. The tolerance only absorbs pool movement between
        // the cached quote and the force-refreshed build.
        assert_eq!(QUOTE_TOLERANCE_PCT, 0.5);
    }

    #[test]
    fn min_output_absorbs_quote_staleness() {
        assert_eq!(min_output_for(1_000_000), 995_000);
        // Rounds down: never demand a minimum the pool cannot satisfy.
        assert_eq!(min_output_for(3), 2);
        assert_eq!(min_output_for(0), 0);
    }

    fn tok(id: &str, amount: u64) -> amm::state::TokenAmount {
        amm::state::TokenAmount {
            token_id: id.to_string(),
            amount,
            decimals: Some(0),
            name: None,
        }
    }

    fn t2t(pool_id: &str, x: amm::state::TokenAmount, y: amm::state::TokenAmount) -> AmmPool {
        AmmPool {
            pool_id: pool_id.to_string(),
            pool_type: amm::state::PoolType::T2T,
            box_id: format!("box_{pool_id}"),
            erg_reserves: None,
            token_x: Some(x),
            token_y: y,
            lp_token_id: format!("lp_{pool_id}"),
            lp_circulating: 1,
            fee_num: 997,
            fee_denom: 1000,
        }
    }

    /// Ranking T2T pools by `token_y.amount` compares raw counts of whichever
    /// token sits in that slot — different tokens, different decimals. Rank by
    /// the quoted output instead, which is the same token across candidates.
    #[test]
    fn t2t_ranks_by_quoted_output_not_raw_reserves() {
        // Deep in A, shallow in B: 1000 A in yields ~99 B.
        let big_y = t2t("big", tok("A", 10_000_000), tok("B", 1_000_000));
        // Shallow in A, mid in B: same input yields ~249_624 B.
        let better = t2t("better", tok("A", 1_000), tok("B", 500_000));
        let pools = vec![big_y, better];

        let (pool, quote) = best_pool_for(&pools, Some("A"), Some("B"), 1_000)
            .expect("a T2T pool trades A/B");

        assert_eq!(
            pool.pool_id, "better",
            "must pick the pool that actually returns more, not the larger token_y"
        );
        assert!(quote.output.amount > 200_000, "got {}", quote.output.amount);
    }

    /// Selecting before quoting reports a tradeable pair as untradeable
    /// whenever the top-ranked candidate cannot serve the swap.
    #[test]
    fn unquotable_pools_are_skipped_not_fatal() {
        // Ranks highest by token_y, but has 1 unit of A out — quotes to zero.
        let dead_end = t2t("dead", tok("A", 1), tok("B", 1_000_000_000));
        let usable = t2t("usable", tok("A", 500_000), tok("B", 1_000_000));
        let pools = vec![dead_end, usable];

        let (pool, quote) = best_pool_for(&pools, Some("B"), Some("A"), 1_000)
            .expect("the usable pool must be found even though a deeper one cannot quote");

        assert_eq!(pool.pool_id, "usable");
        assert!(quote.output.amount > 0);
    }

    /// `build_direct_swap_eip12` derives the output from the pool box alone —
    /// the N2T builder destructures `SwapInput::Token { amount, .. }` and never
    /// checks the token id against the pool. A caller passing a pool_id that
    /// does not trade the requested pair must be rejected before a transaction
    /// is built, not silently built against the wrong pool.
    #[test]
    fn a_pool_must_trade_the_requested_pair() {
        let pool = t2t("p", tok("A", 1_000), tok("B", 1_000));

        assert!(pool_supports(&pool, Some("A"), Some("B")));
        assert!(!pool_supports(&pool, Some("A"), Some("C")));
        assert!(!pool_supports(&pool, None, Some("B")));
    }

    /// A cached pool set belongs to the node it was discovered from. Switching
    /// nodes must not serve pools from the previous one.
    #[test]
    fn cached_pools_are_scoped_to_their_node() {
        let set = PoolSet {
            pools: vec![],
            truncated: false,
            fetched_at: Instant::now(),
            node_url: "https://node-a.example".to_string(),
        };

        assert!(set.is_fresh_for("https://node-a.example"));
        assert!(
            !set.is_fresh_for("https://node-b.example"),
            "a different node must miss the cache"
        );
    }

    /// A built swap must never pay the Citadel address. Pinned to that tree
    /// specifically, not to "no extra outputs" — Argus plans its own 0.0011 ERG
    /// fee, and this assertion must survive it.
    #[test]
    fn built_swap_outputs_never_pay_citadel() {
        let trees = vec![
            "0008cd03aaaaaa".to_string(),
            "0008cd03bbbbbb".to_string(),
        ];
        assert!(!pays_citadel_dev_fee(&trees));

        let with_fee = vec![
            "0008cd03aaaaaa".to_string(),
            CITADEL_DEV_FEE_TREE.to_string(),
        ];
        assert!(pays_citadel_dev_fee(&with_fee));
    }
}
