/// Derive an encryption key from a mnemonic seed and passphrase using Argon2id.
/// Returns 32 bytes suitable for AES-256-GCM.
pub fn derive_encryption_key(seed: &[u8], salt: &[u8]) -> Result<[u8; 32], argon2::Error> {
    let mut key = [0u8; 32];
    Argon2::default().hash_password_into(seed, salt, &mut key)?;
    Ok(key)
}

use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use argon2::Argon2;
use rand::RngCore;
use zeroize::ZeroizeOnDrop;

use crate::CoreError;

/// An encrypted seed blob that lives in-memory and can be serialized to disk.
/// The plaintext seed is zeroed on drop.
#[derive(ZeroizeOnDrop)]
pub struct EncryptedSeed {
    nonce: [u8; 12],
    ciphertext: Vec<u8>,
    salt: [u8; 16],
}

impl EncryptedSeed {
    /// Encrypt raw seed bytes using a key derived from the mnemonic seed + salt.
    pub fn encrypt(seed_bytes: &[u8], key_seed: &[u8]) -> Result<Self, CoreError> {
        let mut salt = [0u8; 16];
        OsRng.fill_bytes(&mut salt);
        let key = derive_encryption_key(key_seed, &salt)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        let cipher = Aes256Gcm::new_from_slice(&key)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        let mut nonce = [0u8; 12];
        OsRng.fill_bytes(&mut nonce);
        let nonce_vec = Nonce::from_slice(&nonce);
        let ciphertext = cipher
            .encrypt(nonce_vec, seed_bytes)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        Ok(EncryptedSeed {
            nonce,
            ciphertext,
            salt,
        })
    }

    /// Decrypt and return the raw seed bytes. Caller must zeroize after use.
    pub fn decrypt(&self, key_seed: &[u8]) -> Result<Vec<u8>, CoreError> {
        let key = derive_encryption_key(key_seed, &self.salt)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        let cipher = Aes256Gcm::new_from_slice(&key)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        let nonce_vec = Nonce::from_slice(&self.nonce);
        let plaintext = cipher
            .decrypt(nonce_vec, self.ciphertext.as_ref())
            .map_err(|e| CoreError::Encryption(format!("Decryption failed: {:?}", e)))?;
        Ok(plaintext)
    }

    /// Serialize to a JSON-safe format. Does not contain the key_seed.
    pub fn to_json(&self) -> Result<serde_json::Value, CoreError> {
        Ok(serde_json::json!({
            "nonce": hex::encode(self.nonce),
            "ciphertext": hex::encode(&self.ciphertext),
            "salt": hex::encode(self.salt),
        }))
    }

    /// Deserialize from a previously-exported JSON value.
    pub fn from_json(json: &serde_json::Value) -> Result<Self, CoreError> {
        let nonce_hex = json["nonce"]
            .as_str()
            .ok_or_else(|| CoreError::Serialization("missing nonce".into()))?;
        let ciphertext_hex = json["ciphertext"]
            .as_str()
            .ok_or_else(|| CoreError::Serialization("missing ciphertext".into()))?;
        let salt_hex = json["salt"]
            .as_str()
            .ok_or_else(|| CoreError::Serialization("missing salt".into()))?;

        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(
            &hex::decode(nonce_hex)
                .map_err(|e| CoreError::Serialization(e.to_string()))?,
        );
        let ciphertext = hex::decode(ciphertext_hex)
            .map_err(|e| CoreError::Serialization(e.to_string()))?;
        let mut salt = [0u8; 16];
        salt.copy_from_slice(
            &hex::decode(salt_hex)
                .map_err(|e| CoreError::Serialization(e.to_string()))?,
        );

        Ok(EncryptedSeed {
            nonce,
            ciphertext,
            salt,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let seed = b"my-secret-ergo-seed-00000000000000";
        let key_seed = b"mnemonic-derived-key-material-here";
        let encrypted = EncryptedSeed::encrypt(seed, key_seed).unwrap();
        let decrypted = encrypted.decrypt(key_seed).unwrap();
        assert_eq!(decrypted.as_slice(), seed);
    }

    #[test]
    fn test_encrypt_decrypt_wrong_key() {
        let seed = b"my-secret-ergo-seed-00000000000000";
        let key_seed = b"correct-key-material";
        let encrypted = EncryptedSeed::encrypt(seed, key_seed).unwrap();
        let result = encrypted.decrypt(b"wrong-key-material");
        assert!(result.is_err());
    }

    #[test]
    fn test_json_roundtrip() {
        let seed = b"test-seed-for-json-roundtrip-000000";
        let key_seed = b"key-material-for-json-test";
        let encrypted = EncryptedSeed::encrypt(seed, key_seed).unwrap();
        let json = encrypted.to_json().unwrap();
        let restored = EncryptedSeed::from_json(&json).unwrap();
        let decrypted = restored.decrypt(key_seed).unwrap();
        assert_eq!(decrypted.as_slice(), seed);
    }
}