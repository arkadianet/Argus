//! Errors found before a recovery transaction can be assembled.

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RecoveryError {
    #[error("box {box_id}: {why}")]
    Box { box_id: String, why: String },
    #[error("box {box_id}: register {register} must be {expected}")]
    Register {
        box_id: String,
        register: String,
        expected: String,
    },
    #[error("serialization error: {0}")]
    Serialization(String),
    #[error("invalid recovery: {0}")]
    Invalid(String),
    #[error("recovery arithmetic overflow: {0}")]
    Overflow(&'static str),
}
