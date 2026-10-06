//! Spectrum pools as Argus reads them: exact pool arithmetic, on-chain token
//! and LP-token prices, and circular arbitrage found, sized and costed.
//!
//! Built for Argus from a comparison of the vendored Citadel `amm` router
//! and Pantheon's `amm-arb-bot` with ergo-sdk's `ergo-pricing`
//! (docs/superpowers/specs/2026-10-06-onchain-pricing-and-arbitrage-design.md),
//! taking the better piece of each and fixing what both got wrong against
//! the deployed contracts. Pure: no network, no keys, no vendored code.
//! Discovery and transaction building stay with the callers.

pub mod arb;
pub mod chain;
pub mod contract;
pub mod graph;
pub mod math;
pub mod pool;
pub mod pricing;

pub use arb::{
    evaluate, requote, route_edges, scan, size_path, ArbLeg, ArbOptions, ArbScan, Costs,
    Opportunity, RouteError, RouteStep,
};
pub use chain::{best_exit, classify, stranded_holding, ChainState, ExitQuote, LegStatus};
pub use graph::{quote_path, Edge, PoolGraph};
pub use pool::{Asset, Pool, PoolError, PoolKind};
pub use pricing::{price_book, LpQuote, PriceBook, PriceRoute, PricingOptions, TokenQuote};
