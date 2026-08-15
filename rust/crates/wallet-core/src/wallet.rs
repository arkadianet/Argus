use std::collections::HashMap;

use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergo_lib::wallet::Wallet;
use zeroize::Zeroize;

use crate::derivation;
use crate::seed::MnemonicPhrase;
use crate::CoreError;

const PRELOAD_INDICES: u32 = 32;
const MAX_OWN_SCAN: u32 = 256;

pub struct UnlockedWallet {
    pub(crate) wallet: Wallet,
    pub(crate) ext_secret_key: ExtSecretKey,
    pub(crate) max_index: u32,
    addresses_by_index: HashMap<u32, String>,
    index_by_address: HashMap<String, u32>,
}

fn cache_address(unlocked: &mut UnlockedWallet, index: u32) -> Result<String, CoreError> {
    if let Some(addr) = unlocked.addresses_by_index.get(&index) {
        return Ok(addr.clone());
    }
    let addr = derivation::derive_address_from_ext_secret_key(&unlocked.ext_secret_key, index)?;
    unlocked.addresses_by_index.insert(index, addr.clone());
    unlocked.index_by_address.insert(addr.clone(), index);
    Ok(addr)
}

pub struct WalletHandle {
    inner: std::sync::Mutex<Option<UnlockedWallet>>,
}

fn recover<T>(result: std::sync::LockResult<T>) -> T {
    result.unwrap_or_else(|p| p.into_inner())
}

impl WalletHandle {
    pub fn create(mnemonic: MnemonicPhrase, passphrase: &str) -> Result<Self, CoreError> {
        let mut seed = mnemonic.to_seed(passphrase)?;
        let handle = Self::from_seed(&seed)?;
        seed.zeroize();
        Ok(handle)
    }

    pub fn restore_from_seed(seed_bytes: &[u8]) -> Result<Self, CoreError> {
        if seed_bytes.len() != 64 {
            return Err(CoreError::Mnemonic("seed must be 64 bytes".into()));
        }
        let mut seed_arr = [0u8; 64];
        seed_arr.copy_from_slice(seed_bytes);
        let handle = Self::from_seed(&seed_arr)?;
        seed_arr.zeroize();
        Ok(handle)
    }

    fn from_seed(seed: &[u8; 64]) -> Result<Self, CoreError> {
        let ext_secret_key = ExtSecretKey::derive_master(*seed)
            .map_err(|e| CoreError::Derivation(e.to_string()))?;
        let mut unlocked = UnlockedWallet {
            wallet: Wallet::from_secrets(Vec::new()),
            ext_secret_key,
            max_index: PRELOAD_INDICES,
            addresses_by_index: HashMap::new(),
            index_by_address: HashMap::new(),
        };
        for i in 0..=PRELOAD_INDICES {
            let child = derivation::derive_child(&unlocked.ext_secret_key, i)?;
            unlocked.wallet.add_secret(child.secret_key());
            cache_address(&mut unlocked, i)?;
        }
        Ok(WalletHandle {
            inner: std::sync::Mutex::new(Some(unlocked)),
        })
    }

    pub fn lock(&self) {
        *recover(self.inner.lock()) = None;
    }

    pub fn is_unlocked(&self) -> bool {
        recover(self.inner.lock()).is_some()
    }

    pub fn derive_address(&self, index: u32) -> Result<String, CoreError> {
        self.ensure_index(index)?;
        let mut guard = recover(self.inner.lock());
        let unlocked = guard.as_mut().ok_or(CoreError::WalletLocked)?;
        cache_address(unlocked, index)
    }

    pub fn ensure_index(&self, index: u32) -> Result<(), CoreError> {
        if index > MAX_OWN_SCAN {
            return Err(CoreError::Derivation(format!(
                "address index {index} exceeds maximum {MAX_OWN_SCAN}"
            )));
        }
        let mut guard = recover(self.inner.lock());
        let unlocked = guard.as_mut().ok_or(CoreError::WalletLocked)?;
        while unlocked.max_index < index {
            let next = unlocked.max_index + 1;
            let child = derivation::derive_child(&unlocked.ext_secret_key, next)?;
            unlocked.wallet.add_secret(child.secret_key());
            unlocked.max_index = next;
        }
        Ok(())
    }

    /// True if `address` is an EIP-3 child of this wallet (scans 0..MAX_OWN_SCAN).
    pub fn owns_address(&self, address: &str) -> Result<bool, CoreError> {
        match self.index_of_address(address)? {
            Some(index) => {
                self.ensure_index(index)?;
                Ok(true)
            }
            None => Ok(false),
        }
    }

    pub fn index_of_address(&self, address: &str) -> Result<Option<u32>, CoreError> {
        let mut guard = recover(self.inner.lock());
        let unlocked = guard.as_mut().ok_or(CoreError::WalletLocked)?;
        if let Some(&index) = unlocked.index_by_address.get(address) {
            return Ok(Some(index));
        }
        for i in 0..=MAX_OWN_SCAN {
            if unlocked.addresses_by_index.contains_key(&i) {
                continue;
            }
            let derived = cache_address(unlocked, i)?;
            if derived == address {
                return Ok(Some(i));
            }
        }
        Ok(None)
    }

    pub fn sign_reduced(
        &self,
        reduced_tx: ergo_lib::chain::transaction::reduced::ReducedTransaction,
    ) -> Result<ergo_lib::chain::transaction::Transaction, CoreError> {
        let guard = recover(self.inner.lock());
        let unlocked = guard.as_ref().ok_or(CoreError::WalletLocked)?;
        unlocked
            .wallet
            .sign_reduced_transaction(reduced_tx, None)
            .map_err(|e| CoreError::Signing(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    #[test]
    fn create_derives_eip3_address() {
        let phrase = MnemonicPhrase::parse(APPKIT).unwrap();
        let handle = WalletHandle::create(phrase, "").unwrap();
        assert_eq!(
            handle.derive_address(0).unwrap(),
            "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8"
        );
        assert!(handle
            .owns_address("9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8")
            .unwrap());
        assert!(!handle.owns_address("not-a-wallet-address").unwrap());
    }

    #[test]
    fn derive_address_rejects_out_of_range_index() {
        let phrase = MnemonicPhrase::parse(APPKIT).unwrap();
        let handle = WalletHandle::create(phrase, "").unwrap();
        let err = handle.derive_address(MAX_OWN_SCAN + 1).unwrap_err();
        assert!(matches!(err, CoreError::Derivation(_)));
        assert!(handle.ensure_index(MAX_OWN_SCAN + 1).is_err());
        assert!(handle.derive_address(MAX_OWN_SCAN).is_ok());
    }
}
