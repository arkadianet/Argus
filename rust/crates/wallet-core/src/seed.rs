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
        let mut raw = phrase.into();
        // Same normalisation the restore screen's live check shows: an
        // English phrase that passed before is unchanged byte for byte, so
        // its seed is too.
        let words = crate::bip39::validated_words(&raw);
        raw.zeroize();
        let mut words = words?;
        let normalized = words.join(" ");
        words.iter_mut().for_each(|w| w.zeroize());
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

    pub fn from_json(json: &serde_json::Value, wrap_key: Option<&str>) -> Result<Self, CoreError> {
        Ok(SeedBox {
            encrypted: EncryptedSeed::from_json(json, wrap_key)?,
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

    /// Pasted text with NBSP, a zero-width space, numbering and capitals
    /// gives the very seed of the clean phrase.
    #[test]
    fn messy_input_derives_the_clean_seed() {
        let clean = MnemonicPhrase::parse(VALID).unwrap();
        let messy = MnemonicPhrase::parse(
            "1. Abandon\u{00A0}2. abandon, 3. abandon\u{200B} 4. abandon 5. abandon 6. abandon \
             7. abandon 8. abandon 9. abandon 10. abandon 11. abandon 12. ABOUT",
        )
        .unwrap();
        assert_eq!(messy.as_str(), clean.as_str());
        assert_eq!(messy.to_seed("").unwrap(), clean.to_seed("").unwrap());
    }

    /// bip32JP vector 1: a Japanese phrase and passphrase give the
    /// published seed (NFKD of the phrase and passphrase, words joined by a
    /// space, which NFKD makes of the ideographic space anyway).
    #[test]
    fn japanese_phrase_gives_the_published_seed() {
        let phrase = MnemonicPhrase::parse(
            "あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あいこくしん　あおぞら",
        )
        .unwrap();
        assert_eq!(
            hex::encode(phrase.to_seed("㍍ガバヴァぱばぐゞちぢ十人十色").unwrap()),
            "a262d6fb6122ecf45be09c50492b31f92e9beb7d9a845987a02cefda57a15f9c467a17872029a9e92299b5cbdf306e3a0ee620245cbd508959b6cb7ca637bd55"
        );
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
