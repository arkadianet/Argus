//! Circular arbitrage across Spectrum pools, on the chained-legs design.
//!
//! A pool contract names its successor as `OUTPUTS(0)`, so one transaction
//! spends one pool box: an n-leg cycle is n transactions, each spending the
//! box the previous one paid out. The safeguards the user asked for:
//!
//! - **Scan** reads the pools fresh from the user's node on every call, and
//!   only while the screen asks; nothing here runs in the background.
//!   Pools whose box a mempool transaction is already spending are skipped.
//! - **Prepare** re-reads every pool on the route, re-sizes the trade,
//!   refuses below the user's minimum profit, builds every leg and checks
//!   the chain adds up (see `crate::arbitrage_chain`). The whole chain is returned for
//!   review before anything is signed.
//! - **Execute** checks immediately before signing that every pool box is
//!   still the one reviewed and not busy in the mempool; if any moved, it
//!   signs nothing and asks for a fresh review. Otherwise it signs every
//!   leg, then broadcasts them back to back.
//! - **Status** follows the legs; when a later leg was rejected or dropped
//!   it names the token the wallet now holds instead of ERG, and
//!   **prepare_unwind** offers that token's sale back to ERG at a fresh
//!   quote, as an ordinary preparation shown on the confirm sheet.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use once_cell::sync::Lazy;
use rand::RngCore;
use serde::Deserialize;
use wallet_amm::contract::{N2T_POOL_TREE, T2T_POOL_TREE};
use wallet_amm::{
    best_exit, classify, price_book, requote, scan, stranded_holding, ArbOptions, Asset,
    ChainState, Costs, LegStatus, Opportunity, Pool, PricingOptions, RouteStep,
};

use super::{recover, CachedPreparation};
use crate::arbitrage_chain::{
    build_chain, build_exit, holds, id_of, pool_from_box, BuiltLeg, FreshPool,
};
use crate::error::ArgusError;

/// Discovery returns at most this many boxes per pool contract.
const DISCOVERY_CAP: u64 = 1000;

/// A reviewed chain older than this is not signed: its pools have had time
/// to move and the numbers the user saw mean little.
const REVIEW_TTL: Duration = Duration::from_secs(5 * 60);

/// Prepared and executed chains kept for status and recovery.
const MAX_CHAINS: usize = 20;

fn generic(msg: impl Into<String>) -> String {
    ArgusError::Generic(msg.into()).to_json_string()
}

fn node_err(e: impl std::fmt::Display) -> String {
    ArgusError::NodeError(e.to_string()).to_json_string()
}

/// Every Spectrum pool, fresh from the node and parsed by `wallet-amm`.
/// Junk boxes at the pool addresses are dropped, and Dexy's look-alike
/// pools are left out as everywhere else in the app. Also says whether
/// discovery hit its cap and may have missed pools.
async fn discover(client: &ergo_node_client::NodeClient) -> Result<(Vec<Pool>, bool), String> {
    let caps = client.require_capabilities().await.map_err(node_err)?;
    if caps.has_extra_index == Some(false) {
        return Err(generic(
            "EXTRA_INDEX_REQUIRED: this node has no extra index, so Spectrum pools cannot be read. \
             Choose a node with extraIndex enabled in settings.",
        ));
    }
    let mut pools = Vec::new();
    let mut truncated = false;
    for tree in [N2T_POOL_TREE, T2T_POOL_TREE] {
        let boxes = client
            .unspent_boxes_by_ergo_tree(tree, 0, DISCOVERY_CAP)
            .await
            .map_err(node_err)?;
        truncated |= boxes.len() as u64 >= DISCOVERY_CAP;
        pools.extend(boxes.iter().filter_map(|b| pool_from_box(b).ok()));
    }
    pools.retain(|p| crate::api_amm_impl::keep_pool(&p.pool_id));
    Ok((pools, truncated))
}

/// Pool box ids that a mempool transaction is already spending, or `None`
/// when the mempool could not be read (the caller says so rather than
/// pretending the pools are free).
async fn busy_pool_boxes(client: &ergo_node_client::NodeClient) -> Option<HashSet<String>> {
    let mut busy = HashSet::new();
    for tree in [N2T_POOL_TREE, T2T_POOL_TREE] {
        let txs = client.get_unconfirmed_by_ergo_tree(tree).await.ok()?;
        for tx in txs {
            for input in tx["inputs"].as_array().into_iter().flatten() {
                if let Some(id) = input["boxId"].as_str() {
                    busy.insert(id.to_string());
                }
            }
        }
    }
    Some(busy)
}

/// What every leg pays: the swap builder's miner fee, the Argus fee as
/// installed, and the wallet's box minimum.
fn current_costs() -> Costs {
    Costs {
        miner_fee_nano: citadel_core::constants::TX_FEE_NANO as u64,
        app_fee_nano: ergo_tx::resolved_dev_fee_config().budget().max(0) as u64,
        box_min_nano: citadel_core::constants::MIN_BOX_VALUE_NANO as u64,
    }
}

#[derive(Deserialize)]
struct ScanOptions {
    min_profit_nano: u64,
    min_depth_nano: u64,
    #[serde(default = "default_max_legs")]
    max_legs: usize,
    #[serde(default)]
    available_nano: Option<u64>,
    #[serde(default)]
    trusted_token_ids: Vec<String>,
    #[serde(default)]
    include_untrusted: bool,
    #[serde(default = "default_max_results")]
    max_results: usize,
}

fn default_max_legs() -> usize {
    3
}

fn default_max_results() -> usize {
    30
}

fn parse<T: for<'de> Deserialize<'de>>(json: &str, what: &str) -> Result<T, String> {
    serde_json::from_str(json)
        .map_err(|e| ArgusError::SerializationError(format!("{what}: {e}")).to_json_string())
}

/// Every arbitrage cycle the pools offer right now, best first.
///
/// `options_json`: `{"min_profit_nano", "min_depth_nano", "max_legs"?,
/// "available_nano"?, "trusted_token_ids"?, "include_untrusted"?,
/// "max_results"?}`. Reads every pool fresh and the mempool once; signs
/// nothing and needs no wallet.
#[flutter_rust_bridge::frb]
pub async fn arbitrage_scan(
    node_url: Option<String>,
    options_json: String,
) -> Result<String, String> {
    let opts: ScanOptions = parse(&options_json, "options")?;
    let client = crate::api_dexy_impl::dexy_client(node_url).await?;
    let (pools, truncated) = discover(&client).await?;
    let height = client.current_height().await.map_err(node_err)?;
    let busy = busy_pool_boxes(&client).await;
    let trusted: HashSet<String> = opts.trusted_token_ids.into_iter().collect();
    let book = price_book(
        &pools,
        &PricingOptions {
            min_depth_nano: opts.min_depth_nano,
            trusted: trusted.clone(),
        },
    );
    let costs = current_costs();
    let result = scan(
        &pools,
        &book,
        &ArbOptions {
            max_legs: opts.max_legs.clamp(2, 3),
            min_depth_nano: opts.min_depth_nano,
            costs,
            min_net_profit_nano: opts.min_profit_nano,
            available_nano: opts.available_nano,
            trusted,
            include_untrusted: opts.include_untrusted,
            busy_boxes: busy.clone().unwrap_or_default(),
            max_results: opts.max_results,
        },
    );
    let mut out = serde_json::to_value(&result)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    out["height"] = serde_json::json!(height);
    out["pool_count"] = serde_json::json!(pools.len());
    out["truncated"] = serde_json::json!(truncated);
    out["mempool_checked"] = serde_json::json!(busy.is_some());
    out["costs"] = serde_json::json!({
        "miner_fee_nano": costs.miner_fee_nano,
        "app_fee_nano": costs.app_fee_nano,
        "box_min_nano": costs.box_min_nano,
    });
    Ok(out.to_string())
}

/// A prepared chain, kept so it can be signed after review, followed after
/// broadcast, and recovered from if it breaks.
struct ChainRecord {
    handle_id: u64,
    node_url: Option<String>,
    prepared_at: Instant,
    opportunity: Opportunity,
    change_tree: String,
    spend_addresses: Vec<String>,
    legs: Vec<BuiltLeg>,
    executed: bool,
    /// Ids of the legs the node accepted, in leg order.
    accepted: Vec<String>,
    failed_leg: Option<usize>,
}

static CHAINS: Lazy<Mutex<HashMap<u64, ChainRecord>>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn store_chain(record: ChainRecord) -> u64 {
    let mut chains = recover(CHAINS.lock());
    // Unexecuted reviews of this wallet are superseded by the new one.
    chains.retain(|_, c| c.executed || c.handle_id != record.handle_id);
    while chains.len() >= MAX_CHAINS {
        let oldest = chains
            .iter()
            .min_by_key(|(_, c)| c.prepared_at)
            .map(|(id, _)| *id);
        match oldest {
            Some(id) => chains.remove(&id),
            None => break,
        };
    }
    loop {
        let id = (rand::rngs::OsRng.next_u64() & 0x7FFF_FFFF_FFFF_FFFF).max(1);
        if let std::collections::hash_map::Entry::Vacant(e) = chains.entry(id) {
            e.insert(record);
            return id;
        }
    }
}

fn unknown_chain() -> String {
    generic("UNKNOWN_CHAIN: this arbitrage is no longer held; scan again")
}

#[derive(Deserialize)]
struct LegSpec {
    pool_id: String,
    from_token_id: Option<String>,
    to_token_id: Option<String>,
}

#[derive(Deserialize)]
struct PrepareRequest {
    legs: Vec<LegSpec>,
    min_profit_nano: u64,
    #[serde(default)]
    available_nano: Option<u64>,
    spend_addresses: Vec<String>,
    change_address: String,
}

/// The route's pools as they are right now, in leg order.
async fn fresh_route(
    client: &ergo_node_client::NodeClient,
    steps: &[RouteStep],
) -> Result<Vec<FreshPool>, String> {
    let mut out = Vec::with_capacity(steps.len());
    for step in steps {
        let (amm, ergo_box) = crate::api_amm_impl::fetch_pool(client, &step.pool_id).await?;
        let pool = pool_from_box(&ergo_box).map_err(|e| {
            generic(format!(
                "POOL_MOVED: pool {} is not tradable: {e}",
                step.pool_id
            ))
        })?;
        out.push(FreshPool {
            pool,
            amm,
            ergo_box,
        });
    }
    Ok(out)
}

fn review_json(chain_id: u64, opp: &Opportunity, legs: &[BuiltLeg]) -> serde_json::Value {
    let mut v = serde_json::to_value(opp).unwrap_or_default();
    v["chain_id"] = serde_json::json!(chain_id);
    v["tx_ids"] = serde_json::json!(legs.iter().map(|l| l.tx_id.clone()).collect::<Vec<_>>());
    v["leg_fees"] = serde_json::json!(legs
        .iter()
        .map(|l| serde_json::json!({"miner_fee_nano": l.miner_fee, "app_fee_nano": l.app_fee}))
        .collect::<Vec<_>>());
    v["expires_in_secs"] = serde_json::json!(REVIEW_TTL.as_secs());
    v
}

/// Re-read the route, re-size it to the wallet, build every leg and check
/// the chain, refusing below `min_profit_nano`. Answers the whole chain for
/// review with a `chain_id` to execute; signs nothing.
#[flutter_rust_bridge::frb]
pub async fn arbitrage_prepare(
    handle_id: u64,
    request_json: String,
    node_url: Option<String>,
) -> Result<String, String> {
    let req: PrepareRequest = parse(&request_json, "request")?;
    let steps: Vec<RouteStep> = req
        .legs
        .iter()
        .map(|l| RouteStep {
            pool_id: l.pool_id.clone(),
            from: Asset::from_token_id(l.from_token_id.as_deref()),
            to: Asset::from_token_id(l.to_token_id.as_deref()),
        })
        .collect();
    let change_tree = wallet_net::client::address_to_ergo_tree(&req.change_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    super::with_handle(handle_id, "arbitrage_prepare", |h| {
        if h.owns_address(&req.change_address)
            .map_err(super::err_str)?
        {
            Ok(())
        } else {
            Err(ArgusError::InvalidAddress(
                "change address is not an address of this wallet".into(),
            )
            .to_json_string())
        }
    })?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let route = fresh_route(&client, &steps).await?;
    if let Some(busy) = busy_pool_boxes(&client).await {
        if route.iter().any(|p| busy.contains(&p.pool.box_id)) {
            return Err(generic(
                "POOL_BUSY: a pool on this route is already being traded in the mempool",
            ));
        }
    }
    let pools: Vec<Pool> = route.iter().map(|p| p.pool.clone()).collect();
    let costs = current_costs();
    let cap = match req.available_nano {
        Some(a) => a.saturating_sub(costs.capital(0, steps.len())),
        None => u64::MAX,
    };
    let opp =
        requote(&pools, &steps, None, cap, &costs, req.min_profit_nano).map_err(|e| match e {
            wallet_amm::RouteError::NotProfitable { .. } => generic(format!("NOT_PROFITABLE: {e}")),
            _ => generic(format!("POOL_MOVED: {e}")),
        })?;

    let (wallet_boxes, _) =
        super::gather_wallet_boxes(handle_id, &req.spend_addresses, node_url.clone()).await?;
    let height = client.current_height().await.map_err(node_err)? as i32;
    let chain = build_chain(
        &route,
        &opp,
        &wallet_boxes,
        &change_tree,
        height,
        req.min_profit_nano as i64,
    )?;

    let (legs, wallet_delta_nano) = (chain.legs, chain.wallet_delta_nano);
    let chain_id = store_chain(ChainRecord {
        handle_id,
        node_url,
        prepared_at: Instant::now(),
        opportunity: opp.clone(),
        change_tree,
        spend_addresses: req.spend_addresses,
        legs: legs.clone(),
        executed: false,
        accepted: Vec::new(),
        failed_leg: None,
    });
    let mut review = review_json(chain_id, &opp, &legs);
    review["wallet_delta_nano"] = serde_json::json!(wallet_delta_nano);
    Ok(review.to_string())
}

/// Forget a reviewed chain the user turned down.
#[flutter_rust_bridge::frb(sync)]
pub fn arbitrage_discard(chain_id: u64) {
    let mut chains = recover(CHAINS.lock());
    if chains.get(&chain_id).is_some_and(|c| !c.executed) {
        chains.remove(&chain_id);
    }
}

/// True when a rejected leg can be retried shortly: the node has not seen
/// the previous leg yet. A missing or double-spent pool box (input 0) is
/// final.
fn is_chained_race(err: &str) -> bool {
    let e = err.to_lowercase();
    let missing =
        e.contains("missing inputs") || e.contains("should be in utxo") || e.contains("not found");
    missing && !e.contains("missing inputs: 0") && !e.contains("double spend")
}

async fn submit_leg(
    client: &wallet_net::client::ErgoNodeClient,
    tx: &serde_json::Value,
    leg: usize,
) -> Result<String, String> {
    let mut delay = Duration::from_millis(300);
    let mut attempt = 0;
    loop {
        match client.submit_transaction(tx).await {
            Ok(id) => return Ok(id),
            Err(e) if leg > 0 && attempt < 3 && is_chained_race(&e) => {
                tokio::time::sleep(delay).await;
                delay *= 2;
                attempt += 1;
            }
            Err(e) => return Err(e),
        }
    }
}

/// The stranded token as the screen shows it: what, how much, and the box.
fn holding_json(rec: &ChainRecord, failed_leg: usize) -> serde_json::Value {
    let Some((token_id, amount)) = stranded_holding(&rec.opportunity.legs, failed_leg) else {
        return serde_json::Value::Null;
    };
    let box_id = rec.legs[failed_leg - 1]
        .wallet_outputs(&rec.change_tree)
        .find(|b| holds(b, &token_id))
        .map(id_of);
    serde_json::json!({"token_id": token_id, "amount": amount, "box_id": box_id, "after_leg": failed_leg})
}

/// Sign every leg of a reviewed chain and broadcast them back to back.
///
/// Immediately before signing, every pool box is read again: if one is no
/// longer the box the review was built on, or a mempool transaction is
/// spending it, nothing is signed and the answer is `{"status": "moved"}`
/// so the screen can prepare and show a fresh review. Otherwise answers
/// `submitted` (every leg accepted), `rejected` (the first leg was refused;
/// nothing changed) or `stranded` (a later leg was refused; `holding`
/// names what the wallet now holds), with each accepted leg's id and
/// wallet delta.
#[flutter_rust_bridge::frb]
pub async fn arbitrage_execute(handle_id: u64, chain_id: u64) -> Result<String, String> {
    let (legs, node_url, box_ids, pool_ids) = {
        let chains = recover(CHAINS.lock());
        let rec = chains.get(&chain_id).ok_or_else(unknown_chain)?;
        if rec.handle_id != handle_id {
            return Err(generic("chain belongs to another wallet"));
        }
        if rec.executed {
            return Err(generic("ALREADY_BROADCAST: this chain was already signed"));
        }
        if rec.prepared_at.elapsed() > REVIEW_TTL {
            return Err(generic(
                "REVIEW_EXPIRED: prices are stale; review the trade again",
            ));
        }
        (
            rec.legs.clone(),
            rec.node_url.clone(),
            rec.opportunity
                .legs
                .iter()
                .map(|l| l.box_id.clone())
                .collect::<Vec<_>>(),
            rec.opportunity
                .legs
                .iter()
                .map(|l| l.pool_id.clone())
                .collect::<Vec<_>>(),
        )
    };

    // The freshness gate, right before signing.
    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let mut moved = false;
    for (pool_id, box_id) in pool_ids.iter().zip(&box_ids) {
        match crate::api_amm_impl::fetch_pool(&client, pool_id).await {
            Ok((_, b)) if &id_of(&b) == box_id => {}
            _ => moved = true,
        }
    }
    if !moved {
        moved = busy_pool_boxes(&client)
            .await
            .is_some_and(|busy| box_ids.iter().any(|b| busy.contains(b)));
    }
    if moved {
        recover(CHAINS.lock()).remove(&chain_id);
        return Ok(serde_json::json!({"status": "moved"}).to_string());
    }

    let wallet_client = super::node_client(node_url.clone()).await?;
    let mut signed = Vec::with_capacity(legs.len());
    for leg in &legs {
        let prep = CachedPreparation {
            handle_id,
            ergo_boxes: leg.inputs.clone(),
            stealth_trees: Vec::new(),
            mix_proofs: Vec::new(),
            data_input_boxes: Vec::new(),
            unsigned_tx: leg.unsigned.clone(),
            miner_fee: leg.miner_fee as i64,
            change_erg: 0,
            recipient_erg: 0,
            node_url: node_url.clone(),
        };
        signed.push(
            super::sign_prepared_tx(handle_id, &prep, &wallet_client, "arbitrage_execute").await?,
        );
    }
    // From here the chain is out of the user's hands: never sign it twice.
    if let Some(rec) = recover(CHAINS.lock()).get_mut(&chain_id) {
        rec.executed = true;
    }

    let mut accepted = Vec::new();
    let mut failure: Option<(usize, String)> = None;
    for (i, tx) in signed.iter().enumerate() {
        match submit_leg(&wallet_client, tx, i).await {
            Ok(id) => accepted.push(id),
            Err(e) => {
                failure = Some((i, e));
                break;
            }
        }
    }

    let mut chains = recover(CHAINS.lock());
    let rec = chains.get_mut(&chain_id).ok_or_else(unknown_chain)?;
    rec.accepted = accepted.clone();
    let deltas: Vec<i64> = legs
        .iter()
        .take(accepted.len())
        .map(|l| l.wallet_delta_nano)
        .collect();
    let out = match failure {
        None => {
            serde_json::json!({"status": "submitted", "tx_ids": accepted, "wallet_deltas": deltas})
        }
        Some((0, e)) => {
            rec.failed_leg = Some(0);
            serde_json::json!({"status": "rejected", "tx_ids": accepted, "wallet_deltas": deltas, "failed_leg": 0, "error": e})
        }
        Some((k, e)) => {
            rec.failed_leg = Some(k);
            serde_json::json!({
                "status": "stranded",
                "tx_ids": accepted,
                "wallet_deltas": deltas,
                "failed_leg": k,
                "error": e,
                "holding": holding_json(rec, k),
            })
        }
    };
    Ok(out.to_string())
}

/// Whether the node has `tx_id` in its mempool or in a block. `Err` when
/// it could not say, so a slow node is never read as a dropped leg.
async fn leg_status(
    client: &ergo_node_client::NodeClient,
    tx_id: &str,
) -> Result<LegStatus, String> {
    let found = |v: &serde_json::Value| v["id"].as_str() == Some(tx_id);
    let absent = |v: &serde_json::Value| v["error"].as_i64() == Some(404);
    let pending = client
        .get_unconfirmed_transaction_by_id(tx_id)
        .await
        .map_err(node_err)?;
    if found(&pending) {
        return Ok(LegStatus::Pending);
    }
    let confirmed = client
        .get_transaction_by_id(tx_id)
        .await
        .map_err(node_err)?;
    if found(&confirmed) {
        return Ok(LegStatus::Confirmed);
    }
    if absent(&pending) && absent(&confirmed) {
        return Ok(LegStatus::Missing);
    }
    Err(node_err(format!(
        "the node gave no clear answer about {tx_id}"
    )))
}

/// Where a broadcast chain stands: `complete`, `in_flight`,
/// `nothing_happened` or `stranded` (with `holding`), and each leg's
/// status. Reads only the user's node.
#[flutter_rust_bridge::frb]
pub async fn arbitrage_status(chain_id: u64) -> Result<String, String> {
    let (accepted, legs, node_url) = {
        let chains = recover(CHAINS.lock());
        let rec = chains.get(&chain_id).ok_or_else(unknown_chain)?;
        (rec.accepted.clone(), rec.legs.len(), rec.node_url.clone())
    };
    let client = crate::api_dexy_impl::dexy_client(node_url).await?;
    let mut statuses = Vec::with_capacity(legs);
    for i in 0..legs {
        statuses.push(match accepted.get(i) {
            Some(id) => leg_status(&client, id).await?,
            None => LegStatus::NotSubmitted,
        });
    }
    let state = classify(&statuses);
    let mut chains = recover(CHAINS.lock());
    let rec = chains.get_mut(&chain_id).ok_or_else(unknown_chain)?;
    let mut out = serde_json::to_value(&state).unwrap_or_default();
    out["legs"] = serde_json::json!(statuses
        .iter()
        .enumerate()
        .map(|(i, s)| serde_json::json!({"tx_id": accepted.get(i), "status": s}))
        .collect::<Vec<_>>());
    if let ChainState::Stranded { failed_leg } = state {
        rec.failed_leg = Some(failed_leg);
        out["holding"] = holding_json(rec, failed_leg);
    }
    Ok(out.to_string())
}

/// The stranded token's sale back to ERG, as an ordinary preparation for
/// the confirm sheet and `send_erg`. Quoted against every pool as it is
/// right now; spends exactly the box the broken chain left the token in,
/// with fees from wallet boxes the chain did not spend.
#[flutter_rust_bridge::frb]
pub async fn arbitrage_prepare_unwind(handle_id: u64, chain_id: u64) -> Result<String, String> {
    let (stranded, token_id, amount, change_tree, spend_addresses, node_url, spent, carried) = {
        let chains = recover(CHAINS.lock());
        let rec = chains.get(&chain_id).ok_or_else(unknown_chain)?;
        if rec.handle_id != handle_id {
            return Err(generic("chain belongs to another wallet"));
        }
        let k = rec
            .failed_leg
            .filter(|&k| k > 0)
            .ok_or_else(|| generic("NOTHING_STRANDED: no leg of this chain left a token behind"))?;
        let (token_id, amount) = stranded_holding(&rec.opportunity.legs, k)
            .ok_or_else(|| generic("NOTHING_STRANDED"))?;
        let last_good = &rec.legs[k - 1];
        let stranded = last_good
            .wallet_outputs(&rec.change_tree)
            .find(|b| holds(b, &token_id))
            .cloned()
            .ok_or_else(|| generic("NOTHING_STRANDED: the stranded box was not found"))?;
        // Boxes the accepted legs spent are gone even if a confirmed-only
        // view still lists them; their other outputs may pay the fee.
        let spent: HashSet<String> = rec.legs[..k]
            .iter()
            .flat_map(|l| l.inputs.iter().skip(1).map(id_of))
            .collect();
        let carried: Vec<ErgoBox> = last_good
            .wallet_outputs(&rec.change_tree)
            .filter(|b| b.box_id() != stranded.box_id())
            .cloned()
            .collect();
        (
            stranded,
            token_id,
            amount,
            rec.change_tree.clone(),
            rec.spend_addresses.clone(),
            rec.node_url.clone(),
            spent,
            carried,
        )
    };

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let (pools, _) = discover(&client).await?;
    let exit = best_exit(&pools, &token_id, amount).ok_or_else(|| {
        generic("NO_EXIT: no ERG pool buys this token right now; try the Swap screen later")
    })?;
    let (amm, ergo_box) = crate::api_amm_impl::fetch_pool(&client, &exit.pool_id).await?;
    let pool = pool_from_box(&ergo_box).map_err(|e| generic(format!("POOL_MOVED: {e}")))?;
    let fresh = FreshPool {
        pool,
        amm,
        ergo_box,
    };

    let (wallet_boxes, _) =
        super::gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    let mut fee_boxes: Vec<ErgoBox> = carried;
    fee_boxes.extend(
        wallet_boxes
            .into_iter()
            .filter(|b| b.tokens.is_none() && !spent.contains(&id_of(b))),
    );
    let height = client.current_height().await.map_err(node_err)? as i32;
    let sale = build_exit(
        &fresh,
        &stranded,
        &token_id,
        amount,
        &fee_boxes,
        &change_tree,
        height,
    )?;

    let preparation_id = super::store_preparation(CachedPreparation {
        handle_id,
        ergo_boxes: sale.inputs,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        data_input_boxes: Vec::new(),
        unsigned_tx: sale.unsigned,
        miner_fee: sale.miner_fee as i64,
        change_erg: sale.change_erg,
        recipient_erg: 0,
        node_url,
    });
    Ok(serde_json::json!({
        "preparation_id": preparation_id,
        "pool_id": exit.pool_id,
        "token_id": token_id,
        "input_amount": amount,
        "output_amount": sale.erg_out,
        "miner_fee": sale.miner_fee,
        "app_fee": sale.app_fee,
        "price_impact_pct": wallet_amm::math::price_impact_pct(
            fresh.pool.reserve(&Asset::token(token_id.clone())).unwrap_or(0),
            amount,
        ),
    })
    .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chained_races_are_retried_but_a_lost_pool_is_final() {
        assert!(is_chained_race("Malformed transaction: Every input of the transaction should be in UTXO. 00bd: 1 == 2. Missing inputs: 1"));
        assert!(!is_chained_race("Malformed transaction: Every input of the transaction should be in UTXO. f7c3: 1 == 2. Missing inputs: 0"));
        assert!(!is_chained_race("Double spending attempt"));
        assert!(!is_chained_race("Script reduced to false"));
    }

    #[test]
    fn unexecuted_reviews_are_superseded_and_discardable() {
        let rec = |handle| ChainRecord {
            handle_id: handle,
            node_url: None,
            prepared_at: Instant::now(),
            opportunity: Opportunity {
                legs: vec![],
                input_nano: 0,
                output_nano: 0,
                gross_profit_nano: 0,
                miner_fees_nano: 0,
                app_fees_nano: 0,
                net_profit_nano: 0,
                profit_pct: 0.0,
                box_min_in_transit_nano: 0,
                capital_nano: 0,
                unwind_loss_nano: None,
                optimal_input_nano: 0,
                sized_to_balance: false,
                affordable: true,
                trusted: true,
            },
            change_tree: String::new(),
            spend_addresses: vec![],
            legs: vec![],
            executed: false,
            accepted: vec![],
            failed_leg: None,
        };
        let first = store_chain(rec(7_001));
        let second = store_chain(rec(7_001));
        let other = store_chain(rec(7_002));
        {
            let chains = recover(CHAINS.lock());
            assert!(
                !chains.contains_key(&first),
                "a new review replaces the old one"
            );
            assert!(chains.contains_key(&second) && chains.contains_key(&other));
        }
        arbitrage_discard(second);
        assert!(!recover(CHAINS.lock()).contains_key(&second));
        recover(CHAINS.lock()).get_mut(&other).unwrap().executed = true;
        arbitrage_discard(other);
        assert!(
            recover(CHAINS.lock()).contains_key(&other),
            "an executed chain stays for recovery"
        );
    }
}
