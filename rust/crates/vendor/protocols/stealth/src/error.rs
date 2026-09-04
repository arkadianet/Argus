//! Errors for stealth address handling.

#[derive(Debug, thiserror::Error, PartialEq, Eq, Clone)]
pub enum StealthError {
    /// The string does not start with the `stealth` marker.
    #[error("not a stealth address: missing 'stealth' prefix")]
    MissingPrefix,
    /// The Base58 body could not be decoded.
    #[error("stealth address is not valid Base58")]
    BadBase58,
    /// Decoded payload is not 33 bytes of key plus 4 bytes of checksum.
    #[error("stealth address has the wrong length ({0} bytes, expected 37)")]
    BadLength(usize),
    /// blake2b256 checksum mismatch.
    #[error("stealth address checksum does not match")]
    BadChecksum,
    /// The key bytes are not a point on secp256k1.
    #[error("stealth address does not decode to a curve point")]
    BadPoint,
    /// An ErgoTree that is not one of the stealth payment scripts.
    #[error("ErgoTree is not a stealth payment script")]
    NotStealthTree,
    /// Key derivation failed.
    #[error("stealth key derivation failed: {0}")]
    Derivation(String),
    /// Serialization / parsing problems from sigma-rust.
    #[error("stealth serialization error: {0}")]
    Serialization(String),
}
