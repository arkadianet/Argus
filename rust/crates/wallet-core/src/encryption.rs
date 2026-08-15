use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use rand::RngCore;
use zeroize::Zeroize;

use crate::CoreError;

const VERSION: u32 = 1;
const NONCE_LEN: usize = 12;
const KEY_LEN: usize = 32;

/// AES-256-GCM sealed seed. The wrap key lives in this blob; confidentiality
/// comes from Android Keystore / iOS Keychain, not from this layer.
pub struct EncryptedSeed {
    nonce: [u8; NONCE_LEN],
    ciphertext: Vec<u8>,
    key: [u8; KEY_LEN],
}

impl Drop for EncryptedSeed {
    fn drop(&mut self) {
        self.key.zeroize();
        self.ciphertext.zeroize();
        self.nonce.zeroize();
    }
}

impl EncryptedSeed {
    pub fn encrypt(seed_bytes: &[u8]) -> Result<Self, CoreError> {
        let mut key = [0u8; KEY_LEN];
        OsRng.fill_bytes(&mut key);
        let cipher = Aes256Gcm::new_from_slice(&key)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        let mut nonce = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut nonce);
        let ciphertext = cipher
            .encrypt(Nonce::from_slice(&nonce), seed_bytes)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        Ok(EncryptedSeed {
            nonce,
            ciphertext,
            key,
        })
    }

    pub fn decrypt(&self) -> Result<Vec<u8>, CoreError> {
        let cipher = Aes256Gcm::new_from_slice(&self.key)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        cipher
            .decrypt(Nonce::from_slice(&self.nonce), self.ciphertext.as_ref())
            .map_err(|e| CoreError::Encryption(format!("Decryption failed: {e:?}")))
    }

    pub fn to_json(&self) -> Result<serde_json::Value, CoreError> {
        Ok(serde_json::json!({
            "v": VERSION,
            "nonce": hex::encode(self.nonce),
            "ct": hex::encode(&self.ciphertext),
            "k": hex::encode(self.key),
        }))
    }

    pub fn from_json(json: &serde_json::Value) -> Result<Self, CoreError> {
        let nonce = decode_fixed::<NONCE_LEN>(json, "nonce")?;
        let key = decode_fixed::<KEY_LEN>(json, "k")?;
        let ciphertext = decode_vec(json, "ct")?;
        if ciphertext.is_empty() {
            return Err(CoreError::Serialization("empty ciphertext".into()));
        }
        Ok(EncryptedSeed {
            nonce,
            ciphertext,
            key,
        })
    }
}

fn decode_vec(json: &serde_json::Value, field: &str) -> Result<Vec<u8>, CoreError> {
    let hex_str = json
        .get(field)
        .and_then(|v| v.as_str())
        .ok_or_else(|| CoreError::Serialization(format!("missing {field}")))?;
    hex::decode(hex_str).map_err(|e| CoreError::Serialization(e.to_string()))
}

fn decode_fixed<const N: usize>(
    json: &serde_json::Value,
    field: &str,
) -> Result<[u8; N], CoreError> {
    let bytes = decode_vec(json, field)?;
    bytes
        .try_into()
        .map_err(|_| CoreError::Serialization(format!("{field} must be {N} bytes")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let seed = b"my-secret-ergo-seed-00000000000000";
        let encrypted = EncryptedSeed::encrypt(seed).unwrap();
        assert_eq!(encrypted.decrypt().unwrap().as_slice(), seed);
    }

    #[test]
    fn json_roundtrip() {
        let seed = b"test-seed-for-json-roundtrip-000000";
        let encrypted = EncryptedSeed::encrypt(seed).unwrap();
        let restored = EncryptedSeed::from_json(&encrypted.to_json().unwrap()).unwrap();
        assert_eq!(restored.decrypt().unwrap().as_slice(), seed);
    }

    #[test]
    fn from_json_rejects_short_nonce() {
        let json = serde_json::json!({
            "v": 1,
            "nonce": "aa",
            "ct": "bb",
            "k": hex::encode([0u8; 32]),
        });
        assert!(EncryptedSeed::from_json(&json).is_err());
    }
}
