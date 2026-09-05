//! Duckpools: pool lending on Ergo, read and used the way the contracts
//! define it.
//!
//! - [`pools`]: the eight mainnet pools, their scripts, proxy addresses and
//!   fee steps.
//! - [`state`]: a pool box parsed, and what a holding is worth.
//! - [`fees`]: the protocol's service fee, as the pool contract computes it.
//! - [`interest`]: the borrow rate from the interest parameter box and the
//!   pool's utilisation.
//! - [`orders`]: quotes and the proxy boxes for lend and withdraw orders,
//!   the transactions that post them, the refund that takes one back, and
//!   how to tell what happened to one.
//!
//! No user action spends a pool box directly. The wallet posts an *order*
//! (a proxy box) and an off-chain bot fills it against the pool; if none
//! does, the order is refundable after the height the wallet chose.

pub mod encode;
pub mod fees;
pub mod interest;
pub mod orders;
pub mod pools;
pub mod state;

pub use interest::{InterestParams, Rates};
pub use orders::{
    build_order_tx, build_refund_tx, classify_spend, LendQuote, OrderOutcome, ProxyBox,
    WithdrawQuote,
};
pub use pools::{pool_by_key, pool_by_lend_token, pool_by_nft, Pool, POOLS};
pub use state::{parse_pool_boxes, PoolState, PoolsError};

/// `MaxLendTokens` in the pool contract: one million above the true
/// maximum so the genesis lend token is worth exactly one unit.
pub const MAX_LEND_TOKENS: i64 = 9_000_000_001_000_000;
/// `MaxBorrowTokens` in the pool contract.
pub const MAX_BORROW_TOKENS: i64 = 9_000_000_000_000_000;
/// The contracts' minimum box value and transaction fee, nanoERG.
pub const MIN_BOX_VALUE: i64 = 1_000_000;
pub const TX_FEE: i64 = 1_000_000;
