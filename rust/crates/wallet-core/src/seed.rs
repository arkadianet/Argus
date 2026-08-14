use crate::CoreError;

/// A BIP-39 mnemonic phrase wrapper.
pub struct MnemonicPhrase {
    phrase: String,
}

impl MnemonicPhrase {
    pub fn new(phrase: String) -> Self {
        MnemonicPhrase { phrase }
    }

    pub fn as_str(&self) -> &str {
        &self.phrase
    }

    pub fn to_seed(&self, passphrase: &str) -> Result<[u8; 64], CoreError> {
        use ergo_lib::wallet::mnemonic::Mnemonic;
        Ok(Mnemonic::to_seed(self.as_str(), passphrase))
    }
}

/// A seed box stores the raw 64-byte seed (from mnemonic -> PBKDF2) in memory,
/// encrypted. It can be serialized/deserialized for Android Keystore / iOS Keychain storage.
pub struct SeedBox {
    /// Encrypted seed bytes (AES-256-GCM)
    pub encrypted: super::EncryptedSeed,
}

impl SeedBox {
    pub fn from_mnemonic(
        mnemonic: &MnemonicPhrase,
        passphrase: &str,
    ) -> Result<Self, CoreError> {
        let seed = mnemonic.to_seed(passphrase)?;
        let encrypted =
            super::EncryptedSeed::encrypt(&seed, &seed[..32])
                .map_err(|e| CoreError::Encryption(e.to_string()))?;
        Ok(SeedBox { encrypted })
    }

    /// Decrypt the seed. Returns raw seed bytes — caller must zeroize.
    pub fn decrypt_seed(&self, mnemonic_key_material: &[u8]) -> Result<Vec<u8>, CoreError> {
        self.encrypted.decrypt(mnemonic_key_material)
    }

    pub fn to_json(&self) -> Result<serde_json::Value, CoreError> {
        self.encrypted.to_json()
    }

    pub fn from_json(json: &serde_json::Value) -> Result<Self, CoreError> {
        let encrypted = super::EncryptedSeed::from_json(json)?;
        Ok(SeedBox { encrypted })
    }
}