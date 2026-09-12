//! Recovery of abandoned v1 stakes, as the deployed contracts define it.
//!
//! [`contracts`] binds each pool to its addresses and assets. [`boxes`] reads
//! canonical chain boxes, and [`validation`] checks the relationships needed
//! for a full unstake. The caller supplies chain data and establishes wallet
//! ownership; this crate does no discovery or submission.

pub mod boxes;
pub mod contracts;
pub mod direct;
pub mod error;
pub mod validation;

pub use boxes::{PaideiaProxyBox, StakeBox, StakeStateBox};
pub use contracts::Pool;
pub use error::RecoveryError;
pub mod proxy;
