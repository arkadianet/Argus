//! Pending transactions: what the wallet may spend while some of its money
//! is unconfirmed, and how pending movements reach the screen.
//!
//! Two rules, kept apart on purpose. A box a pending transaction already
//! spends is never offered, whatever the setting: spending it again is a
//! double spend the node rejects, or accepts in place of the first payment.
//! Whether boxes a pending transaction *created* — incoming payments and the
//! wallet's own change — may be spent is the user's choice in Settings →
//! Security. See `docs/superpowers/specs/2026-08-23-mempool-awareness-design.md`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use once_cell::sync::Lazy;
use wallet_net::client::{address_to_ergo_tree, BoxStatus, ErgoNodeClient};
use wallet_net::mempool::{AddressRead, Spendable};

use super::{node_client, recover, with_handle, GATHER_ADDRESS_CONCURRENCY};
use crate::error::ArgusError;

/// Whether coin selection may spend boxes created by transactions still in
/// the mempool. The app's setting (and its default, `defaultSpendUnconfirmed`
/// in `spend_policy.dart`) is handed over in `WalletService.init`, before any
/// wallet exists to spend from, so this initial value is never observed by a
/// spend.
static SPEND_UNCONFIRMED: AtomicBool = AtomicBool::new(true);

/// Allow or forbid spending unconfirmed funds (incoming payments and the
/// wallet's own change). Boxes a pending transaction already spends are
/// never offered either way.
#[flutter_rust_bridge::frb(sync)]
pub fn set_spend_unconfirmed(allow: bool) {
    SPEND_UNCONFIRMED.store(allow, Ordering::SeqCst);
}

/// The policy coin selection currently follows.
#[flutter_rust_bridge::frb(sync)]
pub fn spend_unconfirmed() -> bool {
    SPEND_UNCONFIRMED.load(Ordering::SeqCst)
}

// ─── Gathering ───────────────────────────────────────────────────────────

/// Read `addresses` for spending and merge them across the wallet: every
/// address's confirmed pages then its complete mempool list, ownership
/// checked as each is admitted (see `gather_unspent_ordered`). Unconfirmed
/// boxes are offered only when `allow_unconfirmed`, and each one is first
/// checked against the mempool by id — the address lists cannot show a
/// pending spend that pays none of the wallet's addresses.
pub(crate) async fn read_spendable(
    handle_id: u64,
    client: &ErgoNodeClient,
    addresses: &[String],
    allow_unconfirmed: bool,
) -> Result<Spendable, String> {
    let reads: Vec<AddressRead> = super::gather_unspent_ordered(
        handle_id,
        addresses,
        GATHER_ADDRESS_CONCURRENCY,
        |addr| async move {
            client
                .read_for_spending(addr)
                .await
                .map_err(|e| ArgusError::NodeError(e).to_json_string())
        },
    )
    .await?;
    let mut spendable = wallet_net::mempool::spendable_across(reads, allow_unconfirmed);
    if allow_unconfirmed {
        client.drop_spent_unconfirmed(&mut spendable).await;
    }
    Ok(spendable)
}

/// The wallet's spendable boxes under the user's policy: the one place every
/// wallet spend gathers its inputs. What waiting held back is remembered for
/// [`explain_shortfall`].
pub(crate) async fn gather_spendable(
    handle_id: u64,
    client: &ErgoNodeClient,
    addresses: &[String],
) -> Result<Spendable, String> {
    let spendable = read_spendable(handle_id, client, addresses, spend_unconfirmed()).await?;
    record_held_back(handle_id, &spendable.held_back);
    Ok(spendable)
}

/// The same gathering for addresses this device cannot sign for (a watched
/// account preparing an offline signature): no handle, so no ownership
/// check, but the same policy and the same spent-box rule.
pub(crate) async fn gather_watched(
    client: &ErgoNodeClient,
    addresses: &[String],
) -> Result<Spendable, String> {
    let mut reads = Vec::with_capacity(addresses.len());
    for address in addresses.iter().filter(|a| !a.is_empty()) {
        reads.push(client.read_for_spending(address).await?);
    }
    let allow = spend_unconfirmed();
    let mut spendable = wallet_net::mempool::spendable_across(reads, allow);
    if allow {
        client.drop_spent_unconfirmed(&mut spendable).await;
    }
    Ok(spendable)
}

/// The wallet's boxes for coin control and the UTXO tools: everything
/// spendable under the user's policy — or confirmed boxes only, when
/// `confirmed_only` — with mix reservations and mixed boxes still listed,
/// as the node lists them; the spend itself applies those rules. Each entry
/// carries its address and whether it is confirmed. Boxes a pending
/// transaction already spends are never listed.
#[flutter_rust_bridge::frb]
pub async fn list_spendable_boxes(
    handle_id: u64,
    addresses: Vec<String>,
    node_url: Option<String>,
    confirmed_only: bool,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let allow = !confirmed_only && spend_unconfirmed();
    let spendable = read_spendable(handle_id, &client, &addresses, allow).await?;
    Ok(listing_json(&spendable).to_string())
}

fn listing_json(spendable: &Spendable) -> serde_json::Value {
    serde_json::Value::Array(
        spendable
            .inputs
            .iter()
            .map(|b| {
                serde_json::json!({
                    "box_id": b.box_id,
                    "value_nano_erg": b.value,
                    "creation_height": b.creation_height,
                    "assets": b.assets.iter().map(|a| serde_json::json!({
                        "token_id": a.token_id,
                        "amount": a.amount,
                    })).collect::<Vec<_>>(),
                    "address": ergo_tx::address::ergo_tree_to_address(&b.ergo_tree).ok(),
                    "confirmed": !spendable.unconfirmed.contains(&b.box_id),
                })
            })
            .collect(),
    )
}

// ─── Explaining a shortfall ──────────────────────────────────────────────

/// Unconfirmed funds the last gathering left out because the wallet waits
/// for a confirmation. Public amounts only. (No `Default`: the bridge
/// generator would export it as a constructor.)
#[derive(Clone, Debug, PartialEq)]
struct HeldBack {
    nano: u64,
    tokens: BTreeMap<String, u64>,
}

impl HeldBack {
    fn nothing() -> Self {
        Self {
            nano: 0,
            tokens: BTreeMap::new(),
        }
    }

    fn is_empty(&self) -> bool {
        self.nano == 0 && self.tokens.is_empty()
    }
}

static HELD_BACK: Lazy<Mutex<HashMap<u64, HeldBack>>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn held_back_of(inputs: &[ergo_tx::Eip12InputBox]) -> HeldBack {
    let mut held = HeldBack::nothing();
    for b in inputs {
        held.nano = held.nano.saturating_add(b.value.parse::<u64>().unwrap_or(0));
        for a in &b.assets {
            let e = held.tokens.entry(a.token_id.to_ascii_lowercase()).or_insert(0);
            *e = e.saturating_add(a.amount.parse::<u64>().unwrap_or(0));
        }
    }
    held
}

fn record_held_back(handle_id: u64, inputs: &[ergo_tx::Eip12InputBox]) {
    let held = held_back_of(inputs);
    let mut all = recover(HELD_BACK.lock());
    if held.is_empty() {
        all.remove(&handle_id);
    } else {
        all.insert(handle_id, held);
    }
}

/// Forget a locked wallet's figures.
pub(crate) fn forget_held_back(handle_id: u64) {
    recover(HELD_BACK.lock()).remove(&handle_id);
}

/// Say "2.5 ERG is still confirming" instead of "insufficient funds" when the
/// wallet waits for confirmations and the funds it left out could have paid
/// for this. Any other error, and every error while unconfirmed funds are
/// allowed, comes back unchanged.
///
/// Builders word their shortfalls differently; this reads the common shape
/// ("need N … have M", a token id when it is about a token). When the
/// figures show waiting would not be enough, the error stands as it was.
pub(crate) fn explain_shortfall(handle_id: u64, error: String) -> String {
    let Some(held) = recover(HELD_BACK.lock()).get(&handle_id).cloned() else {
        return error;
    };
    explain_with(&held, error)
}

/// A builder's or selector's failure as the app's error, explained when the
/// wallet's waiting for confirmations is what left it short.
pub(crate) fn shortfall_error(handle_id: u64, error: impl std::fmt::Display) -> String {
    explain_shortfall(
        handle_id,
        ArgusError::TxBuildFailed(error.to_string()).to_json_string(),
    )
}

/// [`explain_shortfall`] for a gathering that has no wallet handle (a
/// watched account), given what it held back.
pub(crate) fn explain_held(held_back: &[ergo_tx::Eip12InputBox], error: String) -> String {
    explain_with(&held_back_of(held_back), error)
}

/// Errors arrive either as the app's JSON (`{code, message}`) or as plain
/// text; the explanation keeps whichever shape came in.
fn explain_with(held: &HeldBack, error: String) -> String {
    if held.is_empty() {
        return error;
    }
    let parsed = serde_json::from_str::<serde_json::Value>(&error)
        .ok()
        .filter(|v| v["message"].is_string());
    let (code, message) = match &parsed {
        Some(v) => (
            v["code"].as_str().unwrap_or("GENERIC").to_string(),
            v["message"].as_str().unwrap_or_default().to_string(),
        ),
        None => (String::new(), error.clone()),
    };
    let lower = message.to_ascii_lowercase();
    let shortfall = code == "NO_UTXOS"
        || lower.contains("insufficient")
        || lower.contains("not enough")
        || (lower.contains("need") && ["have", "hold", "can use"].iter().any(|k| lower.contains(k)));
    if !shortfall {
        return error;
    }
    let deficit = || {
        let need = number_after(&lower, &["need"])?;
        let have = number_after(&lower, &["have", "hold", "can use", "available"])?;
        Some(need.saturating_sub(have))
    };
    let what = match token_in(&lower) {
        Some(token) => {
            let amount = held.tokens.get(&token).copied().unwrap_or(0);
            if amount == 0 || deficit().is_some_and(|d| amount < d) {
                return error;
            }
            format!(
                "{amount} base units of token {}… are",
                &token[..8.min(token.len())]
            )
        }
        None if lower.contains("token") && !lower.contains("erg") => {
            // A token named only by a short prefix: say what is confirming
            // without claiming it would cover this.
            if held.tokens.is_empty() {
                return error;
            }
            "tokens you received are".to_string()
        }
        None => {
            if held.nano == 0 || deficit().is_some_and(|d| held.nano < d) {
                return error;
            }
            format!("{} ERG is", erg_text(held.nano))
        }
    };
    let explained = format!(
        "{what} still confirming. This wallet spends only confirmed funds, so it \
         waits for one confirmation; to spend unconfirmed funds, turn on Spend \
         unconfirmed funds in Settings → Security. ({message})"
    );
    match parsed {
        Some(_) => serde_json::json!({ "code": code, "message": explained }).to_string(),
        None => explained,
    }
}

/// The first whole number after any of `keywords` in `text`, skipping
/// spaces, colons and a currency word, as in "need 5", "have: 3".
fn number_after(text: &str, keywords: &[&str]) -> Option<u64> {
    let start = keywords
        .iter()
        .filter_map(|k| text.find(k).map(|i| i + k.len()))
        .min()?;
    let rest = text[start..].trim_start_matches(|c: char| c.is_ascii_alphabetic() && c != ' ');
    let rest = rest.trim_start_matches([' ', ':', '\t']);
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// A full 64-character token id in `text`, if there is one.
fn token_in(text: &str) -> Option<String> {
    text.split(|c: char| !c.is_ascii_hexdigit())
        .find(|w| w.len() == 64)
        .map(str::to_string)
}

fn erg_text(nano: u64) -> String {
    let whole = nano / 1_000_000_000;
    let frac = format!("{:09}", nano % 1_000_000_000);
    let frac = frac.trim_end_matches('0');
    if frac.is_empty() {
        whole.to_string()
    } else {
        format!("{whole}.{frac}")
    }
}

// ─── Transactions built elsewhere ────────────────────────────────────────

/// Refuse a transaction a dApp page or an ErgoPay request built when it
/// spends a box a pending transaction already spends, or — while the wallet
/// waits for confirmations — a box of this wallet that is still unconfirmed.
///
/// `known_trees` maps input ids to their scripts where the caller has the
/// boxes; otherwise an unconfirmed box's script comes from the node. A node
/// that cannot answer fails the check: signing on a guess could replace the
/// user's own pending payment.
pub(crate) async fn check_external_inputs(
    handle_id: u64,
    client: &ErgoNodeClient,
    input_ids: &[String],
    known_trees: &HashMap<String, String>,
) -> Result<(), String> {
    let allow = spend_unconfirmed();
    let unreadable = |e: String| {
        ArgusError::NodeError(format!(
            "could not check this transaction's inputs against pending transactions: {e}"
        ))
        .to_json_string()
    };
    let mut confirming = 0u64;
    for id in input_ids {
        let status = if allow {
            match client.mempool_spends(id).await.map_err(unreadable)? {
                true => BoxStatus::SpentInMempool,
                false => BoxStatus::Confirmed,
            }
        } else {
            client.box_status(id).await.map_err(unreadable)?
        };
        match status {
            BoxStatus::SpentInMempool => {
                return Err(ArgusError::TxBuildFailed(format!(
                    "this transaction spends box {id}, which a pending transaction already \
                     spends; signing it would double-spend. Ask the app that built it to \
                     build it again"
                ))
                .to_json_string())
            }
            BoxStatus::Unconfirmed(json) => {
                let tree = known_trees
                    .get(id)
                    .cloned()
                    .or_else(|| json["ergoTree"].as_str().map(str::to_string))
                    .unwrap_or_default();
                if owned_tree(handle_id, &tree) {
                    confirming = confirming.saturating_add(json["value"].as_u64().unwrap_or(0));
                }
            }
            BoxStatus::Confirmed | BoxStatus::Unknown => {}
        }
    }
    if confirming > 0 {
        return Err(ArgusError::TxBuildFailed(format!(
            "this transaction spends {} ERG of yours that is still confirming. This wallet \
             spends only confirmed funds; wait for one confirmation, or turn on Spend \
             unconfirmed funds in Settings → Security",
            erg_text(confirming)
        ))
        .to_json_string());
    }
    Ok(())
}

fn owned_tree(handle_id: u64, tree_hex: &str) -> bool {
    match ergo_tx::address::ergo_tree_to_address(tree_hex) {
        Ok(address) => with_handle(handle_id, "check_external_inputs", |h| {
            Ok(h.owns_address(&address).unwrap_or(false))
        })
        .unwrap_or(false),
        Err(_) => false,
    }
}

/// Refuse to broadcast a preparation whose stealth inputs a pending
/// transaction already spends. Stealth boxes come from the explorer, which
/// lists confirmed state only, and no wallet address sees a stealth spend.
/// Checked here, just before submission, so the node learns which stealth
/// boxes are the user's no earlier than the broadcast itself tells it.
pub(crate) async fn check_stealth_inputs(
    client: &ErgoNodeClient,
    boxes: &[ErgoBox],
    stealth_trees: &[String],
) -> Result<(), String> {
    if stealth_trees.is_empty() {
        return Ok(());
    }
    for b in boxes {
        let tree = b
            .ergo_tree
            .sigma_serialize_bytes()
            .map(hex::encode)
            .unwrap_or_default();
        if !stealth_trees.iter().any(|t| t.eq_ignore_ascii_case(&tree)) {
            continue;
        }
        let id = b.box_id().to_string();
        let spent = client.mempool_spends(&id).await.map_err(|e| {
            ArgusError::NodeError(format!(
                "could not check the stealth coins against pending transactions: {e}"
            ))
            .to_json_string()
        })?;
        if spent {
            return Err(ArgusError::TxBuildFailed(
                "a pending transaction already spends these stealth coins. Nothing was sent; \
                 wait for it to confirm, then refresh"
                    .into(),
            )
            .to_json_string());
        }
    }
    Ok(())
}

// ─── Sync reads ──────────────────────────────────────────────────────────

/// One address as the sync paths read it. A failed mempool read degrades to
/// "nothing pending" here: a slow mempool must never break the confirmed
/// view.
struct SyncRead {
    address: String,
    boxes: Result<Vec<ErgoBox>, String>,
    txs: Vec<serde_json::Value>,
}

/// The live wallet's sync inputs: every address at once, each one's
/// listing and mempool list side by side.
pub(crate) async fn sync_inputs_together(client: &ErgoNodeClient, addresses: &[String]) -> String {
    let reads =
        futures::future::join_all(addresses.iter().map(|address| sync_read(client, address)))
            .await;
    sync_inputs_json(client, reads).await
}

async fn mempool_or_nothing(client: &ErgoNodeClient, address: &str) -> Vec<serde_json::Value> {
    match address_to_ergo_tree(address) {
        Ok(tree) => client.mempool_txs_for(&tree).await.unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

/// Confirmed listing and mempool list for one address, side by side.
async fn sync_read(client: &ErgoNodeClient, address: &str) -> SyncRead {
    let (boxes, txs) = tokio::join!(
        client.get_unspent(address),
        mempool_or_nothing(client, address)
    );
    SyncRead {
        address: address.to_string(),
        boxes: boxes.map(|(b, _)| b),
        txs,
    }
}

/// The same read, one request after the other.
async fn sync_read_in_turn(client: &ErgoNodeClient, address: &str) -> SyncRead {
    let boxes = client.get_unspent(address).await.map(|(b, _)| b);
    let txs = mempool_or_nothing(client, address).await;
    SyncRead {
        address: address.to_string(),
        boxes,
        txs,
    }
}

/// Everything a sync shows, from the address reads: per-address balances,
/// pending activity rows, the UTXO count, the wallet-wide pending summary,
/// and the node that answered.
///
/// The summary is valued once over the union of every address's mempool
/// list, so a payment between two of the wallet's addresses or a chain of
/// spends across them nets correctly, which per-address balances summed
/// cannot. Like the rows, it is null when any confirmed listing failed: a
/// missing listing hides spent inputs. Unconfirmed outputs that a pending
/// transaction paying elsewhere already spends are found by id, a few at
/// most per sync; a lookup that fails leaves the output counted.
async fn sync_inputs_json(client: &ErgoNodeClient, reads: Vec<SyncRead>) -> String {
    let union = wallet_net::mempool::unique_transactions(reads.iter().map(|r| r.txs.as_slice()));
    let mut trees = HashSet::new();
    let mut confirmed: Vec<ErgoBox> = Vec::new();
    let mut complete = true;
    for read in &reads {
        if let Ok(tree) = address_to_ergo_tree(&read.address) {
            trees.insert(tree);
        }
        match &read.boxes {
            Ok(boxes) => confirmed.extend(boxes.iter().cloned()),
            Err(_) => complete = false,
        }
    }
    let markers = spent_elsewhere(client, &union, &trees, &confirmed).await;

    let mut balances = serde_json::Map::new();
    for read in &reads {
        if let Ok(boxes) = &read.boxes {
            let txs: Vec<serde_json::Value> =
                read.txs.iter().chain(markers.iter()).cloned().collect();
            balances.insert(
                read.address.clone(),
                super::balance_from_inputs(&read.address, boxes, &txs),
            );
        }
    }
    let valued: Vec<serde_json::Value> = union.iter().chain(markers.iter()).cloned().collect();
    let mut values = HashMap::new();
    let mut ids = HashSet::new();
    for b in &confirmed {
        values.insert(b.box_id().to_string(), b.value.as_i64());
        ids.insert(b.box_id().to_string());
    }
    serde_json::json!({
        "balances": balances,
        // A missing listing can hide a spent input from any transaction.
        // Null means unavailable; an empty array would claim no pending activity.
        "pending": if complete { Some(super::pending_from_inputs(&union, &trees, &values)) } else { None },
        "utxo_count": if complete { Some(ids.len()) } else { None },
        "summary": if complete {
            Some(wallet_net::mempool::pending_summary(&confirmed, &valued, &trees).to_json())
        } else {
            None
        },
        // The node that actually answered. `connect` falls back past the
        // preferred URL, so this is not necessarily the one the app asked
        // for, and it is the only endpoint that has already been shown these
        // addresses and the token ids in their boxes.
        "served_by": client.url(),
    })
    .to_string()
}

/// Id-less marker transactions spending the set's unconfirmed outputs that a
/// pending transaction already spends without paying the set, so the
/// valuation does not count them as arriving.
async fn spent_elsewhere(
    client: &ErgoNodeClient,
    union: &[serde_json::Value],
    trees: &HashSet<String>,
    confirmed: &[ErgoBox],
) -> Vec<serde_json::Value> {
    let spent = wallet_net::mempool::spent_box_ids(union);
    let confirmed: HashSet<String> = confirmed.iter().map(|b| b.box_id().to_string()).collect();
    let mut candidates: Vec<String> = union
        .iter()
        .flat_map(|tx| tx["outputs"].as_array().cloned().unwrap_or_default())
        .filter(|o| o["ergoTree"].as_str().is_some_and(|t| trees.contains(t)))
        .filter_map(|o| o["boxId"].as_str().map(str::to_string))
        .filter(|id| !spent.contains(id) && !confirmed.contains(id))
        .collect();
    candidates.sort();
    candidates.dedup();
    let mut markers = Vec::new();
    for id in candidates
        .into_iter()
        .take(wallet_net::client::UNCONFIRMED_CHECKS)
    {
        if matches!(client.mempool_spends(&id).await, Ok(true)) {
            markers.push(serde_json::json!({ "inputs": [{ "boxId": id }] }));
        }
    }
    markers
}

/// Balances, pending activity and the pending summary for a wallet this
/// session has not unlocked, read one address at a time: the public refresh
/// of locked wallets asks the node for one thing at a time by design.
#[flutter_rust_bridge::frb]
pub async fn get_public_sync_inputs(
    addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let mut seen = HashSet::new();
    let mut reads = Vec::new();
    for address in addresses.into_iter().filter(|a| !a.is_empty()) {
        if seen.insert(address.clone()) {
            reads.push(sync_read_in_turn(&client, &address).await);
        }
    }
    Ok(sync_inputs_json(&client, reads).await)
}

#[cfg(test)]
#[path = "mempool_tests.rs"]
pub(crate) mod tests;
