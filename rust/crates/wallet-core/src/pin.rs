use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use argon2::{Algorithm, Argon2, Params, Version};
use rand::RngCore;
use zeroize::Zeroize;

use crate::CoreError;

const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const KEY_LEN: usize = 32;
/// OWASP Argon2id minimum (19 MiB). Upper bounds keep a hostile blob from OOM.
const M_COST: u32 = 19_456;
const M_COST_MAX: u32 = 65_536;
const T_COST: u32 = 2;
const T_COST_MAX: u32 = 8;
const P_COST: u32 = 1;
const P_COST_MAX: u32 = 4;
const PIN_WRAP_VERSION: u64 = 1;

pub struct PinWrappedKey {
    salt: [u8; SALT_LEN],
    nonce: [u8; NONCE_LEN],
    ciphertext: Vec<u8>,
    m_cost: u32,
    t_cost: u32,
    p_cost: u32,
}

impl Drop for PinWrappedKey {
    fn drop(&mut self) {
        self.salt.zeroize();
        self.nonce.zeroize();
        self.ciphertext.zeroize();
    }
}

fn validate_pin(pin: &str) -> Result<(), CoreError> {
    let n = pin.chars().count();
    if n < 6 || n > 32 {
        return Err(CoreError::Encryption("PIN must be 6-32 characters".into()));
    }
    Ok(())
}

fn derive_kek(
    pin: &str,
    salt: &[u8],
    m_cost: u32,
    t_cost: u32,
    p_cost: u32,
) -> Result<[u8; KEY_LEN], CoreError> {
    let params = Params::new(m_cost, t_cost, p_cost, Some(KEY_LEN))
        .map_err(|e| CoreError::Encryption(e.to_string()))?;
    let mut kek = [0u8; KEY_LEN];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(pin.as_bytes(), salt, &mut kek)
        .map_err(|e| CoreError::Encryption(e.to_string()))?;
    Ok(kek)
}

impl PinWrappedKey {
    pub fn wrap(wrap_key: &[u8], pin: &str) -> Result<Self, CoreError> {
        validate_pin(pin)?;
        if wrap_key.len() != KEY_LEN {
            return Err(CoreError::Encryption("wrap key must be 32 bytes".into()));
        }
        let mut salt = [0u8; SALT_LEN];
        OsRng.fill_bytes(&mut salt);
        let mut kek = derive_kek(pin, &salt, M_COST, T_COST, P_COST)?;
        let cipher =
            Aes256Gcm::new_from_slice(&kek).map_err(|e| CoreError::Encryption(e.to_string()))?;
        kek.zeroize();
        let mut nonce = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut nonce);
        let ciphertext = cipher
            .encrypt(Nonce::from_slice(&nonce), wrap_key)
            .map_err(|e| CoreError::Encryption(e.to_string()))?;
        Ok(PinWrappedKey {
            salt,
            nonce,
            ciphertext,
            m_cost: M_COST,
            t_cost: T_COST,
            p_cost: P_COST,
        })
    }

    pub fn unwrap(&self, pin: &str) -> Result<[u8; KEY_LEN], CoreError> {
        validate_pin(pin)?;
        let mut kek = derive_kek(pin, &self.salt, self.m_cost, self.t_cost, self.p_cost)?;
        let cipher =
            Aes256Gcm::new_from_slice(&kek).map_err(|e| CoreError::Encryption(e.to_string()))?;
        kek.zeroize();
        let mut plain = cipher
            .decrypt(Nonce::from_slice(&self.nonce), self.ciphertext.as_ref())
            .map_err(|_| CoreError::Encryption("incorrect PIN".into()))?;
        let key = plain
            .as_slice()
            .try_into()
            .map_err(|_| CoreError::Encryption("unwrap produced invalid key".into()));
        plain.zeroize();
        key
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "v": 1,
            "salt": hex::encode(self.salt),
            "nonce": hex::encode(self.nonce),
            "ct": hex::encode(&self.ciphertext),
            "m": self.m_cost,
            "t": self.t_cost,
            "p": self.p_cost,
        })
    }

    pub fn from_json(json: &serde_json::Value) -> Result<Self, CoreError> {
        let version = json
            .get("v")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| CoreError::Serialization("missing pin wrap version".into()))?;
        if version != PIN_WRAP_VERSION {
            return Err(CoreError::Serialization(format!(
                "unsupported pin wrap version {version}"
            )));
        }
        let m_cost = bounded_u32(json, "m", M_COST, M_COST_MAX)?;
        let t_cost = bounded_u32(json, "t", T_COST, T_COST_MAX)?;
        let p_cost = bounded_u32(json, "p", P_COST, P_COST_MAX)?;
        let salt = decode_fixed::<SALT_LEN>(json, "salt")?;
        let nonce = decode_fixed::<NONCE_LEN>(json, "nonce")?;
        let ciphertext = decode_vec(json, "ct")?;
        if ciphertext.is_empty() {
            return Err(CoreError::Serialization("empty pin wrap".into()));
        }
        Ok(PinWrappedKey {
            salt,
            nonce,
            ciphertext,
            m_cost,
            t_cost,
            p_cost,
        })
    }
}

fn bounded_u32(
    json: &serde_json::Value,
    field: &str,
    min: u32,
    max: u32,
) -> Result<u32, CoreError> {
    let raw = json
        .get(field)
        .and_then(|v| v.as_u64())
        .ok_or_else(|| CoreError::Serialization(format!("missing {field}")))?;
    let value = u32::try_from(raw)
        .map_err(|_| CoreError::Serialization(format!("{field} out of range")))?;
    if value < min || value > max {
        return Err(CoreError::Serialization(format!(
            "{field} must be {min}..={max}"
        )));
    }
    Ok(value)
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
    fn pin_wrap_roundtrip() {
        let key = [7u8; 32];
        let wrapped = PinWrappedKey::wrap(&key, "123456").unwrap();
        assert_eq!(wrapped.unwrap("123456").unwrap(), key);
    }

    #[test]
    fn wrong_pin_fails() {
        let key = [7u8; 32];
        let wrapped = PinWrappedKey::wrap(&key, "123456").unwrap();
        assert!(wrapped.unwrap("654321").is_err());
    }

    #[test]
    fn short_pin_rejected() {
        assert!(PinWrappedKey::wrap(&[1u8; 32], "12345").is_err());
    }

    #[test]
    fn json_roundtrip() {
        let key = [9u8; 32];
        let wrapped = PinWrappedKey::wrap(&key, "abcdef").unwrap();
        let restored = PinWrappedKey::from_json(&wrapped.to_json()).unwrap();
        assert_eq!(restored.unwrap("abcdef").unwrap(), key);
    }

    #[test]
    fn from_json_rejects_bad_params() {
        let key = [1u8; 32];
        let good = PinWrappedKey::wrap(&key, "123456").unwrap().to_json();
        let mut missing_v = good.clone();
        missing_v.as_object_mut().unwrap().remove("v");
        assert!(PinWrappedKey::from_json(&missing_v).is_err());

        let mut bad_v = good.clone();
        bad_v["v"] = serde_json::json!(2);
        assert!(PinWrappedKey::from_json(&bad_v).is_err());

        let mut huge_m = good.clone();
        huge_m["m"] = serde_json::json!(u64::MAX);
        assert!(PinWrappedKey::from_json(&huge_m).is_err());

        let mut low_m = good;
        low_m["m"] = serde_json::json!(1);
        assert!(PinWrappedKey::from_json(&low_m).is_err());
    }
}
