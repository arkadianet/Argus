//! Duckpools: pool lending on Ergo, read the way the contracts define it.
//!
//! Stage 1 is read-only: identify the eight mainnet pools, parse a pool
//! box into typed state, and value the lend tokens a wallet already holds.
//! Nothing here builds a transaction; orders (proxy boxes filled by
//! off-chain bots) come later and reuse this reader.
//!
//! The arithmetic follows `lendPool.md` in `duckpools/lend-protocol-
//! contracts`: lend tokens in circulation are the maximum minus what the
//! pool box holds, borrowed likewise for borrow tokens, and one lend token
//! is worth `(pooled + borrowed) / circulating` of the pooled asset.

pub mod pools;
pub mod state;

pub use pools::{pool_by_lend_token, pool_by_nft, Pool, POOLS};
pub use state::{parse_pool_boxes, PoolState, PoolsError};

/// `MaxLendTokens` in the pool contract: one million above the true
/// maximum so the genesis lend token is worth exactly one unit.
pub const MAX_LEND_TOKENS: i64 = 9_000_000_001_000_000;
/// `MaxBorrowTokens` in the pool contract.
pub const MAX_BORROW_TOKENS: i64 = 9_000_000_000_000_000;
