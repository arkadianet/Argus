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
use wallet_core::spend::{select_exact, select_preferring_one_pocket};
use wallet_core::wallet::WalletHandle;
use wallet_core::PinWrappedKey;
use wallet_net::client::{address_to_ergo_tree, ErgoNodeClient};

use crate::error::ArgusError;

/// Argus app fee: paid on every transaction the wallet builds (sends, UTXO
/// tools, swaps, mints). ErgoPay transactions are built by the dApp and are
/// not touched. Disclosed on every confirm sheet and in Settings → About.
pub const ARGUS_FEE_ADDRESS: &str = "9iArkadiaZAPVxbUp2XQ8SVA1zGA29rCPhbpVuUaaKW6fWspUZA";
pub const ARGUS_FEE_NANO: i64 = 1_100_000;

/// Runs at bridge start (`frb(init)`) and is also called explicitly from
/// Dart right after `RustLib.init`, so the fee config is installed before
/// any builder resolves it. The attribute used to sit above the constants
/// and never applied, which left the vendored default in force.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Never the inherited Citadel fee; the Argus fee is installed instead.
    std::env::set_var("CITADEL_DEV_FEE_ENABLED", "false");
    if let Ok(tree) = address_to_ergo_tree(ARGUS_FEE_ADDRESS) {
        ergo_tx::install_dev_fee_config(DevFeeConfig::custom(tree, ARGUS_FEE_NANO));
    }
}

/// The app fee as the UI should display it.
#[flutter_rust_bridge::frb(sync)]
pub fn app_fee_info() -> String {
    let cfg = ergo_tx::resolved_dev_fee_config();
    serde_json::json!({
        "address": ARGUS_FEE_ADDRESS,
        "amount_nano": cfg.budget(),
        "enabled": cfg.enabled,
    })
    .to_string()
}

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
    /// ErgoTree hexes of any stealth inputs in this transaction. Public data;
    /// the DH-tuple secret they need is re-derived from the unlocked wallet
    /// at signing time and never stored.
    stealth_trees: Vec<String>,
    /// Mixing inputs whose proof needs a mix secret. Like stealth, only a
    /// recipe is kept: the secret is re-derived from the unlocked wallet at
    /// signing time.
    mix_proofs: Vec<crate::api_mix_impl::MixProofRecipe>,
    data_input_boxes: Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
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
        None => Err(
            ArgusError::TxBuildFailed("unknown or stale send preparation".into()).to_json_string(),
        ),
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
    let fee_idx = tx
        .outputs
        .iter()
        .position(|o| o.ergo_tree == citadel_core::constants::MINER_FEE_ERGO_TREE)
        .ok_or_else(|| {
            ArgusError::TxBuildFailed("fee output not found in unsigned tx".into()).to_json_string()
        })?;

    let change_idx = tx
        .outputs
        .iter()
        .rposition(|o| o.ergo_tree == change_ergo_tree)
        .ok_or_else(|| {
            ArgusError::TxBuildFailed("change output not found in unsigned tx".into())
                .to_json_string()
        })?;

    let change_val: i64 = tx.outputs[change_idx].value.parse::<i64>().map_err(|e| {
        ArgusError::TxBuildFailed(format!("invalid change value: {e}")).to_json_string()
    })?;
    let new_change = change_val - delta;
    if new_change < 0 {
        return Err(ArgusError::TxBuildFailed(format!(
            "custom fee {custom_fee} nanoERG exceeds available change {change_val} nanoERG"
        ))
        .to_json_string());
    }
    tx.outputs[fee_idx].value = custom_fee.to_string();
    // The change box is the sole carrier of leftover tokens — never erase it.
    let carries_tokens = !tx.outputs[change_idx].assets.is_empty();
    if new_change == 0 && carries_tokens {
        return Err(ArgusError::TxBuildFailed(
            "custom fee would remove the change box holding tokens; lower the fee".into(),
        )
        .to_json_string());
    }
    let mut final_fee = custom_fee;
    if new_change == 0 || (!carries_tokens && new_change < MIN_BOX_VALUE_NANO) {
        // Dust change folds into the miner fee rather than failing the send.
        final_fee = i64::checked_add(custom_fee, new_change).ok_or_else(|| {
            ArgusError::TxBuildFailed("custom fee out of range".into()).to_json_string()
        })?;
        tx.outputs[fee_idx].value = final_fee.to_string();
        tx.outputs.remove(change_idx);
    } else {
        tx.outputs[change_idx].value = new_change.to_string();
    }
    Ok(final_fee)
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

fn with_handle<T>(
    handle_id: u64,
    op: &'static str,
    f: impl FnOnce(&WalletHandle) -> Result<T, String>,
) -> Result<T, String> {
    let handles = recover(HANDLES.lock());
    let handle = handles
        .get(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound(op, handle_id).to_json_string())?;
    f(handle)
}

/// Connected clients by preferred URL, kept for a minute. Every call used
/// to reconnect and probe `/info` first; a refresh is a dozen calls, so the
/// probes alone cost seconds on a public node. A node that dies inside
/// the minute fails its calls until the entry expires, which the sync
/// reports as stale rather than hiding.
static NODE_CLIENTS: Mutex<Option<HashMap<String, (std::time::Instant, ErgoNodeClient)>>> =
    Mutex::new(None);
const NODE_CLIENT_TTL: std::time::Duration = std::time::Duration::from_secs(60);

fn clear_node_clients() {
    if let Some(map) = recover(NODE_CLIENTS.lock()).as_mut() {
        map.clear();
    }
}

async fn node_client(node_url: Option<String>) -> Result<ErgoNodeClient, String> {
    let key = node_url.clone().unwrap_or_default();
    if let Some(map) = recover(NODE_CLIENTS.lock()).as_ref() {
        if let Some((at, client)) = map.get(&key) {
            if at.elapsed() < NODE_CLIENT_TTL {
                return Ok(client.clone());
            }
        }
    }
    let client = ErgoNodeClient::connect(node_url)
        .await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;
    recover(NODE_CLIENTS.lock())
        .get_or_insert_with(HashMap::new)
        .insert(key, (std::time::Instant::now(), client.clone()));
    Ok(client)
}

#[flutter_rust_bridge::frb]
pub fn set_network(node_urls: Vec<String>, explorer_url: Option<String>) {
    wallet_net::client::set_network(node_urls, explorer_url);
    clear_node_clients();
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
    let encrypted =
        wallet_core::EncryptedSeed::encrypt(&phrase.to_seed(passphrase).map_err(err_str)?)
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
pub fn wallet_restore(
    encrypted_seed_json: String,
    wrap_key: Option<String>,
) -> Result<u64, String> {
    let json: serde_json::Value = serde_json::from_str(&encrypted_seed_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let encrypted =
        wallet_core::EncryptedSeed::from_json(&json, wrap_key.as_deref()).map_err(err_str)?;
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
    with_handle(handle_id, "derive_address", |h| {
        h.derive_address(index).map_err(err_str)
    })
}

#[flutter_rust_bridge::frb]
pub fn create_encrypted_seed(
    mnemonic_phrase: String,
    passphrase: String,
) -> Result<String, String> {
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
        let reduced =
            wallet_core::transaction::deserialize_reduced(&reduced_tx_bytes).map_err(err_str)?;
        let signed_tx = handle.sign_reduced(reduced).map_err(err_str)?;
        serde_json::to_value(&signed_tx)
            .map(|v| v.to_string())
            .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
    })
}

/// Human summary of an ErgoPay reduced transaction: inputs (with values and
/// tokens when the node can supply the boxes), outputs classified as
/// recipient / change / fee, and totals. See `api_ergopay_impl`.
#[flutter_rust_bridge::frb]
pub async fn describe_reduced_transaction(
    handle_id: u64,
    reduced_tx_bytes: Vec<u8>,
    node_url: Option<String>,
) -> Result<String, String> {
    let reduced =
        wallet_core::transaction::deserialize_reduced(&reduced_tx_bytes).map_err(err_str)?;
    // Input boxes are best effort: a node without the box (spent, pruned,
    // unreachable) still leaves the outputs and fee readable.
    let mut input_boxes = Vec::new();
    if let Ok(client) = node_client(node_url).await {
        for input in reduced.unsigned_tx.inputs.iter() {
            let id: String = input.box_id.clone().into();
            input_boxes.push(client.get_blockchain_box_by_id(&id).await.ok());
        }
    } else {
        input_boxes.resize(reduced.unsigned_tx.inputs.len(), None);
    }
    let summary = with_handle(handle_id, "describe_reduced_transaction", |handle| {
        Ok(crate::api_ergopay_impl::summarize_reduced(
            &reduced,
            &|addr| handle.owns_address(addr).unwrap_or(false),
            &input_boxes,
        ))
    })?;
    serde_json::to_string(&summary)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Broadcast an already signed transaction (node JSON) and return its id.
#[flutter_rust_bridge::frb]
pub async fn submit_signed_transaction(
    tx_json: String,
    node_url: Option<String>,
) -> Result<String, String> {
    let value: serde_json::Value = serde_json::from_str(&tx_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let client = node_client(node_url).await?;
    client
        .submit_transaction(&value)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())
}

/// True when `address` is an EIP-3 child of the unlocked wallet.
#[flutter_rust_bridge::frb]
pub fn wallet_owns_address(handle_id: u64, address: String) -> Result<bool, String> {
    with_handle(handle_id, "wallet_owns_address", |handle| {
        handle.owns_address(&address).map_err(err_str)
    })
}

// ─── Stealth addresses ───────────────────────────────────────────────────
//
// A stealth address publishes `u = g^x`; a sender pays a one-time script
// `proveDHTuple(g^r, g^y, u^r, u^y)`. Wire-compatible with ErgoMixer, so
// payments work in both directions with its users. See
// `docs/superpowers/specs/2026-09-04-stealth-addresses-design.md`.

/// This wallet's published `stealth…` string. Requires an unlocked wallet.
#[flutter_rust_bridge::frb]
pub fn stealth_address(handle_id: u64) -> Result<String, String> {
    with_handle(handle_id, "stealth_address", |h| {
        h.stealth_address().map_err(err_str)
    })
}

/// `sha256` of the stealth script template — the path segment for the
/// explorer's `boxes/unspent/byErgoTreeTemplateHash/{hash}` endpoint.
#[flutter_rust_bridge::frb(sync)]
pub fn stealth_template_hash() -> String {
    stealth::stealth_template_hash_hex()
}

/// The BIP-32 path the stealth secret is derived on, for display in Settings.
#[flutter_rust_bridge::frb(sync)]
pub fn stealth_derivation_path() -> String {
    stealth::STEALTH_DERIVATION_PATH.to_string()
}

/// Validate a `stealth…` string: prefix, Base58, length, blake2b checksum
/// and that the key is a point on the curve.
#[flutter_rust_bridge::frb(sync)]
pub fn validate_stealth_address(address: String) -> bool {
    stealth::is_stealth_address(&address)
}

/// True when a recipient string was *meant* to be a stealth address, so the
/// UI can say "bad checksum" rather than "unknown address".
#[flutter_rust_bridge::frb(sync)]
pub fn looks_like_stealth_address(address: String) -> bool {
    stealth::looks_like_stealth_address(&address)
}

/// Derive a fresh one-time payment address for a `stealth…` recipient.
///
/// Call this once per payment: `r` and `y` are drawn here and discarded, so
/// two calls for the same recipient return unlinkable addresses.
#[flutter_rust_bridge::frb]
pub fn stealth_payment_address(stealth_address: String) -> Result<String, String> {
    stealth::payment_address_for_stealth_address(&stealth_address)
        .map_err(|e| ArgusError::InvalidAddress(e.to_string()).to_json_string())
}

/// A fresh one-time address to send our own change to, with its script.
///
/// The script is returned so the wallet can record what it created: money
/// it sent itself must be findable without waiting for a template scan.
#[flutter_rust_bridge::frb]
pub fn stealth_self_change_target(stealth_address: String) -> Result<String, String> {
    let address = stealth::payment_address_for_stealth_address(&stealth_address)
        .map_err(|e| ArgusError::InvalidAddress(e.to_string()).to_json_string())?;
    let tree = address_to_ergo_tree(&address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    serde_json::to_string(&serde_json::json!({ "address": address, "ergo_tree": tree }))
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Given the explorer's response for the stealth template hash, report which
/// boxes this wallet can spend, with ERG and token totals.
///
/// Dart owns the HTTP call (it already has the configured explorer and can
/// degrade to "stealth balance unknown" when it fails); this is the local,
/// private half of detection.
#[flutter_rust_bridge::frb]
pub fn stealth_scan(handle_id: u64, explorer_boxes_json: String) -> Result<String, String> {
    // Take the secret under the handle lock, then scan outside it: the box
    // list is sized by the network, and every other FFI call would block.
    let secret = with_handle(handle_id, "stealth_scan", |h| {
        h.stealth_secret().map_err(err_str)
    })?;
    crate::api_stealth_impl::scan(&secret, &explorer_boxes_json)
}

/// Prepare a transaction moving every owned stealth box to one of this
/// wallet's own addresses. Confirm and broadcast it with `send_erg`.
#[flutter_rust_bridge::frb]
pub async fn prepare_stealth_sweep(
    handle_id: u64,
    explorer_boxes_json: String,
    destination_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    // Only the ownership check and the secret need the handle lock; parsing
    // and per-box scalar work happen after it is released.
    let secret = with_handle(handle_id, "prepare_stealth_sweep", |h| {
        if !h.owns_address(&destination_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "stealth sweep destination is not an address of this wallet".into(),
            )
            .to_json_string());
        }
        h.stealth_secret().map_err(err_str)
    })?;
    let all = stealth::parse_explorer_boxes(&explorer_boxes_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let owned = stealth::detect_owned(&secret, &all);
    if owned.is_empty() {
        return Err(ArgusError::NoUtxos("no stealth boxes to sweep".into()).to_json_string());
    }

    let inputs = owned
        .iter()
        .map(crate::api_stealth_impl::to_input)
        .collect::<Vec<_>>();
    let ergo_boxes = owned
        .iter()
        .map(crate::api_stealth_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let stealth_trees = owned
        .iter()
        .map(|b| b.ergo_tree.clone())
        .collect::<Vec<_>>();

    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let destination_tree = address_to_ergo_tree(&destination_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let built = crate::api_stealth_impl::build_sweep(&inputs, &destination_tree, height, fee_nano)?;

    let input_boxes = input_boxes_json(&inputs);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees,
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx: built.unsigned_tx,
        miner_fee: built.miner_fee,
        change_erg: 0,
        recipient_erg: built.swept_erg,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "recipient": destination_address,
        "amount_nano_erg": built.swept_erg,
        "miner_fee": built.miner_fee,
        "change_nano_erg": 0,
        "input_count": built.input_count,
        "token_count": built.token_count,
        "citadel_fee_nano": built.app_fee_nano,
        "input_boxes": input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub fn generate_mnemonic(strength: u32) -> Result<String, String> {
    use ergo_lib::wallet::mnemonic_generator::{Language, MnemonicGenerator};

    // All five BIP-39 strengths are supported; 160-bit (15 words) is the
    // Ergo ecosystem standard. Unknown values are rejected rather than
    // silently substituted.
    let strength = match strength {
        128 | 160 | 192 | 224 | 256 => strength,
        other => {
            return Err(ArgusError::InvalidMnemonic(format!(
                "unsupported mnemonic strength {other}: use 128, 160, 192, 224, or 256"
            ))
            .to_json_string())
        }
    };
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

/// Validate an Ergo address (base58) against the checksum and network prefix.
#[flutter_rust_bridge::frb]
pub fn validate_ergo_address(address: String) -> bool {
    address_to_ergo_tree(&address).is_ok()
}

#[flutter_rust_bridge::frb]
pub async fn get_balance(address: String, node_url: Option<String>) -> Result<String, String> {
    let client = node_client(node_url).await?;
    // One listing serves both the confirmed figure and the mempool netting.
    let (boxes, _) = client
        .get_unspent(&address)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let nano: u64 = boxes
        .iter()
        .fold(0u64, |acc, b| acc.saturating_add(*b.value.as_u64()));
    let mut tokens: Vec<(String, u64)> = {
        let mut by_id: HashMap<String, u64> = HashMap::new();
        for b in &boxes {
            if let Some(held) = b.tokens.as_ref() {
                for t in held.iter() {
                    let id: String = t.token_id.clone().into();
                    let entry = by_id.entry(id).or_insert(0);
                    *entry = entry.saturating_add(*t.amount.as_u64());
                }
            }
        }
        by_id.into_iter().collect()
    };

    // Mempool delta: unconfirmed sends drop the balance before they confirm.
    // Any mempool failure degrades to the confirmed figure — never fail here.
    let mut delta: i64 = 0;
    if let Ok(tree) = address_to_ergo_tree(&address) {
        if let Ok(txs) = client.mempool_txs_for(&tree).await {
            if !txs.is_empty() {
                {
                    let mut confirmed_values: std::collections::HashMap<String, i64> =
                        std::collections::HashMap::new();
                    let mut confirmed_tokens: std::collections::HashMap<
                        String,
                        Vec<(String, i64)>,
                    > = std::collections::HashMap::new();
                    for b in &boxes {
                        confirmed_values.insert(b.box_id().to_string(), b.value.as_i64());
                        if let Some(held) = b.tokens.as_ref() {
                            let held: Vec<(String, i64)> = held
                                .iter()
                                .map(|t| (t.token_id.clone().into(), *t.amount.as_u64() as i64))
                                .collect();
                            if !held.is_empty() {
                                confirmed_tokens.insert(b.box_id().to_string(), held);
                            }
                        }
                    }
                    delta = wallet_net::mempool::balance_delta(&txs, &tree, &confirmed_values);
                    // Pending token spends reduce the reported amounts under
                    // the same ownership and spent-set rules as the ERG delta.
                    let token_delta =
                        wallet_net::mempool::token_deltas(&txs, &tree, &confirmed_tokens);
                    if !token_delta.is_empty() {
                        let mut by_id: std::collections::HashMap<String, u64> =
                            tokens.into_iter().collect();
                        for (id, d) in token_delta {
                            let confirmed = *by_id.get(&id).unwrap_or(&0);
                            let updated = (confirmed as i64 + d).max(0) as u64;
                            // Positive deltas introduce tokens the address
                            // holds only in the mempool (pending arrivals).
                            if updated > 0 || by_id.contains_key(&id) {
                                by_id.insert(id, updated);
                            }
                        }
                        tokens = by_id.into_iter().collect();
                    }
                }
            }
        }
    }

    serde_json::to_string(&serde_json::json!({
        "balance_nano_erg": (nano as i64 + delta).max(0),
        "tokens": tokens_json(&tokens),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub async fn get_token_info(
    token_id: String,
    explorer_url: Option<String>,
) -> Result<String, String> {
    let mut info = wallet_net::client::get_token_info(&token_id, explorer_url.as_deref())
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    // EIP-4 media: the issuance box (IndexedToken.boxId) carries the asset
    // type in R7 and a link in R9. Best effort — a plain token has neither.
    if let Some(box_id) = info
        .get("boxId")
        .and_then(|b| b.as_str())
        .map(str::to_string)
    {
        if let Ok(client) = node_client(None).await {
            if let Ok(bx) = client.get_blockchain_box_by_id(&box_id).await {
                let regs = bx.get("additionalRegisters");
                let kind = regs
                    .and_then(|r| r.get("R7"))
                    .and_then(|v| v.as_str())
                    .and_then(crate::api_ergopay_impl::eip4_media_kind);
                let link = regs
                    .and_then(|r| r.get("R9"))
                    .and_then(|v| v.as_str())
                    .and_then(crate::api_ergopay_impl::decode_coll_byte_register)
                    .filter(|l| crate::api_ergopay_impl::is_media_link(l));
                if let Some(obj) = info.as_object_mut() {
                    if let Some(k) = kind {
                        obj.insert("mediaKind".into(), serde_json::Value::String(k.into()));
                    }
                    if let Some(l) = link {
                        obj.insert("iconUrl".into(), serde_json::Value::String(l.trim().into()));
                    }
                }
            }
        }
    }
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

/// Unconfirmed transactions for the wallet's addresses, as activity entries.
///
/// Same shape as confirmed history entries (`TxSummary`) plus `confirmed:
/// false`, so the dashboard renders them through the same tile — `height: 0`
/// is what drives its Pending badge. The queried node endpoint needs no extra
/// index; any per-address failure simply yields no entries from that address.
/// A transaction touching several wallet addresses is returned once.
#[flutter_rust_bridge::frb]
pub async fn get_pending_transactions(
    addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let client = node_client(node_url).await?;

    let addrs: Vec<String> = addresses.into_iter().filter(|a| !a.is_empty()).collect();

    let mut join_set = tokio::task::JoinSet::new();
    for addr in &addrs {
        let client_c = client.clone();
        let addr = addr.clone();
        join_set.spawn(async move {
            match address_to_ergo_tree(&addr) {
                Ok(tree) => client_c.mempool_txs_for(&tree).await.unwrap_or_default(),
                Err(_) => Vec::new(),
            }
        });
    }
    // The confirmed listings run alongside the mempool reads instead of
    // one after another once those are in.
    let mut unspent_set = tokio::task::JoinSet::new();
    for addr in &addrs {
        let client_c = client.clone();
        let addr = addr.clone();
        unspent_set.spawn(async move {
            client_c
                .get_unspent(&addr)
                .await
                .map(|(boxes, _)| boxes)
                .unwrap_or_default()
        });
    }

    // Collect uniquely by ID first: a transaction touching several wallet
    // addresses surfaces once, regardless of which fetch completes first.
    let mut seen = std::collections::HashSet::new();
    let mut unique: Vec<serde_json::Value> = Vec::new();
    while let Some(res) = join_set.join_next().await {
        let txs = res.unwrap_or_default();
        for tx in txs {
            let id = match tx["id"].as_str() {
                Some(i) => i.to_string(),
                None => continue,
            };
            if seen.insert(id) {
                unique.push(tx);
            }
        }
    }

    // Wallet-wide context: combined confirmed values and every owned tree, so
    // each transaction is valued exactly once from the whole wallet's
    // perspective instead of whichever address saw it first.
    let mut trees = std::collections::HashSet::new();
    let mut confirmed_values: std::collections::HashMap<String, i64> =
        std::collections::HashMap::new();
    for addr in &addrs {
        if let Ok(tree) = address_to_ergo_tree(addr) {
            trees.insert(tree);
        }
    }
    while let Some(res) = unspent_set.join_next().await {
        for b in res.unwrap_or_default() {
            confirmed_values.insert(b.box_id().to_string(), b.value.as_i64());
        }
    }

    let mut out = Vec::new();
    for tx in &unique {
        let id = match tx["id"].as_str() {
            Some(i) => i.to_string(),
            None => continue,
        };
        let v = wallet_net::mempool::wallet_balance_delta(
            std::slice::from_ref(tx),
            &trees,
            &confirmed_values,
        );
        let token_ids: Vec<String> = tx["outputs"]
            .as_array()
            .map(|outs| {
                outs.iter()
                    .filter_map(|o| o["assets"].as_array())
                    .flatten()
                    .filter_map(|a| a["tokenId"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        // Tokens arriving at any wallet address (mempool outputs paying an
        // owned tree), so the activity list can render incoming amounts.
        let mut received: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
        if let Some(outs) = tx["outputs"].as_array() {
            for o in outs {
                let tree_owned = o["ergoTree"]
                    .as_str()
                    .map(|t| trees.contains(t))
                    .unwrap_or(false);
                if !tree_owned {
                    continue;
                }
                if let Some(assets) = o["assets"].as_array() {
                    for a in assets {
                        if let Some(tid) = a["tokenId"].as_str() {
                            let entry = received.entry(tid.to_string()).or_insert(0);
                            *entry = entry.saturating_add(a["amount"].as_u64().unwrap_or(0));
                        }
                    }
                }
            }
        }
        out.push(serde_json::json!({
            "tx_id": id,
            "height": 0u64,
            "timestamp": 0u64,
            "value_nano_erg": v,
            "token_ids": token_ids,
            "tokens_received": received.into_iter().map(|(token_id, amount)| {
                serde_json::json!({"token_id": token_id, "amount": amount})
            }).collect::<Vec<_>>(),
            "num_inputs": tx["inputs"].as_array().map(|a| a.len() as u32).unwrap_or(0),
            "num_outputs": tx["outputs"].as_array().map(|a| a.len() as u32).unwrap_or(0),
            "confirmed": false,
        }));
    }

    serde_json::to_string(&out)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

const MAX_DISCOVERY: u32 = 512;

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
        .track_singleton_lineage(
            &singleton_token_id,
            &starting_box_id,
            max_hops.unwrap_or(50),
        )
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

/// A recipient's tokens: the `tokens` array when it has any, else the
/// single `token_id`/`token_amount` pair. The two shapes are alternatives,
/// never added together. A caller sending one token writes both, so that
/// the single-recipient path can read the pair, and summing them would
/// send twice what was asked for.
fn parse_recipient_tokens(rcpt: &serde_json::Value) -> Result<Vec<(String, u64)>, String> {
    if let Some(list) = rcpt["tokens"].as_array() {
        if !list.is_empty() {
            let mut tokens = Vec::with_capacity(list.len());
            for t in list {
                if let Some(pair) = resolve_send_token(
                    t["token_id"].as_str().map(|id| id.to_string()),
                    t["amount"].as_u64(),
                )? {
                    tokens.push(pair);
                }
            }
            return Ok(tokens);
        }
    }
    Ok(resolve_send_token(
        rcpt["token_id"].as_str().map(|id| id.to_string()),
        rcpt["token_amount"].as_u64(),
    )?
    .into_iter()
    .collect())
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

/// A babel box (EIP-31) able to pay `fee` in `token_id`, as both the
/// signing box and the EIP-12 input, with the box read.
struct BabelPick {
    babel: ergo_tx::BabelBox,
    eip12: ergo_tx::Eip12InputBox,
    ergo_box: ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox,
}

/// The best babel box on the node for `token_id`: the one asking the
/// fewest tokens for `fee` that still stays a box afterwards.
async fn find_babel(
    client: &ErgoNodeClient,
    token_id: &str,
    fee: i64,
) -> Result<BabelPick, String> {
    let tree = ergo_tx::babel_ergo_tree(token_id);
    let boxes = client
        .unspent_boxes_by_ergo_tree(&tree, 0, 100)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let mut best: Option<BabelPick> = None;
    for item in boxes {
        // Both shapes from the same item: the signer's box and the
        // builder's input.
        let (Ok(ergo_box), Ok(eip12)) = (
            serde_json::from_value::<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>(item.clone()),
            serde_json::from_value::<ergo_tx::Eip12InputBox>(item),
        ) else {
            continue;
        };
        let Ok(babel) = ergo_tx::BabelBox::parse(&eip12, token_id) else { continue };
        if !babel.can_pay(fee) {
            continue;
        }
        if best.as_ref().map(|p| babel.price > p.babel.price).unwrap_or(true) {
            best = Some(BabelPick { babel, eip12, ergo_box });
        }
    }
    best.ok_or_else(|| {
        ArgusError::TxBuildFailed(
            "no babel fee box offers to take this token for the fee right now".into(),
        )
        .to_json_string()
    })
}

/// Add boxes from `pool` to `selected` until they hold `need` of `token`.
fn ensure_token(
    selected: &mut Vec<ergo_tx::Eip12InputBox>,
    pool: &[ergo_tx::Eip12InputBox],
    token: &str,
    need: u64,
) -> Result<(), String> {
    let held = |set: &[ergo_tx::Eip12InputBox]| -> u64 {
        set.iter()
            .flat_map(|b| b.assets.iter())
            .filter(|a| a.token_id.eq_ignore_ascii_case(token))
            .map(|a| a.amount.parse::<u64>().unwrap_or(0))
            .sum()
    };
    let mut have = held(selected);
    for b in pool {
        if have >= need {
            break;
        }
        if selected.iter().any(|s| s.box_id == b.box_id) {
            continue;
        }
        let in_box = held(std::slice::from_ref(b));
        if in_box > 0 {
            have += in_box;
            selected.push(b.clone());
        }
    }
    if have < need {
        return Err(ArgusError::TxBuildFailed(format!(
            "the wallet holds {have} of the fee token but the fee needs {need}"
        ))
        .to_json_string());
    }
    Ok(())
}

fn babel_json(s: &ergo_tx::BabelSummary) -> serde_json::Value {
    serde_json::json!({
        "token_id": s.token_id,
        "tokens_paid": s.tokens_paid,
        "price": s.price,
        "fee_nano": s.fee_nano,
        "babel_box_id": s.babel_box_id,
    })
}

/// Boxes set aside for a pending mix: the funding box a self-send made,
/// waiting for the entry that spends it. Anything else that selects
/// coins (a send, a swap, another mix's funding, the UTXO tools) must
/// leave it alone, or the entry finds no box and the mix sits pending.
/// Keyed by wallet handle; the app keeps it current from its mix records.
#[derive(Clone, Debug, serde::Deserialize, PartialEq, Eq)]
struct FundingReservation {
    /// Every output of the funding transaction; only the one of the
    /// funding's exact value with no tokens is the funding box, so the
    /// change is not held back.
    box_ids: Vec<String>,
    value_nano_erg: i64,
}

impl FundingReservation {
    /// The funding box: one of the funding transaction's outputs with the
    /// funding's exact value and no tokens. A tokenless change box of the
    /// same value would be held too; that never under-reserves, and it
    /// frees itself when the entry commits.
    fn covers(&self, b: &ergo_tx::Eip12InputBox) -> bool {
        self.box_ids.iter().any(|id| id == &b.box_id)
            && b.assets.is_empty()
            && b.value.parse::<i64>().ok() == Some(self.value_nano_erg)
    }
}

/// Boxes that came out of a mix, per wallet handle. Automatic coin
/// selection never touches them, and a hand-picked set may hold them only
/// on their own: one transaction spending a mixed box next to an ordinary
/// one tells the chain they share an owner, which is what the mix cost
/// money to hide.
static MIXED_BOXES: Lazy<Mutex<HashMap<u64, HashSet<String>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Tell coin selection which boxes came out of a mix; an empty list frees them.
#[flutter_rust_bridge::frb(sync)]
pub fn mix_set_mixed_boxes(handle_id: u64, box_ids: Vec<String>) -> Result<(), String> {
    let mut all = recover(MIXED_BOXES.lock());
    if box_ids.is_empty() {
        all.remove(&handle_id);
    } else {
        all.insert(handle_id, box_ids.into_iter().collect());
    }
    Ok(())
}

/// The mixed-box rule over box ids: which of `available` may be offered.
/// With no choice made, mixed boxes are left out; with a choice, it must be
/// all mixed or none.
fn mixed_rule<'a>(
    mixed: &HashSet<String>,
    available: impl Iterator<Item = &'a str>,
    selected_box_ids: Option<&[String]>,
) -> Result<HashSet<String>, String> {
    match selected_box_ids.filter(|ids| !ids.is_empty()) {
        None => Ok(available
            .filter(|id| !mixed.contains(*id))
            .map(str::to_string)
            .collect()),
        Some(ids) => {
            let chosen_mixed = ids.iter().filter(|id| mixed.contains(*id)).count();
            if chosen_mixed > 0 && chosen_mixed < ids.len() {
                return Err(ArgusError::TxBuildFailed(
                    "the chosen boxes mix coins that came out of a mix with ordinary ones; \
                     spending them together ties the mixed money back to this wallet and \
                     undoes the mix. Choose only mixed boxes, or none of them"
                        .into(),
                )
                .to_json_string());
            }
            Ok(available.map(str::to_string).collect())
        }
    }
}

/// [`mixed_rule`] applied to a wallet's spendable boxes.
fn apply_mixed_rule(
    handle_id: u64,
    boxes: Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
    eip12: Vec<ergo_tx::Eip12InputBox>,
    selected_box_ids: Option<&[String]>,
) -> Result<
    (
        Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
        Vec<ergo_tx::Eip12InputBox>,
    ),
    String,
> {
    let mixed = recover(MIXED_BOXES.lock())
        .get(&handle_id)
        .cloned()
        .unwrap_or_default();
    if mixed.is_empty() {
        return Ok((boxes, eip12));
    }
    let keep = mixed_rule(&mixed, eip12.iter().map(|e| e.box_id.as_str()), selected_box_ids)?;
    Ok(boxes
        .into_iter()
        .zip(eip12)
        .filter(|(_, e)| keep.contains(&e.box_id))
        .unzip())
}

static RESERVED_FUNDING: Lazy<Mutex<HashMap<u64, Vec<FundingReservation>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Set aside the funding boxes of this wallet's pending mixes. Replaces
/// the previous set for the handle; an empty list frees everything.
/// `reservations_json`: `[{"box_ids": [...], "value_nano_erg": 1006600000}]`.
#[flutter_rust_bridge::frb(sync)]
pub fn mix_set_reserved_funding(handle_id: u64, reservations_json: String) -> Result<(), String> {
    let list: Vec<FundingReservation> = serde_json::from_str(&reservations_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let mut all = recover(RESERVED_FUNDING.lock());
    if list.is_empty() {
        all.remove(&handle_id);
    } else {
        all.insert(handle_id, list);
    }
    Ok(())
}

/// Drop the boxes a pending mix has set aside (see [`FundingReservation`]).
fn without_reserved(
    handle_id: u64,
    boxes: Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
    eip12: Vec<ergo_tx::Eip12InputBox>,
) -> (
    Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
    Vec<ergo_tx::Eip12InputBox>,
) {
    let reserved = recover(RESERVED_FUNDING.lock())
        .get(&handle_id)
        .cloned()
        .unwrap_or_default();
    if reserved.is_empty() {
        return (boxes, eip12);
    }
    boxes
        .into_iter()
        .zip(eip12)
        .filter(|(_, e)| !reserved.iter().any(|r| r.covers(e)))
        .unzip()
}

/// The wallet's unspent boxes, less what a pending mix has set aside.
async fn gather_unspent(
    handle_id: u64,
    client: &ErgoNodeClient,
    addresses: &[String],
) -> Result<
    (
        Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
        Vec<ergo_tx::Eip12InputBox>,
    ),
    String,
> {
    let (boxes, eip12) = gather_unspent_all(handle_id, client, addresses).await?;
    Ok(without_reserved(handle_id, boxes, eip12))
}

/// Every unspent box, reserved ones included: for the mix entry itself.
async fn gather_unspent_all(
    handle_id: u64,
    client: &ErgoNodeClient,
    addresses: &[String],
) -> Result<
    (
        Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
        Vec<ergo_tx::Eip12InputBox>,
    ),
    String,
> {
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
            .get_effective_unspent(addr)
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
        .map(|b| {
            serde_json::json!({
                "box_id": b.box_id,
                "value_nano_erg": b.value,
                "creation_height": b.creation_height,
                "assets": b.assets.iter().map(|a| serde_json::json!({
                    "token_id": a.token_id,
                    "amount": a.amount,
                })).collect::<Vec<_>>(),
            })
        })
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
    let selected_ids = selected_box_ids
        .iter()
        .map(String::as_str)
        .collect::<HashSet<_>>();
    if selected_ids.is_empty() {
        return Ok(inputs);
    }
    let available_ids = inputs
        .iter()
        .map(|input| input.box_id.as_str())
        .collect::<HashSet<_>>();
    let mut missing = selected_ids
        .difference(&available_ids)
        .copied()
        .collect::<Vec<_>>();
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
    let (boxes, inputs) = apply_mixed_rule(handle_id, boxes, inputs, Some(selected_box_ids))?;
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
        let applied_fee = apply_custom_fee(
            &mut built.unsigned_tx,
            &change_tree,
            built.miner_fee,
            custom_fee,
        )?;
        built.miner_fee = applied_fee;
        built.change_erg = built
            .unsigned_tx
            .outputs
            .iter()
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
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
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

/// True when `address` is one this wallet can spend from: a derived
/// address, or a stealth script its stealth key owns.
///
/// Stealth change is a payment to ourselves on a fresh one-time script, so
/// it is not among the derived addresses and must be recognised this way.
fn wallet_can_spend_change(h: &wallet_core::WalletHandle, address: &str) -> Result<bool, String> {
    if h.owns_address(address).map_err(err_str)? {
        return Ok(true);
    }
    let tree = match address_to_ergo_tree(address) {
        Ok(t) => t,
        Err(_) => return Ok(false),
    };
    if !stealth::is_stealth_tree(&tree) {
        return Ok(false);
    }
    let secret = h.stealth_secret().map_err(err_str)?;
    Ok(secret.owns_tree(&tree))
}

#[allow(clippy::too_many_arguments)]
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
    input_box_ids: Option<Vec<String>>,
    stealth_boxes_json: Option<String>,
    babel_token_id: Option<String>,
) -> Result<
    (
        Vec<serde_json::Value>,
        Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
        ergo_tx::SendBuildResult,
        Vec<String>,
        Option<ergo_tx::BabelSummary>,
    ),
    String,
> {
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
        if !wallet_can_spend_change(h, change_address)? {
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
    let (mut boxes, mut eip12) = gather_unspent(handle_id, &client, &spend).await?;
    // Stealth boxes sit on one-time scripts, so address discovery cannot
    // find them. Dart passes the explorer's list; only boxes this wallet's
    // stealth key owns are added, and only chosen ones are ever spent.
    let stealth_owned = match stealth_boxes_json.as_deref() {
        Some(json) if !json.trim().is_empty() => {
            let secret = with_handle(handle_id, "send", |h| h.stealth_secret().map_err(err_str))?;
            let all = stealth::parse_explorer_boxes(json)
                .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
            stealth::detect_owned(&secret, &all)
        }
        _ => Vec::new(),
    };
    for b in &stealth_owned {
        eip12.push(crate::api_stealth_impl::to_input(b));
        boxes.push(crate::api_stealth_impl::to_ergo_box(b)?);
    }
    let (mut boxes, eip12) = apply_mixed_rule(handle_id, boxes, eip12, input_box_ids.as_deref())?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend.join(",")).to_json_string());
    }

    let fee_for_required = fee_nano.unwrap_or(TX_FEE_NANO);
    // With a babel box paying the fee, the wallet's ERG covers only the
    // amount and a change box; the babel box brings the fee's ERG.
    let babel = match babel_token_id.as_deref().filter(|t| !t.is_empty()) {
        Some(t) => Some(find_babel(&client, t, fee_for_required).await?),
        None => None,
    };
    let required = i64::checked_add(amount_nano_erg, if babel.is_some() { 0 } else { fee_for_required })
        .and_then(|v| i64::checked_add(v, MIN_BOX_VALUE_NANO))
        .filter(|v| *v > 0)
        .ok_or_else(|| {
            ArgusError::TxBuildFailed("send amount out of range".into()).to_json_string()
        })? as u64;
    let token_ref = send_token.as_ref().map(|(id, amt)| (id.as_str(), *amt));
    // Coin control: when the user chose boxes, spend exactly those. Falling
    // back to automatic selection here would silently pull in a box they
    // deliberately left out, which is the linking they were avoiding.
    let stealth_ids = stealth_owned
        .iter()
        .map(|b| b.box_id.clone())
        .collect::<Vec<_>>();
    let mut selected = match input_box_ids.as_deref() {
        Some(ids) => select_exact(&eip12, ids, required, token_ref)
            .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?,
        // Automatic selection still avoids putting stealth and ordinary
        // boxes in one input list unless neither pocket can pay alone.
        None => select_preferring_one_pocket(&eip12, &stealth_ids, required, token_ref)
            .map(|(s, _mixed)| s)
            .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?,
    };
    if let Some(pick) = &babel {
        // The fee's worth of the token must be among the inputs too, on
        // top of whatever the send delivers of it.
        let sent_same = send_token
            .as_ref()
            .filter(|(id, _)| id.eq_ignore_ascii_case(&pick.babel.token_id))
            .map(|(_, n)| *n)
            .unwrap_or(0);
        let need = sent_same + pick.babel.tokens_for(fee_for_required);
        ensure_token(&mut selected.boxes, &eip12, &pick.babel.token_id, need)?;
        selected.boxes.push(pick.eip12.clone());
        boxes.push(pick.ergo_box.clone());
    }

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
        &ergo_tx::resolved_dev_fee_config(),
    )
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    let mut built = built;
    if let Some(custom_fee) = fee_nano {
        let applied_fee = apply_custom_fee(
            &mut built.unsigned_tx,
            &change_tree,
            built.summary.miner_fee,
            custom_fee,
        )?;
        built.summary.miner_fee = applied_fee;
        built.summary.change_erg = built
            .unsigned_tx
            .outputs
            .iter()
            .find(|o| o.ergo_tree == change_tree)
            .map(|o| o.value.parse::<i64>().unwrap_or(0))
            .unwrap_or(0);
    }
    let babel_summary = match &babel {
        Some(pick) => {
            let s = ergo_tx::apply_babel(&mut built.unsigned_tx, &pick.babel, &change_tree)
                .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
            built.summary.change_erg = built
                .unsigned_tx
                .outputs
                .iter()
                // From the end, as apply_babel does: a send to the
                // wallet's own change address gives the recipient box the
                // same script, and only the last one is the change.
                .rev()
                .find(|o| o.ergo_tree == change_tree)
                .map(|o| o.value.parse::<i64>().unwrap_or(0))
                .unwrap_or(0);
            Some(s)
        }
        None => None,
    };

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

    // Which of the chosen inputs need a DH-tuple secret at signing time.
    let stealth_trees = selected
        .boxes
        .iter()
        .filter(|b| stealth_owned.iter().any(|s| s.box_id == b.box_id))
        .map(|b| b.ergo_tree.clone())
        .collect::<Vec<_>>();

    let input_boxes = input_boxes_json(&selected.boxes);

    Ok((input_boxes, ergo_boxes, built, stealth_trees, babel_summary))
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
    input_box_ids: Option<Vec<String>>,
    stealth_boxes_json: Option<String>,
    babel_token_id: Option<String>,
) -> Result<String, String> {
    let (input_boxes, ergo_boxes, built, stealth_trees, babel) = prepare(
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
        input_box_ids,
        stealth_boxes_json,
        babel_token_id,
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
        stealth_trees,
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
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
        "babel": babel.as_ref().map(babel_json),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Issue a token (EIP-4): mint `amount` units named `name` into a box of
/// this wallet's `change_address`, with `description` and `decimals`.
/// For an NFT pass `nft_kind` (`picture`, `audio`, `video`), the SHA-256
/// of the content as hex, and its link; amount must be 1 and decimals 0.
/// Confirm with `send_erg`. The token id is known before signing.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn prepare_mint(
    handle_id: u64,
    sender_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    name: String,
    description: String,
    decimals: u8,
    amount: u64,
    nft_kind: Option<String>,
    nft_content_hash_hex: Option<String>,
    nft_url: Option<String>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let nft = match nft_kind.as_deref().filter(|k| !k.is_empty()) {
        Some(kind) => Some(ergo_tx::NftDetails {
            kind: ergo_tx::NftKind::parse(kind).ok_or_else(|| {
                ArgusError::TxBuildFailed(format!("unknown NFT kind {kind:?}")).to_json_string()
            })?,
            content_hash: hex::decode(nft_content_hash_hex.unwrap_or_default())
                .map_err(|e| ArgusError::TxBuildFailed(format!("content hash: {e}")).to_json_string())?,
            url: nft_url.unwrap_or_default(),
        }),
        None => None,
    };
    let spec = ergo_tx::MintSpec {
        name,
        description,
        decimals,
        amount,
        nft,
    };
    let miner_fee = mix_miner_fee(fee_nano)?;
    let user_tree = with_handle(handle_id, "prepare_mint", |h| {
        if !h.owns_address(&change_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress("the token box must go to this wallet".into()).to_json_string());
        }
        address_to_ergo_tree(&change_address).map_err(|e| ArgusError::InvalidAddress(e).to_json_string())
    })?;
    let spend = resolve_spend_addresses(&sender_address, &spend_addresses);
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let (boxes, utxos) = gather_unspent(handle_id, &client, &spend).await?;
    let (_, utxos) = apply_mixed_rule(handle_id, boxes, utxos, None)?;
    let fee_cfg = ergo_tx::resolved_dev_fee_config();
    // The token box, the change box, both fees.
    let required = (2 * MIN_BOX_VALUE_NANO + miner_fee + fee_cfg.budget()) as u64;
    let selected = wallet_core::spend::select_for_send(&utxos, required, None)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let built = ergo_tx::build_mint_tx(&selected.boxes, &spec, &user_tree, height as i32)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let ergo_boxes = selected
        .boxes
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let input_boxes = input_boxes_json(&selected.boxes);
    let summary = built.summary;
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx: built.unsigned_tx,
        miner_fee: summary.miner_fee,
        change_erg: summary.change_erg,
        recipient_erg: summary.box_value,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "token_id": summary.token_id,
        "amount": summary.amount,
        "box_value": summary.box_value,
        "miner_fee": summary.miner_fee,
        "app_fee_nano": summary.citadel_fee_nano,
        "change_nano_erg": summary.change_erg,
        "input_boxes": input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Burn tokens: every input token not in `burns_json` (`[{"token_id":
/// "...", "amount": 5}]`) comes back to `change_address`; the named
/// amounts are left out of every output and so cease to exist. Confirm
/// with `send_erg`. The wallet's ordinary boxes only, never stealth.
#[flutter_rust_bridge::frb]
pub async fn prepare_burn(
    handle_id: u64,
    sender_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    burns_json: String,
    node_url: Option<String>,
) -> Result<String, String> {
    let raw: Vec<serde_json::Value> = serde_json::from_str(&burns_json)
        .map_err(|e| ArgusError::SerializationError(format!("burn list: {e}")).to_json_string())?;
    let mut items: Vec<ergo_tx::BurnItem> = Vec::new();
    for b in raw {
        let token_id = b["token_id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| ArgusError::TxBuildFailed("burn entry without token_id".into()).to_json_string())?
            .to_string();
        let amount = b["amount"]
            .as_u64()
            .filter(|n| *n > 0)
            .ok_or_else(|| ArgusError::TxBuildFailed(format!("burn amount for {token_id} must be positive")).to_json_string())?;
        items.push(ergo_tx::BurnItem { token_id, amount });
    }
    if items.is_empty() {
        return Err(ArgusError::TxBuildFailed("nothing to burn".into()).to_json_string());
    }
    let user_tree = with_handle(handle_id, "prepare_burn", |h| {
        if !h.owns_address(&change_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress("change must go to this wallet".into()).to_json_string());
        }
        address_to_ergo_tree(&change_address).map_err(|e| ArgusError::InvalidAddress(e).to_json_string())
    })?;
    let spend = resolve_spend_addresses(&sender_address, &spend_addresses);
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let (boxes, utxos) = gather_unspent(handle_id, &client, &spend).await?;
    let (_, utxos) = apply_mixed_rule(handle_id, boxes, utxos, None)?;
    // Every box carrying a token to burn must be spent (the builder burns
    // by omission, so the whole holding passes through it), plus ERG for
    // the fees and a change box from wherever.
    let fee_cfg = ergo_tx::resolved_dev_fee_config();
    let mut chosen: Vec<ergo_tx::Eip12InputBox> = utxos
        .iter()
        .filter(|b| b.assets.iter().any(|a| items.iter().any(|i| i.token_id.eq_ignore_ascii_case(&a.token_id))))
        .cloned()
        .collect();
    let have: i64 = chosen.iter().map(|b| b.value.parse::<i64>().unwrap_or(0)).sum();
    let need = TX_FEE_NANO + fee_cfg.budget() + MIN_BOX_VALUE_NANO;
    if have < need {
        let more = wallet_core::spend::select_for_send(
            &utxos.iter().filter(|b| !chosen.iter().any(|c| c.box_id == b.box_id)).cloned().collect::<Vec<_>>(),
            (need - have) as u64,
            None,
        )
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
        chosen.extend(more.boxes);
    }
    let built = ergo_tx::build_multi_burn_tx(&chosen, &items, &user_tree, height as i32)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let ergo_boxes = chosen
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let input_boxes = input_boxes_json(&chosen);
    let summary = built.summary;
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx: built.unsigned_tx,
        miner_fee: summary.miner_fee,
        change_erg: summary.change_erg,
        recipient_erg: 0,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "burned": summary.burned_tokens.iter().map(|b| serde_json::json!({"token_id": b.token_id, "amount": b.amount})).collect::<Vec<_>>(),
        "miner_fee": summary.miner_fee,
        "app_fee_nano": summary.citadel_fee_nano,
        "change_nano_erg": summary.change_erg,
        "input_boxes": input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

// ---------------------------------------------------------------------------
// Rosen bridge: transfers out of Ergo
// ---------------------------------------------------------------------------

/// The bridge as vendored: lock address, fee NFT, contracts version, and
/// every Ergo asset it takes with the chains it can go to. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn rosen_info() -> String {
    serde_json::json!({
        "lock_address": rosen::LOCK_ADDRESS,
        "min_fee_nft": rosen::MIN_FEE_NFT,
        "contracts_version": rosen::CONTRACTS_VERSION,
        "tokens_map_version": rosen::tokens::map_version(),
        "chains": rosen::chains(),
        "tokens": rosen::token_map(),
    })
    .to_string()
}

/// The terms for sending `token_id` (`erg` for ERG) to `to_chain` at
/// `height`, from the minimum-fee boxes given (a list of boxes carrying
/// the fee NFT, any shape), and what `amount` would cost and deliver.
/// Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn rosen_quote(
    fee_boxes_json: String,
    token_id: String,
    to_chain: String,
    amount: i64,
    height: i64,
) -> Result<String, String> {
    let root: serde_json::Value = serde_json::from_str(&fee_boxes_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let boxes: Vec<serde_json::Value> = match root.get("items") {
        Some(v) => v.as_array().cloned().unwrap_or_default(),
        None => root.as_array().cloned().unwrap_or_default(),
    };
    let cfg = rosen::fees::find_fee_box(&boxes, &token_id)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let fee = cfg
        .from_ergo(height, &to_chain)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let quote = fee.quote(amount);
    serde_json::to_string(&serde_json::json!({
        "fee": fee,
        "quote": quote,
        "fee_box_id": cfg.box_id,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Whether `address` is well formed for `chain`; an empty string when it
/// is, the reason otherwise. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn rosen_validate_address(chain: String, address: String) -> String {
    match rosen::validate_address(&chain, &address) {
        Ok(()) => String::new(),
        Err(e) => e.to_string(),
    }
}

/// Prepare a transfer out of Ergo: `amount` of `token_id` (`erg` for ERG)
/// locked for `to_chain` and `to_address`, with the bridge and network
/// fees the quote gave. The lock box records `sender_address` as where a
/// failed transfer comes back to. Confirm with `send_erg`.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn rosen_prepare_lock(
    handle_id: u64,
    sender_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    token_id: String,
    amount: i64,
    to_chain: String,
    to_address: String,
    bridge_fee: i64,
    network_fee: i64,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    if let Err(e) = rosen::validate_address(&to_chain, &to_address) {
        return Err(ArgusError::InvalidAddress(e.to_string()).to_json_string());
    }
    let miner_fee = mix_miner_fee(fee_nano)?;
    let change_tree = with_handle(handle_id, "rosen_prepare_lock", |h| {
        for a in [&sender_address, &change_address] {
            if !h.owns_address(a).map_err(err_str)? {
                return Err(ArgusError::InvalidAddress("transfer addresses must belong to this wallet".into()).to_json_string());
            }
        }
        address_to_ergo_tree(&change_address).map_err(|e| ArgusError::InvalidAddress(e).to_json_string())
    })?;
    let lock_tree = address_to_ergo_tree(rosen::LOCK_ADDRESS)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let is_erg = token_id.eq_ignore_ascii_case("erg");
    let spec = rosen::LockSpec {
        token_id: if is_erg { None } else { Some(token_id.to_ascii_lowercase()) },
        amount,
        to_chain: to_chain.clone(),
        to_address: to_address.trim().to_string(),
        from_address: sender_address.clone(),
        bridge_fee,
        network_fee,
    };
    let spend = resolve_spend_addresses(&sender_address, &spend_addresses);
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let (boxes, utxos) = gather_unspent(handle_id, &client, &spend).await?;
    let (_, utxos) = apply_mixed_rule(handle_id, boxes, utxos, None)?;
    let fee_cfg = ergo_tx::resolved_dev_fee_config();
    let app_fee = if fee_cfg.enabled {
        Some((fee_cfg.recipient_ergo_tree.as_str(), fee_cfg.budget()))
    } else {
        None
    };
    let lock_value = if is_erg { amount } else { rosen::LOCK_MIN_BOX_VALUE };
    let token = if is_erg { None } else { Some((token_id.as_str(), amount as u64)) };
    let mut built = None;
    for extra in [0i64, MIN_BOX_VALUE_NANO] {
        let required = (lock_value + miner_fee + app_fee.map(|(_, n)| n).unwrap_or(0) + extra) as u64;
        let selected = wallet_core::spend::select_for_send(&utxos, required, token)
            .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
        match rosen::build_lock_tx(&selected.boxes, &spec, &lock_tree, &change_tree, app_fee, miner_fee, height as i32) {
            Ok(r) => {
                built = Some((r, selected.boxes));
                break;
            }
            Err(rosen::LockError::InsufficientErg { .. }) if extra == 0 => continue,
            Err(e) => return Err(ArgusError::TxBuildFailed(e.to_string()).to_json_string()),
        }
    }
    let (result, used) = built.ok_or_else(|| {
        ArgusError::TxBuildFailed("could not select inputs for the transfer".into()).to_json_string()
    })?;
    let ergo_boxes = used
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let input_boxes = input_boxes_json(&used);
    let summary = result.summary;
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx: result.unsigned_tx,
        miner_fee: summary.miner_fee,
        change_erg: summary.change_erg,
        recipient_erg: summary.lock_value,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "lock_address": rosen::LOCK_ADDRESS,
        "lock_value": summary.lock_value,
        "miner_fee": summary.miner_fee,
        "app_fee_nano": summary.app_fee_nano,
        "change_nano_erg": summary.change_erg,
        "height": height,
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
        handle_id,
        "consolidate",
        &spend_addresses,
        &selected_box_ids,
        &change_address,
        spend_addresses.join(","),
        node_url,
        fee_nano,
        |inputs, change_tree, height| {
            if inputs.len() < 2 {
                return Err(ArgusError::TxBuildFailed(
                    "Consolidation requires at least 2 input boxes".into(),
                )
                .to_json_string());
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
    )
    .await?;
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
        handle_id,
        "split_erg",
        &spend_addresses,
        &selected_box_ids,
        &change_address,
        "no inputs available for split".into(),
        node_url,
        fee_nano,
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
    )
    .await?;
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
        handle_id,
        "split_token",
        &spend_addresses,
        &selected_box_ids,
        &change_address,
        "no inputs available for split".into(),
        node_url,
        fee_nano,
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
    )
    .await?;
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
    let parsed_specs: Vec<serde_json::Value> =
        serde_json::from_str(&outputs_json).map_err(|e| {
            ArgusError::SerializationError(format!("Invalid outputs JSON: {e}")).to_json_string()
        })?;

    let mut specs = Vec::with_capacity(parsed_specs.len());
    for s in parsed_specs {
        let value = s["value_nano_erg"].as_i64().ok_or_else(|| {
            ArgusError::TxBuildFailed("output missing value_nano_erg".into()).to_json_string()
        })?;
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
        handle_id,
        "restructure",
        &spend_addresses,
        &selected_box_ids,
        &change_address,
        "no inputs available for restructure".into(),
        node_url,
        fee_nano,
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
    )
    .await?;
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

/// Reduce a prepared transaction and sign it, returning the signed transaction
/// as a `serde_json::Value`.
async fn sign_prepared_tx(
    handle_id: u64,
    prep: &CachedPreparation,
    client: &ErgoNodeClient,
    op: &'static str,
) -> Result<serde_json::Value, String> {
    let state_context = client
        .get_state_context()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let reduced_bytes = reduce_transaction_with_context(
        &prep.unsigned_tx,
        prep.ergo_boxes.clone(),
        prep.data_input_boxes.clone(),
        &state_context,
    )
    .map_err(|e| ArgusError::TxReductionFailed(e.to_string()).to_json_string())?;

    with_handle(handle_id, op, |handle| {
        let reduced = ReducedTransaction::sigma_parse_bytes(&reduced_bytes)
            .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
        // Stealth inputs need a DH-tuple secret each, derived here and dropped
        // with the throwaway prover; ordinary sends take the unchanged path.
        let signed_tx = if prep.stealth_trees.is_empty() && prep.mix_proofs.is_empty() {
            handle.sign_reduced(reduced).map_err(err_str)?
        } else {
            let mut extra = crate::api_stealth_impl::dht_secrets_for(handle, &prep.stealth_trees)?;
            extra.extend(crate::api_mix_impl::secrets_for(
                handle,
                &prep.mix_proofs,
                &prep.ergo_boxes,
            )?);
            handle
                .sign_reduced_with_secrets(reduced, extra)
                .map_err(err_str)?
        };
        serde_json::to_value(&signed_tx)
            .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
    })
}

#[flutter_rust_bridge::frb]
pub async fn send_erg(handle_id: u64, preparation_id: u64) -> Result<String, String> {
    let prep = take_preparation(handle_id, preparation_id)?;
    let client = node_client(prep.node_url.clone()).await?;
    let tx_json = sign_prepared_tx(handle_id, &prep, &client, "send_erg").await?;

    let tx_id = client
        .submit_transaction(&tx_json)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    // The outputs' ids, so a caller that needs one specific box of this
    // transaction (a mix's funding box) can find it by id rather than by
    // guessing from its value. Ids cover no proofs, so they match the
    // broadcast transaction; best effort, never a reason to fail a send.
    let output_box_ids: Vec<String> = ergo_tx::chain::derive_output_boxes(&prep.unsigned_tx)
        .map(|(_, outs)| outs.into_iter().map(|b| b.box_id).collect())
        .unwrap_or_default();

    // What the wallet's balance moves by once the mempool shows this
    // transaction: outputs back to us minus the inputs we spent. The app
    // shows the row and the figure at once instead of waiting for a poll.
    // Only for an ordinary spend: a stealth sweep or a mix move spends
    // boxes outside the public balance, so no figure is offered and the
    // node's view is waited for.
    let wallet_delta = if prep.stealth_trees.is_empty() && prep.mix_proofs.is_empty() {
        Some(wallet_delta_nano_erg(handle_id, &prep.unsigned_tx, &prep.ergo_boxes))
    } else {
        None
    };

    serde_json::to_string(&serde_json::json!({
        "tx_id": tx_id,
        "preparation_id": preparation_id,
        "miner_fee": prep.miner_fee,
        "change_nano_erg": prep.change_erg,
        "amount_nano_erg": prep.recipient_erg,
        "output_box_ids": output_box_ids,
        "wallet_delta_nano_erg": wallet_delta,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Net nanoERG change for the wallet: its outputs minus the inputs, all of
/// which a preparation spends from the wallet. Unknown ownership counts an
/// output as foreign, so the figure errs towards a larger spend.
fn wallet_delta_nano_erg(
    handle_id: u64,
    unsigned: &ergo_tx::Eip12UnsignedTx,
    inputs: &[ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox],
) -> i64 {
    let spent: i64 = inputs.iter().map(|b| b.value.as_i64()).sum();
    let mut back: i64 = 0;
    for out in &unsigned.outputs {
        let owned = ergo_tx::address::ergo_tree_to_address(&out.ergo_tree)
            .ok()
            .map(|addr| {
                with_handle(handle_id, "wallet_delta", |h| {
                    h.owns_address(&addr).map_err(err_str)
                })
                .unwrap_or(false)
            })
            .unwrap_or(false);
        if owned {
            back += out.value.parse::<i64>().unwrap_or(0);
        }
    }
    back - spent
}

/// The transaction behind a preparation, summarised for a confirm sheet's
/// details: inputs, outputs by kind (recipient, change, miner fee, app
/// fee), data inputs, and the unsigned EIP-12 JSON for the user to copy.
/// Does not consume the preparation.
#[flutter_rust_bridge::frb]
pub fn preparation_details(handle_id: u64, preparation_id: u64) -> Result<String, String> {
    let (unsigned, boxes, data_inputs, miner_fee) = {
        let cache = recover(PREPARATIONS.lock());
        let p = cache
            .get(&preparation_id)
            .filter(|p| p.handle_id == handle_id)
            .ok_or_else(|| {
                ArgusError::TxBuildFailed("unknown or stale send preparation".into())
                    .to_json_string()
            })?;
        (
            p.unsigned_tx.clone(),
            p.ergo_boxes.clone(),
            p.data_input_boxes
                .iter()
                .map(|b| b.box_id().to_string())
                .collect::<Vec<_>>(),
            p.miner_fee,
        )
    };
    let tx = ergo_tx::chain::to_unsigned_transaction(&unsigned)
        .map_err(|e| ArgusError::TxBuildFailed(e).to_json_string())?;
    let input_boxes: Vec<Option<serde_json::Value>> =
        boxes.iter().map(|b| serde_json::to_value(b).ok()).collect();
    let mut summary = with_handle(handle_id, "preparation_details", |h| {
        Ok(crate::api_ergopay_impl::summarize_unsigned(
            &tx,
            &|addr| h.owns_address(addr).unwrap_or(false),
            &input_boxes,
        ))
    })?;
    summary["unsigned_tx"] = serde_json::to_value(&unsigned)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    summary["data_inputs"] = serde_json::json!(data_inputs);
    summary["miner_fee_nano_erg"] = serde_json::json!(miner_fee);
    Ok(summary.to_string())
}

/// Sign a prepared transaction without submitting it. Returns the raw signed
/// transaction as an EIP-12 JSON string. Use this for air-gapped / raw-tx
/// export workflows.
#[flutter_rust_bridge::frb]
pub async fn sign_preparation(handle_id: u64, preparation_id: u64) -> Result<String, String> {
    let prep = take_preparation(handle_id, preparation_id)?;
    let client = node_client(prep.node_url.clone()).await?;
    let tx_json = sign_prepared_tx(handle_id, &prep, &client, "sign_preparation").await?;
    serde_json::to_string(&tx_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// A single parsed recipient for a multi-recipient send.
struct ParsedRecipient {
    address: String,
    amount_nano_erg: i64,
    tokens: Vec<(String, u64)>,
}

/// Prepare a multi-recipient send. Each element of `recipients_json` is a JSON
/// object: `{"address":"...","amount_nano_erg":123,"tokens":[{"token_id":"...","amount":456}]}`;
/// a single `token_id`/`token_amount` pair is accepted too.
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
    input_box_ids: Option<Vec<String>>,
    stealth_boxes_json: Option<String>,
    babel_token_id: Option<String>,
) -> Result<String, String> {
    let change_tree = address_to_ergo_tree(&change_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;

    if fee_nano.unwrap_or(TX_FEE_NANO) < TX_FEE_NANO {
        return Err(ArgusError::TxBuildFailed(format!(
            "custom fee is below minimum {TX_FEE_NANO}"
        ))
        .to_json_string());
    }

    let recipients: Vec<serde_json::Value> =
        serde_json::from_str(&recipients_json).map_err(|e| {
            ArgusError::SerializationError(format!("Invalid recipients JSON: {e}")).to_json_string()
        })?;

    if recipients.is_empty() {
        return Err(
            ArgusError::TxBuildFailed("at least one recipient is required".into()).to_json_string(),
        );
    }

    let mut parsed: Vec<ParsedRecipient> = Vec::new();
    let mut total_send_erg: i64 = 0;
    for rcpt in recipients {
        let addr = rcpt["address"].as_str().ok_or_else(|| {
            ArgusError::TxBuildFailed("recipient missing address".into()).to_json_string()
        })?;
        let tokens = parse_recipient_tokens(&rcpt)?;
        let mut amount = match rcpt.get("amount_nano_erg") {
            None | Some(serde_json::Value::Null) => 0,
            Some(value) => value.as_i64().ok_or_else(|| {
                ArgusError::TxBuildFailed("recipient amount_nano_erg must be an integer".into())
                    .to_json_string()
            })?,
        };
        if !tokens.is_empty() {
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
        total_send_erg = total_send_erg.checked_add(amount).ok_or_else(|| {
            ArgusError::TxBuildFailed("recipient total amount out of range".into()).to_json_string()
        })?;
        parsed.push(ParsedRecipient {
            address: addr.to_string(),
            amount_nano_erg: amount,
            tokens,
        });
    }

    let has_sent_tokens = parsed.iter().any(|rcpt| !rcpt.tokens.is_empty());
    if total_send_erg <= 0 && !has_sent_tokens {
        return Err(ArgusError::TxBuildFailed(
            "at least one recipient must receive ERG or tokens".into(),
        )
        .to_json_string());
    }

    // Collect all recipient trees
    let mut recipient_specs: Vec<ergo_tx::RecipientSpec> = Vec::new();
    for rcpt in &parsed {
        let tree = address_to_ergo_tree(&rcpt.address)
            .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
        recipient_specs.push(ergo_tx::RecipientSpec {
            ergo_tree: tree,
            amount_nano_erg: rcpt.amount_nano_erg,
            tokens: rcpt.tokens.clone(),
        });
    }

    with_handle(handle_id, "prepare_send_multi", |h| {
        if !wallet_can_spend_change(h, &change_address)? {
            return Err(ArgusError::InvalidAddress(
                "change is not an address of this wallet".into(),
            )
            .to_json_string());
        }
        Ok(())
    })?;

    let spend = resolve_spend_addresses(&sender_address, &spend_addresses);
    let client = node_client(node_url.clone()).await?;
    let (mut boxes, mut eip12) = gather_unspent(handle_id, &client, &spend).await?;
    let stealth_owned = match stealth_boxes_json.as_deref() {
        Some(json) if !json.trim().is_empty() => {
            let secret = with_handle(handle_id, "send_multi", |h| {
                h.stealth_secret().map_err(err_str)
            })?;
            let all = stealth::parse_explorer_boxes(json)
                .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
            stealth::detect_owned(&secret, &all)
        }
        _ => Vec::new(),
    };
    for b in &stealth_owned {
        eip12.push(crate::api_stealth_impl::to_input(b));
        boxes.push(crate::api_stealth_impl::to_ergo_box(b)?);
    }
    let (mut boxes, eip12) = apply_mixed_rule(handle_id, boxes, eip12, input_box_ids.as_deref())?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend.join(",")).to_json_string());
    }

    // Collect tokens we need to cover
    let mut needed_tokens: HashMap<String, u64> = HashMap::new();
    for rcpt in &parsed {
        for (id, amt) in &rcpt.tokens {
            let entry = needed_tokens.entry(id.clone()).or_insert(0);
            *entry = entry.checked_add(*amt).ok_or_else(|| {
                ArgusError::TxBuildFailed("token requirement out of range".into()).to_json_string()
            })?;
        }
    }

    // For input selection we need the total ERG + all token amounts
    let fee_for_required = fee_nano.unwrap_or(TX_FEE_NANO);
    // With a babel box paying the fee, the wallet's ERG covers only the
    // recipients and a change box, and the fee's worth of the token joins
    // what the send needs.
    let babel = match babel_token_id.as_deref().filter(|t| !t.is_empty()) {
        Some(t) => Some(find_babel(&client, t, fee_for_required).await?),
        None => None,
    };
    if let Some(pick) = &babel {
        let entry = needed_tokens.entry(pick.babel.token_id.clone()).or_insert(0);
        *entry = entry.saturating_add(pick.babel.tokens_for(fee_for_required));
    }

    // Use UTXO selection: pick boxes covering total_send_erg + fee + min change,
    // and which collectively hold the needed tokens.
    let required = i64::checked_add(total_send_erg, if babel.is_some() { 0 } else { fee_for_required })
        .and_then(|v| i64::checked_add(v, MIN_BOX_VALUE_NANO))
        .filter(|v| *v > 0)
        .ok_or_else(|| {
            ArgusError::TxBuildFailed("recipient total amount out of range".into()).to_json_string()
        })? as u64;
    // Coin control, as in prepare_send: the chosen boxes are the whole
    // input set, never a starting point the selector may extend.
    let mut selected = match input_box_ids.as_deref() {
        Some(ids) => {
            let token_ref = needed_tokens
                .iter()
                .next()
                .map(|(id, amt)| (id.as_str(), *amt));
            let exact = select_exact(&eip12, ids, required, token_ref)
                .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
            // Every token this send delivers must be covered by the choice.
            for (id, amount) in &needed_tokens {
                let have: u64 = exact
                    .boxes
                    .iter()
                    .flat_map(|b| b.assets.iter())
                    .filter(|a| &a.token_id == id)
                    .map(|a| a.amount.parse::<u64>().unwrap_or(0))
                    .sum();
                if have < *amount {
                    return Err(ArgusError::TxBuildFailed(format!(
                        "the chosen boxes hold {have} of token {id}, this send needs {amount}"
                    ))
                    .to_json_string());
                }
            }
            exact.boxes
        }
        None => {
            // Same rule as the single send: try ordinary boxes alone, then
            // stealth alone, and only combine when neither can pay.
            let is_stealth =
                |b: &ergo_tx::Eip12InputBox| stealth_owned.iter().any(|s| s.box_id == b.box_id);
            let ordinary = eip12
                .iter()
                .filter(|b| !is_stealth(b))
                .cloned()
                .collect::<Vec<_>>();
            let only_stealth = eip12
                .iter()
                .filter(|b| is_stealth(b))
                .cloned()
                .collect::<Vec<_>>();
            let attempt = |set: &[ergo_tx::Eip12InputBox]| {
                if set.is_empty() {
                    return None;
                }
                select_for_multi_send(set, required, &needed_tokens)
                    .ok()
                    .filter(|s| !s.is_empty())
            };
            match attempt(&ordinary).or_else(|| attempt(&only_stealth)) {
                Some(s) => s,
                None => select_for_multi_send(&eip12, required, &needed_tokens)
                    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?,
            }
        }
    };

    if selected.is_empty() {
        return Err(ArgusError::NoUtxos(spend.join(",")).to_json_string());
    }
    if let Some(pick) = &babel {
        selected.push(pick.eip12.clone());
        boxes.push(pick.ergo_box.clone());
    }

    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;

    let built = ergo_tx::build_multi_send_tx_with_fee(
        &selected,
        &recipient_specs,
        &change_tree,
        fee_for_required,
        height,
    )
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let mut unsigned_tx = built.unsigned_tx;
    let mut change_erg = built.summary.change_erg;
    let babel_summary = match &babel {
        Some(pick) => {
            let s = ergo_tx::apply_babel(&mut unsigned_tx, &pick.babel, &change_tree)
                .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
            change_erg = unsigned_tx
                .outputs
                .iter()
                // From the end, as apply_babel does: a send to the
                // wallet's own change address gives the recipient box the
                // same script, and only the last one is the change.
                .rev()
                .find(|o| o.ergo_tree == change_tree)
                .map(|o| o.value.parse::<i64>().unwrap_or(0))
                .unwrap_or(0);
            Some(s)
        }
        None => None,
    };

    // Get the ErgoBox representations for signing
    let ergo_boxes = selected
        .iter()
        .filter_map(|eip| {
            boxes
                .iter()
                .find(|b| b.box_id().to_string() == eip.box_id)
                .cloned()
        })
        .collect::<Vec<_>>();
    if ergo_boxes.len() != selected.len() {
        return Err(ArgusError::TxBuildFailed("UTXO set mismatch".into()).to_json_string());
    }

    let input_boxes = input_boxes_json(&selected);
    let stealth_trees = selected
        .iter()
        .filter(|b| stealth_owned.iter().any(|s| s.box_id == b.box_id))
        .map(|b| b.ergo_tree.clone())
        .collect::<Vec<_>>();
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees,
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx,
        miner_fee: fee_for_required,
        change_erg,
        recipient_erg: total_send_erg,
        node_url,
    });

    let recipient_summary: Vec<serde_json::Value> = parsed
        .iter()
        .map(|rcpt| {
            serde_json::json!({
                "address": rcpt.address,
                "amount_nano_erg": rcpt.amount_nano_erg,
                "token_id": rcpt.tokens.first().map(|(id, _)| id),
                "token_amount": rcpt.tokens.first().map(|(_, amt)| amt),
                "tokens": rcpt.tokens.iter().map(|(id, amt)| serde_json::json!({"token_id": id, "amount": amt})).collect::<Vec<_>>(),
            })
        })
        .collect();

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
        "babel": babel_summary.as_ref().map(babel_json),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Select UTXOs that collectively hold enough ERG and tokens for a multi-send.
fn select_for_multi_send(
    eip12: &[ergo_tx::Eip12InputBox],
    required_erg: u64,
    needed_tokens: &HashMap<String, u64>,
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
            let all_ok = needed_tokens
                .iter()
                .all(|(id, need)| total_tokens.get(id).copied().unwrap_or(0) >= *need);
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
    for (id, need) in needed_tokens {
        let have = total_tokens.get(id).copied().unwrap_or(0);
        if have < *need {
            return Err(format!(
                "insufficient tokens {id}: have {have}, need {need}"
            ));
        }
    }

    Ok(selected)
}

// ─────────────────────────────────────────────────────────────────────────────
// Dexy protocol (mobile): live market state + mint/swap/LP previews, plus
// build-free broadcasts reusing the prepare → confirm → send flow.
// ─────────────────────────────────────────────────────────────────────────────

/// Live Dexy protocol state + mint-path rates for `gold` or `usd`.
#[flutter_rust_bridge::frb]
pub async fn dexy_state(variant: String, node_url: Option<String>) -> Result<String, String> {
    crate::api_dexy_impl::state(&variant, node_url).await
}

/// Mint cost preview at the live oracle rate.
#[flutter_rust_bridge::frb]
pub async fn dexy_preview_mint(
    variant: String,
    amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    crate::api_dexy_impl::preview_mint(&variant, amount, node_url).await
}

/// Swap quote using live LP reserves. `direction` is `erg_to_dexy` or `dexy_to_erg`.
#[flutter_rust_bridge::frb]
pub async fn dexy_preview_swap(
    variant: String,
    direction: String,
    amount: i64,
    slippage_pct: Option<f64>,
    node_url: Option<String>,
) -> Result<String, String> {
    crate::api_dexy_impl::preview_swap(&variant, &direction, amount, slippage_pct, node_url).await
}

/// LP deposit/redeem preview. `action` is `"deposit"` or `"redeem"`.
#[flutter_rust_bridge::frb]
pub async fn dexy_preview_lp(
    variant: String,
    action: String,
    erg_amount: i64,
    dexy_amount: i64,
    lp_amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    crate::api_dexy_impl::preview_lp(
        &variant,
        &action,
        erg_amount,
        dexy_amount,
        lp_amount,
        node_url,
    )
    .await
}

/// Fetch the selected user input boxes from the wallet, keyed by box id,
/// validating ownership against the wallet handle.
async fn gather_wallet_boxes(
    handle_id: u64,
    spend_addresses: &[String],
    node_url: Option<String>,
) -> Result<
    (
        Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
        Vec<ergo_tx::Eip12InputBox>,
    ),
    String,
> {
    let client = node_client(node_url).await?;
    let (boxes, eip12) = gather_unspent(handle_id, &client, spend_addresses).await?;
    apply_mixed_rule(handle_id, boxes, eip12, None)
}

/// Order the user's full ErgoBoxes to match input order after `protocol_count`
/// protocol inputs, using the selected EIP-12 box ids.
fn ordered_user_boxes(
    selected_ids: &[String],
    all_boxes: &[ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox],
) -> Result<Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>, String> {
    let by_id = all_boxes
        .iter()
        .map(|b| (b.box_id().to_string(), b.clone()))
        .collect::<HashMap<_, _>>();
    let mut out = Vec::with_capacity(selected_ids.len());
    for id in selected_ids {
        out.push(by_id.get(id).cloned().ok_or_else(|| {
            ArgusError::TxBuildFailed(format!("missing user UTXO {id}")).to_json_string()
        })?);
    }
    Ok(out)
}

/// Largest output value paid to the user's tree — used as the "change" figure
/// in confirm flows.
fn user_change_erg(unsigned_tx: &ergo_tx::Eip12UnsignedTx, user_ergo_tree: &str) -> i64 {
    unsigned_tx
        .outputs
        .iter()
        .filter(|o| o.ergo_tree == user_ergo_tree)
        .map(|o| o.value.parse::<i64>().unwrap_or(0))
        .max()
        .unwrap_or(0)
}

/// Validate dexy destinations: `recipient_address` may be any valid Ergo
/// address (external token sends), `change_address` must belong to the wallet.
/// Returns `(recipient_tree, change_tree)`.
fn resolve_dexy_destinations(
    handle_id: u64,
    op: &'static str,
    recipient_address: &str,
    change_address: &str,
) -> Result<(String, String), String> {
    let recipient_tree = address_to_ergo_tree(recipient_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let change_tree = address_to_ergo_tree(change_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    with_handle(handle_id, op, |handle| {
        if !handle.owns_address(change_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "change address is not an address of this wallet".into(),
            )
            .to_json_string());
        }
        Ok(())
    })?;
    Ok((recipient_tree, change_tree))
}

/// Prepare a Dexy mint: builds the FreeMint transaction, caches it, and returns
/// a preview JSON with the `preparation_id` for the shared confirm → broadcast
/// flow. `recipient_address` receives the minted tokens (any valid Ergo
/// address); ERG change returns to wallet-owned `change_address`.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn dexy_build_mint(
    handle_id: u64,
    variant: String,
    amount: i64,
    held_tokens: i64,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let dexy_variant = variant
        .parse::<dexy::constants::DexyVariant>()
        .map_err(|_| {
            ArgusError::Generic(format!("Invalid Dexy variant: {variant}")).to_json_string()
        })?;
    let ids = crate::api_dexy_impl::ids_for(dexy_variant)?;

    if held_tokens < 0 {
        return Err(
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string(),
        );
    }

    let (recipient_tree, change_tree) = resolve_dexy_destinations(
        handle_id,
        "dexy_build_mint",
        &recipient_address,
        &change_address,
    )?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let state = dexy::fetch::fetch_dexy_state(&client, &caps, &ids)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let ctx = dexy::fetch::fetch_tx_context(&client, &caps, &ids)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;

    let (all_boxes, eip12) =
        gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?
        as i32;

    let user_tree = change_tree.clone();
    let request = dexy::tx_builder::MintDexyRequest {
        variant: dexy_variant,
        amount,
        user_address: change_address.clone(),
        user_ergo_tree: user_tree.clone(),
        user_inputs: eip12,
        current_height: height,
        recipient_ergo_tree: Some(recipient_tree),
        recipient_held_tokens: held_tokens,
    };

    let built = dexy::tx_builder::build_mint_dexy_tx(&request, &ctx, &state)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    // Inputs: [free_mint, bank, buyback] + user inputs (in order). Data inputs: oracle + lp.
    let selected_ids = built
        .unsigned_tx
        .inputs
        .iter()
        .skip(3)
        .map(|i| i.box_id.clone())
        .collect::<Vec<_>>();
    let user_boxes = ordered_user_boxes(&selected_ids, &all_boxes)?;

    let mut ergo_boxes = vec![
        ctx.free_mint_box.clone(),
        ctx.bank_box.clone(),
        ctx.buyback_box.clone(),
    ];
    ergo_boxes.extend(user_boxes);
    let data_input_boxes = vec![ctx.oracle_box.clone(), ctx.lp_box.clone()];

    let miner_fee = built.summary.tx_fee_nano;
    let change_erg = user_change_erg(&built.unsigned_tx, &change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes,
        unsigned_tx: built.unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: built.summary.erg_amount_nano,
        node_url,
    });

    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "action": built.summary.action,
        "token_amount": built.summary.token_amount + held_tokens,
        "minted_amount": built.summary.token_amount,
        "held_amount": held_tokens,
        "token_name": dexy_variant.token_name(),
        "erg_cost_nano": built.summary.erg_amount_nano,
        "bank_fee_nano": built.summary.bank_fee_nano,
        "buyback_fee_nano": built.summary.buyback_fee_nano,
        "miner_fee": miner_fee,
        "change_nano_erg": change_erg,
        "recipient": recipient_address,
        "change_address": change_address,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a Dexy LP swap (both directions) into the standard broadcast flow.
/// `recipient_address` receives the swapped output (any valid Ergo address);
/// ERG/token change returns to wallet-owned `change_address`.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn dexy_build_swap(
    handle_id: u64,
    variant: String,
    direction: String,
    amount: i64,
    min_output: i64,
    held_tokens: i64,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let dexy_variant = variant
        .parse::<dexy::constants::DexyVariant>()
        .map_err(|_| {
            ArgusError::Generic(format!("Invalid Dexy variant: {variant}")).to_json_string()
        })?;
    let swap_direction = match direction.as_str() {
        "erg_to_dexy" => dexy::tx_builder::SwapDirection::ErgToDexy,
        "dexy_to_erg" => dexy::tx_builder::SwapDirection::DexyToErg,
        _ => {
            return Err(ArgusError::Generic(format!(
                "Invalid direction '{direction}'. Use 'erg_to_dexy' or 'dexy_to_erg'"
            ))
            .to_json_string())
        }
    };
    let ids = crate::api_dexy_impl::ids_for(dexy_variant)?;

    if held_tokens < 0 {
        return Err(
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string(),
        );
    }

    let (recipient_tree, change_tree) = resolve_dexy_destinations(
        handle_id,
        "dexy_build_swap",
        &recipient_address,
        &change_address,
    )?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let state = dexy::fetch::fetch_dexy_state(&client, &caps, &ids)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let ctx = dexy::fetch::fetch_swap_tx_context(&client, &caps, &ids)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;

    let (all_boxes, eip12) =
        gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?
        as i32;
    let user_tree = change_tree.clone();
    let request = dexy::tx_builder::SwapDexyRequest {
        variant: dexy_variant,
        direction: swap_direction,
        input_amount: amount,
        min_output,
        user_address: change_address.clone(),
        user_ergo_tree: user_tree.clone(),
        user_inputs: eip12,
        current_height: height,
        recipient_ergo_tree: Some(recipient_tree),
        recipient_held_tokens: held_tokens,
    };

    let built = dexy::tx_builder::build_swap_dexy_tx(&request, &ctx, &state)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    let selected_ids = built
        .unsigned_tx
        .inputs
        .iter()
        .skip(2)
        .map(|i| i.box_id.clone())
        .collect::<Vec<_>>();
    let user_boxes = ordered_user_boxes(&selected_ids, &all_boxes)?;

    let mut ergo_boxes = vec![ctx.lp_box.clone(), ctx.swap_box.clone()];
    ergo_boxes.extend(user_boxes);

    let miner_fee = built.summary.miner_fee_nano;
    let change_erg = user_change_erg(&built.unsigned_tx, &change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx: built.unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: built.summary.output_amount,
        node_url,
    });

    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "action": "swap",
        "direction": built.summary.direction,
        "input_amount": built.summary.input_amount,
        "output_amount": built.summary.output_amount,
        // Tokens actually delivered. Only an ERG-funded swap hands tokens to
        // the recipient; selling dexy delivers ERG, so it reports none.
        "token_amount": if built.summary.direction == "erg_to_dexy" {
            built.summary.output_amount + held_tokens
        } else {
            0
        },
        "held_amount": held_tokens,
        "min_output": built.summary.min_output,
        "price_impact_pct": built.summary.price_impact_pct,
        "fee_pct": built.summary.fee_pct,
        "miner_fee": miner_fee,
        "change_nano_erg": change_erg,
        "recipient": recipient_address,
        "change_address": change_address,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Build an LP deposit (add liquidity) transaction and cache it for broadcast.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn dexy_build_lp_deposit(
    handle_id: u64,
    variant: String,
    deposit_erg: i64,
    deposit_dexy: i64,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let dexy_variant = variant
        .parse::<dexy::constants::DexyVariant>()
        .map_err(|_| {
            ArgusError::Generic(format!("Invalid Dexy variant: {variant}")).to_json_string()
        })?;
    let ids = crate::api_dexy_impl::ids_for(dexy_variant)?;

    let (recipient_tree, change_tree) = resolve_dexy_destinations(
        handle_id,
        "dexy_build_lp_deposit",
        &recipient_address,
        &change_address,
    )?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let ctx =
        dexy::fetch::fetch_lp_tx_context(&client, &caps, &ids, dexy::fetch::LpAction::Deposit)
            .await
            .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;

    let (all_boxes, eip12) =
        gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?
        as i32;
    let user_tree = change_tree.clone();
    let request = dexy::tx_builder::LpDepositRequest {
        variant: dexy_variant,
        deposit_erg,
        deposit_dexy,
        user_address: change_address.clone(),
        user_ergo_tree: user_tree.clone(),
        user_inputs: eip12,
        current_height: height,
        recipient_ergo_tree: Some(recipient_tree),
    };

    let built = dexy::tx_builder::build_lp_deposit_tx(
        &request,
        &ctx,
        &ids.dexy_token,
        &ids.lp_token_id,
        dexy_variant.initial_lp(),
    )
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    let selected_ids = built
        .unsigned_tx
        .inputs
        .iter()
        .skip(2)
        .map(|i| i.box_id.clone())
        .collect::<Vec<_>>();
    let user_boxes = ordered_user_boxes(&selected_ids, &all_boxes)?;

    let mut ergo_boxes = vec![ctx.lp_box.clone(), ctx.action_box.clone()];
    ergo_boxes.extend(user_boxes);

    let miner_fee = built.summary.miner_fee_nano;
    let change_erg = user_change_erg(&built.unsigned_tx, &change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx: built.unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: built.summary.lp_tokens,
        node_url,
    });

    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "action": built.summary.action,
        "erg_amount": built.summary.erg_amount,
        "dexy_amount": built.summary.dexy_amount,
        "lp_tokens": built.summary.lp_tokens,
        "miner_fee": miner_fee,
        "change_nano_erg": change_erg,
        "recipient": recipient_address,
        "change_address": change_address,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Build an LP redeem (remove liquidity) transaction and return it for broadcast.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn dexy_build_lp_redeem(
    handle_id: u64,
    variant: String,
    lp_to_burn: i64,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let dexy_variant = variant
        .parse::<dexy::constants::DexyVariant>()
        .map_err(|_| {
            ArgusError::Generic(format!("Invalid Dexy variant: {variant}")).to_json_string()
        })?;
    let ids = crate::api_dexy_impl::ids_for(dexy_variant)?;

    let (recipient_tree, change_tree) = resolve_dexy_destinations(
        handle_id,
        "dexy_build_lp_redeem",
        &recipient_address,
        &change_address,
    )?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let ctx = dexy::fetch::fetch_lp_tx_context(&client, &caps, &ids, dexy::fetch::LpAction::Redeem)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;

    let (all_boxes, eip) =
        gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?
        as i32;
    let user_tree = change_tree.clone();
    let request = dexy::tx_builder::LpRedeemRequest {
        variant: dexy_variant,
        lp_to_burn,
        user_address: change_address.clone(),
        user_ergo_tree: user_tree.clone(),
        user_inputs: eip,
        current_height: height,
        recipient_ergo_tree: Some(recipient_tree),
    };

    let built = dexy::tx_builder::build_lp_redeem_tx(
        &request,
        &ctx,
        &ids.dexy_token,
        &ids.lp_token_id,
        dexy_variant.initial_lp(),
    )
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    let selected_ids: Vec<String> = built
        .unsigned_tx
        .inputs
        .iter()
        .skip(2)
        .map(|i| i.box_id.clone())
        .collect();
    let user_boxes = ordered_user_boxes(&selected_ids, &all_boxes)?;

    let mut ergo_boxes = vec![ctx.lp_box.clone(), ctx.action_box.clone()];
    ergo_boxes.extend(user_boxes);

    // LP redeem spends the oracle as a data input; a missing oracle box must
    // abort preparation rather than silently producing an unreducible tx.
    let mut data_input_boxes: Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox> = Vec::new();
    if let Some(data_input) = &ctx.oracle_data_input {
        let oracle_box = client
            .get_box_by_id(&citadel_core::BoxId::new(&data_input.box_id))
            .await
            .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
        data_input_boxes.push(oracle_box);
    }

    let miner_fee = built.summary.miner_fee_nano;
    let change_erg = user_change_erg(&built.unsigned_tx, &change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes,
        unsigned_tx: built.unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: built.summary.lp_tokens,
        node_url,
    });

    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "action": built.summary.action,
        "erg_amount": built.summary.erg_amount,
        "dexy_amount": built.summary.dexy_amount,
        "lp_tokens": built.summary.lp_tokens,
        "miner_fee": miner_fee,
        "change_nano_erg": change_erg,
        "recipient": recipient_address,
        "change_address": change_address,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Live SigmaUSD (AgeUSD) protocol state: bank reserves, oracle rate, reserve
/// ratio, token prices, liabilities/equity, and per-action availability.
#[flutter_rust_bridge::frb]
pub async fn sigmausd_state(node_url: Option<String>) -> Result<String, String> {
    crate::api_sigmausd_impl::state(node_url).await
}

/// Cost/proceeds preview for one of the four SigmaUSD bank actions at the
/// live oracle rate. `action` is `mint_sigusd`, `redeem_sigusd`, `mint_sigrsv`,
/// or `redeem_sigrsv`.
#[flutter_rust_bridge::frb]
pub async fn sigmausd_preview(
    action: String,
    amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    crate::api_sigmausd_impl::preview(&action, amount, node_url).await
}

/// Build a SigmaUSD bank transaction into the standard broadcast flow. The
/// primary output (minted tokens, or redeemed ERG with leftover tokens) goes
/// to `recipient_address` — any valid Ergo address; ERG change returns to
/// wallet-owned `change_address`.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn sigmausd_build(
    handle_id: u64,
    action: String,
    amount: i64,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
    held_tokens: i64,
) -> Result<String, String> {
    if held_tokens < 0 {
        return Err(
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string(),
        );
    }
    use citadel_core::BoxId;
    use sigmausd::fetch::fetch_tx_context;
    use sigmausd::state::{BankBoxData, OracleBoxData, SigmaUsdState};
    use sigmausd::tx_builder::{
        build_mint_sigrsv_tx, build_mint_sigusd_tx, build_redeem_sigrsv_tx, build_redeem_sigusd_tx,
        validate_mint_sigrsv, validate_mint_sigusd, validate_redeem_sigrsv, validate_redeem_sigusd,
        MintSigRsvRequest, MintSigUsdRequest, RedeemSigRsvRequest, RedeemSigUsdRequest,
        SigmaUsdAction,
    };

    let parsed_action = action.parse::<SigmaUsdAction>().map_err(|_| {
        ArgusError::Generic(format!("Invalid SigmaUSD action: {action}")).to_json_string()
    })?;
    let ids = crate::api_sigmausd_impl::nft_ids()?;

    let (recipient_tree, change_tree) = resolve_dexy_destinations(
        handle_id,
        "sigmausd_build",
        &recipient_address,
        &change_address,
    )?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;

    let (all_boxes, eip12) =
        gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?
        as i32;

    let fetched = fetch_tx_context(&client, &caps, &ids)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;

    // Derive the validation state from the SAME bank/oracle boxes the builder
    // will consume, so ratio checks can never pass on a stale snapshot.
    let state = SigmaUsdState::from_boxes(
        &BankBoxData {
            box_id: BoxId::new(fetched.bank_box.box_id().to_string()),
            value_nano: fetched.bank_erg_nano,
            sigusd_circulating: fetched.sigusd_circulating,
            sigrsv_circulating: fetched.sigrsv_circulating,
        },
        &OracleBoxData {
            box_id: BoxId::new(fetched.oracle_box.box_id().to_string()),
            nanoerg_per_usd: fetched.oracle_rate,
        },
    );

    let check = match parsed_action {
        SigmaUsdAction::MintSigUsd => validate_mint_sigusd(amount, &state),
        SigmaUsdAction::RedeemSigUsd => validate_redeem_sigusd(amount, &state),
        SigmaUsdAction::MintSigRsv => validate_mint_sigrsv(amount, &state),
        SigmaUsdAction::RedeemSigRsv => validate_redeem_sigrsv(amount, &state),
    };
    check.map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    let user_tree = change_tree.clone();
    let ctx = sigmausd::tx_builder::TxContext {
        nft_ids: ids,
        bank_input: fetched.bank_input,
        bank_erg_nano: fetched.bank_erg_nano,
        sigusd_circulating: fetched.sigusd_circulating,
        sigrsv_circulating: fetched.sigrsv_circulating,
        sigusd_in_bank: fetched.sigusd_in_bank,
        sigrsv_in_bank: fetched.sigrsv_in_bank,
        oracle_data_input: fetched.oracle_data_input,
        oracle_rate: fetched.oracle_rate,
    };

    let built = match parsed_action {
        SigmaUsdAction::MintSigUsd => build_mint_sigusd_tx(
            &MintSigUsdRequest {
                amount,
                user_address: change_address.clone(),
                user_ergo_tree: user_tree.clone(),
                user_inputs: eip12,
                current_height: height,
                recipient_ergo_tree: Some(recipient_tree),
                recipient_held_tokens: held_tokens,
            },
            &ctx,
            &state,
        ),
        SigmaUsdAction::RedeemSigUsd => build_redeem_sigusd_tx(
            &RedeemSigUsdRequest {
                amount,
                user_address: change_address.clone(),
                user_ergo_tree: user_tree.clone(),
                user_inputs: eip12,
                current_height: height,
                recipient_ergo_tree: Some(recipient_tree),
            },
            &ctx,
            &state,
        ),
        SigmaUsdAction::MintSigRsv => build_mint_sigrsv_tx(
            &MintSigRsvRequest {
                amount,
                user_address: change_address.clone(),
                user_ergo_tree: user_tree.clone(),
                user_inputs: eip12,
                current_height: height,
                recipient_ergo_tree: Some(recipient_tree),
                recipient_held_tokens: held_tokens,
            },
            &ctx,
            &state,
        ),
        SigmaUsdAction::RedeemSigRsv => build_redeem_sigrsv_tx(
            &RedeemSigRsvRequest {
                amount,
                user_address: change_address.clone(),
                user_ergo_tree: user_tree.clone(),
                user_inputs: eip12,
                current_height: height,
                recipient_ergo_tree: Some(recipient_tree),
            },
            &ctx,
            &state,
        ),
    }
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    // Inputs: [bank] + user inputs (in order). Data inputs: oracle.
    let selected_ids = built
        .unsigned_tx
        .inputs
        .iter()
        .skip(1)
        .map(|i| i.box_id.clone())
        .collect::<Vec<_>>();
    let user_boxes = ordered_user_boxes(&selected_ids, &all_boxes)?;

    let mut ergo_boxes = vec![fetched.bank_box];
    ergo_boxes.extend(user_boxes);
    let data_input_boxes = vec![fetched.oracle_box];

    let miner_fee = built.summary.tx_fee_nano;
    let change_erg = user_change_erg(&built.unsigned_tx, &change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes,
        unsigned_tx: built.unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: built.summary.erg_amount_nano,
        node_url,
    });

    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "action": built.summary.action,
        "token_amount": built.summary.token_amount,
        "token_name": built.summary.token_name,
        "erg_amount_nano": built.summary.erg_amount_nano,
        "protocol_fee_nano": built.summary.protocol_fee_nano,
        "citadel_fee_nano": built.summary.citadel_fee_nano,
        "miner_fee": miner_fee,
        "change_nano_erg": change_erg,
        "recipient": recipient_address,
        "change_address": change_address,
        "held_amount": held_tokens,
        "delivered_amount": built.summary.token_amount + held_tokens,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Discovered Spectrum pools with token metadata. Read-only; never touches the
/// wallet handle. `truncated` is true when discovery hit its 1000-box cap and
/// some pools may be missing.
#[flutter_rust_bridge::frb]
pub async fn amm_pools(
    node_url: Option<String>,
    force_refresh: bool,
    known_tokens_json: Option<String>,
) -> Result<String, String> {
    if let Some(known) = known_tokens_json.as_deref() {
        crate::api_amm_impl::seed_token_cache(known);
    }
    let set = crate::api_amm_impl::load_pools(node_url.clone(), force_refresh).await?;
    let client = crate::api_dexy_impl::dexy_client(node_url).await?;

    // Collect the distinct ids first: pools share tokens heavily, so this cuts
    // the number of lookups well below one per pool side.
    let mut unique_ids: Vec<String> = Vec::new();
    for pool in &set.pools {
        for id in crate::api_amm_impl::pool_token_ids(pool) {
            if !unique_ids.contains(&id) {
                unique_ids.push(id);
            }
        }
    }

    let mut tokens = serde_json::Map::new();
    for (id, meta) in crate::api_amm_impl::token_meta_many(&client, unique_ids).await {
        tokens.insert(
            id,
            serde_json::to_value(meta)
                .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?,
        );
    }

    serde_json::to_string(&serde_json::json!({
        "truncated": set.truncated,
        "pools": set.pools,
        "tokens": tokens,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

// ---------------------------------------------------------------------------
// Spectrum liquidity: add, remove, and create a pool
// ---------------------------------------------------------------------------

/// The pool box and the wallet's boxes for a liquidity transaction: the
/// pool by its id (always fresh), the user's boxes, the height.
async fn liquidity_context(
    handle_id: u64,
    pool_id: &str,
    spend_addresses: &[String],
    node_url: Option<String>,
) -> Result<
    (
        amm::state::AmmPool,
        ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox,
        ergo_tx::Eip12InputBox,
        Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
        Vec<ergo_tx::Eip12InputBox>,
        i32,
    ),
    String,
> {
    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let (pool, pool_ergo_box) = crate::api_amm_impl::fetch_pool(&client, pool_id).await?;
    let creation = client
        .get_box_creation_info(&pool_ergo_box.box_id().to_string())
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let pool_box = ergo_tx::Eip12InputBox::from_ergo_box(&pool_ergo_box, creation.0, creation.1);
    let (all_boxes, eip12) = gather_wallet_boxes(handle_id, spend_addresses, node_url).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;
    Ok((pool, pool_ergo_box, pool_box, all_boxes, eip12, height))
}

/// Store a built pool transaction (pool box first, then the user's boxes)
/// and answer with its preparation id and summary.
#[allow(clippy::too_many_arguments)]
fn store_pool_tx(
    handle_id: u64,
    unsigned_tx: ergo_tx::Eip12UnsignedTx,
    pool_ergo_box: ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox,
    all_boxes: &[ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox],
    change_tree: &str,
    miner_fee: i64,
    node_url: Option<String>,
    summary: serde_json::Value,
) -> Result<String, String> {
    let output_trees: Vec<String> = unsigned_tx.outputs.iter().map(|o| o.ergo_tree.clone()).collect();
    if crate::api_amm_impl::pays_citadel_dev_fee(&output_trees) {
        return Err(ArgusError::Generic(
            "DEV_FEE_LEAK: built tx pays the Citadel dev fee — init_app guard failed".into(),
        )
        .to_json_string());
    }
    let selected_ids = unsigned_tx
        .inputs
        .iter()
        .skip(1)
        .map(|i| i.box_id.clone())
        .collect::<Vec<_>>();
    let user_boxes = ordered_user_boxes(&selected_ids, all_boxes)?;
    let mut ergo_boxes = vec![pool_ergo_box];
    ergo_boxes.extend(user_boxes);
    let change_erg = user_change_erg(&unsigned_tx, change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: vec![],
        unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: 0,
        node_url,
    });
    let mut out = summary;
    out["preparation_id"] = serde_json::json!(preparation_id);
    serde_json::to_string(&out).map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Add liquidity to a Spectrum pool directly (no bot): `x_amount` is
/// nanoERG for an ERG pool or the X token's units for a token pair,
/// `y_amount` the Y token's units; the LP tokens come back to
/// `recipient_address`. Confirm with `send_erg`.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn amm_build_lp_deposit(
    handle_id: u64,
    pool_id: String,
    x_amount: i64,
    y_amount: i64,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    if x_amount <= 0 || y_amount <= 0 {
        return Err(ArgusError::Generic("Amounts must be positive".into()).to_json_string());
    }
    let (recipient_tree, change_tree) =
        resolve_dexy_destinations(handle_id, "amm_build_lp_deposit", &recipient_address, &change_address)?;
    let (pool, pool_ergo_box, pool_box, all_boxes, eip12, height) =
        liquidity_context(handle_id, &pool_id, &spend_addresses, node_url.clone()).await?;
    let built = amm::build_lp_deposit_eip12(&pool_box, &pool, x_amount as u64, y_amount as u64, &eip12, &recipient_tree, height)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let s = &built.summary;
    let summary = serde_json::json!({
        "pool_id": pool_id,
        "x_deposited": s.erg_deposited,
        "y_deposited": s.token_deposited,
        "token_name": s.token_name,
        "lp_reward": s.lp_reward,
        "lp_token_id": pool.lp_token_id,
        "miner_fee": s.miner_fee,
        "total_erg_cost": s.total_erg_cost,
    });
    store_pool_tx(handle_id, built.unsigned_tx, pool_ergo_box, &all_boxes, &change_tree, s.miner_fee as i64, node_url, summary)
}

/// Remove liquidity: hand `lp_amount` LP tokens back to the pool for the
/// matching share of both reserves, paid to `recipient_address`. Confirm
/// with `send_erg`.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn amm_build_lp_redeem(
    handle_id: u64,
    pool_id: String,
    lp_amount: i64,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    if lp_amount <= 0 {
        return Err(ArgusError::Generic("Amount must be positive".into()).to_json_string());
    }
    let (recipient_tree, change_tree) =
        resolve_dexy_destinations(handle_id, "amm_build_lp_redeem", &recipient_address, &change_address)?;
    let (pool, pool_ergo_box, pool_box, all_boxes, eip12, height) =
        liquidity_context(handle_id, &pool_id, &spend_addresses, node_url.clone()).await?;
    let built = amm::build_lp_redeem_eip12(&pool_box, &pool, lp_amount as u64, &eip12, &recipient_tree, height)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let s = &built.summary;
    let summary = serde_json::json!({
        "pool_id": pool_id,
        "lp_redeemed": s.lp_redeemed,
        "x_received": s.erg_received,
        "y_received": s.token_received,
        "token_name": s.token_name,
        "miner_fee": s.miner_fee,
        "total_erg_cost": s.total_erg_cost,
    });
    store_pool_tx(handle_id, built.unsigned_tx, pool_ergo_box, &all_boxes, &change_tree, s.miner_fee as i64, node_url, summary)
}

fn pool_setup_params(
    pool_type: &str,
    x_token_id: Option<String>,
    x_amount: i64,
    y_token_id: &str,
    y_amount: i64,
    fee_num: i32,
) -> Result<amm::pool_setup::PoolSetupParams, String> {
    let pool_type = match pool_type {
        "N2T" => amm::state::PoolType::N2T,
        "T2T" => amm::state::PoolType::T2T,
        other => return Err(ArgusError::Generic(format!("unknown pool type {other:?}")).to_json_string()),
    };
    if x_amount <= 0 || y_amount <= 0 {
        return Err(ArgusError::Generic("Amounts must be positive".into()).to_json_string());
    }
    Ok(amm::pool_setup::PoolSetupParams {
        pool_type,
        x_token_id: x_token_id.filter(|s| !s.is_empty()),
        x_amount: x_amount as u64,
        y_token_id: y_token_id.to_string(),
        y_amount: y_amount as u64,
        fee_num,
    })
}

/// First of a pool's two transactions: mint the LP supply into a
/// *bootstrap* box of this wallet holding the initial reserves. The LP
/// token id is known before signing; the pool's NFT will be the bootstrap
/// box's id once it exists. Confirm with `send_erg`, then call
/// `amm_build_pool_create` with the bootstrap box id once it confirms.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn amm_build_pool_bootstrap(
    handle_id: u64,
    pool_type: String,
    x_token_id: Option<String>,
    x_amount: i64,
    y_token_id: String,
    y_amount: i64,
    fee_num: i32,
    user_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let params = pool_setup_params(&pool_type, x_token_id, x_amount, &y_token_id, y_amount, fee_num)?;
    let (user_tree, _) = resolve_dexy_destinations(handle_id, "amm_build_pool_bootstrap", &user_address, &user_address)?;
    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let (all_boxes, eip12) = gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;
    let built = amm::build_pool_bootstrap_eip12(&params, &eip12, &user_tree, height)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let ids: Vec<String> = built.unsigned_tx.inputs.iter().map(|i| i.box_id.clone()).collect();
    let ergo_boxes = ordered_user_boxes(&ids, &all_boxes)?;
    let bootstrap_box_id = ergo_tx::chain::derive_output_boxes(&built.unsigned_tx)
        .map(|(_, outs)| outs.first().map(|b| b.box_id.clone()).unwrap_or_default())
        .map_err(|e| ArgusError::TxBuildFailed(e).to_json_string())?;
    let s = built.summary.clone();
    let change_erg = user_change_erg(&built.unsigned_tx, &user_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: vec![],
        unsigned_tx: built.unsigned_tx,
        miner_fee: s.miner_fee as i64,
        change_erg,
        recipient_erg: 0,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "bootstrap_box_id": bootstrap_box_id,
        "lp_token_id": s.lp_token_id,
        "lp_minted": s.lp_minted,
        "user_lp_share": s.user_lp_share,
        "pool_type": pool_type,
        "x_amount": s.x_amount,
        "y_amount": s.y_amount,
        "fee_percent": s.fee_percent,
        "miner_fee": s.miner_fee,
        "total_erg_cost": s.total_erg_cost,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Second of a pool's two transactions: spend the confirmed bootstrap box
/// into the pool box (its NFT minted here) and the user's LP share. The
/// parameters must be the ones the bootstrap was built with. Confirm with
/// `send_erg`.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn amm_build_pool_create(
    handle_id: u64,
    bootstrap_box_id: String,
    pool_type: String,
    x_token_id: Option<String>,
    x_amount: i64,
    y_token_id: String,
    y_amount: i64,
    fee_num: i32,
    lp_token_id: String,
    user_lp_share: i64,
    user_address: String,
    node_url: Option<String>,
) -> Result<String, String> {
    let params = pool_setup_params(&pool_type, x_token_id, x_amount, &y_token_id, y_amount, fee_num)?;
    let (user_tree, _) = resolve_dexy_destinations(handle_id, "amm_build_pool_create", &user_address, &user_address)?;
    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    let bootstrap = client
        .get_eip12_box_by_id(&bootstrap_box_id)
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    if !bootstrap.ergo_tree.eq_ignore_ascii_case(&user_tree) {
        return Err(ArgusError::TxBuildFailed("the bootstrap box is not this wallet's".into()).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;
    let built = amm::build_pool_create_eip12(&bootstrap, &params, &lp_token_id, user_lp_share as u64, &user_tree, height)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let ergo_box = crate::api_mix_impl::to_ergo_box(&bootstrap)?;
    let s = built.summary.clone();
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes: vec![ergo_box],
        data_input_boxes: vec![],
        unsigned_tx: built.unsigned_tx,
        miner_fee: TX_FEE_NANO,
        change_erg: 0,
        recipient_erg: 0,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "pool_nft_id": s.pool_nft_id,
        "lp_token_id": s.lp_token_id,
        "pool_type": s.pool_type,
        "fee_num": s.fee_num,
        "miner_fee": TX_FEE_NANO,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Quote a single-hop swap. `from_token`/`to_token` are `None` for ERG,
/// matching how the Send screen encodes ERG as a null asset id.
#[flutter_rust_bridge::frb]
pub async fn amm_quote(
    from_token: Option<String>,
    to_token: Option<String>,
    amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    if amount <= 0 {
        return Err(ArgusError::Generic("Amount must be positive".into()).to_json_string());
    }
    let set = crate::api_amm_impl::load_pools(node_url, false).await?;
    // Selection quotes every candidate, so an unquotable pool is skipped rather
    // than chosen and then failed on.
    let (pool, quote) = crate::api_amm_impl::best_pool_for(
        &set.pools,
        from_token.as_deref(),
        to_token.as_deref(),
        amount as u64,
    )
    .ok_or_else(|| {
        ArgusError::Generic("NO_POOL: no Spectrum pool can trade this pair at this size".into())
            .to_json_string()
    })?;

    serde_json::to_string(&serde_json::json!({
        "pool_id": pool.pool_id,
        "box_id": pool.box_id,
        "output_amount": quote.output.amount,
        "output_token": quote.output.token_id,
        "min_output": crate::api_amm_impl::min_output_for(quote.output.amount),
        "price_impact_pct": quote.price_impact,
        "fee_amount": quote.fee_amount,
        "quote_tolerance_pct": crate::api_amm_impl::QUOTE_TOLERANCE_PCT,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// ERG needed to receive exactly `output_amount` of `to_token` from the
/// cheapest Spectrum N2T pool. For buy-and-send: prices a shortfall.
#[flutter_rust_bridge::frb]
pub async fn amm_quote_exact_output(
    to_token: String,
    output_amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    if output_amount <= 0 {
        return Err(ArgusError::Generic("Amount must be positive".into()).to_json_string());
    }
    let set = crate::api_amm_impl::load_pools(node_url, false).await?;
    let (pool, erg_in) =
        crate::api_amm_impl::best_pool_for_output(&set.pools, &to_token, output_amount as u64)
            .ok_or_else(|| {
                ArgusError::Generic("NO_POOL: no Spectrum pool can deliver this amount".into())
                    .to_json_string()
            })?;
    serde_json::to_string(&serde_json::json!({
        "pool_id": pool.pool_id,
        "box_id": pool.box_id,
        "erg_in": erg_in,
        "output_amount": output_amount,
        "fee_num": pool.fee_num,
        "fee_denom": pool.fee_denom,
        "erg_reserves": pool.erg_reserves,
        "token_reserves": pool.token_y.amount,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a Spectrum direct swap: builds the transaction, caches it, and
/// returns a preview JSON with the `preparation_id` for the shared confirm →
/// broadcast flow.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn amm_build_swap(
    handle_id: u64,
    from_token: Option<String>,
    to_token: Option<String>,
    amount: i64,
    min_output: i64,
    pool_id: String,
    recipient_address: String,
    change_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
    held_tokens: i64,
) -> Result<String, String> {
    if amount <= 0 || min_output <= 0 {
        return Err(ArgusError::Generic("Amount must be positive".into()).to_json_string());
    }
    if held_tokens < 0 {
        return Err(
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string(),
        );
    }
    let (recipient_tree, change_tree) = resolve_dexy_destinations(
        handle_id,
        "amm_build_swap",
        &recipient_address,
        &change_address,
    )?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    // The pool's current box by its NFT: one indexed request, always fresh,
    // instead of re-downloading every Spectrum pool to locate it.
    let (pool_owned, pool_ergo_box) = crate::api_amm_impl::fetch_pool(&client, &pool_id).await?;
    let pool = &pool_owned;

    // The builders derive the output from the pool box alone — the N2T path
    // destructures `SwapInput::Token { amount, .. }` and never checks the token
    // id — so a pool_id that does not trade this pair would build a swap
    // delivering the wrong asset. Reject before building.
    if !crate::api_amm_impl::pool_supports(pool, from_token.as_deref(), to_token.as_deref()) {
        return Err(ArgusError::Generic(
            "PAIR_MISMATCH: the selected pool does not trade this pair — re-quote".into(),
        )
        .to_json_string());
    }
    let creation = client
        .get_box_creation_info(&pool_ergo_box.box_id().to_string())
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let pool_box = ergo_tx::Eip12InputBox::from_ergo_box(&pool_ergo_box, creation.0, creation.1);

    let (all_boxes, eip12) =
        gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?
        as i32;

    let input = crate::api_amm_impl::swap_input(from_token.as_deref(), amount as u64);
    let built = amm::direct_swap::build_direct_swap_eip12_with_held(
        &pool_box,
        pool,
        &input,
        min_output as u64,
        &eip12,
        &change_tree,
        height,
        Some(&recipient_tree),
        None,
        held_tokens as u64,
    )
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    // Argus levies no dev fee. Fail loudly rather than silently paying Citadel.
    let output_trees: Vec<String> = built
        .unsigned_tx
        .outputs
        .iter()
        .map(|o| o.ergo_tree.clone())
        .collect();
    if crate::api_amm_impl::pays_citadel_dev_fee(&output_trees) {
        return Err(ArgusError::Generic(
            "DEV_FEE_LEAK: built tx pays the Citadel dev fee — init_app guard failed".into(),
        )
        .to_json_string());
    }

    // Pool box is inputs[0]; user boxes follow in order.
    let selected_ids = built
        .unsigned_tx
        .inputs
        .iter()
        .skip(1)
        .map(|i| i.box_id.clone())
        .collect::<Vec<_>>();
    let user_boxes = ordered_user_boxes(&selected_ids, &all_boxes)?;

    let mut ergo_boxes = vec![pool_ergo_box];
    ergo_boxes.extend(user_boxes);

    let miner_fee = built.summary.miner_fee as i64;
    let change_erg = user_change_erg(&built.unsigned_tx, &change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: vec![],
        unsigned_tx: built.unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: 0,
        node_url,
    });

    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "input_amount": built.summary.input_amount,
        "input_token": built.summary.input_token,
        "output_amount": built.summary.output_amount,
        "output_token": built.summary.output_token,
        "min_output": built.summary.min_output,
        "miner_fee": built.summary.miner_fee,
        "total_erg_cost": built.summary.total_erg_cost,
        "pool_id": pool_id,
        "to_token": to_token,
        "held_amount": held_tokens,
        "delivered_amount": built.summary.output_amount as i64 + held_tokens,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recipients_token_shapes_are_alternatives_not_a_sum() {
        // The app writes both shapes when a recipient gets one token, so
        // that the single-recipient path can read the pair. Reading both
        // would send twice what was asked for.
        let both = serde_json::json!({
            "address": "9x",
            "tokens": [{"token_id": "tok_a", "amount": 250}],
            "token_id": "tok_a",
            "token_amount": 250,
        });
        assert_eq!(
            parse_recipient_tokens(&both).unwrap(),
            vec![("tok_a".to_string(), 250)]
        );
        // Several tokens in one box come through in order.
        let many = serde_json::json!({
            "tokens": [{"token_id": "tok_a", "amount": 1}, {"token_id": "tok_b", "amount": 2}],
            "token_id": "tok_a",
            "token_amount": 1,
        });
        assert_eq!(
            parse_recipient_tokens(&many).unwrap(),
            vec![("tok_a".to_string(), 1), ("tok_b".to_string(), 2)]
        );
        // The pair alone still works, and no tokens at all is fine.
        let pair = serde_json::json!({"token_id": "tok_a", "token_amount": 7});
        assert_eq!(
            parse_recipient_tokens(&pair).unwrap(),
            vec![("tok_a".to_string(), 7)]
        );
        assert!(parse_recipient_tokens(&serde_json::json!({"address": "9x"}))
            .unwrap()
            .is_empty());
        assert!(parse_recipient_tokens(&serde_json::json!({"tokens": []}))
            .unwrap()
            .is_empty());
        // A half-written pair is still refused rather than dropped.
        assert!(parse_recipient_tokens(&serde_json::json!({"token_id": "tok_a"})).is_err());
        assert!(parse_recipient_tokens(&serde_json::json!({
            "tokens": [{"token_id": "tok_a"}]
        }))
        .is_err());
    }

    #[test]
    fn a_reserved_funding_box_is_left_out_but_its_change_is_not() {
        fn eb(id: &str, value: i64, tokens: bool) -> ergo_tx::Eip12InputBox {
            ergo_tx::Eip12InputBox {
                box_id: id.into(),
                transaction_id: "t".into(),
                index: 0,
                value: value.to_string(),
                ergo_tree: "0008cd".into(),
                assets: if tokens { vec![ergo_tx::Eip12Asset::new("aa", 1)] } else { vec![] },
                creation_height: 1,
                additional_registers: Default::default(),
                extension: Default::default(),
            }
        }
        let handle = 77_777;
        mix_set_reserved_funding(
            handle,
            r#"[{"box_ids": ["fund", "change"], "value_nano_erg": 1006600000}]"#.into(),
        )
        .unwrap();
        // Clone out of the lock: the setter below takes it again.
        let r = recover(RESERVED_FUNDING.lock())[&handle][0].clone();
        assert!(r.covers(&eb("fund", 1_006_600_000, false)));
        assert!(!r.covers(&eb("change", 5_000, false)), "the change box is free");
        assert!(!r.covers(&eb("fund", 1_006_600_000, true)), "tokens: not the funding box");
        assert!(!r.covers(&eb("other", 1_006_600_000, false)), "another wallet box of the same size");
        assert!(!recover(RESERVED_FUNDING.lock()).contains_key(&(handle + 1)));
        // The filter itself: the funding box is dropped from what coin
        // selection sees, everything else stays, in order.
        let boxes = [
            eb("fund", 1_006_600_000, false),
            eb("change", 5_000, false),
            eb("other", 1_006_600_000, false),
            eb("fund", 1_006_600_000, true),
        ];
        let ergo: Vec<_> = boxes.iter().map(|b| crate::api_mix_impl::to_ergo_box(b).unwrap_or_else(|_| test_ergo_box(b))).collect();
        let (kept_boxes, kept) = without_reserved(handle, ergo, boxes.to_vec());
        assert_eq!(kept.iter().map(|b| b.box_id.as_str()).collect::<Vec<_>>(), ["change", "other", "fund"]);
        assert_eq!(kept_boxes.len(), 3);
        let (all_boxes, all) = without_reserved(handle + 1, kept_boxes.clone(), kept.clone());
        assert_eq!(all.len(), 3, "another handle has no reservation");
        assert_eq!(all_boxes.len(), 3);
        mix_set_reserved_funding(handle, "[]".into()).unwrap();
        assert!(!recover(RESERVED_FUNDING.lock()).contains_key(&handle));
        assert!(mix_set_reserved_funding(handle, "nope".into()).is_err());
    }

    /// A stand-in ErgoBox for a synthetic EIP-12 box whose id does not hash.
    fn test_ergo_box(b: &ergo_tx::Eip12InputBox) -> ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox {
        let node = serde_json::json!({
            "boxId": "00".repeat(32), "transactionId": "91".repeat(32), "index": 0,
            "value": b.value.parse::<i64>().unwrap(), "ergoTree": "0008cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a02",
            "creationHeight": 1, "assets": [], "additionalRegisters": {},
        });
        let err = serde_json::from_value::<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>(node.clone()).err().unwrap().to_string();
        let id = err.rsplit(' ').next().unwrap().to_string();
        let mut fixed = node; fixed["boxId"] = serde_json::json!(id);
        serde_json::from_value(fixed).unwrap()
    }

    #[test]
    fn mix_miner_fee_defaults_and_refuses_below_the_minimum() {
        assert_eq!(mix_miner_fee(None).unwrap(), TX_FEE_NANO);
        assert_eq!(
            mix_miner_fee(Some(TX_FEE_NANO + 1)).unwrap(),
            TX_FEE_NANO + 1
        );
        assert!(mix_miner_fee(Some(TX_FEE_NANO - 1)).is_err());
        assert!(mix_miner_fee(Some(-1)).is_err());
    }

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    #[test]
    fn generate_mnemonic_supports_the_15_word_ergo_standard() {
        let phrase = generate_mnemonic(160).expect("160-bit generation must work");
        let n = phrase.split_whitespace().count();
        assert_eq!(n, 15, "160-bit entropy must yield 15 words, got {n}");
        wallet_core::bip39::validate_phrase(&phrase)
            .expect("generated 15-word phrase must pass validation");
    }

    #[test]
    fn generate_mnemonic_covers_every_bip39_strength() {
        for (strength, words) in [(128u32, 12usize), (192, 18), (224, 21), (256, 24)] {
            let phrase = generate_mnemonic(strength)
                .unwrap_or_else(|e| panic!("{strength}-bit generation failed: {e}"));
            assert_eq!(
                phrase.split_whitespace().count(),
                words,
                "{strength}-bit entropy must yield {words} words"
            );
        }
        assert!(
            generate_mnemonic(129).is_err(),
            "unsupported strengths must be rejected, not substituted"
        );
    }

    #[test]
    fn dapp_prepare_sign_refuses_empty_and_foreign_transactions() {
        let session: serde_json::Value =
            serde_json::from_str(&wallet_create(APPKIT.to_string(), "".into()).unwrap()).unwrap();
        let handle_id: u64 = session["handle_id"].as_str().unwrap().parse().unwrap();
        let own_tree = address_to_ergo_tree(&derive_address(handle_id, 0).unwrap()).unwrap();
        let foreign_tree = "0008cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a02";
        let rt = tokio::runtime::Runtime::new().unwrap();
        let tx_with = |tree: &str| {
            let input = ergo_tx::Eip12InputBox {
                box_id: String::new(),
                transaction_id: "91".repeat(32),
                index: 0,
                value: "1000000000".into(),
                ergo_tree: tree.into(),
                assets: vec![],
                creation_height: 1000,
                additional_registers: Default::default(),
                extension: Default::default(),
            };
            serde_json::json!({
                "inputs": [{
                    "boxId": box_id_of(&input),
                    "transactionId": input.transaction_id, "index": 0, "value": input.value,
                    "ergoTree": input.ergo_tree, "creationHeight": 1000, "assets": [], "additionalRegisters": {}
                }],
                "outputs": [{"value": "998900000", "ergoTree": tree, "creationHeight": 1000, "assets": [], "additionalRegisters": {}},
                            {"value": "1100000", "ergoTree": citadel_core::constants::MINER_FEE_ERGO_TREE, "creationHeight": 1000, "assets": [], "additionalRegisters": {}}]
            })
            .to_string()
        };
        let err = |r: Result<String, String>| r.unwrap_err();
        assert!(err(rt.block_on(dapp_prepare_sign(handle_id, r#"{"inputs": [], "outputs": []}"#.into(), None))).contains("no inputs"));
        assert!(err(rt.block_on(dapp_prepare_sign(handle_id, tx_with(foreign_tree), None))).contains("another wallet"));
        let ok: serde_json::Value = serde_json::from_str(&rt.block_on(dapp_prepare_sign(handle_id, tx_with(&own_tree), None)).unwrap()).unwrap();
        assert!(ok["preparation_id"].as_u64().unwrap() > 0);
        assert_eq!(ok["miner_fee"], 1_100_000);
        assert_eq!(ok["summary"]["all_inputs_owned"], true);
    }

    /// The id ergo-lib gives a box with these fields: its JSON parser
    /// checks the id and names the computed one when it differs.
    fn box_id_of(input: &ergo_tx::Eip12InputBox) -> String {
        let node = serde_json::json!({
            "boxId": "00".repeat(32), "transactionId": input.transaction_id, "index": input.index,
            "value": input.value.parse::<i64>().unwrap(), "ergoTree": input.ergo_tree,
            "creationHeight": input.creation_height, "assets": [], "additionalRegisters": {},
        });
        let err = serde_json::from_value::<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>(node)
            .err()
            .expect("a zero id never matches")
            .to_string();
        err.rsplit(' ').next().unwrap().to_string()
    }

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
        assert!(serde_json::from_str::<serde_json::Value>(&blob)
            .unwrap()
            .get("k")
            .is_none());
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
    fn duckpools_state_values_holdings_from_the_captured_pool() {
        let boxes = format!(
            "[{}]",
            include_str!("../../vendor/protocols/duckpools/test/fixtures/pool_erg.json")
        );
        let lend = duckpools::POOLS[0].lend_token;
        let out =
            duckpools_state(boxes, format!(r#"{{"{lend}": 482880000}}"#), String::new()).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        let erg = &v[0];
        assert_eq!(erg["pool"], "erg");
        assert_eq!(erg["wallet_lend_tokens"], 482880000);
        let value = erg["wallet_value"].as_i64().unwrap();
        assert!((999_000_000..=1_000_100_000).contains(&value), "{value}");
        assert!(duckpools_pools().contains(lend));
        assert!(duckpools_state("[]".into(), "nope".into(), String::new()).is_err());
    }

    #[test]
    fn preparation_details_reads_without_consuming() {
        // Unknown id, or another wallet's, is refused.
        assert!(preparation_details(1, 424242).is_err());
        let id = store_preparation(CachedPreparation {
            handle_id: 5,
            ergo_boxes: Vec::new(),
            stealth_trees: Vec::new(),
            mix_proofs: Vec::new(),
            data_input_boxes: Vec::new(),
            unsigned_tx: ergo_tx::Eip12UnsignedTx {
                inputs: Vec::new(),
                data_inputs: Vec::new(),
                outputs: Vec::new(),
            },
            miner_fee: 1_100_000,
            change_erg: 0,
            recipient_erg: 0,
            node_url: None,
        });
        assert!(
            preparation_details(6, id).is_err(),
            "another wallet's preparation"
        );
        // An empty transaction cannot be converted, but the preparation must
        // still be there afterwards: details never consume.
        let _ = preparation_details(5, id);
        assert!(
            take_preparation(5, id).is_ok(),
            "still cached after details"
        );
    }

    #[test]
    fn take_preparation_rejects_unknown_stale_and_repeat() {
        assert!(take_preparation(1, 99).is_err());
        let id = store_preparation(CachedPreparation {
            handle_id: 7,
            stealth_trees: Vec::new(),
            mix_proofs: Vec::new(),
            ergo_boxes: Vec::new(),
            data_input_boxes: Vec::new(),
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
        assert_eq!(resolve_spend_addresses("9aaa", &[]), vec!["9aaa"]);
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
        assert_eq!(
            unwrap_key_with_pin(json.clone(), "123456".into()).unwrap(),
            key
        );
        assert!(unwrap_key_with_pin(json, "654321".into()).is_err());
    }

    fn test_input_box(
        box_id: &str,
        value: &str,
        assets: Vec<(&str, &str)>,
    ) -> ergo_tx::Eip12InputBox {
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

    #[tokio::test]
    async fn shared_gather_excludes_tracked_mixed_boxes() {
        use std::io::{Read, Write};
        let handle = WalletHandle::restore_from_seed(&[7; 64]).unwrap();
        let address = handle.derive_address(0).unwrap();
        let handle_id = register_handle(handle);
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../vendor/protocols/zerojoin/test/fixtures/half_mix_boxes.json"
        ))
        .unwrap();
        let mixed = fixture["items"][0]["boxId"].as_str().unwrap().to_string();
        let plain = fixture["items"][1]["boxId"].as_str().unwrap().to_string();
        mix_set_mixed_boxes(handle_id, vec![mixed.clone()]).unwrap();
        let body = serde_json::json!([fixture["items"][0], fixture["items"][1]]).to_string();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopped = stop.clone();
        let server = std::thread::spawn(move || {
            while !stopped.load(std::sync::atomic::Ordering::Relaxed) {
                let Ok((mut stream, _)) = listener.accept() else {
                    std::thread::sleep(std::time::Duration::from_millis(5));
                    continue;
                };
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                    .unwrap();
                let mut buffer = [0; 8192];
                let n = stream.read(&mut buffer).unwrap();
                let request = String::from_utf8_lossy(&buffer[..n]);
                let reply = if request.contains("/info") {
                    r#"{"fullHeight":1500000,"headersHeight":1500000}"#
                } else if request.contains("/blockchain/box/unspent/byAddress") {
                    &body
                } else {
                    "[]"
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    reply.len(),
                    reply
                )
                .unwrap();
            }
        });
        let result = gather_wallet_boxes(handle_id, &[address], Some(url)).await;
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        server.join().unwrap();
        mix_set_mixed_boxes(handle_id, vec![]).unwrap();
        wallet_lock(handle_id).unwrap();
        let (boxes, inputs) = result.unwrap();
        assert_eq!(
            inputs.iter().map(|b| b.box_id.clone()).collect::<Vec<_>>(),
            [plain]
        );
        assert_eq!(boxes.len(), inputs.len());
        assert!(boxes.iter().all(|b| b.box_id().to_string() != mixed));
    }

    #[test]
    fn withdrawal_override_is_kept_in_the_returned_state() {
        let handle = WalletHandle::restore_from_seed(&[8; 64]).unwrap();
        let address = handle.derive_address(0).unwrap();
        let expected_tree = address_to_ergo_tree(&address).unwrap();
        let mut state = zerojoin::MixState::new(
            0,
            zerojoin::RingSpec::erg(1_000_000_000),
            20,
            3,
            "old_destination".into(),
            1,
        );
        let paid_tree = mix_leave_destination(&mut state, Some(address)).unwrap();
        assert_eq!(paid_tree, expected_tree);
        let summary = zerojoin::MixTxSummary {
            action: "withdraw".into(),
            denomination: 1_000_000_000,
            mix_level_after: 0,
            tokens_burned: 0,
            miner_fee_nano: 1_100_000,
            operator_fee_nano: 0,
        };
        let raw = mix_move_result(state, zerojoin::Applied::Withdrawn, summary, "tx", 2).unwrap();
        let result: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(result["state"]["destination_ergo_tree"], paid_tree);
    }

    #[test]
    fn mixed_boxes_stay_out_of_automatic_selection_and_never_mix_with_others() {
        let mixed: HashSet<String> = ["m1", "m2"].iter().map(|s| s.to_string()).collect();
        let all = ["m1", "p1", "m2"];
        let auto = mixed_rule(&mixed, all.iter().copied(), None).unwrap();
        assert_eq!(auto.into_iter().collect::<Vec<_>>(), ["p1"]);
        let only_mixed = mixed_rule(&mixed, all.iter().copied(), Some(&["m1".into(), "m2".into()])).unwrap();
        assert_eq!(only_mixed.len(), 3, "a mixed-only choice sees everything; the filter picks");
        let err = mixed_rule(&mixed, all.iter().copied(), Some(&["m1".into(), "p1".into()])).unwrap_err();
        assert!(err.contains("undoes the mix"), "{err}");
        let none_mixed = mixed_rule(&mixed, all.iter().copied(), Some(&["p1".into()])).unwrap();
        assert_eq!(none_mixed.len(), 3);
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
            filtered
                .iter()
                .map(|input| input.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["b1", "b3"]
        );
        let error = filter_selected_inputs(inputs, &["b1".into(), "missing".into()]).unwrap_err();
        assert!(error.contains("selected UTXO(s) not found: missing"));
    }
}

// ---------------------------------------------------------------------------
// ZeroJoin mixing
// ---------------------------------------------------------------------------
//
// The Dart side persists each mix's state JSON and fetches chain snapshots
// (`{"half_boxes","full_boxes","fee_boxes","token_boxes","height"}`); these
// calls decide, build, sign and broadcast. See `api_mix_impl`.

fn mix_now(now_unix: i64) -> i64 {
    if now_unix > 0 {
        now_unix
    } else {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }
}

/// The miner fee for a mixing move: the caller's, or the default, refused
/// below the network minimum here rather than by the node after signing.
fn mix_miner_fee(fee_nano: Option<i64>) -> Result<i64, String> {
    let fee = fee_nano.unwrap_or(TX_FEE_NANO);
    if fee < TX_FEE_NANO {
        return Err(ArgusError::TxBuildFailed(format!(
            "custom fee {fee} nanoERG is below minimum {TX_FEE_NANO}"
        ))
        .to_json_string());
    }
    Ok(fee)
}

/// The four ErgoMixer contract trees, so the app can ask an explorer for
/// unspent boxes under each. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn mix_contract_trees() -> String {
    serde_json::json!({
        "half": zerojoin::HALF_MIX_ERGO_TREE_HEX,
        "full": zerojoin::FULL_MIX_ERGO_TREE_HEX,
        "fee": zerojoin::FEE_EMISSION_ERGO_TREE_HEX,
        "token": zerojoin::TOKEN_EMISSION_ERGO_TREE_HEX,
        "mixing_token_id": zerojoin::MIXING_TOKEN_ID,
    })
    .to_string()
}

/// Rings, token levels and operator boxes in a snapshot. Pure.
#[flutter_rust_bridge::frb]
pub fn mix_rings(chain_json: String) -> Result<String, String> {
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    Ok(crate::api_mix_impl::rings_json(&view).to_string())
}

/// What a funding box must hold to enter `denomination` at `level`. For a
/// token ring, `token_id` and `token_amount` name the ring and the answer
/// adds the token the box must carry (ring amount plus commission).
#[flutter_rust_bridge::frb]
pub fn mix_funding_requirement(
    chain_json: String,
    denomination: i64,
    level: i32,
    fee_nano: Option<i64>,
    token_id: Option<String>,
    token_amount: Option<i64>,
) -> Result<String, String> {
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let fee = mix_miner_fee(fee_nano)?;
    let ring_token = match (token_id, token_amount) {
        (Some(id), Some(amount)) => Some((id, amount)),
        (None, None) => None,
        _ => return Err(crate::api_mix_impl::ring_err("a token ring needs both a token id and an amount")),
    };
    Ok(crate::api_mix_impl::funding_requirement_for(&view, denomination, ring_token, level, fee)?.to_string())
}

/// A fresh mix state, not yet in the pool. `destination_address` is where
/// the money goes when the mix ends: a P2PK address or a stealth payment
/// address of this wallet's own.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub fn mix_new_state(
    mix_id: u32,
    denomination: i64,
    token_id: Option<String>,
    token_amount: Option<i64>,
    level: i32,
    rounds: u32,
    destination_address: String,
    now_unix: i64,
) -> Result<String, String> {
    let tree = address_to_ergo_tree(&destination_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let ring = zerojoin::RingSpec {
        value: denomination,
        token_id,
        token_amount,
    };
    let state = zerojoin::MixState::new(mix_id, ring, level, rounds, tree, mix_now(now_unix));
    crate::api_mix_impl::state_json(&state)
}

/// The next move for a mix, as JSON. Pure: builds nothing.
#[flutter_rust_bridge::frb]
pub fn mix_plan(
    state_json: String,
    chain_json: String,
    own_half_box_ids: Vec<String>,
) -> Result<String, String> {
    let state = crate::api_mix_impl::parse_state(&state_json)?;
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    serde_json::to_string(&zerojoin::plan(&state, &view, &own_half_box_ids))
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Fold the snapshot into the state: a half-mix box of ours that someone
/// joined becomes our full-mix box. Returns the (possibly unchanged) state.
#[flutter_rust_bridge::frb]
pub fn mix_observe(
    handle_id: u64,
    state_json: String,
    chain_json: String,
    now_unix: i64,
) -> Result<String, String> {
    let state = crate::api_mix_impl::parse_state(&state_json)?;
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let secret = with_handle(handle_id, "mix_observe", |h| {
        h.mix_secret(state.mix_id, state.round).map_err(err_str)
    })?;
    let next = zerojoin::observe(state, &view, &secret, mix_now(now_unix));
    crate::api_mix_impl::state_json(&next)
}

/// Rebuild every live mix of this wallet from the seed and a snapshot that
/// holds every unspent half- and full-mix box. Returns a JSON array of
/// states with no destination set.
#[flutter_rust_bridge::frb]
pub fn mix_recover(handle_id: u64, chain_json: String, now_unix: i64) -> Result<String, String> {
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let states = with_handle(handle_id, "mix_recover", |h| {
        Ok(zerojoin::recover(
            &view,
            |m, r| h.mix_secret(m, r).ok(),
            mix_now(now_unix),
        ))
    })?;
    serde_json::to_string(&states)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a mix's entry transaction from one of the wallet's own boxes.
/// Confirm it with `send_erg`; persist `next_state` only once that
/// succeeds.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn mix_prepare_entry(
    handle_id: u64,
    state_json: String,
    chain_json: String,
    funding_address: String,
    funding_box_id: String,
    own_half_box_ids: Vec<String>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
    now_unix: i64,
) -> Result<String, String> {
    let state = crate::api_mix_impl::parse_state(&state_json)?;
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let miner_fee = mix_miner_fee(fee_nano)?;
    let client = node_client(node_url.clone()).await?;
    let (_, unspent) = gather_unspent_all(handle_id, &client, &[funding_address]).await?;
    let funding = unspent
        .iter()
        .find(|b| b.box_id == funding_box_id)
        .ok_or_else(|| {
            ArgusError::NoUtxos("the funding box is not unspent at that address".into())
                .to_json_string()
        })?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;

    let built = with_handle(handle_id, "mix_prepare_entry", |h| {
        crate::api_mix_impl::build_entry(
            &crate::api_mix_impl::handle_secrets(h, state.mix_id),
            &state,
            &view,
            funding,
            &own_half_box_ids,
            miner_fee,
            height,
        )
    })?;
    let ergo_boxes = built
        .inputs
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let input_boxes = input_boxes_json(&built.inputs);
    let summary = built.tx.summary.clone();
    let next_state = state.after(built.applied, "", mix_now(now_unix));
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: built.recipes,
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx: built.tx.unsigned_tx,
        miner_fee,
        change_erg: 0,
        recipient_erg: summary.denomination,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "action": summary.action,
        "summary": summary,
        "next_state": next_state,
        "input_boxes": input_boxes,
        "miner_fee": miner_fee,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Reduce, sign and broadcast one built move with the unlocked wallet.
async fn broadcast_mix_move(
    handle_id: u64,
    built: crate::api_mix_impl::BuiltMove,
    client: &ErgoNodeClient,
    op: &'static str,
) -> Result<String, String> {
    broadcast_mix_move_with(built, client, |reduced, extra| {
        with_handle(handle_id, op, |handle| {
            handle
                .sign_reduced_with_secrets(reduced, extra)
                .map_err(err_str)
        })
    })
    .await
}

/// Reduce, sign with `sign` and broadcast one built move. Returns the
/// transaction id.
async fn broadcast_mix_move_with(
    built: crate::api_mix_impl::BuiltMove,
    client: &ErgoNodeClient,
    sign: impl FnOnce(
        ReducedTransaction,
        Vec<ergo_lib::wallet::secret_key::SecretKey>,
    ) -> Result<ergo_lib::chain::transaction::Transaction, String>,
) -> Result<String, String> {
    let ergo_boxes = built
        .inputs
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let state_context = client
        .get_state_context()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let reduced_bytes = reduce_transaction_with_context(
        &built.tx.unsigned_tx,
        ergo_boxes,
        Vec::new(),
        &state_context,
    )
    .map_err(|e| ArgusError::TxReductionFailed(e.to_string()).to_json_string())?;
    let extra: Vec<_> = built
        .tx
        .prover_inputs
        .into_iter()
        .map(|p| p.into_secret_key())
        .collect();
    let reduced = ReducedTransaction::sigma_parse_bytes(&reduced_bytes)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let signed = sign(reduced, extra)?;
    let tx_json = serde_json::to_value(&signed)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    client
        .submit_transaction(&tx_json)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())
}

// ---------------------------------------------------------------------------
// Background mixing: the same moves from a stored mix key, no wallet needed
// ---------------------------------------------------------------------------

/// The key for one mix, as hex, for the app's keystore. It derives every
/// round of that mix and nothing else; see `zerojoin::MixKey`.
#[flutter_rust_bridge::frb]
pub fn mix_export_key(handle_id: u64, mix_id: u32) -> Result<String, String> {
    with_handle(handle_id, "mix_export_key", |h| {
        let key = h.mix_key(mix_id).map_err(err_str)?;
        let bytes = key
            .to_bytes()
            .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
        Ok(hex::encode(&bytes[..]))
    })
}

/// `mix_observe` from a stored key instead of the unlocked wallet.
#[flutter_rust_bridge::frb]
pub fn mix_observe_with_key(
    state_json: String,
    chain_json: String,
    key_hex: String,
    now_unix: i64,
) -> Result<String, String> {
    let state = crate::api_mix_impl::parse_state(&state_json)?;
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let key = crate::api_mix_impl::parse_key(&key_hex, state.mix_id)?;
    let secret = key
        .round_secret(state.round)
        .map_err(|e| ArgusError::SigningFailed(e.to_string()).to_json_string())?;
    let next = zerojoin::observe(state, &view, &secret, mix_now(now_unix));
    crate::api_mix_impl::state_json(&next)
}

/// `mix_advance` from a stored key. Remixes and withdrawals spend only mix
/// boxes and the operator's fee box, so the round secrets sign them alone:
/// no wallet key, no seed, no unlock.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn mix_advance_with_key(
    state_json: String,
    chain_json: String,
    own_half_box_ids: Vec<String>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
    now_unix: i64,
    key_hex: String,
) -> Result<String, String> {
    let now = mix_now(now_unix);
    let state = crate::api_mix_impl::parse_state(&state_json)?;
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let key = crate::api_mix_impl::parse_key(&key_hex, state.mix_id)?;
    let miner_fee = mix_miner_fee(fee_nano)?;
    let client = node_client(node_url).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;

    let built = crate::api_mix_impl::build_move(
        &crate::api_mix_impl::key_secrets(&key),
        &state,
        &view,
        &own_half_box_ids,
        miner_fee,
        height,
    )?;
    let Some(built) = built else {
        let plan = zerojoin::plan(&state, &view, &own_half_box_ids);
        return serde_json::to_string(&serde_json::json!({
            "state": state,
            "action": "wait",
            "plan": plan,
        }))
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string());
    };
    let applied = built.applied.clone();
    let summary = built.tx.summary.clone();
    let tx_id = broadcast_mix_move_with(built, &client, |reduced, extra| {
        ergo_lib::wallet::Wallet::from_secrets(extra)
            .sign_reduced_transaction(reduced, None)
            .map_err(|e| ArgusError::SigningFailed(e.to_string()).to_json_string())
    })
    .await?;
    mix_move_result(state, applied, summary, &tx_id, now)
}

fn mix_move_result(
    state: zerojoin::MixState,
    applied: zerojoin::Applied,
    summary: zerojoin::MixTxSummary,
    tx_id: &str,
    now: i64,
) -> Result<String, String> {
    let next = state.after(applied, tx_id, now);
    serde_json::to_string(&serde_json::json!({
        "state": next,
        "action": summary.action,
        "summary": summary,
        "tx_id": tx_id,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Advance a mix already in the pool by one move: remix as Bob or Alice,
/// or withdraw once the rounds are done. Broadcasts and returns the new
/// state, or `{"state": <unchanged>, "action": "wait", "reason": …}` when
/// there is nothing to do yet.
#[flutter_rust_bridge::frb]
pub async fn mix_advance(
    handle_id: u64,
    state_json: String,
    chain_json: String,
    own_half_box_ids: Vec<String>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
    now_unix: i64,
) -> Result<String, String> {
    let now = mix_now(now_unix);
    let state = crate::api_mix_impl::parse_state(&state_json)?;
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let miner_fee = mix_miner_fee(fee_nano)?;
    let client = node_client(node_url).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;

    let built = with_handle(handle_id, "mix_advance", |h| {
        crate::api_mix_impl::build_move(
            &crate::api_mix_impl::handle_secrets(h, state.mix_id),
            &state,
            &view,
            &own_half_box_ids,
            miner_fee,
            height,
        )
    })?;
    let Some(built) = built else {
        let plan = zerojoin::plan(&state, &view, &own_half_box_ids);
        return serde_json::to_string(&serde_json::json!({
            "state": state,
            "action": "wait",
            "plan": plan,
        }))
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string());
    };
    let applied = built.applied.clone();
    let summary = built.tx.summary.clone();
    let tx_id = broadcast_mix_move(handle_id, built, &client, "mix_advance").await?;
    mix_move_result(state, applied, summary, &tx_id, now)
}

/// Take a mix's money out now: withdraw a full-mix box or reclaim a
/// half-mix box nobody joined. `destination_address` overrides the one
/// chosen at the start (required for a recovered mix, which has none).
#[flutter_rust_bridge::frb]
pub async fn mix_leave(
    handle_id: u64,
    state_json: String,
    chain_json: String,
    destination_address: Option<String>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
    now_unix: i64,
) -> Result<String, String> {
    let now = mix_now(now_unix);
    let mut state = crate::api_mix_impl::parse_state(&state_json)?;
    let view = crate::api_mix_impl::parse_view(&chain_json)?;
    let miner_fee = mix_miner_fee(fee_nano)?;
    let destination = mix_leave_destination(&mut state, destination_address)?;
    let client = node_client(node_url).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let built = with_handle(handle_id, "mix_leave", |h| {
        crate::api_mix_impl::build_leave(
            &crate::api_mix_impl::handle_secrets(h, state.mix_id),
            &state,
            &view,
            &destination,
            miner_fee,
            height,
        )
    })?;
    let applied = built.applied.clone();
    let summary = built.tx.summary.clone();
    let tx_id = broadcast_mix_move(handle_id, built, &client, "mix_leave").await?;
    mix_move_result(state, applied, summary, &tx_id, now)
}

fn mix_leave_destination(
    state: &mut zerojoin::MixState,
    destination_address: Option<String>,
) -> Result<String, String> {
    let destination = match destination_address {
        Some(a) => {
            address_to_ergo_tree(&a).map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?
        }
        None => state.destination_ergo_tree.clone(),
    };
    state.destination_ergo_tree = destination.clone();
    Ok(destination)
}

// ---------------------------------------------------------------------------
// Duckpools lending: read-only pool state and positions
// ---------------------------------------------------------------------------

/// The eight mainnet pools: key, ticker, decimals, ids and the pool script
/// the app queries the chain by. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn duckpools_pools() -> String {
    serde_json::json!(duckpools::POOLS
        .iter()
        .map(|p| serde_json::json!({
            "key": p.key,
            "ticker": p.ticker,
            "decimals": p.decimals,
            "pool_nft": p.pool_nft,
            "lend_token": p.lend_token,
            "borrow_token": p.borrow_token,
            "currency_id": p.currency_id,
            "ergo_tree": p.ergo_tree,
            "interest_param_nft": p.interest_param_nft,
            "lend_proxy_address": p.lend_proxy_address,
            "withdraw_proxy_address": p.withdraw_proxy_address,
            "fee_thresholds": [p.fee_thresholds.0, p.fee_thresholds.1],
            "param_nft": p.param_nft,
            "child_nft": p.child_nft,
            "parent_nft": p.parent_nft,
            "collateral_address": p.collateral_address,
            "borrow_proxy_address": p.borrow_proxy_address,
            "repay_proxy_address": p.repay_proxy_address,
            "partial_repay_proxy_address": p.partial_repay_proxy_address,
            "collateral_ergo_tree": address_to_ergo_tree(p.collateral_address).unwrap_or_default(),
            "erg_dex_nft": p.erg_dex_nft,
            "dex_nfts": p.dex_nfts(),
            "token_collaterals": p.token_collaterals,
        }))
        .collect::<Vec<_>>())
    .to_string()
}

/// Pool state from a list of pool boxes (explorer or node shape), with the
/// wallet's position in each and, when the interest parameter boxes are
/// given, the yearly rates. `holdings_json` maps token id to the amount
/// the wallet holds. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn duckpools_state(
    pool_boxes_json: String,
    holdings_json: String,
    interest_boxes_json: String,
) -> Result<String, String> {
    crate::api_duckpools_impl::state_json(&pool_boxes_json, &holdings_json, &interest_boxes_json)
}

/// A lend or withdraw quote at today's pool state. `amount` is asset units
/// for a lend, lend tokens for a withdraw. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn duckpools_quote(
    pool_boxes_json: String,
    pool_key: String,
    kind: String,
    amount: i64,
    slippage_bps: i64,
    refund_height: i64,
) -> Result<String, String> {
    let (pool, state) = crate::api_duckpools_impl::state_for(&pool_boxes_json, &pool_key)?;
    let q = crate::api_duckpools_impl::Quote::new(
        pool,
        &state,
        &kind,
        amount,
        slippage_bps,
        refund_height,
        None,
    )?;
    Ok(q.json().to_string())
}

/// The wallet's loans and the markets it can borrow in, from one JSON
/// object of boxes: `collateral` (every box under the collateral scripts),
/// `parents` and `children` (the interest boxes), `dex` (the Spectrum
/// ERG pools that price collateral) and `params` (the pool parameter
/// boxes). `wallet_addresses` are the wallet's addresses. Pure, but the
/// collateral list is unbounded, so it runs off the UI isolate.
#[flutter_rust_bridge::frb]
pub async fn duckpools_loans(
    loan_boxes_json: String,
    wallet_addresses: Vec<String>,
    height: i64,
) -> Result<String, String> {
    let trees = wallet_addresses
        .iter()
        .map(|a| address_to_ergo_tree(a))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    crate::api_duckpools_impl::loans_json(&loan_boxes_json, &trees, height)
}

/// A borrow, repay or partial-repay quote. Borrow: `amount` is the loan,
/// `collateral_amount` what is put up (nanoERG for a token pool; units of
/// `collateral_asset` for the ERG pool). Repay: `collateral_box_id` names
/// the loan. Partial repay: both `amount` (the repayment) and the box id.
/// Pure.
#[flutter_rust_bridge::frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn duckpools_loan_quote(
    pool_boxes_json: String,
    loan_boxes_json: String,
    pool_key: String,
    kind: String,
    amount: i64,
    collateral_asset: String,
    collateral_amount: i64,
    collateral_box_id: String,
    height: i64,
) -> Result<String, String> {
    let (pool, state) = crate::api_duckpools_impl::state_for(&pool_boxes_json, &pool_key)?;
    let root: serde_json::Value = serde_json::from_str(&loan_boxes_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let snapshot = crate::api_duckpools_impl::LoanSnapshot::parse(pool, &root)?;
    let q = crate::api_duckpools_impl::Quote::new(
        pool,
        &state,
        &kind,
        amount,
        0,
        0,
        Some(crate::api_duckpools_impl::LoanArgs {
            snapshot: &snapshot,
            collateral_asset: &collateral_asset,
            collateral_amount,
            collateral_box_id: &collateral_box_id,
            height,
        }),
    )?;
    Ok(q.json().to_string())
}

/// Prepare an order: the proxy box from the wallet's boxes, confirmed with
/// `send_erg`. The proxy pays fills and refunds to `user_address`, which
/// must be this wallet's. Returns the preparation, the quote, the proxy
/// box id (known before signing) and the refund height. Loan-side kinds
/// (`borrow`, `repay`, `partial_repay`) need `loan_boxes_json` as
/// `duckpools_loans` takes it, plus `collateral_amount` (and, for the ERG
/// pool, `collateral_asset`) for a borrow and `collateral_box_id` for a
/// repayment.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn duckpools_prepare_order(
    handle_id: u64,
    pool_boxes_json: String,
    pool_key: String,
    kind: String,
    amount: i64,
    slippage_bps: i64,
    refund_after_blocks: i64,
    user_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
    loan_boxes_json: Option<String>,
    collateral_asset: Option<String>,
    collateral_amount: Option<i64>,
    collateral_box_id: Option<String>,
) -> Result<String, String> {
    let (pool, state) = crate::api_duckpools_impl::state_for(&pool_boxes_json, &pool_key)?;
    let snapshot = match loan_boxes_json.as_deref().filter(|s| !s.trim().is_empty()) {
        Some(json) => {
            let root: serde_json::Value = serde_json::from_str(json)
                .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
            Some(crate::api_duckpools_impl::LoanSnapshot::parse(pool, &root)?)
        }
        None => None,
    };
    let miner_fee = mix_miner_fee(fee_nano)?;
    let (user_tree, change_tree) = with_handle(handle_id, "duckpools_prepare_order", |h| {
        for a in [&user_address, &change_address] {
            if !h.owns_address(a).map_err(err_str)? {
                return Err(ArgusError::InvalidAddress(
                    "order addresses must belong to this wallet".into(),
                )
                .to_json_string());
            }
        }
        Ok((
            address_to_ergo_tree(&user_address)
                .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?,
            address_to_ergo_tree(&change_address)
                .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?,
        ))
    })?;
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    if refund_after_blocks < 30 {
        return Err(ArgusError::TxBuildFailed(
            "give the bots at least 30 blocks before a refund".into(),
        )
        .to_json_string());
    }
    let refund_height = height as i64 + refund_after_blocks;
    let collateral_box_id = collateral_box_id.unwrap_or_default();
    let collateral_asset = collateral_asset.unwrap_or_default();
    let quote = crate::api_duckpools_impl::Quote::new(
        pool,
        &state,
        &kind,
        amount,
        slippage_bps,
        refund_height,
        snapshot.as_ref().map(|snapshot| crate::api_duckpools_impl::LoanArgs {
            snapshot,
            collateral_asset: &collateral_asset,
            collateral_amount: collateral_amount.unwrap_or(0),
            collateral_box_id: &collateral_box_id,
            height: height as i64,
        }),
    )?;
    let proxy = quote.proxy_box(pool, &user_tree)?;
    let spend: Vec<String> = if spend_addresses.is_empty() {
        vec![user_address.clone()]
    } else {
        spend_addresses
    };
    let (boxes, utxos) = gather_unspent(handle_id, &client, &spend).await?;
    let (_, utxos) = apply_mixed_rule(handle_id, boxes, utxos, None)?;
    let fee_cfg = ergo_tx::resolved_dev_fee_config();
    let app_fee = if fee_cfg.enabled {
        Some((fee_cfg.recipient_ergo_tree.as_str(), fee_cfg.budget()))
    } else {
        None
    };
    let token = quote.token_needed(pool);
    let (unsigned_tx, used) = crate::api_duckpools_impl::build_order(
        &proxy,
        &utxos,
        token.as_ref().map(|(id, n)| (id.as_str(), *n)),
        &change_tree,
        app_fee,
        miner_fee,
        height,
    )?;
    let ergo_boxes = used
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let proxy_box_id = ergo_tx::chain::derive_output_boxes(&unsigned_tx)
        .map(|(_, outs)| outs.first().map(|b| b.box_id.clone()).unwrap_or_default())
        .map_err(|e| ArgusError::TxBuildFailed(e).to_json_string())?;
    let input_boxes = input_boxes_json(&used);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx,
        miner_fee,
        change_erg: 0,
        recipient_erg: quote.box_value(),
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "quote": quote.json(),
        "proxy_box_id": proxy_box_id,
        "refund_height": refund_height,
        "height": height,
        "miner_fee": miner_fee,
        "app_fee_nano": app_fee.map(|(_, n)| n).unwrap_or(0),
        "input_boxes": input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare the refund of an unfilled order after its refund height: the
/// proxy box back to `user_address` less the contract's one fee. Confirm
/// with `send_erg`. The proxy contracts need no signature for this; they
/// check the outputs. A borrow order also accepts the borrower's own
/// signature at any height, and the wallet signs, so it can be taken
/// back early.
#[flutter_rust_bridge::frb]
pub async fn duckpools_prepare_refund(
    handle_id: u64,
    proxy_box_json: String,
    user_address: String,
    node_url: Option<String>,
) -> Result<String, String> {
    let proxy = zerojoin::parse_explorer_boxes(&format!("[{proxy_box_json}]"))
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?
        .into_iter()
        .next()
        .ok_or_else(|| ArgusError::SerializationError("no proxy box".into()).to_json_string())?;
    let user_tree = with_handle(handle_id, "duckpools_prepare_refund", |h| {
        if !h.owns_address(&user_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "refund address must belong to this wallet".into(),
            )
            .to_json_string());
        }
        address_to_ergo_tree(&user_address)
            .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())
    })?;
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let unsigned_tx = duckpools::build_refund_tx(&proxy, &user_tree, height)
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let value: i64 = unsigned_tx.outputs[0].value.parse().unwrap_or(0);
    let ergo_box = crate::api_mix_impl::to_ergo_box(&proxy)?;
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes: vec![ergo_box],
        data_input_boxes: Vec::new(),
        unsigned_tx,
        miner_fee: duckpools::TX_FEE,
        change_erg: 0,
        recipient_erg: value,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "value_nano_erg": value,
        "miner_fee": duckpools::TX_FEE,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Quote a collateral adjustment: `new_amount` is the collateral the loan
/// should hold afterwards (nanoERG, or the token's units for an ERG pool
/// loan). Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn duckpools_adjust_quote(
    loan_boxes_json: String,
    pool_key: String,
    collateral_box_id: String,
    new_amount: i64,
    height: i64,
) -> Result<String, String> {
    let pool = duckpools::pool_by_key(&pool_key)
        .ok_or_else(|| ArgusError::TxBuildFailed(format!("unknown pool {pool_key}")).to_json_string())?;
    let root: serde_json::Value = serde_json::from_str(&loan_boxes_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let snapshot = crate::api_duckpools_impl::LoanSnapshot::parse(pool, &root)?;
    let (_, quote) = snapshot.adjust_quote(&collateral_box_id, new_amount, height)?;
    serde_json::to_string(&quote)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare a collateral adjustment: the borrower's own spend of the
/// collateral box, with the interest and price boxes as data inputs and
/// the wallet's boxes for whatever is added and the fee. Confirm with
/// `send_erg`; the wallet's key for the loan signs it. No bot is
/// involved and nothing waits for a fill.
#[flutter_rust_bridge::frb]
#[allow(clippy::too_many_arguments)]
pub async fn duckpools_prepare_adjust(
    handle_id: u64,
    loan_boxes_json: String,
    pool_key: String,
    collateral_box_id: String,
    new_amount: i64,
    user_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let pool = duckpools::pool_by_key(&pool_key)
        .ok_or_else(|| ArgusError::TxBuildFailed(format!("unknown pool {pool_key}")).to_json_string())?;
    let root: serde_json::Value = serde_json::from_str(&loan_boxes_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let snapshot = crate::api_duckpools_impl::LoanSnapshot::parse(pool, &root)?;
    let miner_fee = mix_miner_fee(fee_nano)?;
    let change_tree = with_handle(handle_id, "duckpools_prepare_adjust", |h| {
        for a in [&user_address, &change_address] {
            if !h.owns_address(a).map_err(err_str)? {
                return Err(ArgusError::InvalidAddress(
                    "adjustment addresses must belong to this wallet".into(),
                )
                .to_json_string());
            }
        }
        address_to_ergo_tree(&change_address)
            .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())
    })?;
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let (position, quote) = snapshot.adjust_quote(&collateral_box_id, new_amount, height as i64)?;
    let data = snapshot.adjust_data_inputs(&root, &position)?;
    let collateral = snapshot.collateral_input(&collateral_box_id)?;
    let spend: Vec<String> = if spend_addresses.is_empty() {
        vec![user_address.clone()]
    } else {
        spend_addresses
    };
    let (boxes, utxos) = gather_unspent(handle_id, &client, &spend).await?;
    let (_, utxos) = apply_mixed_rule(handle_id, boxes, utxos, None)?;
    // gather_unspent has just proved every spend address is this wallet's,
    // so the loan is ours only if its borrower is one of them. Without
    // this the wallet would build a transaction it can never sign.
    let owns_loan = spend
        .iter()
        .chain(std::iter::once(&user_address))
        .filter_map(|a| address_to_ergo_tree(a).ok())
        .any(|t| t.eq_ignore_ascii_case(&position.borrower_tree));
    if !owns_loan {
        return Err(
            ArgusError::TxBuildFailed("that loan was not borrowed by this wallet".into())
                .to_json_string(),
        );
    }
    let (erg_needed, token) = quote.wallet_needs();
    let mut built = None;
    for extra in [0i64, duckpools::MIN_BOX_VALUE] {
        let selected = wallet_core::spend::select_for_send(
            &utxos,
            (erg_needed + miner_fee + extra) as u64,
            token.as_ref().map(|(id, n)| (id.as_str(), *n as u64)),
        )
        .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
        match duckpools::build_adjust_tx(
            &quote,
            &collateral,
            &selected.boxes,
            &data,
            &change_tree,
            miner_fee,
            height as i32,
        ) {
            Ok(tx) => {
                built = Some((tx, selected.boxes));
                break;
            }
            Err(e) if extra == 0 && e.to_string().contains("change") => continue,
            Err(e) => return Err(ArgusError::TxBuildFailed(e.to_string()).to_json_string()),
        }
    }
    let (unsigned_tx, used) = built.ok_or_else(|| {
        ArgusError::TxBuildFailed("could not select inputs that leave a valid change box".into())
            .to_json_string()
    })?;
    let mut ergo_boxes = vec![crate::api_mix_impl::to_ergo_box(&collateral)?];
    for b in &used {
        ergo_boxes.push(crate::api_mix_impl::to_ergo_box(b)?);
    }
    let data_input_boxes = [&data.base_child, &data.parent, &data.head_child, &data.dex]
        .into_iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let change_erg = user_change_erg(&unsigned_tx, &change_tree);
    let input_boxes = input_boxes_json(&used);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes,
        unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: 0,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "quote": quote,
        "height": height,
        "miner_fee": miner_fee,
        "input_boxes": input_boxes,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// What the transaction that spent a proxy box did with it: filled,
/// refunded, or something else. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn duckpools_order_outcome(
    kind: String,
    proxy_box_id: String,
    tx_json: String,
) -> Result<String, String> {
    crate::api_duckpools_impl::outcome_json(&kind, &proxy_box_id, &tx_json)
}

// ── SigmaFi ─────────────────────────────────────────────────────────────

/// The loan assets SigmaFi lists, each with the order and bond scripts
/// whose boxes make up the market. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn sigmafi_contracts() -> String {
    crate::api_sigmafi_impl::contracts_json()
}

/// Boxes under the SigmaFi scripts (explorer or node JSON, one array)
/// read into open orders and active bonds at `height`. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn sigmafi_market(boxes_json: String, height: i64) -> Result<String, String> {
    crate::api_sigmafi_impl::market_json(&boxes_json, height)
}

/// Prepare a loan request: the collateral into an order box the wallet's
/// `user_address` key can cancel. Confirm with `send_erg`.
#[allow(clippy::too_many_arguments)]
#[flutter_rust_bridge::frb]
pub async fn sigmafi_prepare_open(
    handle_id: u64,
    loan_asset: String,
    principal: i64,
    repayment: i64,
    term_blocks: i64,
    collateral_erg: i64,
    collateral_tokens_json: String,
    user_address: String,
    spend_addresses: Vec<String>,
    change_address: String,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let miner_fee = mix_miner_fee(fee_nano)?;
    if sigmafi::loan_token(&loan_asset).is_none() {
        return Err(ArgusError::TxBuildFailed(format!(
            "SigmaFi does not lend {loan_asset}"
        ))
        .to_json_string());
    }
    let (user_tree, change_tree) = with_handle(handle_id, "sigmafi_prepare_open", |h| {
        for a in [&user_address, &change_address] {
            if !h.owns_address(a).map_err(err_str)? {
                return Err(ArgusError::InvalidAddress(
                    "order addresses must belong to this wallet".into(),
                )
                .to_json_string());
            }
        }
        Ok((
            address_to_ergo_tree(&user_address)
                .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?,
            address_to_ergo_tree(&change_address)
                .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?,
        ))
    })?;
    let collateral_tokens = crate::api_sigmafi_impl::parse_collateral_tokens(&collateral_tokens_json)?;
    let to_u64 = |n: i64, what: &str| {
        u64::try_from(n).map_err(|_| ArgusError::TxBuildFailed(format!("{what} is negative")).to_json_string())
    };
    let principal = to_u64(principal, "the loan")?;
    let repayment = to_u64(repayment, "the repayment")?;
    let collateral_erg = to_u64(collateral_erg, "the collateral")?;
    let term_blocks = i32::try_from(term_blocks)
        .map_err(|_| ArgusError::TxBuildFailed("term".into()).to_json_string())?;
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let spend: Vec<String> = if spend_addresses.is_empty() {
        vec![user_address.clone()]
    } else {
        spend_addresses
    };
    let (boxes, utxos) = gather_unspent(handle_id, &client, &spend).await?;
    let (_, utxos) = apply_mixed_rule(handle_id, boxes, utxos, None)?;
    let unsigned_tx = sigmafi::build_open_order(&sigmafi::OpenOrderRequest {
        borrower_tree: &user_tree,
        change_tree: Some(&change_tree),
        loan_asset: &loan_asset,
        principal,
        repayment,
        term_blocks,
        collateral_erg,
        collateral_tokens: &collateral_tokens,
        utxos: &utxos,
        height,
        miner_fee,
    })
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;
    let used: Vec<ergo_tx::Eip12InputBox> = unsigned_tx.inputs.clone();
    let ergo_boxes = used
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let order_box_id = ergo_tx::chain::derive_output_boxes(&unsigned_tx)
        .map(|(_, outs)| outs.first().map(|b| b.box_id.clone()).unwrap_or_default())
        .map_err(|e| ArgusError::TxBuildFailed(e).to_json_string())?;
    let order_value: i64 = unsigned_tx.outputs[0].value.parse().unwrap_or(0);
    let change_erg = user_change_erg(&unsigned_tx, &change_tree);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: order_value,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "order_box_id": order_box_id,
        "order_value": order_value,
        "height": height,
        "miner_fee": miner_fee,
        "dev_fee": sigmafi::dev_fee(principal),
        "ui_fee": sigmafi::ui_fee(principal),
        "input_boxes": input_boxes_json(&used),
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Prepare one of the spends of a SigmaFi box: `cancel` an order of this
/// wallet, `close` (fill) anyone's order as the lender, `repay` a bond
/// this wallet borrowed, or `liquidate` a matured bond this wallet lent.
/// `box_json` is the box as the explorer or node returned it. The
/// interface fee a fill pays goes to Argus. Confirm with `send_erg`.
#[flutter_rust_bridge::frb]
pub async fn sigmafi_prepare_spend(
    handle_id: u64,
    action: String,
    box_json: String,
    user_address: String,
    spend_addresses: Vec<String>,
    node_url: Option<String>,
    fee_nano: Option<i64>,
) -> Result<String, String> {
    let miner_fee = mix_miner_fee(fee_nano)?;
    let protocol_box = crate::api_sigmafi_impl::parse_box(&box_json)?;
    let user_tree = with_handle(handle_id, "sigmafi_prepare_spend", |h| {
        if !h.owns_address(&user_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "the address must belong to this wallet".into(),
            )
            .to_json_string());
        }
        address_to_ergo_tree(&user_address).map_err(|e| ArgusError::InvalidAddress(e).to_json_string())
    })?;
    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let spend = crate::api_sigmafi_impl::Spend::read(&action, &protocol_box, height)?;
    if let Some(required) = spend.required_address() {
        let owns = with_handle(handle_id, "sigmafi_prepare_spend", |h| {
            h.owns_address(required).map_err(err_str)
        })?;
        if !owns {
            return Err(ArgusError::TxBuildFailed(format!(
                "this {} belongs to {}, not to this wallet",
                if action == "cancel" { "order" } else { "bond" },
                required
            ))
            .to_json_string());
        }
    }
    let ui_fee_tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let mut spend_from: Vec<String> = if spend_addresses.is_empty() {
        vec![user_address.clone()]
    } else {
        spend_addresses
    };
    // The change returns to the key the contract names; that address must
    // be readable too, or its own boxes would be left out of the spend.
    if let Some(required) = spend.required_address() {
        if !spend_from.iter().any(|a| a == required) {
            spend_from.push(required.to_string());
        }
    }
    let (boxes, utxos) = gather_unspent(handle_id, &client, &spend_from).await?;
    let (_, utxos) = apply_mixed_rule(handle_id, boxes, utxos, None)?;
    let unsigned_tx = spend.build(&protocol_box, &user_tree, &ui_fee_tree, &utxos, height, miner_fee)?;
    let ergo_boxes = unsigned_tx
        .inputs
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let change_tree = spend.change_tree(&user_tree);
    let change_erg = user_change_erg(&unsigned_tx, &change_tree);
    let first_out: i64 = unsigned_tx.outputs[0].value.parse().unwrap_or(0);
    let input_boxes = input_boxes_json(&unsigned_tx.inputs);
    let mut summary = spend.summary(height);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: first_out,
        node_url,
    });
    summary["preparation_id"] = serde_json::json!(preparation_id);
    summary["miner_fee"] = serde_json::json!(miner_fee);
    summary["height"] = serde_json::json!(height);
    summary["input_boxes"] = serde_json::json!(input_boxes);
    Ok(summary.to_string())
}

// ── EIP-12 dApp connector ───────────────────────────────────────────────

/// Check and summarise an unsigned EIP-12 transaction a dApp page asks
/// the wallet to sign. Every input and data input must carry its whole
/// box, and each must hash back to its id, so a page cannot slip a
/// mangled box past the reducer. The result carries `preparation_id`
/// for the confirm sheet and `sign_preparation`, and the same summary
/// ErgoPay requests show.
#[flutter_rust_bridge::frb]
pub async fn dapp_prepare_sign(
    handle_id: u64,
    tx_json: String,
    node_url: Option<String>,
) -> Result<String, String> {
    let unsigned_tx = crate::api_dapp_impl::parse_unsigned(&tx_json)?;
    if unsigned_tx.inputs.is_empty() || unsigned_tx.outputs.is_empty() {
        return Err(ArgusError::TxBuildFailed(
            "the transaction has no inputs or no outputs".into(),
        )
        .to_json_string());
    }
    let ergo_boxes = unsigned_tx
        .inputs
        .iter()
        .map(crate::api_mix_impl::to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let data_input_boxes = unsigned_tx
        .data_inputs
        .iter()
        .map(crate::api_dapp_impl::data_input_to_ergo_box)
        .collect::<Result<Vec<_>, _>>()?;
    let tx = ergo_tx::chain::to_unsigned_transaction(&unsigned_tx)
        .map_err(|e| ArgusError::TxBuildFailed(e).to_json_string())?;
    let input_json: Vec<Option<serde_json::Value>> =
        ergo_boxes.iter().map(crate::api_dapp_impl::node_json).collect();
    let summary = with_handle(handle_id, "dapp_prepare_sign", |h| {
        Ok(crate::api_ergopay_impl::summarize_unsigned(
            &tx,
            &|addr| h.owns_address(addr).unwrap_or(false),
            &input_json,
        ))
    })?;
    // A page may only ask the wallet to spend the wallet's own boxes; a
    // transaction spending a contract box the wallet cannot sign for
    // would fail later anyway, but one spending someone else's P2PK box
    // is a sign of a confused or hostile page and is refused up front.
    let foreign_p2pk = ergo_boxes.iter().any(|b| {
        let tree = b.ergo_tree.sigma_serialize_bytes().map(hex::encode).unwrap_or_default();
        tree.starts_with("0008cd")
            && !with_handle(handle_id, "dapp_prepare_sign", |h| {
                Ok(h.owns_address(&crate::api_ergopay_impl::tree_to_address(&b.ergo_tree))
                    .unwrap_or(false))
            })
            .unwrap_or(false)
    });
    if foreign_p2pk {
        return Err(ArgusError::TxBuildFailed(
            "the transaction spends a box that belongs to another wallet".into(),
        )
        .to_json_string());
    }
    let miner_fee = crate::api_dapp_impl::miner_fee_of(&unsigned_tx);
    let change_erg = summary["change_nano_erg"].as_i64().unwrap_or(0);
    let sent = summary["sent_nano_erg"].as_i64().unwrap_or(0);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees: Vec::new(),
        mix_proofs: Vec::new(),
        ergo_boxes,
        data_input_boxes,
        unsigned_tx,
        miner_fee,
        change_erg,
        recipient_erg: sent,
        node_url,
    });
    serde_json::to_string(&serde_json::json!({
        "preparation_id": preparation_id,
        "miner_fee": miner_fee,
        "summary": summary,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// The wallet's unspent boxes in the shape `ergo.get_utxos()` returns:
/// full boxes with string amounts.
#[flutter_rust_bridge::frb]
pub async fn dapp_utxos(
    handle_id: u64,
    addresses: Vec<String>,
    node_url: Option<String>,
) -> Result<String, String> {
    let client = node_client(node_url).await?;
    let (_, eip12) = gather_unspent(handle_id, &client, &addresses).await?;
    // Which of them are in a block: the gathered set also holds this
    // wallet's mempool outputs, and a page must not take those as settled.
    let mut confirmed = std::collections::HashSet::new();
    for addr in &addresses {
        if let Ok(boxes) = client.get_unspent(addr).await {
            confirmed.extend(boxes.1.into_iter().map(|b| b.box_id));
        }
    }
    let list: Vec<serde_json::Value> = eip12
        .iter()
        .map(|b| crate::api_dapp_impl::utxo_json(b, confirmed.contains(&b.box_id)))
        .collect();
    Ok(serde_json::Value::Array(list).to_string())
}

/// Every Duckpools proxy script, hex, for the app to read boxes under
/// when it looks for orders it has no record of. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn duckpools_proxy_trees() -> String {
    let trees: Vec<String> = duckpools::proxy_trees().into_iter().map(|(t, _, _)| t).collect();
    serde_json::Value::Array(trees.into_iter().map(serde_json::Value::String).collect()).to_string()
}

/// The wallet's orders among boxes read under the proxy scripts: those
/// whose user register names one of `addresses`. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn duckpools_discover_orders(boxes_json: String, addresses: Vec<String>) -> Result<String, String> {
    let boxes: Vec<serde_json::Value> = serde_json::from_str(&boxes_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let mut trees = Vec::with_capacity(addresses.len());
    for a in &addresses {
        trees.push(address_to_ergo_tree(a).map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?);
    }
    let found = duckpools::discover_orders(&boxes, &trees)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    serde_json::to_string(&found).map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

// ── Stake recovery (read-only) ───────────────────────────────────────────

/// Deployed staking pools with full address-derived trees. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn stake_recovery_contracts() -> Result<String, String> {
    crate::api_stake_recovery_impl::contracts_json()
}

/// Decode and validate one state-NFT box. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn stake_recovery_state(pool_id: String, box_json: String) -> Result<String, String> {
    crate::api_stake_recovery_impl::state_json(&pool_id, &box_json)
}

/// Decode a page for the wallet's candidate token ids, optionally against state. Pure.
#[flutter_rust_bridge::frb(sync)]
pub fn stake_recovery_positions(
    pool_id: String,
    boxes_json: String,
    keys_json: String,
    state_box_json: String,
) -> Result<String, String> {
    crate::api_stake_recovery_impl::positions_json(
        &pool_id,
        &boxes_json,
        &keys_json,
        &state_box_json,
    )
}
