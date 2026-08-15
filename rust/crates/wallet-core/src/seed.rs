use zeroize::Zeroize;

use crate::CoreError;
use crate::EncryptedSeed;

/// BIP-39 mnemonic. Validated on construction; zeroized on drop.
pub struct MnemonicPhrase {
    phrase: String,
}

impl Drop for MnemonicPhrase {
    fn drop(&mut self) {
        self.phrase.zeroize();
    }
}

impl MnemonicPhrase {
    pub fn parse(phrase: impl Into<String>) -> Result<Self, CoreError> {
        let normalized = phrase
            .into()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        crate::bip39::validate_phrase(&normalized)?;
        Ok(MnemonicPhrase { phrase: normalized })
    }

    pub fn as_str(&self) -> &str {
        &self.phrase
    }

    pub fn to_seed(&self, passphrase: &str) -> Result<[u8; 64], CoreError> {
        use ergo_lib::wallet::mnemonic::Mnemonic;
        Ok(Mnemonic::to_seed(self.as_str(), passphrase))
    }
}

pub struct SeedBox {
    pub encrypted: EncryptedSeed,
}

impl SeedBox {
    pub fn from_mnemonic(mnemonic: &MnemonicPhrase, passphrase: &str) -> Result<Self, CoreError> {
        let mut seed = mnemonic.to_seed(passphrase)?;
        let encrypted = EncryptedSeed::encrypt(&seed)?;
        seed.zeroize();
        Ok(SeedBox { encrypted })
    }

    pub fn decrypt_seed(&self) -> Result<Vec<u8>, CoreError> {
        self.encrypted.decrypt()
    }

    pub fn to_json(&self) -> Result<serde_json::Value, CoreError> {
        self.encrypted.to_json()
    }

    pub fn from_json(json: &serde_json::Value) -> Result<Self, CoreError> {
        Ok(SeedBox {
            encrypted: EncryptedSeed::from_json(json)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn rejects_invalid_checksum() {
        let bad = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon";
        assert!(MnemonicPhrase::parse(bad).is_err());
    }

    #[test]
    fn accepts_valid_phrase() {
        assert!(MnemonicPhrase::parse(VALID).is_ok());
    }

    #[test]
    fn seedbox_roundtrip() {
        let phrase = MnemonicPhrase::parse(VALID).unwrap();
        let box_ = SeedBox::from_mnemonic(&phrase, "").unwrap();
        let seed = box_.decrypt_seed().unwrap();
        assert_eq!(seed.len(), 64);
        assert_eq!(seed, phrase.to_seed("").unwrap());
    }
}
