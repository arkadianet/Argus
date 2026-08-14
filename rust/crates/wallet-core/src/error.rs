use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("Mnemonic error: {0}")]
    Mnemonic(String),

    #[error("Derivation error: {0}")]
    Derivation(String),

    #[error("Encryption error: {0}")]
    Encryption(String),

    #[error("Key not found: {0}")]
    KeyNotFound(String),

    #[error("Transaction error: {0}")]
    Transaction(String),

    #[error("Reduction error: {0}")]
    Reduction(String),

    #[error("Signing error: {0}")]
    Signing(String),

    #[error("Wallet locked")]
    WalletLocked,

    #[error("Serialization error: {0}")]
    Serialization(String),

    #[error("IO error: {0}")]
    Io(String),
}