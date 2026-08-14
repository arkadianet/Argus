use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Structured error type for all Argus wallet operations.
/// Serialized to JSON for Dart-side parsing.
#[derive(Debug, Clone, Serialize, Deserialize, Error)]
pub enum ArgusError {
    #[error("Handle {1} not found — wallet may not be unlocked")]
    HandleNotFound(&'static str, u64),

    #[error("Wallet is locked")]
    WalletLocked,

    #[error("Invalid mnemonic: {0}")]
    InvalidMnemonic(String),

    #[error("Derivation failed: {0}")]
    DerivationFailed(String),

    #[error("Encryption failed: {0}")]
    EncryptionFailed(String),

    #[error("Node unreachable at {0}")]
    NodeUnreachable(String),

    #[error("Node returned error: {0}")]
    NodeError(String),

    #[error("No UTXOs available for address {0}")]
    NoUtxos(String),

    #[error("Transaction build failed: {0}")]
    TxBuildFailed(String),

    #[error("Transaction reduction failed: {0}")]
    TxReductionFailed(String),

    #[error("Signing failed: {0}")]
    SigningFailed(String),

    #[error("Invalid address: {0}")]
    InvalidAddress(String),

    #[error("Serialization error: {0}")]
    SerializationError(String),

    #[error("{0}")]
    Generic(String),
}

impl ArgusError {
    pub fn code(&self) -> &'static str {
        match self {
            ArgusError::HandleNotFound(..) => "HANDLE_NOT_FOUND",
            ArgusError::WalletLocked => "WALLET_LOCKED",
            ArgusError::InvalidMnemonic(_) => "INVALID_MNEMONIC",
            ArgusError::DerivationFailed(_) => "DERIVATION_FAILED",
            ArgusError::EncryptionFailed(_) => "ENCRYPTION_FAILED",
            ArgusError::NodeUnreachable(_) => "NODE_UNREACHABLE",
            ArgusError::NodeError(_) => "NODE_ERROR",
            ArgusError::NoUtxos(_) => "NO_UTXOS",
            ArgusError::TxBuildFailed(_) => "TX_BUILD_FAILED",
            ArgusError::TxReductionFailed(_) => "TX_REDUCTION_FAILED",
            ArgusError::SigningFailed(_) => "SIGNING_FAILED",
            ArgusError::InvalidAddress(_) => "INVALID_ADDRESS",
            ArgusError::SerializationError(_) => "SERIALIZATION_ERROR",
            ArgusError::Generic(_) => "GENERIC",
        }
    }

    /// Serialize to a JSON string for crossing the FRB boundary.
    pub fn to_json_string(&self) -> String {
        serde_json::json!({
            "code": self.code(),
            "message": self.to_string(),
        })
        .to_string()
    }
}

impl From<wallet_core::CoreError> for ArgusError {
    fn from(e: wallet_core::CoreError) -> Self {
        match e {
            wallet_core::CoreError::Mnemonic(msg) => ArgusError::InvalidMnemonic(msg),
            wallet_core::CoreError::Derivation(msg) => ArgusError::DerivationFailed(msg),
            wallet_core::CoreError::Encryption(msg) => ArgusError::EncryptionFailed(msg),
            wallet_core::CoreError::KeyNotFound(msg) => ArgusError::Generic(msg),
            wallet_core::CoreError::Transaction(msg) => ArgusError::TxBuildFailed(msg),
            wallet_core::CoreError::Reduction(msg) => ArgusError::TxReductionFailed(msg),
            wallet_core::CoreError::Signing(msg) => ArgusError::SigningFailed(msg),
            wallet_core::CoreError::WalletLocked => ArgusError::WalletLocked,
            wallet_core::CoreError::Serialization(msg) => ArgusError::SerializationError(msg),
            wallet_core::CoreError::Io(msg) => ArgusError::Generic(msg),
        }
    }
}

/// Convert any error into a JSON error string for FRB boundary.
pub fn err_to_string<E: std::fmt::Display>(e: E) -> String {
    ArgusError::Generic(e.to_string()).to_json_string()
}