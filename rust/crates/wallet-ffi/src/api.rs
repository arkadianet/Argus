//! Argus wallet FFI — flutter_rust_bridge interface.

use std::collections::HashMap;
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
    built: ergo_tx::SendBuildResult,
    node_url: Option<String>,
}

static PREPARATIONS: Lazy<Mutex<HashMap<u64, CachedPreparation>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn store_preparation(prep: CachedPreparation) -> u64 {
    let mut cache = recover(PREPARATIONS.lock());
    cache.retain(|_, p| p.handle_id != prep.handle_id);
    loop {
        let id = rand::rngs::OsRng.next_u64();
        if id != 0 && !cache.contains_key(&id) {
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

fn register_handle(handle: WalletHandle) -> u64 {
    let mut handles = recover(HANDLES.lock());
    loop {
        let id = rand::rngs::OsRng.next_u64();
        if id != 0 && !handles.contains_key(&id) {
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
        "handle_id": handle_id,
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

    for index in 0..MAX_DISCOVERY {
        scanned_up_to = index;
        let addr = with_handle(handle_id, "discover_addresses", |h| {
            h.derive_address(index).map_err(err_str)
        })?;
        let has_txs = client
            .address_has_transactions(&addr)
            .await
            .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
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
                break;
            }
        }
    }

    let next_unused = last_used.map(|i| i + 1).unwrap_or(0);
    serde_json::to_string(&serde_json::json!({
        "addresses": used,
        "scanned_up_to": scanned_up_to,
        "next_unused_index": next_unused,
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
) -> Result<(Vec<serde_json::Value>, Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>, ergo_tx::SendBuildResult), String> {
    if amount_nano_erg < MIN_BOX_VALUE_NANO {
        return Err(ArgusError::TxBuildFailed(format!(
            "amount must be at least {MIN_BOX_VALUE_NANO} nanoERG"
        ))
        .to_json_string());
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

    let required = (amount_nano_erg + TX_FEE_NANO + MIN_BOX_VALUE_NANO) as u64;
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
        built,
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
        &prep.built.unsigned_tx,
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
        "miner_fee": prep.built.summary.miner_fee,
        "change_nano_erg": prep.built.summary.change_erg,
        "amount_nano_erg": prep.built.summary.recipient_erg,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    #[test]
    fn create_restore_lock() {
        let session: serde_json::Value =
            serde_json::from_str(&wallet_create(APPKIT.to_string(), "".into()).unwrap()).unwrap();
        let handle_id = session["handle_id"].as_u64().unwrap();
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

    fn dummy_build() -> ergo_tx::SendBuildResult {
        ergo_tx::SendBuildResult {
            unsigned_tx: ergo_tx::Eip12UnsignedTx {
                inputs: vec![],
                data_inputs: vec![],
                outputs: vec![],
            },
            summary: ergo_tx::SendSummary {
                recipient_erg: 0,
                token_id: None,
                token_amount: None,
                change_erg: 0,
                miner_fee: 0,
                citadel_fee_nano: 0,
                input_count: 0,
            },
        }
    }

    #[test]
    fn take_preparation_rejects_unknown_stale_and_repeat() {
        assert!(take_preparation(1, 99).is_err());
        let id = store_preparation(CachedPreparation {
            handle_id: 7,
            ergo_boxes: Vec::new(),
            built: dummy_build(),
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
}
