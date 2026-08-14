//! Argus wallet FFI — flutter_rust_bridge interface.
//!
//! All secrets are handled via opaque handles. No mnemonic or seed bytes
//! cross the Dart boundary as strings or byte arrays visible to the shell.
//! The shell receives only opaque u64 handle IDs, addresses (base58 strings),
//! and serialized transaction bytes.

use std::collections::HashMap;

use wallet_core::seed::MnemonicPhrase;
use wallet_core::wallet::WalletHandle;
use wallet_core::derivation;
use wallet_net::client::ErgoNodeClient;
use wallet_net::client::address_to_ergo_tree;
use citadel_core::NodeConfig;
use std::sync::Mutex;
use once_cell::sync::Lazy;

use crate::error::{ArgusError, err_to_string};

/// Shortcut: wrap a core error into a JSON error string for FRB.
fn err_str<E: Into<ArgusError>>(e: E) -> String {
    e.into().to_json_string()
}

// ─── Opaque handle store ────────────────────────────────────────────────────
// The Dart side never sees secret key material — only u64 handle IDs.
static HANDLES: Lazy<Mutex<HashMap<u64, WalletHandle>>> = Lazy::new(|| {
    Mutex::new(HashMap::new())
});
static NEXT_ID: Lazy<Mutex<u64>> = Lazy::new(|| Mutex::new(1));

fn register_handle(handle: WalletHandle) -> u64 {
    let mut id_lock = NEXT_ID.lock().unwrap();
    let id = *id_lock;
    *id_lock += 1;
    let mut handles = HANDLES.lock().unwrap();
    handles.insert(id, handle);
    id
}

/// Create a new wallet from a BIP-39 mnemonic phrase.
/// The mnemonic is consumed as a Rust String (not a Dart String visible in the shell).
/// Returns an opaque handle ID.
#[flutter_rust_bridge::frb]
pub fn wallet_create(mnemonic_phrase: String, passphrase: String) -> Result<u64, String> {
    let phrase = MnemonicPhrase::new(mnemonic_phrase);
    let handle = WalletHandle::create(phrase, &passphrase)
        .map_err(err_str::<wallet_core::CoreError>)?;
    Ok(register_handle(handle))
}

/// Restore a wallet from encrypted seed JSON.
#[flutter_rust_bridge::frb]
pub fn wallet_restore(encrypted_seed_json: String, key_material: Vec<u8>) -> Result<u64, String> {
    let json: serde_json::Value = serde_json::from_str(&encrypted_seed_json)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let encrypted_seed = wallet_core::EncryptedSeed::from_json(&json)
        .map_err(err_str)?;
    let seed_bytes = encrypted_seed.decrypt(&key_material)
        .map_err(err_str)?;
    let handle = WalletHandle::restore_from_seed(&seed_bytes)
        .map_err(err_str)?;
    Ok(register_handle(handle))
}

/// Lock a wallet — drop secret keys from memory.
#[flutter_rust_bridge::frb]
pub fn wallet_lock(handle_id: u64) -> Result<(), String> {
    let handles = HANDLES.lock().unwrap();
    let handle = handles.get(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound("wallet_lock", handle_id).to_json_string())?;
    handle.lock();
    Ok(())
}

/// Check if a wallet handle is still unlocked.
#[flutter_rust_bridge::frb]
pub fn wallet_is_unlocked(handle_id: u64) -> Result<bool, String> {
    let handles = HANDLES.lock().unwrap();
    let handle = handles.get(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound("wallet_is_unlocked", handle_id).to_json_string())?;
    Ok(handle.is_unlocked())
}

/// Derive an Ergo mainnet address at the given EIP-3 index.
#[flutter_rust_bridge::frb]
pub fn derive_address(handle_id: u64, index: u32) -> Result<String, String> {
    let handles = HANDLES.lock().unwrap();
    let handle = handles.get(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound("derive_address", handle_id).to_json_string())?;
    handle.derive_address(index).map_err(err_str)
}

/// Create an encrypted seed blob from a mnemonic (for Keystore/Keychain).
#[flutter_rust_bridge::frb]
pub fn create_encrypted_seed(mnemonic_phrase: String, passphrase: String) -> Result<String, String> {
    let phrase = MnemonicPhrase::new(mnemonic_phrase);
    let seed = phrase.to_seed(&passphrase)
        .map_err(err_str)?;
    let encrypted = wallet_core::EncryptedSeed::encrypt(&seed, &seed[..32])
        .map_err(err_str)?;
    let json = encrypted.to_json()
        .map_err(err_str)?;
    serde_json::to_string(&json).map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Sign an EIP-19 ReducedTransaction (byte blob).
#[flutter_rust_bridge::frb]
pub fn sign_reduced_transaction(
    handle_id: u64,
    reduced_tx_bytes: Vec<u8>,
) -> Result<String, String> {
    let handles = HANDLES.lock().unwrap();
    let handle = handles.get(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound("sign_reduced_transaction", handle_id).to_json_string())?;

    let reduced = wallet_core::transaction::deserialize_reduced(&reduced_tx_bytes)
        .map_err(err_str)?;
    let signed_tx = handle.sign_reduced(reduced)
        .map_err(err_str)?;

    serde_json::to_value(&signed_tx)
        .map(|v| v.to_string())
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Test-only: derive first address from the known test vector.
#[flutter_rust_bridge::frb]
pub fn test_derive_display() -> Result<String, String> {
    let mnemonic = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";
    let addr = derivation::derive_address(mnemonic, "", 0)
        .map_err(err_str)?;
    Ok(addr)
}

/// Build, reduce, and sign an ERG (and optionally token) send transaction using a public node.
///
/// * `handle_id` — opaque wallet handle (from wallet_create/wallet_restore)
/// * `sender_address` — the wallet's Ergo base58 address
/// * `recipient_address` — destination base58 address
/// * `amount_nano_erg` — amount in nanoERG (1 ERG = 1_000_000_000 nanoERG)
/// * `token_id` — optional token ID (hex) to send alongside ERG
/// * `token_amount` — optional token amount (required if token_id is set)
/// * `node_url` — optional Ergo node URL (uses default if empty)
///
/// Returns the signed transaction as a JSON string, ready for submission.
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
    use ergo_lib::chain::transaction::reduced::ReducedTransaction;
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
    use ergo_tx::send::build_send_tx;
    use ergopay_core::reduce_transaction_with_context;

    let send_token: Option<(&str, u64)> = token_id
        .as_deref()
        .zip(token_amount)
        .filter(|(_, amt)| *amt > 0);
    let url = node_url.unwrap_or_else(|| wallet_net::client::DEFAULT_NODE_URL.to_string());
    let config = NodeConfig {
        url,
        api_key: String::new(),
    };

    let client = ErgoNodeClient::new(config).await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;
    let sender_tree = address_to_ergo_tree(&sender_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let utxos = client.get_eip12_utxos(&sender_address).await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    if utxos.is_empty() {
        return Err(ArgusError::NoUtxos(sender_address).to_json_string());
    }
    let height = client.current_height().await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())? as i32;
    let recipient_tree = address_to_ergo_tree(&recipient_address)
        .map_err(|e| ArgusError::InvalidAddress(e).to_json_string())?;
    let build_result = build_send_tx(
        &utxos, &recipient_tree, &sender_tree, amount_nano_erg, send_token, height,
    )
    .map_err(|e| ArgusError::TxBuildFailed(e.to_string()).to_json_string())?;

    let input_boxes = client
        .unspent_boxes_by_address(&sender_address, 0, 500)
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let state_context = client.get_state_context().await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let reduced_bytes = reduce_transaction_with_context(
        &build_result.unsigned_tx, input_boxes, Vec::new(), &state_context,
    )
    .map_err(|e| ArgusError::TxReductionFailed(e.to_string()).to_json_string())?;

    let handles = HANDLES.lock().unwrap();
    let handle = handles
        .get(&handle_id)
        .ok_or_else(|| ArgusError::HandleNotFound("send_erg", handle_id).to_json_string())?;

    let reduced = ReducedTransaction::sigma_parse_bytes(&reduced_bytes)
        .map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())?;
    let signed_tx = handle
        .sign_reduced(reduced)
        .map_err(err_str)?;

    serde_json::to_string(&signed_tx).map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

/// Fetch transaction history for an address from a public Ergo node.
/// limit caps at 100; pass 0 for default (20).
#[flutter_rust_bridge::frb]
pub async fn get_transaction_history(
    address: String,
    node_url: Option<String>,
    limit: u64,
) -> Result<String, String> {
    let url = node_url.unwrap_or_else(|| wallet_net::client::DEFAULT_NODE_URL.to_string());
    let config = NodeConfig {
        url,
        api_key: String::new(),
    };
    let client = ErgoNodeClient::new(config).await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;
    let cap = if limit == 0 { 20 } else { limit.min(100) };
    let txs = client.get_transaction_history(&address, cap).await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    serde_json::to_string(&txs).map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[flutter_rust_bridge::frb]
pub fn generate_mnemonic(strength: u32) -> Result<String, String> {
    use ergo_lib::wallet::mnemonic_generator::{MnemonicGenerator, Language};

    let strength = strength.max(128).min(256);
    let byte_len = (strength / 8) as usize;
    let entropy: Vec<u8> = {
        use rand::RngCore;
        let mut bytes = vec![0u8; byte_len];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        bytes
    };

    let generator = MnemonicGenerator::new(Language::English, strength)
        .map_err(|e| ArgusError::InvalidMnemonic(format!("{:?}", e)).to_json_string())?;
    let phrase = generator
        .from_entropy(entropy)
        .map_err(|e| ArgusError::InvalidMnemonic(format!("{:?}", e)).to_json_string())?;
    Ok(phrase)
}

/// Discover wallet addresses by scanning indices with BIP-44 gap discovery.
/// Scans from index 0 upward; stops after `gap_limit` consecutive indices
/// with zero UTXOs at the given node.
/// Returns a JSON array of (index, address) pairs for used addresses.
#[flutter_rust_bridge::frb]
pub async fn discover_addresses(
    handle_id: u64,
    node_url: Option<String>,
    gap_limit: u32,
) -> Result<String, String> {
let url = node_url.unwrap_or_else(|| wallet_net::client::DEFAULT_NODE_URL.to_string());
    let config = NodeConfig {
        url,
        api_key: String::new(),
    };
    let client = ErgoNodeClient::new(config).await
        .map_err(|e| ArgusError::NodeUnreachable(e).to_json_string())?;

    // Pre-derive addresses while holding the lock, then release before network calls
    let addrs: Vec<(u32, String)> = {
        let handles = HANDLES.lock().unwrap();
        let handle = handles.get(&handle_id)
            .ok_or_else(|| ArgusError::HandleNotFound("discover_addresses", handle_id).to_json_string())?;
        let mut addrs = Vec::with_capacity(1000);
        for i in 0..1000u32 {
            let addr = handle.derive_address(i).map_err(err_str)?;
            addrs.push((i, addr));
        }
        addrs
    }; // MutexGuard dropped here

    let gap = gap_limit.max(1).min(100) as usize;
    let mut consecutive_empty = 0usize;
    let mut used: Vec<serde_json::Value> = Vec::new();

    for (index, addr) in &addrs {
        if consecutive_empty >= gap {
            break;
        }
        let utxos = client.get_eip12_utxos(addr).await
            .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
        if utxos.is_empty() {
            consecutive_empty += 1;
        } else {
            consecutive_empty = 0;
            let balances = client.get_address_balances(addr).await
                .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
            used.push(serde_json::json!({
                "index": index,
                "address": addr,
                "balance_nano_erg": balances.0,
                "token_count": balances.1.len(),
            }));
        }
    }

    let scanned = addrs.len() as u32;
    let next_unused = scanned.saturating_sub(consecutive_empty as u32);

    serde_json::to_string(&serde_json::json!({
        "addresses": used,
        "scanned_up_to": scanned - 1,
        "next_unused_index": next_unused,
    })).map_err(|e| ArgusError::SerializationError(e.to_string()).to_json_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_and_derive() {
        let mnemonic = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet".to_string();
        let handle_id = wallet_create(mnemonic, "".to_string()).unwrap();
        assert!(wallet_is_unlocked(handle_id).unwrap());
        let addr = derive_address(handle_id, 0).unwrap();
        assert_eq!(addr, "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8");
        wallet_lock(handle_id).unwrap();
        assert!(!wallet_is_unlocked(handle_id).unwrap());
    }

    #[test]
    fn test_encrypted_seed_roundtrip() {
        let mnemonic = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet".to_string();
        let json = create_encrypted_seed(mnemonic.clone(), "".to_string()).unwrap();
        let phrase = MnemonicPhrase::new(mnemonic);
        let seed = phrase.to_seed("").unwrap();
        let handle_id = wallet_restore(json, seed[..32].to_vec()).unwrap();
        let addr = derive_address(handle_id, 0).unwrap();
        assert_eq!(addr, "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8");
    }

    #[test]
    fn test_test_derive_display() {
        let addr = test_derive_display().unwrap();
        assert_eq!(addr, "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8");
    }
}