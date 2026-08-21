//! Argus wallet FFI — flutter_rust_bridge interface.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use citadel_core::constants::{MIN_BOX_VALUE_NANO, TX_FEE_NANO};
use ergo_lib::chain::transaction::reduced::ReducedTransaction;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_tx::{build_send_tx_with_fee, DevFeeConfig};
use ergopay_core::reduce_transaction_with_context;
use once_cell::sync::Lazy;
use rand::RngCore;
use wallet_core::seed::MnemonicPhrase;
use wallet_core::spend::select_for_send;
use wallet_core::wallet::WalletHandle;
use wallet_core::PinWrappedKey;
use wallet_net::client::{address_to_ergo_tree, ErgoNodeClient};

use crate::error::ArgusError;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {}

fn err_str<E: Into<ArgusError>>(e: E) -> String {
    e.into().to_json_string()
}

fn recover<T>(r: std::sync::LockResult<T>) -> T {
    r.unwrap_or_else(|p| p.into_inner())
}

static HANDLES: Lazy<Mutex<HashMap<u64, WalletHandle>>> = Lazy::new(|| Mutex::new(HashMap::new()));

struct CachedPreparation {
    handle_id: u64,
    ergo_boxes: Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
    unsigned_tx: ergo_tx::Eip12UnsignedTx,
    miner_fee: i64,
    change_erg: i64,
    recipient_erg: i64,
    node_url: Option<String>,
}

static PREPARATIONS: Lazy<Mutex<HashMap<u64, CachedPreparation>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn store_preparation(prep: CachedPreparation) -> u64 {
    let mut cache = recover(PREPARATIONS.lock());
    cache.retain(|_, p| p.handle_id != prep.handle_id);
    loop {
        let id = (rand::rngs::OsRng.next_u64() & 0x7FFF_FFFF_FFFF_FFFF).max(1);
        if !cache.contains_key(&id) {
            cache.insert(id, prep);
            return id;
        }
    }
}

fn take_preparation(handle_id: u64, preparation_id: u64) -> Result<CachedPreparation, String> {
    let mut cache = recover(PREPARATIONS.lock());
    match cache.get(&preparation_id).map(|p| p.handle_id) {
        None => Err(ArgusError::TxBuildFailed("unknown or stale send preparation".into())
            .to_json_string()),
        Some(owner) if owner != handle_id => Err(ArgusError::TxBuildFailed(
            "send preparation does not match wallet".into(),
        )
        .to_json_string()),
        Some(_) => Ok(cache.remove(&preparation_id).expect("preparation present")),
    }
}

fn drop_preparations_for(handle_id: u64) {
    recover(PREPARATIONS.lock()).retain(|_, p| p.handle_id != handle_id);
}

/// Adjust miner fee in an already-built EIP-12 unsigned tx.
/// Finds the fee output (by `MINER_FEE_ERGO_TREE`), the change output (by `change_ergo_tree`)
/// and shifts `delta = custom_fee - current_fee` from change to fee.
fn apply_custom_fee(
    tx: &mut ergo_tx::Eip12UnsignedTx,
    change_ergo_tree: &str,
    current_fee: i64,
    custom_fee: i64,
) -> Result<i64, String> {
    if current_fee == custom_fee {
        return Ok(current_fee);
    }
    let delta = custom_fee - current_fee;
    let fee_idx = tx.outputs.iter().position(|o| {
        o.ergo_tree == citadel_core::constants::MINER_FEE_ERGO_TREE
    }).ok_or_else(|| ArgusError::TxBuildFailed("fee output not found in unsigned tx".into()).to_json_string())?;

    let change_idx = tx.outputs.iter().position(|o| o.ergo_tree == change_ergo_tree)
        .ok_or_else(|| ArgusError::TxBuildFailed("change output not found in unsigned tx".into()).to_json_string())?;

    let change_val: i64 = tx.outputs[change_idx].value.parse::<i64>()
        .map_err(|e| ArgusError::TxBuildFailed(format!("invalid change value: {e}")).to_json_string())?;
    let new_change = change_val - delta;
    if new_change < 0 {
        return Err(ArgusError::TxBuildFailed(format!(
            "custom fee {custom_fee} nanoERG exceeds available change {change_val} nanoERG"
        )).to_json_string());
    }
    tx.outputs[fee_idx].value = custom_fee.to_string();
    if new_change == 0 {
        tx.outputs = tx.outputs.iter()
            .filter(|o| o.ergo_tree != change_ergo_tree)
            .collect::<Vec<_>>();
    } else if new_change < MIN_BOX_VALUE_NANO {
        return Err(ArgusError::TxBuildFailed(format!(
            "change {new_change} below min box value {MIN_BOX_VALUE_NANO}"
        )).to_json_string());
    } else {
        tx.outputs[change_idx].value = new_change.to_string();
    }
    Ok(custom_fee)
}

fn register_handle(handle: WalletHandle) -> u64 {
    let mut handles = recover(HANDLES.lock());
    loop {
        let id = (rand::rngs::OsRng.next_u64() & 0x7FFF_FFFF_FFFF_FFFF).max(1);
        if !handles.contains_key(&id) {
            handles.insert(id, handle);
            return id;
        }
    }
}

fn with_handle<T>(handle_id: u64, op: &'static str, f: impl FnOnce(&WalletHandle) -> Result<T, String>) -> Result<T, String> {
    let handles = recover(HANDLES.lock());
    let handle = handles
        .get(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound(op, handle_id).to_json_string())?;
    f(handle)
}

async fn node_client(node_url: Option<String>) -> Result<ErgoNodeClient, String> {
    ErgoNodeClient::connect(node_url)
        .await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())
}

#[flutter_rust_bridge::frb]
pub fn set_network(node_urls: Vec<String>, explorer_url: Option<String>) {
    wallet_net::client::set_network(node_urls, explorer_url);
}

#[flutter_rust_bridge::frb]
pub async fn probe_network() -> Result<String, String> {
    let mut out = Vec::new();
    for url in wallet_net::client::node_urls(None) {
        match wallet_net::client::probe_height(&url).await {
            Ok(height) => out.push(serde_json::json!({
                "url": url,
                "ok": true,
                "height": height,
            })),
            Err(err) => out.push(serde_json::json!({
                "url": url,
                "ok": false,
                "error": err,
            })),
        }
    }
    serde_json::to_string(&serde_json::json!({
        "nodes": out,
        "explorer": wallet_net::client::configured_explorer(),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

fn tokens_json(tokens: &[(String, u64)]) -> Vec<serde_json::Value> {
    tokens
        .iter()
        .map(|(id, amount)| serde_json::json!({ "id": id, "amount": amount }))
        .collect()
}

fn session_json(
    handle_id: u64,
    encrypted_seed_json: String,
    wrap_key: String,
) -> Result<String, String> {
    serde_json::to_string(&serde_json::json!({
        "handle_id": handle_id.to_string(),
        "encrypted_seed_json": encrypted_seed_json,
        "wrap_key": wrap_key,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

fn open_wallet(mnemonic_phrase: String, passphrase: &str) -> Result<(u64, String, String), String> {
    let phrase = MnemonicPhrase::parse(mnemonic_phrase).map_err(err_str)?;
    let encrypted = wallet_core::EncryptedSeed::encrypt(
        &phrase
            .to_seed(passphrase)
            .map_err(err_str)?,
    )
    .map_err(err_str)?;
    let json = serde_json::to_string(&encrypted.to_json().map_err(err_str)?)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let wrap_key = encrypted.wrap_key_hex();
    let handle = WalletHandle::create(phrase, passphrase).map_err(err_str)?;
    Ok((register_handle(handle), json, wrap_key))
}

/// Create a wallet from a BIP-39 mnemonic. Returns `{handle_id, encrypted_seed_json, wrap_key}`.
#[flutter_rust_bridge::frb]
pub fn wallet_create(mnemonic_phrase: String, passphrase: String) -> Result<String, String> {
    let (id, json, wrap_key) = open_wallet(mnemonic_phrase, &passphrase)?;
    session_json(id, json, wrap_key)
}

/// Restore from a Keystore blob plus the separately stored wrap key.
/// v1 blobs that still embed `k` accept a null wrap key.
#[flutter_rust_bridge::frb]
pub fn wallet_restore(encrypted_seed_json: String, wrap_key: Option<String>) -> Result<u64, String> {
    let json: serde_json::Value = serde_json::from_str(&encrypted_seed_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let encrypted = wallet_core::EncryptedSeed::from_json(&json, wrap_key.as_deref()).map_err(err_str)?;
    let mut seed_bytes = encrypted.decrypt().map_err(err_str)?;
    let handle = WalletHandle::restore_from_seed(&seed_bytes).map_err(err_str)?;
    use zeroize::Zeroize;
    seed_bytes.zeroize();
    Ok(register_handle(handle))
}

#[flutter_rust_bridge::frb]
pub fn wallet_lock(handle_id: u64) -> Result<(), String> {
    let mut handles = recover(HANDLES.lock());
    let handle = handles
        .remove(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound("wallet_lock", handle_id).to_json_string())?;
    handle.lock();
    drop_preparations_for(handle_id);
    Ok(())
}

#[flutter_rust_bridge::frb]
pub fn wallet_is_unlocked(handle_id: u64) -> Result<bool, String> {
    with_handle(handle_id, "wallet_is_unlocked", |h| Ok(h.is_unlocked()))
}

#[flutter_rust_bridge::frb]
pub fn derive_address(handle_id: u64, index: u32) -> Result<String, String> {
    with_handle(handle_id, "derive_address", |h| h.derive_address(index).map_err(err_str))
}

#[flutter_rust_bridge::frb]
pub fn create_encrypted_seed(mnemonic_phrase: String, passphrase: String) -> Result<String, String> {
    let phrase = MnemonicPhrase::parse(mnemonic_phrase).map_err(err_str)?;
    let mut seed = phrase.to_seed(&passphrase).map_err(err_str)?;
    let encrypted = wallet_core::EncryptedSeed::encrypt(&seed).map_err(err_str)?;
    use zeroize::Zeroize;
    seed.zeroize();
    let json = encrypted.to_json().map_err(err_str)?;
    serde_json::to_string(&serde_json::json!({
        "encrypted_seed_json": json,
        "wrap_key": encrypted.wrap_key_hex(),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Seal the AES wrap key with a PIN (Argon2id + AES-GCM). Returns pin-wrap JSON.
#[flutter_rust_bridge::frb]
pub fn wrap_key_with_pin(wrap_key_hex: String, pin: String) -> Result<String, String> {
    let bytes = hex::decode(wrap_key_hex.trim())
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let wrapped = PinWrappedKey::wrap(&bytes, &pin).map_err(err_str)?;
    Ok(wrapped.to_json().to_string())
}

/// Recover the AES wrap key from pin-wrap JSON.
#[flutter_rust_bridge::frb]
pub fn unwrap_key_with_pin(pin_wrap_json: String, pin: String) -> Result<String, String> {
    let json: serde_json::Value = serde_json::from_str(&pin_wrap_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let wrapped = PinWrappedKey::from_json(&json).map_err(err_str)?;
    let key = wrapped.unwrap(&pin).map_err(err_str)?;
    Ok(hex::encode(key))
}

#[flutter_rust_bridge::frb]
pub fn sign_reduced_transaction(
    handle_id: u64,
    reduced_tx_bytes: Vec<u8>,
) -> Result<String, String> {
    with_handle(handle_id, "sign_reduced_transaction", |handle| {
        let reduced = wallet_core::transaction::deserialize_reduced(&reduced_tx_bytes)
            .map_err(err_str)?;
        let signed_tx = handle.sign_reduced(reduced).map_err(err_str)?;
        serde_json::to_value(&signed_tx)
            .map(|v| v.to_string())
            .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
    })
}

#[flutter_rust_bridge::frb]
pub fn generate_mnemonic(strength: u32) -> Result<String, String> {
    use ergo_lib::wallet::mnemonic_generator::{Language, MnemonicGenerator};

    let strength = if strength >= 192 { 256 } else { 128 };
    let byte_len = (strength / 8) as usize;
    let mut entropy = vec![0u8; byte_len];
    rand::rngs::OsRng.fill_bytes(&mut entropy);
    let generator = MnemonicGenerator::new(Language::English, strength)
        .map_err(|e| ArgusError::InvalidMnemonic(format!("{e:?}")).to_json_string())?;
    let phrase = generator
        .from_entropy(entropy)
        .map_err(|e| ArgusError::InvalidMnemonic(format!("{e:?}")).to_json_string())?;
    Ok(phrase)
}

#[flutter_rust_bridge::frb]
pub async fn get_balance(address: String, node_url: Option<String>) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let (nano, tokens) = client
        .get_address_balances(&address)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    serde_json::to_string(&serde_json::json!({
        "balance_nano_erg": nano,
        "tokens": tokens_json(&tokens),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub async fn get_token_info(token_id: String, explorer_url: Option<String>) -> Result<String, String> {
    let info = wallet_net::client::get_token_info(&token_id, explorer_url.as_deref())
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    serde_json::to_string(&info)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub async fn get_transaction_history(
    address: String,
    node_url: Option<String>,
    limit: u64,
    offset: u64,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let cap = if limit == 0 { 20 } else { limit.min(100) };
    let txs = client
        .get_transaction_history(&address, cap, offset)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    serde_json::to_string(&txs)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

const MAX_DISCOVERY: u32 = 256;

#[flutter_rust_bridge::frb]
pub async fn discover_addresses(
    handle_id: u64,
    node_url: Option<String>,
    gap_limit: u32,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let gap = gap_limit.max(1).min(100);

    let mut used = Vec::new();
    let mut last_used: Option<u32> = None;
    let mut consecutive_empty = 0u32;
    let mut scanned_up_to = 0u32;

    const CHUNK_SIZE: u32 = 10;
    let mut current_start = 0u32;

    while current_start < MAX_DISCOVERY {
        let chunk_end = (current_start + CHUNK_SIZE).min(MAX_DISCOVERY);
        let mut chunk_addrs = Vec::new();

        for index in current_start..chunk_end {
            let addr = with_handle(handle_id, "discover_addresses", |h| {
                h.derive_address(index).map_err(err_str)
            })?;
            chunk_addrs.push((index, addr));
        }

        // Query tx status for all addresses in this chunk concurrently
        let mut join_set = tokio::task::JoinSet::new();
        for (index, addr) in chunk_addrs {
            let client_c = client.clone();
            join_set.spawn(async move {
                let has_txs = client_c.address_has_transactions(&addr).await;
                (index, addr, has_txs)
            });
        }

        let mut chunk_results = Vec::new();
        while let Some(res) = join_set.join_next().await {
            match res {
                Ok((idx, addr, has_txs_res)) => {
                    chunk_results.push((idx, addr, has_txs_res));
                }
                Err(e) => return Err(ArgusError::NodeError(e.to_string()).to_json_string()),
            }
        }
        chunk_results.sort_by_key(|(idx, _, _)| *idx);

        let mut stopped = false;
        for (index, addr, has_txs_res) in chunk_results {
            scanned_up_to = index;
            let has_txs = has_txs_res.map_err(|e| ArgusError::NodeError(e).to_json_string())?;
            if has_txs {
                consecutive_empty = 0;
                last_used = Some(index);
                with_handle(handle_id, "discover_addresses", |h| {
                    h.ensure_index(index).map_err(err_str)
                })?;
                let balances = client
                    .get_address_balances(&addr)
                    .await
                    .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
                used.push(serde_json::json!({
                    "index": index,
                    "address": addr,
                    "balance_nano_erg": balances.0,
                    "tokens": tokens_json(&balances.1),
                }));
            } else {
                consecutive_empty += 1;
                if consecutive_empty >= gap {
                    stopped = true;
                    break;
                }
            }
        }

        if stopped {
            break;
        }
        current_start = chunk_end;
    }

    let next_unused = last_used.map(|i| i + 1).unwrap_or(0);
    serde_json::to_string(&serde_json::json!({
        "addresses": used,
        "scanned_up_to": scanned_up_to,
        "next_unused_index": next_unused,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Follow a singleton token forward through spent transactions to locate the current unspent box.
///
/// Designed to work on standard nodes without extraIndex or explorer indexing.
#[flutter_rust_bridge::frb]
pub async fn walk_singleton_lineage(
    singleton_token_id: String,
    starting_box_id: String,
    node_url: Option<String>,
    max_hops: Option<u32>,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let res = client
        .track_singleton_lineage(&singleton_token_id, &starting_box_id, max_hops.unwrap_or(50))
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    serde_json::to_string(&res)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Compute total balances and summary from a local WalletDatabase JSON snapshot.
#[flutter_rust_bridge::frb]
pub fn db_compute_summary(db_json: String) -> Result<String, String> {
    let db = wallet_core::WalletDatabase::from_json(&db_json).map_err(err_str)?;
    let (erg_nano, tokens) = db.get_total_balances().map_err(err_str)?;
    let unspent_count = db.get_unspent_boxes().len();
    let receive_0 = db.get_address_0().map(|a| a.address.clone());
    let lineages: Vec<&wallet_core::TrackedLineage> = db.lineages.values().collect();

    serde_json::to_string(&serde_json::json!({
        "balance_nano_erg": erg_nano,
        "tokens": tokens,
        "unspent_box_count": unspent_count,
        "receive_address_0": receive_0,
        "last_synced_height": db.sync.last_synced_height,
        "tracked_lineages": lineages,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

fn resolve_send_token(
    token_id: Option<String>,
    token_amount: Option<u64>,
) -> Result<Option<(String, u64)>, String> {
    match (token_id, token_amount) {
        (None, None) => Ok(None),
        (Some(id), Some(amt)) if !id.is_empty() && amt > 0 => Ok(Some((id, amt))),
        _ => Err(ArgusError::TxBuildFailed(
            "token_id and token_amount must both be a non-empty id and amount > 0".into(),
        )
        .to_json_string()),
    }
}

fn resolve_spend_addresses(sender: &str, extra: &[String]) -> Vec<String> {
    let mut spend = extra
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>();
    if spend.is_empty() && !sender.is_empty() {
        spend.push(sender.to_string());
    }
    spend.sort();
    spend.dedup();
    spend
}

async fn gather_unspent(
    handle_id: u64,
    client: &ErgoNodeClient,
    addresses: &[String],
) -> Result<(Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>, Vec<ergo_tx::Eip12InputBox>), String> {
    let mut boxes = Vec::new();
    let mut eip12 = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for addr in addresses {
        if addr.is_empty() {
            continue;
        }
        with_handle(handle_id, "send", |h| {
            if !h.owns_address(addr).map_err(err_str)? {
                return Err(ArgusError::InvalidAddress(
                    "spend address is not an address of this wallet".into(),
                )
                .to_json_string());
            }
            Ok(())
        })?;
        let (b, e) = client
            .get_unspent(addr)
            .await
            .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
        for (bx, input) in b.into_iter().zip(e.into_iter()) {
            if seen.insert(input.box_id.clone()) {
                boxes.push(bx);
                eip12.push(input);
            }
        }
    }
    Ok((boxes, eip12))
}

fn input_boxes_json(boxes: &[ergo_tx::Eip12InputBox]) -> Vec<serde_json::Value> {
    boxes
        .iter()
        .map(|b| serde_json::json!({
            "box_id": b.box_id,
            "value_nano_erg": b.value,
            "creation_height": b.creation_height,
            "assets": b.assets.iter().map(|a| serde_json::json!({
                "token_id": a.token_id,
                "amount": a.amount,
            })).collect::<Vec<_>>(),
        }))
        .collect()
}

struct ManagementBuild<S> {
    unsigned_tx: ergo_tx::Eip12UnsignedTx,
    summary: S,
    miner_fee: i64,
    change_erg: i64,
    recipient_erg: i64,
}

struct PreparedManagement<S> {
    preparation_id: u64,
    input_boxes: Vec<serde_json::Value>,
    summary: S,
}

fn filter_selected_inputs(
    inputs: Vec<ergo_tx::Eip12InputBox>,
    selected_box_ids: &[String],
) -> Result<Vec<ergo_tx::Eip12InputBox>, String> {
    let selected_ids = selected_box_ids.iter().map(String::as_str).collect::<HashSet<_>>();
    if selected_ids.is_empty() {
        return Ok(inputs);
    }
    let available_ids = inputs.iter().map(|input| input.box_id.as_str()).collect::<HashSet<_>>();
    let mut missing = selected_ids.difference(&available_ids).copied().collect::<Vec<_>>();
    missing.sort_unstable();
    if !missing.is_empty() {
        return Err(ArgusError::TxBuildFailed(format!(
            "selected UTXO(s) not found: {}",
            missing.join(", ")
        ))
        .to_json_string());
    }
    Ok(inputs
        .into_iter()
        .filter(|input| selected_ids.contains(input.box_id.as_str()))
        .collect())
}

async fn prepare_management<S>(
    handle_id: u64,
    operation: &'static str,
    spend_addresses: &[String],
    selected_box_ids: &[String],
    change_address: &str,
    no_inputs_message: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
    build: impl FnOnce(&[ergo_tx::Eip12InputBox], &str, i32) -> Result<ManagementBuild<S>, String>,
) -> Result<PreparedManagement<S>, String> {
    with_handle(handle_id, operation, |handle| {
        if !handle.owns_address(change_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "change is not an address of this wallet".into(),
            )
            .to_json_string());
        }
        Ok(())
    })?;

    let client = node_client(node_url.clone()).await?;
    let (boxes, inputs) = gather_unspent(handle_id, &client, spend_addresses).await?;
    let inputs = filter_selected_inputs(inputs, selected_box_ids)?;
    if inputs.is_empty() {
        return Err(ArgusError::NoUtxos(no_inputs_message).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let change_tree = address_to_ergo_tree(change_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let mut built = build(&inputs, &change_tree, height)?;

    if let Some(custom_fee) = fee_nano {
        if custom_fee < TX_FEE_NANO {
            return Err(ArgusError::TxBuildFailed(format!(
                "custom fee {custom_fee} nanoERG is below minimum {TX_FEE_NANO}"
            ))
            .to_json_string());
        }
        apply_custom_fee(
            &mut built.unsigned_tx,
            &change_tree,
            built.miner_fee,
            custom_fee,
        )?;
        built.miner_fee = custom_fee;
        built.change_erg = built.unsigned_tx.outputs.iter()
            .find(|o| o.ergo_tree == change_tree)
            .map(|o| o.value.parse::<i64>().unwrap_or(0))
            .unwrap_or(0);
    }

    let mut boxes_by_id = boxes
        .into_iter()
        .map(|ergo_box| (ergo_box.box_id().to_string(), ergo_box))
        .collect::<HashMap<_, _>>();
    let ergo_boxes = inputs
        .iter()
        .map(|input| {
            boxes_by_id.remove(&input.box_id).ok_or_else(|| {
                ArgusError::TxBuildFailed(format!(
                    "UTXO set mismatch: missing ErgoBox {}",
                    input.box_id
                ))
                .to_json_string()
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let input_boxes = input_boxes_json(&inputs);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        ergo_boxes,
        unsigned_tx: built.unsigned_tx,
        miner_fee: built.miner_fee,
        change_erg: built.change_erg,
        recipient_erg: built.recipient_erg,
        node_url,
    });
    Ok(PreparedManagement {
        preparation_id,
        input_boxes,
        summary: built.summary,
    })
}

async fn prepare(
    handle_id: u64,
    sender_address: &str,
    spend_addresses: &[String],
    change_address: &str,
    recipient_address: &str,
    amount_nano_erg: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<(Vec<serde_json::Value>, Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>, ergo_tx::SendBuildResult), String> {
    if amount_nano_erg < MIN_BOX_VALUE_NANO {
        return Err(ArgusError::TxBuildFailed(format!(
            "amount must be at least {MIN_BOX_VALUE_NANO} nanoERG"
        ))
        .to_json_string());
    }
    if let Some(fee) = fee_nano {
        if fee < TX_FEE_NANO {
            return Err(ArgusError::TxBuildFailed(format!(
                "custom fee {fee} nanoERG is below minimum {TX_FEE_NANO}"
            ))
            .to_json_string());
        }
    }
    with_handle(handle_id, "send", |h| {
        if !h.owns_address(change_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "change is not an address of this wallet".into(),
            )
            .to_json_string());
        }
        Ok(())
    })?;

    let spend = resolve_spend_addresses(sender_address, spend_addresses);

    let send_token = resolve_send_token(token_id, token_amount)?;
    let client = node_client(node_url).await?;
    let (boxes, eip12) = gather_unspent(handle_id, &client, &spend).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend.join(",")).to_json_string());
    }

    let fee_for_required = fee_nano.unwrap_or(TX_FEE_NANO);
    let required = (amount_nano_erg + fee_for_required + MIN_BOX_VALUE_NANO) as u64;
    let token_ref = send_token.as_ref().map(|(id, amt)| (id.as_str(), *amt));
    let selected = select_for_send(&eip12, required, token_ref).map_err(|e| {
        ArgusError::TxBuildFailed(e.to_string()).to_json_string()
    })?;

    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let recipient_tree = address_to_ergo_tree(recipient_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let change_tree = address_to_ergo_tree(change_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;

    let built = build_send_tx_with_fee(
        &selected.boxes,
        &recipient_tree,
        &change_tree,
        amount_nano_erg,
        token_ref,
        height,
        &DevFeeConfig::disabled(),
    )
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    let mut built = built;
    if let Some(custom_fee) = fee_nano {
        if let Err(e) = apply_custom_fee(&mut built.unsigned_tx, &change_tree, built.summary.miner_fee, custom_fee) {
            return Err(e);
        }
        built.summary.miner_fee = custom_fee;
        built.summary.change_erg = built.unsigned_tx.outputs.iter()
            .find(|o| o.ergo_tree == change_tree)
            .map(|o| o.value.parse::<i64>().unwrap_or(0))
            .unwrap_or(0);
    }

    let ergo_boxes = selected
        .boxes
        .iter()
        .filter_map(|eip| {
            boxes
                .iter()
                .find(|b| b.box_id().to_string() == eip.box_id)
                .cloned()
        })
        .collect::<Vec<_>>();
    if ergo_boxes.len() != selected.boxes.len() {
        return Err(ArgusError::TxBuildFailed("UTXO set mismatch".into()).to_json_string());
    }

    let input_boxes = input_boxes_json(&selected.boxes);

    Ok((input_boxes, ergo_boxes, built))
}

#[flutter_rust_bridge::frb]
pub async fn prepare_send(
    handle_id: u64,
    sender_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    recipient_address: String,
    amount_nano_erg: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let (input_boxes, ergo_boxes, built) = prepare(
        handle_id,
        &sender_address,
        &spend_addresses,
        &change_address,
        &recipient_address,
        amount_nano_erg,
        token_id,
        token_amount,
        node_url.clone(),
        fee_nano,
    )
    .await?;
    let recipient_erg = built.summary.recipient_erg;
    let miner_fee = built.summary.miner_fee;
    let change_erg = built.summary.change_erg;
    let input_count = built.summary.input_count;
    let citadel_fee_nano = built.summary.citadel_fee_nano;
    let preview_token_id = built.summary.token_id.clone();
    let preview_token_amount = built.summary.token_amount;
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        ergo_boxes,
        unsigned_tx: built.unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "recipient": recipient_address,
        "change_address": change_address,
        "amount_nano_erg": recipient_erg,
        "miner_fee": miner_fee,
        "change_nano_erg": change_erg,
        "input_count": input_count,
        "citadel_fee_nano": citadel_fee_nano,
        "token_id": preview_token_id,
        "token_amount": preview_token_amount,
        "input_boxes": input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a UTXO consolidation transaction to merge multiple boxes into one.
#[flutter_rust_bridge::frb]
pub async fn prepare_consolidate(
    handle_id: u64,
    spend_addresses: Vec<String>,
    selected_box_ids: Vec<String>,
    change_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let prepared = prepare_management(
        handle_id, "consolidate", &spend_addresses, &selected_box_ids, &change_address,
        spend_addresses.join(","), node_url, fee_nano,
        |inputs, change_tree, height| {
            if inputs.len() < 2 {
                return Err(ArgusError::TxBuildFailed(
                    "Consolidation requires at least 2 input boxes".into(),
                ).to_json_string());
            }
            let built = ergo_tx::build_consolidate_tx(inputs, change_tree, height)
                .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
            Ok(ManagementBuild {
                miner_fee: built.summary.miner_fee,
                change_erg: built.summary.change_erg,
                recipient_erg: 0,
                unsigned_tx: built.unsigned_tx,
                summary: built.summary,
            })
        },
    ).await?;
    let summary = prepared.summary;

    serde_json::to_string(&serde_json::json!({
        "preparation_id": prepared.preparation_id,
        "input_count": summary.input_count,
        "total_erg_in": summary.total_erg_in,
        "change_nano_erg": summary.change_erg,
        "token_count": summary.token_count,
        "miner_fee": summary.miner_fee,
        "input_boxes": prepared.input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a transaction to split ERG into N equal boxes.
#[flutter_rust_bridge::frb]
pub async fn prepare_split_erg(
    handle_id: u64,
    spend_addresses: Vec<String>,
    selected_box_ids: Vec<String>,
    count: u32,
    amount_per_box_nano: i64,
    change_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let mode = ergo_tx::SplitMode::Erg {
        amount_per_box: amount_per_box_nano,
    };
    let prepared = prepare_management(
        handle_id, "split_erg", &spend_addresses, &selected_box_ids, &change_address,
        "no inputs available for split".into(), node_url, fee_nano,
        move |inputs, change_tree, height| {
            let built = ergo_tx::build_split_tx(inputs, &mode, count as usize, change_tree, height)
                .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
            Ok(ManagementBuild {
                miner_fee: built.summary.miner_fee,
                change_erg: built.summary.change_erg,
                recipient_erg: 0,
                unsigned_tx: built.unsigned_tx,
                summary: built.summary,
            })
        },
    ).await?;
    let summary = prepared.summary;

    serde_json::to_string(&serde_json::json!({
        "preparation_id": prepared.preparation_id,
        "split_count": summary.split_count,
        "amount_per_box": summary.amount_per_box,
        "total_split": summary.total_split,
        "change_nano_erg": summary.change_erg,
        "miner_fee": summary.miner_fee,
        "input_boxes": prepared.input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a transaction to split tokens into N equal boxes.
#[flutter_rust_bridge::frb]
pub async fn prepare_split_token(
    handle_id: u64,
    spend_addresses: Vec<String>,
    selected_box_ids: Vec<String>,
    token_id: String,
    count: u32,
    amount_per_box: u64,
    erg_per_box_nano: i64,
    change_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let mode = ergo_tx::SplitMode::Token {
        token_id: token_id.clone(),
        amount_per_box,
        erg_per_box: erg_per_box_nano,
    };
    let prepared = prepare_management(
        handle_id, "split_token", &spend_addresses, &selected_box_ids, &change_address,
        "no inputs available for split".into(), node_url, fee_nano,
        move |inputs, change_tree, height| {
            let built = ergo_tx::build_split_tx(inputs, &mode, count as usize, change_tree, height)
                .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
            Ok(ManagementBuild {
                miner_fee: built.summary.miner_fee,
                change_erg: built.summary.change_erg,
                recipient_erg: 0,
                unsigned_tx: built.unsigned_tx,
                summary: built.summary,
            })
        },
    ).await?;
    let summary = prepared.summary;

    serde_json::to_string(&serde_json::json!({
        "preparation_id": prepared.preparation_id,
        "split_count": summary.split_count,
        "token_id": token_id,
        "amount_per_box": summary.amount_per_box,
        "total_split": summary.total_split,
        "change_nano_erg": summary.change_erg,
        "miner_fee": summary.miner_fee,
        "input_boxes": prepared.input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a custom restructure transaction to allocate specific amounts and tokens into custom output boxes.
#[flutter_rust_bridge::frb]
pub async fn prepare_restructure(
    handle_id: u64,
    spend_addresses: Vec<String>,
    selected_box_ids: Vec<String>,
    outputs_json: String,
    change_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let parsed_specs: Vec<serde_json::Value> = serde_json::from_str(&outputs_json)
        .map_err(|e| ArgusError::SerializationError(format!("Invalid outputs JSON: {e}")).to_json_string())?;

    let mut specs = Vec::with_capacity(parsed_specs.len());
    for s in parsed_specs {
        let value = s["value_nano_erg"]
            .as_i64()
            .ok_or_else(|| ArgusError::TxBuildFailed("output missing value_nano_erg".into()).to_json_string())?;
        let tokens = s["tokens"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|t| {
                        let id = t["id"].as_str()?.to_string();
                        let amt = t["amount"].as_u64()?;
                        Some((id, amt))
                    })
                    .collect()
            })
            .unwrap_or_default();
        specs.push(ergo_tx::RestructureOutputSpec { value, tokens });
    }
    let prepared = prepare_management(
        handle_id, "restructure", &spend_addresses, &selected_box_ids, &change_address,
        "no inputs available for restructure".into(), node_url, fee_nano,
        move |inputs, change_tree, height| {
            let built = ergo_tx::build_restructure_tx(inputs, &specs, change_tree, height)
                .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
            Ok(ManagementBuild {
                miner_fee: built.summary.miner_fee,
                change_erg: built.summary.change_erg,
                recipient_erg: built.summary.allocated_erg,
                unsigned_tx: built.unsigned_tx,
                summary: built.summary,
            })
        },
    ).await?;
    let summary = prepared.summary;

    serde_json::to_string(&serde_json::json!({
        "preparation_id": prepared.preparation_id,
        "input_count": summary.input_count,
        "output_count": summary.output_count,
        "total_erg_in": summary.total_erg_in,
        "allocated_erg": summary.allocated_erg,
        "change_nano_erg": summary.change_erg,
        "has_change": summary.has_change,
        "miner_fee": summary.miner_fee,
        "input_boxes": prepared.input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// List all unspent boxes (UTXOs) for the given addresses. Returns a JSON array
/// of `InputBoxInput`-compatible objects (same shape as the `input_boxes` field
/// in `prepareSend`).
#[flutter_rust_bridge::frb]
pub async fn list_unspent_boxes(
    handle_id: u64,
    addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let (_, eip12) = gather_unspent(handle_id, &client, &addresses).await?;
    let json = input_boxes_json(&eip12);
    serde_json::to_string(&json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub async fn send_erg(handle_id: u64, preparation_id: u64) -> Result<String, String> {
    let prep = take_preparation(handle_id, preparation_id)?;
    let client = node_client(prep.node_url).await?;

    let state_context = client
        .get_state_context()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let reduced_bytes = reduce_transaction_with_context(
        &prep.unsigned_tx,
        prep.ergo_boxes,
        Vec::new(),
        &state_context,
    )
    .map_err(|e| ArgusError::TxReductionFailed(e.to_string()).to_json_string())?;

    let signed_tx = with_handle(handle_id, "send_erg", |handle| {
        let reduced = ReducedTransaction::sigma_parse_bytes(&reduced_bytes)
            .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
        handle.sign_reduced(reduced).map_err(err_str)
    })?;

    let tx_json = serde_json::to_value(&signed_tx)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let tx_id = client
        .submit_transaction(&tx_json)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;

    serde_json::to_string(&serde_json::json!({
        "tx_id": tx_id,
        "preparation_id": preparation_id,
        "miner_fee": prep.miner_fee,
        "change_nano_erg": prep.change_erg,
        "amount_nano_erg": prep.recipient_erg,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Sign a prepared transaction without submitting it. Returns the raw signed
/// transaction as an EIP-12 JSON string. Use this for air-gapped / raw-tx
/// export workflows.
#[flutter_rust_bridge::frb]
pub async fn sign_preparation(handle_id: u64, preparation_id: u64) -> Result<String, String> {
    let prep = take_preparation(handle_id, preparation_id)?;
    let client = node_client(prep.node_url).await?;

    let state_context = client
        .get_state_context()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let reduced_bytes = reduce_transaction_with_context(
        &prep.unsigned_tx,
        prep.ergo_boxes,
        Vec::new(),
        &state_context,
    )
    .map_err(|e| ArgusError::TxReductionFailed(e.to_string()).to_json_string())?;

    let signed_tx = with_handle(handle_id, "sign_preparation", |handle| {
        let reduced = ReducedTransaction::sigma_parse_bytes(&reduced_bytes)
            .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
        handle.sign_reduced(reduced).map_err(err_str)
    })?;

    let tx_json = serde_json::to_value(&signed_tx)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    serde_json::to_string(&tx_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a multi-recipient send. Each element of `recipients_json` is a JSON
/// object: `{"address":"...","amount_nano_erg":123,"token_id":"...","token_amount":456}`.
/// At least one recipient must carry ERG or tokens. The change goes to
/// `change_address`. Supports all `prepare_send` options (fee_nano, etc.).
#[flutter_rust_bridge::frb]
pub async fn prepare_send_multi(
    handle_id: u64,
    sender_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    recipients_json: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let change_tree = address_to_ergo_tree(&change_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;

    if fee_nano.unwrap_or(TX_FEE_NANO) < TX_FEE_NANO {
        return Err(ArgusError::TxBuildFailed(format!(
            "custom fee is below minimum {TX_FEE_NANO}"
        ))
        .to_json_string());
    }

    let recipients: Vec<serde_json::Value> = serde_json::from_str(&recipients_json)
        .map_err(|e| ArgusError::SerializationError(format!("Invalid recipients JSON: {e}")).to_json_string())?;

    if recipients.is_empty() {
        return Err(ArgusError::TxBuildFailed("at least one recipient is required".into())
            .to_json_string());
    }

    let mut parsed: Vec<(String, i64, Option<(String, u64)>)> = Vec::new();
    let mut total_send_erg: i64 = 0;
    for rcpt in recipients {
        let addr = rcpt["address"].as_str()
            .ok_or_else(|| ArgusError::TxBuildFailed("recipient missing address".into()).to_json_string())?;
        let token = rcpt["token_id"].as_str().and_then(|id| {
            let amt = rcpt["token_amount"].as_u64()?;
            Some((id.to_string(), amt))
        });
        let mut amount = rcpt["amount_nano_erg"].as_i64()
            .ok_or_else(|| ArgusError::TxBuildFailed("recipient missing amount_nano_erg".into()).to_json_string())?;
        if token.is_some() {
            if amount < MIN_BOX_VALUE_NANO {
                amount = MIN_BOX_VALUE_NANO;
            }
        } else if amount < MIN_BOX_VALUE_NANO {
            return Err(ArgusError::TxBuildFailed(format!(
                "recipient {} amount must be at least {MIN_BOX_VALUE_NANO} nanoERG or carry tokens",
                addr
            ))
            .to_json_string());
        }
        total_send_erg += amount;
        parsed.push((addr.to_string(), amount, token));
    }

    if total_send_erg <= 0 {
        return Err(ArgusError::TxBuildFailed("at least one recipient must receive ERG".into())
            .to_json_string());
    }

    // Collect all recipient trees
    let mut recipient_specs: Vec<(String, Option<(String, u64)>)> = Vec::new();
    for (addr, _amount, token) in &parsed {
        let tree = address_to_ergo_tree(addr)
            .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
        recipient_specs.push((tree, token.clone()));
    }

    with_handle(handle_id, "prepare_send_multi", |h| {
        if !h.owns_address(&change_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "change is not an address of this wallet".into(),
            )
            .to_json_string());
        }
        Ok(())
    })?;

    let spend = resolve_spend_addresses(&sender_address, &spend_addresses);
    let client = node_client(node_url.clone()).await?;
    let (boxes, eip12) = gather_unspent(handle_id, &client, &spend).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend.join(",")).to_json_string());
    }

    // Collect tokens we need to cover
    let mut needed_tokens: HashMap<String, u64> = HashMap::new();
    for (_, _, token_opt) in &parsed {
        if let Some((id, amt)) = token_opt {
            *needed_tokens.entry(id.clone()).or_insert(0) += amt;
        }
    }

    // For input selection we need the total ERG + all token amounts
    let fee_for_required = fee_nano.unwrap_or(TX_FEE_NANO);
    let total_token_ids: Vec<String> = needed_tokens.keys().cloned().collect();

    // Use UTXO selection: pick boxes covering total_send_erg + fee + min change,
    // and which collectively hold the needed tokens.
    let required = (total_send_erg + fee_for_required + MIN_BOX_VALUE_NANO) as u64;
    let selected = select_for_multi_send(&eip12, required, &needed_tokens, &total_token_ids)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    if selected.is_empty() {
        return Err(ArgusError::NoUtxos(spend.join(",")).to_json_string());
    }

    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;

    // Build outputs: recipient outputs + token-change + change + fee
    let mut outputs: Vec<ergo_tx::Eip12Output> = Vec::new();
    let mut token_change: HashMap<String, u64> = HashMap::new();
    // Aggregate input token balances
    let mut input_tokens: HashMap<String, u64> = HashMap::new();
    for input in &selected {
        for asset in &input.assets {
            *input_tokens.entry(asset.token_id.clone()).or_insert(0) +=
                asset.amount.parse::<u64>().unwrap_or(0);
        }
    }
    // Subtract sent tokens
    for (_, _, token_opt) in &parsed {
        if let Some((id, amt)) = token_opt {
            if let Some(balance) = input_tokens.get_mut(id) {
                *balance = balance.saturating_sub(*amt);
                if *balance == 0 {
                    input_tokens.remove(id);
                }
            }
        }
    }
    // Remaining tokens go to change
    for (id, amt) in &input_tokens {
        token_change.insert(id.clone(), *amt);
    }

    // Total input erg
    let total_erg: i64 = selected.iter()
        .map(|b| b.value.parse::<i64>().unwrap_or(0))
        .sum();

    let has_token_change = !token_change.is_empty();
    let change_erg = total_erg - total_send_erg - fee_for_required;
    let need_change = change_erg > 0 || has_token_change;

    if need_change {
        if has_token_change && change_erg < MIN_BOX_VALUE_NANO {
            return Err(ArgusError::TxBuildFailed(format!(
                "token change requires at least {MIN_BOX_VALUE_NANO} nanoERG leftover, have {change_erg}"
            ))
            .to_json_string());
        }
        if change_erg > 0 && change_erg < MIN_BOX_VALUE_NANO {
            return Err(ArgusError::TxBuildFailed(format!(
                "change {change_erg} below min box value {MIN_BOX_VALUE_NANO}"
            ))
            .to_json_string());
        }
    }

    // Recipient outputs
    for (idx, (tree, token_opt)) in recipient_specs.iter().enumerate() {
        let amount = parsed[idx].1;
        let assets = match token_opt {
            Some((id, amt)) => vec![ergo_tx::Eip12Asset::new(id.clone(), *amt as i64)],
            None => vec![],
        };
        outputs.push(ergo_tx::Eip12Output {
            value: amount.to_string(),
            ergo_tree: tree.clone(),
            assets,
            creation_height: height,
            additional_registers: std::collections::HashMap::new(),
        });
    }

    // Change output
    let change_assets: Vec<ergo_tx::Eip12Asset> = token_change
        .iter()
        .map(|(id, amt)| ergo_tx::Eip12Asset::new(id.clone(), *amt as i64))
        .collect();
    if need_change {
        let change_value = if change_erg > 0 { change_erg } else { MIN_BOX_VALUE_NANO };
        outputs.push(ergo_tx::Eip12Output {
            value: change_value.to_string(),
            ergo_tree: change_tree.clone(),
            assets: change_assets,
            creation_height: height,
            additional_registers: std::collections::HashMap::new(),
        });
    }

    outputs.push(ergo_tx::Eip12Output::fee(fee_for_required, height));

    let unsigned_tx = ergo_tx::Eip12UnsignedTx {
        inputs: selected.clone(),
        data_inputs: vec![],
        outputs,
    };

    // Get the ErgoBox representations for signing
    let ergo_boxes = selected.iter().filter_map(|eip| {
        boxes.iter().find(|b| b.box_id().to_string() == eip.box_id).cloned()
    }).collect::<Vec<_>>();
    if ergo_boxes.len() != selected.len() {
        return Err(ArgusError::TxBuildFailed("UTXO set mismatch".into()).to_json_string());
    }

    let input_boxes = input_boxes_json(&selected);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        ergo_boxes,
        unsigned_tx,
        miner_fee: fee_for_required,
        change_erg,
        recipient_erg: total_send_erg,
        node_url,
    });

    let recipient_summary: Vec<serde_json::Value> = parsed.iter().map(|(addr, amount, token_opt)| {
        serde_json::json!({
            "address": addr,
            "amount_nano_erg": amount,
            "token_id": token_opt.as_ref().map(|(id, _)| id),
            "token_amount": token_opt.as_ref().map(|(_, amt)| amt),
        })
    }).collect();

    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "recipients": recipient_summary,
        "change_address": change_address,
        "total_amount_nano_erg": total_send_erg,
        "amount_nano_erg": total_send_erg,
        "miner_fee": fee_for_required,
        "change_nano_erg": change_erg,
        "input_count": selected.len(),
        "citadel_fee_nano": 0,
        "input_boxes": input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Select UTXOs that collectively hold enough ERG and tokens for a multi-send.
fn select_for_multi_send(
    eip12: &[ergo_tx::Eip12InputBox],
    required_erg: u64,
    needed_tokens: &HashMap<String, u64>,
    token_ids: &[String],
) -> Result<Vec<ergo_tx::Eip12InputBox>, String> {
    let mut total_erg: u64 = 0;
    let mut total_tokens: HashMap<String, u64> = HashMap::new();
    let mut selected: Vec<ergo_tx::Eip12InputBox> = Vec::new();

    for input in eip12.iter().rev() {
        selected.push(input.clone());
        let val: u64 = input.value.parse::<u64>().unwrap_or(0);
        total_erg = total_erg.saturating_add(val);
        for asset in &input.assets {
            *total_tokens.entry(asset.token_id.clone()).or_insert(0) +=
                asset.amount.parse::<u64>().unwrap_or(0);
        }

        if total_erg >= required_erg {
            let all_ok = token_ids.iter().all(|id| {
                total_tokens.get(id).copied().unwrap_or(0) >= *needed_tokens.get(id).unwrap()
            });
            if all_ok {
                break;
            }
        }
    }

    if total_erg < required_erg {
        return Err(format!(
            "insufficient ERG: have {total_erg}, need at least {required_erg}"
        ));
    }
    for id in token_ids {
        let have = total_tokens.get(id).copied().unwrap_or(0);
        let need = needed_tokens.get(id).copied().unwrap_or(0);
        if have < need {
            return Err(format!("insufficient tokens {id}: have {have}, need {need}"));
        }
    }

    Ok(selected)
}

#[cfg(test)]
mod tests {
    use super::*;

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    #[test]
    fn create_restore_lock() {
        let session: serde_json::Value =
            serde_json::from_str(&wallet_create(APPKIT.to_string(), "".into()).unwrap()).unwrap();
        let handle_id: u64 = session["handle_id"].as_str().unwrap().parse().unwrap();
        assert!(wallet_is_unlocked(handle_id).unwrap());
        let addr = derive_address(handle_id, 0).unwrap();
        assert_eq!(addr, "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8");

        let blob = session["encrypted_seed_json"].as_str().unwrap().to_string();
        let wrap_key = session["wrap_key"].as_str().unwrap().to_string();
        assert!(serde_json::from_str::<serde_json::Value>(&blob).unwrap().get("k").is_none());
        wallet_lock(handle_id).unwrap();
        assert!(wallet_is_unlocked(handle_id).is_err());

        let restored = wallet_restore(blob, Some(wrap_key)).unwrap();
        assert_eq!(
            derive_address(restored, 0).unwrap(),
            "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8"
        );
    }

    #[test]
    fn rejects_bad_mnemonic() {
        assert!(wallet_create("not a real mnemonic phrase at all".into(), "".into()).is_err());
    }

    #[test]
    fn generate_is_valid_bip39() {
        let phrase = generate_mnemonic(128).unwrap();
        assert_eq!(phrase.split_whitespace().count(), 12);
        assert!(MnemonicPhrase::parse(phrase).is_ok());
        let phrase24 = generate_mnemonic(256).unwrap();
        assert_eq!(phrase24.split_whitespace().count(), 24);
    }

    #[test]
    fn take_preparation_rejects_unknown_stale_and_repeat() {
        assert!(take_preparation(1, 99).is_err());
        let id = store_preparation(CachedPreparation {
            handle_id: 7,
            ergo_boxes: Vec::new(),
            unsigned_tx: ergo_tx::Eip12UnsignedTx {
                inputs: vec![],
                data_inputs: vec![],
                outputs: vec![],
            },
            miner_fee: 0,
            change_erg: 0,
            recipient_erg: 0,
            node_url: None,
        });
        assert!(take_preparation(8, id).is_err());
        assert!(take_preparation(7, id).is_ok());
        assert!(take_preparation(7, id).is_err());
    }

    #[test]
    fn spend_list_uses_all_owned_and_falls_back() {
        let many = resolve_spend_addresses(
            "9aaa",
            &["9ccc".into(), " 9bbb ".into(), "9ccc".into(), "".into()],
        );
        assert_eq!(many, vec!["9bbb", "9ccc"]);
        assert_eq!(
            resolve_spend_addresses("9aaa", &[]),
            vec!["9aaa"]
        );
    }

    #[test]
    fn send_token_pair_must_be_complete() {
        assert!(resolve_send_token(None, None).unwrap().is_none());
        assert_eq!(
            resolve_send_token(Some("abc".into()), Some(2)).unwrap(),
            Some(("abc".into(), 2))
        );
        assert!(resolve_send_token(Some("abc".into()), None).is_err());
        assert!(resolve_send_token(None, Some(2)).is_err());
        assert!(resolve_send_token(Some("".into()), Some(2)).is_err());
        assert!(resolve_send_token(Some("abc".into()), Some(0)).is_err());
    }

    #[test]
    fn pin_wrap_roundtrip() {
        let key = hex::encode([3u8; 32]);
        let json = wrap_key_with_pin(key.clone(), "123456".into()).unwrap();
        assert_eq!(unwrap_key_with_pin(json.clone(), "123456".into()).unwrap(), key);
        assert!(unwrap_key_with_pin(json, "654321".into()).is_err());
    }

    fn test_input_box(box_id: &str, value: &str, assets: Vec<(&str, &str)>) -> ergo_tx::Eip12InputBox {
        serde_json::from_str(
            &serde_json::json!({
                "boxId": box_id,
                "transactionId": "t",
                "index": 0,
                "value": value,
                "ergoTree": "00",
                "assets": assets.iter().map(|(id, amt)| serde_json::json!({"tokenId": id, "amount": amt})).collect::<Vec<_>>(),
                "creationHeight": 100,
                "additionalRegisters": {},
                "extension": {},
            })
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn input_boxes_json_serializes_value_and_assets() {
        let plain = test_input_box("b1", "2700000000", vec![]);
        let nft = test_input_box("b2", "1000000", vec![("nft", "1")]);
        let arr = input_boxes_json(&[plain, nft]);
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["box_id"], "b1");
        assert_eq!(arr[0]["value_nano_erg"], "2700000000");
        assert_eq!(arr[0]["creation_height"], 100);
        assert_eq!(arr[0]["assets"].as_array().unwrap().len(), 0);
        assert_eq!(arr[1]["box_id"], "b2");
        assert_eq!(arr[1]["assets"][0]["token_id"], "nft");
        assert_eq!(arr[1]["assets"][0]["amount"], "1");
    }

    #[test]
    fn selected_inputs_reject_missing_ids_and_preserve_input_order() {
        let inputs = vec![
            test_input_box("b1", "1000000", vec![]),
            test_input_box("b2", "2000000", vec![]),
            test_input_box("b3", "3000000", vec![]),
        ];
        let filtered = filter_selected_inputs(inputs.clone(), &["b3".into(), "b1".into()]).unwrap();
        assert_eq!(
            filtered.iter().map(|input| input.box_id.as_str()).collect::<Vec<_>>(),
            vec!["b1", "b3"]
        );
        let error = filter_selected_inputs(inputs, &["b1".into(), "missing".into()]).unwrap_err();
        assert!(error.contains("selected UTXO(s) not found: missing"));
    }
}
