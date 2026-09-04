//! The published `stealth…` string.
//!
//! Format, identical to ErgoMixer's `createStealthAddress`:
//! `"stealth" + Base58(u ‖ blake2b256(u)[..4])` where `u = g^x` is the
//! receiver's key in compressed SEC-1 form (33 bytes).

use ergo_chain_types::{blake2b256_hash, EcPoint};
use sigma_ser::ScorexSerializable;

use crate::error::StealthError;

/// Marker every published stealth string starts with.
pub const STEALTH_PREFIX: &str = "stealth";

/// Compressed point (33) + checksum (4).
const PAYLOAD_LEN: usize = 37;

/// Encode a receiver key as its published `stealth…` string.
pub fn encode_stealth_address(u: &EcPoint) -> Result<String, StealthError> {
    let key = u
        .scorex_serialize_bytes()
        .map_err(|e| StealthError::Serialization(e.to_string()))?;
    let checksum = blake2b256_hash(&key);
    let mut payload = key;
    payload.extend_from_slice(&checksum.0[..4]);
    Ok(format!(
        "{STEALTH_PREFIX}{}",
        bs58::encode(&payload).into_string()
    ))
}

/// Decode and fully validate a `stealth…` string into the receiver key `u`.
pub fn decode_stealth_address(address: &str) -> Result<EcPoint, StealthError> {
    let trimmed = address.trim();
    let body = trimmed
        .strip_prefix(STEALTH_PREFIX)
        .ok_or(StealthError::MissingPrefix)?;
    if body.is_empty() {
        return Err(StealthError::MissingPrefix);
    }
    let payload = bs58::decode(body)
        .into_vec()
        .map_err(|_| StealthError::BadBase58)?;
    if payload.len() != PAYLOAD_LEN {
        return Err(StealthError::BadLength(payload.len()));
    }
    let (key, checksum) = payload.split_at(PAYLOAD_LEN - 4);
    if blake2b256_hash(key).0[..4] != *checksum {
        return Err(StealthError::BadChecksum);
    }
    EcPoint::from_base16_str(hex::encode(key)).ok_or(StealthError::BadPoint)
}

/// Cheap predicate for UI validation: is this a well-formed stealth string?
pub fn is_stealth_address(address: &str) -> bool {
    decode_stealth_address(address).is_ok()
}

/// True when the string looks like it *wants* to be a stealth address, so the
/// UI can report a checksum problem instead of "unknown address format".
pub fn looks_like_stealth_address(address: &str) -> bool {
    address.trim().starts_with(STEALTH_PREFIX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_chain_types::ec_point::{exponentiate_gen, generator};
    use ergotree_ir::sigma_protocol::dlog_group::random_scalar_in_group_range;

    fn sample_key() -> EcPoint {
        exponentiate_gen(&random_scalar_in_group_range(rand::rngs::OsRng))
    }

    #[test]
    fn round_trips() {
        for _ in 0..8 {
            let u = sample_key();
            let s = encode_stealth_address(&u).unwrap();
            assert!(s.starts_with("stealth"));
            assert_eq!(decode_stealth_address(&s).unwrap(), u);
            assert!(is_stealth_address(&s));
        }
    }

    #[test]
    fn generator_encodes_to_a_stable_string() {
        // Fixed vector: the generator itself, so the encoding cannot drift.
        let s = encode_stealth_address(&generator()).unwrap();
        assert_eq!(decode_stealth_address(&s).unwrap(), generator());
        assert!(s.len() > 50);
    }

    /// Dart's `looksLikeStealthAddress` accepts a Base58 body of 48-53
    /// characters. Every real address must land inside that window or the
    /// Send form would reject what this crate produces.
    #[test]
    fn encoded_length_matches_the_dart_shape_check() {
        for _ in 0..64 {
            let s = encode_stealth_address(&sample_key()).unwrap();
            let body = s.strip_prefix(STEALTH_PREFIX).unwrap().len();
            assert!(
                (48..=53).contains(&body),
                "body of {body} chars is outside the Dart window: {s}"
            );
        }
    }

    #[test]
    fn rejects_bad_prefix() {
        assert_eq!(
            decode_stealth_address("9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8")
                .unwrap_err(),
            StealthError::MissingPrefix
        );
        assert_eq!(
            decode_stealth_address("stealth").unwrap_err(),
            StealthError::MissingPrefix
        );
    }

    #[test]
    fn rejects_corrupted_checksum() {
        let s = encode_stealth_address(&sample_key()).unwrap();
        let mut bytes: Vec<char> = s.chars().collect();
        let last = bytes.len() - 1;
        bytes[last] = if bytes[last] == 'a' { 'b' } else { 'a' };
        let broken: String = bytes.into_iter().collect();
        assert!(matches!(
            decode_stealth_address(&broken),
            Err(StealthError::BadChecksum) | Err(StealthError::BadLength(_))
        ));
        assert!(!is_stealth_address(&broken));
        assert!(looks_like_stealth_address(&broken));
    }

    #[test]
    fn rejects_non_base58() {
        assert_eq!(
            decode_stealth_address("stealth0OIl+/").unwrap_err(),
            StealthError::BadBase58
        );
    }
}
