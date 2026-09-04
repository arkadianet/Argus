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
use wallet_core::spend::{select_exact, select_for_send};
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

    let change_idx = tx.outputs.iter().rposition(|o| o.ergo_tree == change_ergo_tree)
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
    // The change box is the sole carrier of leftover tokens — never erase it.
    let carries_tokens = !tx.outputs[change_idx].assets.is_empty();
    if new_change == 0 && carries_tokens {
        return Err(ArgusError::TxBuildFailed(
            "custom fee would remove the change box holding tokens; lower the fee".into(),
        ).to_json_string());
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

/// Human summary of an ErgoPay reduced transaction: inputs (with values and
/// tokens when the node can supply the boxes), outputs classified as
/// recipient / change / fee, and totals. See `api_ergopay_impl`.
#[flutter_rust_bridge::frb]
pub async fn describe_reduced_transaction(
    handle_id: u64,
    reduced_tx_bytes: Vec<u8>,
    node_url: Option<String>,
) -> Result<String, String> {
    let reduced = wallet_core::transaction::deserialize_reduced(&reduced_tx_bytes)
        .map_err(err_str)?;
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
    stealth::payment_address_for_stealth_address(&stealth_address).map_err(|e| {
        ArgusError::InvalidAddress(e.to_string()).to_json_string()
    })
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
    let stealth_trees = owned.iter().map(|b| b.ergo_tree.clone()).collect::<Vec<_>>();

    let client = node_client(node_url.clone()).await?;
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let destination_tree = address_to_ergo_tree(&destination_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let built =
        crate::api_stealth_impl::build_sweep(&inputs, &destination_tree, height, fee_nano)?;

    let input_boxes = input_boxes_json(&inputs);
    let preparation_id = store_preparation(CachedPreparation {
        handle_id,
        stealth_trees,
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
    let (nano, mut tokens) = client
        .get_address_balances(&address)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;

    // Mempool delta: unconfirmed sends drop the balance before they confirm.
    // Any mempool failure degrades to the confirmed figure — never fail here.
    let mut delta: i64 = 0;
    if let Ok(tree) = address_to_ergo_tree(&address) {
        if let Ok(txs) = client.mempool_txs_for(&tree).await {
            if !txs.is_empty() {
                if let Ok((boxes, _)) = client.get_unspent(&address).await {
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
                    delta = wallet_net::mempool::balance_delta(
                        &txs,
                        &tree,
                        &confirmed_values,
                    );
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
pub async fn get_token_info(token_id: String, explorer_url: Option<String>) -> Result<String, String> {
    let mut info = wallet_net::client::get_token_info(&token_id, explorer_url.as_deref())
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    // EIP-4 media: the issuance box (IndexedToken.boxId) carries the asset
    // type in R7 and a link in R9. Best effort — a plain token has neither.
    if let Some(box_id) = info.get("boxId").and_then(|b| b.as_str()).map(str::to_string) {
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
        if let Ok((boxes, _)) = client.get_unspent(addr).await {
            for b in boxes {
                confirmed_values.insert(b.box_id().to_string(), b.value.as_i64());
            }
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
        let mut received: std::collections::HashMap<String, u64> =
            std::collections::HashMap::new();
        if let Some(outs) = tx["outputs"].as_array() {
            for o in outs {
                let tree_owned =
                    o["ergoTree"].as_str().map(|t| trees.contains(t)).unwrap_or(false);
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
        let applied_fee = apply_custom_fee(
            &mut built.unsigned_tx,
            &change_tree,
            built.miner_fee,
            custom_fee,
        )?;
        built.miner_fee = applied_fee;
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
        stealth_trees: Vec::new(),
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
    let required = i64::checked_add(amount_nano_erg, fee_for_required)
        .and_then(|v| i64::checked_add(v, MIN_BOX_VALUE_NANO))
        .filter(|v| *v > 0)
        .ok_or_else(|| {
            ArgusError::TxBuildFailed("send amount out of range".into()).to_json_string()
        })? as u64;
    let token_ref = send_token.as_ref().map(|(id, amt)| (id.as_str(), *amt));
    // Coin control: when the user chose boxes, spend exactly those. Falling
    // back to automatic selection here would silently pull in a box they
    // deliberately left out, which is the linking they were avoiding.
    let selected = match input_box_ids.as_deref() {
        Some(ids) => select_exact(&eip12, ids, required, token_ref)
            .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?,
        None => select_for_send(&eip12, required, token_ref)
            .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?,
    };

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
        let applied_fee = apply_custom_fee(&mut built.unsigned_tx, &change_tree, built.summary.miner_fee, custom_fee)?;
        built.summary.miner_fee = applied_fee;
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
    input_box_ids: Option<Vec<String>>,
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
        input_box_ids,
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
        stealth_trees: Vec::new(),
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
        let signed_tx = if prep.stealth_trees.is_empty() {
            handle.sign_reduced(reduced).map_err(err_str)?
        } else {
            let extra = crate::api_stealth_impl::dht_secrets_for(handle, &prep.stealth_trees)?;
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
    let client = node_client(prep.node_url.clone()).await?;
    let tx_json = sign_prepared_tx(handle_id, &prep, &client, "sign_preparation").await?;
    serde_json::to_string(&tx_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// A single parsed recipient for a multi-recipient send.
struct ParsedRecipient {
    address: String,
    amount_nano_erg: i64,
    token: Option<(String, u64)>,
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
    input_box_ids: Option<Vec<String>>,
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

    let mut parsed: Vec<ParsedRecipient> = Vec::new();
    let mut total_send_erg: i64 = 0;
    for rcpt in recipients {
        let addr = rcpt["address"].as_str()
            .ok_or_else(|| ArgusError::TxBuildFailed("recipient missing address".into()).to_json_string())?;
        let token = resolve_send_token(
            rcpt["token_id"].as_str().map(|id| id.to_string()),
            rcpt["token_amount"].as_u64(),
        )?;
        let mut amount = match rcpt.get("amount_nano_erg") {
            None | Some(serde_json::Value::Null) => 0,
            Some(value) => value.as_i64().ok_or_else(|| {
                ArgusError::TxBuildFailed("recipient amount_nano_erg must be an integer".into())
                    .to_json_string()
            })?,
        };
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
        total_send_erg = total_send_erg.checked_add(amount).ok_or_else(|| {
            ArgusError::TxBuildFailed("recipient total amount out of range".into())
                .to_json_string()
        })?;
        parsed.push(ParsedRecipient {
            address: addr.to_string(),
            amount_nano_erg: amount,
            token,
        });
    }

    let has_sent_tokens = parsed.iter().any(|rcpt| rcpt.token.is_some());
    if total_send_erg <= 0 && !has_sent_tokens {
        return Err(ArgusError::TxBuildFailed("at least one recipient must receive ERG or tokens".into())
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
            token: rcpt.token.clone(),
        });
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
    for rcpt in &parsed {
        if let Some((id, amt)) = &rcpt.token {
            let entry = needed_tokens.entry(id.clone()).or_insert(0);
            *entry = entry.checked_add(*amt).ok_or_else(|| {
                ArgusError::TxBuildFailed("token requirement out of range".into())
                    .to_json_string()
            })?;
        }
    }

    // For input selection we need the total ERG + all token amounts
    let fee_for_required = fee_nano.unwrap_or(TX_FEE_NANO);

    // Use UTXO selection: pick boxes covering total_send_erg + fee + min change,
    // and which collectively hold the needed tokens.
    let required = i64::checked_add(total_send_erg, fee_for_required)
        .and_then(|v| i64::checked_add(v, MIN_BOX_VALUE_NANO))
        .filter(|v| *v > 0)
        .ok_or_else(|| {
            ArgusError::TxBuildFailed("recipient total amount out of range".into())
                .to_json_string()
        })? as u64;
    // Coin control, as in prepare_send: the chosen boxes are the whole
    // input set, never a starting point the selector may extend.
    let selected = match input_box_ids.as_deref() {
        Some(ids) => {
            let token_ref = needed_tokens.iter().next().map(|(id, amt)| (id.as_str(), *amt));
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
        None => select_for_multi_send(&eip12, required, &needed_tokens)
            .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?,
    };

    if selected.is_empty() {
        return Err(ArgusError::NoUtxos(spend.join(",")).to_json_string());
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
    let unsigned_tx = built.unsigned_tx;
    let change_erg = built.summary.change_erg;

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
        stealth_trees: Vec::new(),
        ergo_boxes,
        data_input_boxes: Vec::new(),
        unsigned_tx,
        miner_fee: fee_for_required,
        change_erg,
        recipient_erg: total_send_erg,
        node_url,
    });

    let recipient_summary: Vec<serde_json::Value> = parsed.iter().map(|rcpt| {
        serde_json::json!({
            "address": rcpt.address,
            "amount_nano_erg": rcpt.amount_nano_erg,
            "token_id": rcpt.token.as_ref().map(|(id, _)| id),
            "token_amount": rcpt.token.as_ref().map(|(_, amt)| amt),
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
            let all_ok = needed_tokens.iter().all(|(id, need)| {
                total_tokens.get(id).copied().unwrap_or(0) >= *need
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
    for (id, need) in needed_tokens {
        let have = total_tokens.get(id).copied().unwrap_or(0);
        if have < *need {
            return Err(format!("insufficient tokens {id}: have {have}, need {need}"));
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
    crate::api_dexy_impl::preview_lp(&variant, &action, erg_amount, dexy_amount, lp_amount, node_url)
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
    Ok((boxes, eip12))
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
        out.push(
            by_id
                .get(id)
                .cloned()
                .ok_or_else(|| ArgusError::TxBuildFailed(format!("missing user UTXO {id}")).to_json_string())?,
        );
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
    let dexy_variant = variant.parse::<dexy::constants::DexyVariant>().map_err(|_| {
        ArgusError::Generic(format!("Invalid Dexy variant: {variant}")).to_json_string()
    })?;
    let ids = crate::api_dexy_impl::ids_for(dexy_variant)?;

    if held_tokens < 0 {
        return Err(
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string()
        );
    }

    let (recipient_tree, change_tree) =
        resolve_dexy_destinations(handle_id, "dexy_build_mint", &recipient_address, &change_address)?;

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
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;

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
    let dexy_variant = variant.parse::<dexy::constants::DexyVariant>().map_err(|_| {
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
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string()
        );
    }

    let (recipient_tree, change_tree) =
        resolve_dexy_destinations(handle_id, "dexy_build_swap", &recipient_address, &change_address)?;

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
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;
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
    let dexy_variant = variant.parse::<dexy::constants::DexyVariant>().map_err(|_| {
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
    let ctx = dexy::fetch::fetch_lp_tx_context(
        &client,
        &caps,
        &ids,
        dexy::fetch::LpAction::Deposit,
    )
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
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;
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
    let dexy_variant = variant.parse::<dexy::constants::DexyVariant>().map_err(|_| {
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
    let ctx = dexy::fetch::fetch_lp_tx_context(
        &client,
        &caps,
        &ids,
        dexy::fetch::LpAction::Redeem,
    )
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
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;
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
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string()
        );
    }
    use citadel_core::BoxId;
    use sigmausd::fetch::fetch_tx_context;
    use sigmausd::state::{BankBoxData, OracleBoxData, SigmaUsdState};
    use sigmausd::tx_builder::{
        build_mint_sigusd_tx, build_mint_sigrsv_tx, build_redeem_sigusd_tx,
        build_redeem_sigrsv_tx, validate_mint_sigusd, validate_mint_sigrsv,
        validate_redeem_sigusd, validate_redeem_sigrsv, MintSigRsvRequest, MintSigUsdRequest,
        RedeemSigRsvRequest, RedeemSigUsdRequest, SigmaUsdAction,
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
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;

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
                ArgusError::Generic(
                    "NO_POOL: no Spectrum pool can deliver this amount".into(),
                )
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
            ArgusError::Generic("held_tokens must not be negative".into()).to_json_string()
        );
    }
    let (recipient_tree, change_tree) =
        resolve_dexy_destinations(handle_id, "amm_build_swap", &recipient_address, &change_address)?;

    let client = crate::api_dexy_impl::dexy_client(node_url.clone()).await?;
    // The pool's current box by its NFT: one indexed request, always fresh,
    // instead of re-downloading every Spectrum pool to locate it.
    let (pool_owned, pool_ergo_box) =
        crate::api_amm_impl::fetch_pool(&client, &pool_id).await?;
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
    let pool_box =
        ergo_tx::Eip12InputBox::from_ergo_box(&pool_ergo_box, creation.0, creation.1);

    let (all_boxes, eip12) =
        gather_wallet_boxes(handle_id, &spend_addresses, node_url.clone()).await?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(spend_addresses.join(",")).to_json_string());
    }
    let height = client
        .current_height()
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())? as i32;

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
            stealth_trees: Vec::new(),
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
