//! Rosen bridge, from the Ergo side.
//!
//! A transfer out of Ergo is one transaction: the asset goes into a box
//! at the bridge's *lock* address whose R4 says where it is going (the
//! target chain and address), what the bridge and the target network
//! charge, and who sent it. Watchers see the box, guards pay out on the
//! other chain. The fees come from a *minimum-fee* box the bridge keeps
//! on chain per token, read here as its registers define them.
//!
//! - [`tokens`]: which Ergo tokens bridge where, from Rosen's tokens map.
//! - [`fees`]: the minimum-fee box and what a transfer costs.
//! - [`lock`]: the lock transaction.
//! - [`address`]: whether a target-chain address is well formed.

pub mod address;
pub mod fees;
pub mod lock;
pub mod tokens;

pub use address::{validate_address, AddressError};
pub use fees::{ChainFee, FeeConfig, FeeQuote, FeesError};
pub use lock::{build_lock_tx, LockBuildResult, LockError, LockSpec, LockSummary};
pub use tokens::{bridgeable, chains, token_map, BridgeTarget, BridgedToken};

/// The bridge's lock address on mainnet (contracts 7.1.0, public launch).
pub const LOCK_ADDRESS: &str = "nB3L2PD3J4rMmyGk7nnNdESpPXxhPRQ4t1chF8LTXtceMQjKCEgL2pFjPY6cehGjyEFZyHEomBTFXZyqfonvxDozrTtK5JzatD8SdmcPeJNWPvdRb5UxEMXE4WQtpAFzt2veT8Z6bmoWN";
/// The NFT every minimum-fee box carries.
pub const MIN_FEE_NFT: &str = "e2ed4d64393222db666f20e67803e9e6fbe6d64531e14ff52ddd95615b0cbf17";
/// The chain key Ergo goes by in the bridge.
pub const ERGO_CHAIN: &str = "ergo";
/// The lock box carries this much ERG when the asset is a token.
pub const LOCK_MIN_BOX_VALUE: i64 = 2_000_000;
/// The version of Rosen's contracts these identities come from.
pub const CONTRACTS_VERSION: &str = "7.1.0";
