use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use rand::RngCore;
use zeroize::Zeroize;

use crate::CoreError;

const VERSION: u32 = 2;
const VERSION_LEGACY: u32 = 1;
const NONCE_LEN: usize = 12;
const KEY_LEN: usize = 32;

/// AES-256-GCM sealed seed. The wrap key is stored separately in
/// Keystore/Keychain. v1 blobs that still embed `k` are accepted for migration.
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
        let cipher =
            Aes256Gcm::new_from_slice(&key).map_err(|e| CoreError::Encryption(e.to_string()))?;
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

    pub fn wrap_key_hex(&self) -> String {
        hex::encode(self.key)
    }

    pub fn to_json(&self) -> Result<serde_json::Value, CoreError> {
        Ok(serde_json::json!({
            "v": VERSION,
            "nonce": hex::encode(self.nonce),
            "ct": hex::encode(&self.ciphertext),
        }))
    }

    pub fn from_json(json: &serde_json::Value, wrap_key: Option<&str>) -> Result<Self, CoreError> {
        let version = json
            .get("v")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| CoreError::Serialization("missing schema version".into()))?;
        let key = match version {
            v if v == VERSION as u64 => decode_key_hex(wrap_key.ok_or_else(|| {
                CoreError::Serialization("missing wrap key for schema v2".into())
            })?)?,
            v if v == VERSION_LEGACY as u64 => decode_fixed::<KEY_LEN>(json, "k")?,
            v => {
                return Err(CoreError::Serialization(format!(
                    "unsupported schema version {v}"
                )));
            }
        };
        let nonce = decode_fixed::<NONCE_LEN>(json, "nonce")?;
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

fn decode_key_hex(hex_str: &str) -> Result<[u8; KEY_LEN], CoreError> {
    let bytes = hex::decode(hex_str).map_err(|e| CoreError::Serialization(e.to_string()))?;
    bytes
        .try_into()
        .map_err(|_| CoreError::Serialization(format!("wrap key must be {KEY_LEN} bytes")))
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
        let restored = EncryptedSeed::from_json(
            &encrypted.to_json().unwrap(),
            Some(&encrypted.wrap_key_hex()),
        )
        .unwrap();
        assert_eq!(restored.decrypt().unwrap().as_slice(), seed);
    }

    #[test]
    fn to_json_omits_wrap_key() {
        let seed = b"test-seed-for-json-roundtrip-000000";
        let encrypted = EncryptedSeed::encrypt(seed).unwrap();
        assert!(encrypted.to_json().unwrap().get("k").is_none());
    }

    #[test]
    fn v2_requires_wrap_key() {
        let seed = b"test-seed-for-json-roundtrip-000000";
        let encrypted = EncryptedSeed::encrypt(seed).unwrap();
        assert!(EncryptedSeed::from_json(&encrypted.to_json().unwrap(), None).is_err());
    }

    #[test]
    fn v1_blob_still_decrypts_with_embedded_key() {
        let seed = b"legacy-self-decrypting-seed-000000";
        let encrypted = EncryptedSeed::encrypt(seed).unwrap();
        let legacy = serde_json::json!({
            "v": 1,
            "nonce": hex::encode(encrypted.nonce),
            "ct": hex::encode(&encrypted.ciphertext),
            "k": encrypted.wrap_key_hex(),
        });
        let restored = EncryptedSeed::from_json(&legacy, None).unwrap();
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
        assert!(EncryptedSeed::from_json(&json, None).is_err());
    }

    #[test]
    fn from_json_rejects_unsupported_version() {
        let json = serde_json::json!({
            "v": 99,
            "nonce": hex::encode([0u8; 12]),
            "ct": "aa",
            "k": hex::encode([0u8; 32]),
        });
        let err = EncryptedSeed::from_json(&json, None)
            .err()
            .expect("unsupported version");
        assert!(matches!(err, CoreError::Serialization(_)));
    }

    #[test]
    fn from_json_rejects_missing_version() {
        let json = serde_json::json!({
            "nonce": hex::encode([0u8; 12]),
            "ct": "aa",
            "k": hex::encode([0u8; 32]),
        });
        assert!(EncryptedSeed::from_json(&json, None).is_err());
    }
}
