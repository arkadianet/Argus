//! Argus wallet FFI — flutter_rust_bridge interface.

use std::collections::HashMap;
use std::sync::Mutex;

use citadel_core::constants::{MIN_BOX_VALUE_NANO, TX_FEE_NANO};
use citadel_core::NodeConfig;
use ergo_lib::chain::transaction::reduced::ReducedTransaction;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_tx::{build_send_tx_with_fee, DevFeeConfig};
use ergopay_core::reduce_transaction_with_context;
use once_cell::sync::Lazy;
use rand::RngCore;
use wallet_core::seed::MnemonicPhrase;
use wallet_core::spend::select_for_send;
use wallet_core::wallet::WalletHandle;
use wallet_net::client::{address_to_ergo_tree, ErgoNodeClient};

use crate::error::ArgusError;

fn err_str<E: Into<ArgusError>>(e: E) -> String {
    e.into().to_json_string()
}

fn recover<T>(r: std::sync::LockResult<T>) -> T {
    r.unwrap_or_else(|p| p.into_inner())
}

static HANDLES: Lazy<Mutex<HashMap<u64, WalletHandle>>> = Lazy::new(|| Mutex::new(HashMap::new()));

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

fn node_config(node_url: Option<String>) -> NodeConfig {
    NodeConfig {
        url: node_url.unwrap_or_else(|| wallet_net::client::DEFAULT_NODE_URL.to_string()),
        api_key: String::new(),
    }
}

fn session_json(handle_id: u64, encrypted_seed_json: String) -> Result<String, String> {
    serde_json::to_string(&serde_json::json!({
        "handle_id": handle_id,
        "encrypted_seed_json": encrypted_seed_json,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

fn open_wallet(mnemonic_phrase: String, passphrase: &str) -> Result<(u64, String), String> {
    let phrase = MnemonicPhrase::parse(mnemonic_phrase).map_err(err_str)?;
    let encrypted = wallet_core::EncryptedSeed::encrypt(
        &phrase
            .to_seed(passphrase)
            .map_err(err_str)?,
    )
    .map_err(err_str)?;
    let json = serde_json::to_string(&encrypted.to_json().map_err(err_str)?)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let handle = WalletHandle::create(phrase, passphrase).map_err(err_str)?;
    Ok((register_handle(handle), json))
}

/// Create a wallet from a BIP-39 mnemonic. Returns `{handle_id, encrypted_seed_json}`.
#[flutter_rust_bridge::frb]
pub fn wallet_create(mnemonic_phrase: String, passphrase: String) -> Result<String, String> {
    let (id, json) = open_wallet(mnemonic_phrase, &passphrase)?;
    session_json(id, json)
}

/// Restore from a Keystore blob. The blob is decryptable without extra key material;
/// the platform store is the wrap.
#[flutter_rust_bridge::frb]
pub fn wallet_restore(encrypted_seed_json: String) -> Result<u64, String> {
    let json: serde_json::Value = serde_json::from_str(&encrypted_seed_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let encrypted = wallet_core::EncryptedSeed::from_json(&json).map_err(err_str)?;
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
    serde_json::to_string(&json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
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
    let client = ErgoNodeClient::new(node_config(node_url))
        .await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;
    let (nano, tokens) = client
        .get_address_balances(&address)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    serde_json::to_string(&serde_json::json!({
        "balance_nano_erg": nano,
        "token_count": tokens.len(),
        "token_ids": tokens,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub async fn get_transaction_history(
    address: String,
    node_url: Option<String>,
    limit: u64,
) -> Result<String, String> {
    let client = ErgoNodeClient::new(node_config(node_url))
        .await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;
    let cap = if limit == 0 { 20 } else { limit.min(100) };
    let txs = client
        .get_transaction_history(&address, cap)
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
    let client = ErgoNodeClient::new(node_config(node_url))
        .await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;
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
                "token_count": balances.1.len(),
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

struct PreparedSend {
    eip12: Vec<ergo_tx::Eip12InputBox>,
    ergo_boxes: Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>,
    recipient_tree: String,
    sender_tree: String,
    height: i32,
    amount: i64,
    token: Option<(String, u64)>,
}

async fn prepare(
    handle_id: u64,
    sender_address: &str,
    recipient_address: &str,
    amount_nano_erg: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node_url: Option<String>,
) -> Result<(PreparedSend, ergo_tx::SendBuildResult, ErgoNodeClient), String> {
    if amount_nano_erg < MIN_BOX_VALUE_NANO {
        return Err(ArgusError::TxBuildFailed(format!(
            "amount must be at least {MIN_BOX_VALUE_NANO} nanoERG"
        ))
        .to_json_string());
    }
    with_handle(handle_id, "send", |h| {
        if !h.owns_address(sender_address).map_err(err_str)? {
            return Err(ArgusError::InvalidAddress(
                "sender is not an address of this wallet".into(),
            )
            .to_json_string());
        }
        Ok(())
    })?;

    let send_token: Option<(String, u64)> = token_id
        .filter(|s| !s.is_empty())
        .zip(token_amount)
        .filter(|(_, amt)| *amt > 0);
    let client = ErgoNodeClient::new(node_config(node_url))
        .await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;
    let (boxes, eip12) = client
        .get_unspent(sender_address)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    if eip12.is_empty() {
        return Err(ArgusError::NoUtxos(sender_address.to_string()).to_json_string());
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
    let sender_tree = address_to_ergo_tree(sender_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;

    let built = build_send_tx_with_fee(
        &selected.boxes,
        &recipient_tree,
        &sender_tree,
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

    Ok((
        PreparedSend {
            eip12: selected.boxes,
            ergo_boxes,
            recipient_tree,
            sender_tree,
            height,
            amount: amount_nano_erg,
            token: send_token,
        },
        built,
        client,
    ))
}

#[flutter_rust_bridge::frb]
pub async fn prepare_send(
    handle_id: u64,
    sender_address: String,
    recipient_address: String,
    amount_nano_erg: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node_url: Option<String>,
) -> Result<String, String> {
    let (_prep, built, _client) = prepare(
        handle_id,
        &sender_address,
        &recipient_address,
        amount_nano_erg,
        token_id,
        token_amount,
        node_url,
    )
    .await?;
    serde_json::to_string(&serde_json::json!({
        "recipient": recipient_address,
        "amount_nano_erg": built.summary.recipient_erg,
        "miner_fee": built.summary.miner_fee,
        "change_nano_erg": built.summary.change_erg,
        "input_count": built.summary.input_count,
        "citadel_fee_nano": built.summary.citadel_fee_nano,
    }))
    .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub async fn send_erg(
    handle_id: u64,
    sender_address: String,
    recipient_address: String,
    amount_nano_erg: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node_url: Option<String>,
) -> Result<String, String> {
    let (prep, built, client) = prepare(
        handle_id,
        &sender_address,
        &recipient_address,
        amount_nano_erg,
        token_id,
        token_amount,
        node_url,
    )
    .await?;
    let _ = (prep.recipient_tree, prep.sender_tree, prep.height, prep.amount, prep.token, prep.eip12);

    let state_context = client
        .get_state_context()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let reduced_bytes = reduce_transaction_with_context(
        &built.unsigned_tx,
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
        "miner_fee": built.summary.miner_fee,
        "change_nano_erg": built.summary.change_erg,
        "amount_nano_erg": built.summary.recipient_erg,
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
        wallet_lock(handle_id).unwrap();
        assert!(wallet_is_unlocked(handle_id).is_err());

        let restored = wallet_restore(blob).unwrap();
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
}
