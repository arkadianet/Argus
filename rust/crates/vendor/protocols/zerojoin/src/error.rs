//! Errors for ZeroJoin mixing.

/// Everything that can go wrong before a mixing transaction is signed.
///
/// No variant ever carries a secret scalar: the messages are safe to log.
#[derive(Debug, thiserror::Error, PartialEq, Eq, Clone)]
pub enum ZeroJoinError {
    /// A pinned contract constant no longer matches what it is derived from.
    #[error("contract mismatch ({what}): expected {expected}, found {found}")]
    ContractMismatch {
        what: String,
        expected: String,
        found: String,
    },
    /// A box was handed to a parser for the wrong kind of box.
    #[error("box {box_id} is not a {expected} box")]
    WrongBoxKind { box_id: String, expected: String },
    /// A required register is missing or has the wrong type.
    #[error("box {box_id}: register {register} is missing or not a {expected}")]
    BadRegister {
        box_id: String,
        register: String,
        expected: String,
    },
    /// A box does not carry the mixing token where the contracts require it.
    #[error("box {box_id} does not hold the mixing token")]
    MissingMixingToken { box_id: String },
    /// Mix-token accounting the contracts would reject.
    #[error("mixing token accounting: {0}")]
    TokenAccounting(String),
    /// Not enough ERG in the supplied inputs.
    #[error("insufficient funds: need {needed} nanoERG, have {available}")]
    InsufficientFunds { needed: i64, available: i64 },
    /// The token emission box has no batch for the requested mix level.
    #[error("token emission box offers no batch for {requested} mixing tokens (has {available:?})")]
    NoSuchBatch {
        requested: i32,
        available: Vec<i32>,
    },
    /// The requested miner fee exceeds what the fee emission box allows.
    #[error("miner fee {requested} exceeds the fee box maximum {max_fee}")]
    FeeTooLarge { requested: i64, max_fee: i64 },
    /// Secret derivation failed.
    #[error("mix key derivation failed: {0}")]
    Derivation(String),
    /// Serialization / parsing problems from sigma-rust.
    #[error("serialization error: {0}")]
    Serialization(String),
    /// A caller-supplied value the builders cannot work with.
    #[error("invalid argument: {0}")]
    Invalid(String),
}
