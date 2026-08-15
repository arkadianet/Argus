use sha2::{Digest, Sha256};

use crate::CoreError;

const WORDLIST: &str = include_str!("bip39_english.txt");

fn word_index(word: &str) -> Option<u16> {
    WORDLIST.lines().position(|w| w == word).map(|i| i as u16)
}

/// BIP-39 checksum + wordlist check (English).
pub fn validate_phrase(phrase: &str) -> Result<(), CoreError> {
    let words: Vec<&str> = phrase.split_whitespace().collect();
    let n = words.len();
    if ![12, 15, 18, 21, 24].contains(&n) {
        return Err(CoreError::Mnemonic(
            "mnemonic must be 12, 15, 18, 21, or 24 words".into(),
        ));
    }
    let mut bits = Vec::with_capacity(n * 11);
    for w in &words {
        let idx = word_index(w).ok_or_else(|| CoreError::Mnemonic(format!("unknown word: {w}")))?;
        for i in (0..11).rev() {
            bits.push((idx >> i) & 1 == 1);
        }
    }
    let ent_len = n * 11 * 32 / 33;
    let cs_len = n * 11 - ent_len;
    let mut entropy = vec![0u8; ent_len / 8];
    for (i, bit) in bits.iter().take(ent_len).enumerate() {
        if *bit {
            entropy[i / 8] |= 1 << (7 - (i % 8));
        }
    }
    let hash = Sha256::digest(&entropy);
    for i in 0..cs_len {
        let expected = (hash[i / 8] >> (7 - (i % 8))) & 1 == 1;
        if bits[ent_len + i] != expected {
            return Err(CoreError::Mnemonic("invalid checksum".into()));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abandon_about_is_valid() {
        validate_phrase(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        )
        .unwrap();
    }

    #[test]
    fn abandon_abandon_is_invalid() {
        assert!(validate_phrase(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        )
        .is_err());
    }
}
