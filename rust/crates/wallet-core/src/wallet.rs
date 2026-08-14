use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergo_lib::wallet::Wallet;

use crate::derivation;
use crate::seed::MnemonicPhrase;
use crate::CoreError;

/// An unlocked wallet containing derived secret keys in memory.
pub struct UnlockedWallet {
    pub(crate) wallet: Wallet,
    pub(crate) ext_secret_key: ExtSecretKey,
    pub(crate) account: u32,
}

/// A thread-safe opaque handle to a wallet session.
/// The mnemonic is never stored — only derived key material.
pub struct WalletHandle {
    pub(crate) inner: std::sync::Mutex<Option<UnlockedWallet>>,
}

impl WalletHandle {
    pub fn new() -> Self {
        WalletHandle {
            inner: std::sync::Mutex::new(None),
        }
    }

    /// Create a wallet from a BIP-39 mnemonic phrase. The mnemonic is consumed.
    pub fn create(mnemonic: MnemonicPhrase, passphrase: &str) -> Result<Self, CoreError> {
        let wallet = Wallet::from_mnemonic(mnemonic.as_str(), passphrase)
            .map_err(|e| CoreError::Mnemonic(e.to_string()))?;

        // Also derive the ExtSecretKey for address generation
        let seed = mnemonic.to_seed(passphrase)?;
        let ext_secret_key =
            ExtSecretKey::derive_master(seed).map_err(|e| CoreError::Derivation(e.to_string()))?;

        Ok(WalletHandle {
            inner: std::sync::Mutex::new(Some(UnlockedWallet {
                wallet,
                ext_secret_key,
                account: 0,
            })),
        })
    }

    /// Restore from raw 64-byte seed bytes (e.g., decrypted from SeedBox).
    pub fn restore_from_seed(seed_bytes: &[u8]) -> Result<Self, CoreError> {
        if seed_bytes.len() != 64 {
            return Err(CoreError::Mnemonic("seed must be 64 bytes".into()));
        }
        let mut seed_arr = [0u8; 64];
        seed_arr.copy_from_slice(seed_bytes);

        let ext_secret_key = ExtSecretKey::derive_master(seed_arr)
            .map_err(|e| CoreError::Derivation(e.to_string()))?;
        let wallet = Wallet::from_secrets(vec![ext_secret_key.secret_key()]);

        Ok(WalletHandle {
            inner: std::sync::Mutex::new(Some(UnlockedWallet {
                wallet,
                ext_secret_key,
                account: 0,
            })),
        })
    }

    /// Lock the wallet — drop secret keys from memory.
    pub fn lock(&self) {
        let mut guard = self.inner.lock().unwrap();
        *guard = None;
    }

    pub fn is_unlocked(&self) -> bool {
        self.inner.lock().unwrap().is_some()
    }

    /// Derive an address at the given EIP-3 index (m/44'/429'/0'/0/index).
    pub fn derive_address(&self, index: u32) -> Result<String, CoreError> {
        let guard = self.inner.lock().unwrap();
        let unlocked = guard.as_ref().ok_or(CoreError::WalletLocked)?;
        derivation::derive_address_from_ext_secret_key(&unlocked.ext_secret_key, index)
    }

    /// Sign a reduced transaction (EIP-19).
    pub fn sign_reduced(
        &self,
        reduced_tx: ergo_lib::chain::transaction::reduced::ReducedTransaction,
    ) -> Result<ergo_lib::chain::transaction::Transaction, CoreError> {
        let guard = self.inner.lock().unwrap();
        let unlocked = guard.as_ref().ok_or(CoreError::WalletLocked)?;
        unlocked
            .wallet
            .sign_reduced_transaction(reduced_tx, None)
            .map_err(|e| CoreError::Signing(e.to_string()))
    }
}