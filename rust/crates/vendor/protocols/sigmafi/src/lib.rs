//! SigmaFi: peer-to-peer bonds on Ergo, as the contracts define them.
//!
//! A borrower posts an *order*: collateral locked under the order contract
//! with the loan they want (R5), what they will repay (R6) and the term in
//! blocks (R7). A lender *closes* it: the collateral moves into a *bond*
//! box, the loan goes to the borrower, and the contract's two fees are
//! paid. Before maturity the borrower *repays* the bond and takes the
//! collateral back; after maturity the lender *liquidates* it and keeps
//! the collateral. An unfilled order can be *cancelled* by its borrower.
//!
//! - [`contracts`]: the order and bond scripts, per loan asset.
//! - [`tokens`]: the loan assets SigmaFi's own interface lists.
//! - [`market`]: order and bond boxes parsed, with the figures a screen
//!   shows.
//! - [`tx`]: the five transactions, built the way SigmaFi's interface
//!   builds them (Fleet plugins in `sigmafi-ui`).
//!
//! Every box here is an [`ergo_tx::Eip12InputBox`]; the caller fetches
//! them (by contract address) and hands them in.

pub mod contracts;
pub mod market;
pub mod tokens;
pub mod tx;

pub use contracts::{bond_contract, loan_asset_of_bond, loan_asset_of_order, order_contract};
pub use market::{parse_market, ActiveBond, Market, MarketError, OpenOrder};
pub use tokens::{loan_token, LoanToken, LOAN_TOKENS};
pub use tx::{
    build_cancel_order, build_close_order, build_liquidate, build_open_order, build_repay,
    OpenOrderRequest, SigmaFiTxError,
};

/// The loan asset id SigmaFi uses for ERG itself.
pub const ERG: &str = "ERG";
/// Miner fee SigmaFi's interface pays (Fleet's recommended minimum).
pub const MINER_FEE: i64 = 1_100_000;
/// The smallest box value the builders create; also the value of a
/// token-only order and of the token fee and loan boxes.
pub const SAFE_MIN_BOX_VALUE: i64 = 1_000_000;
/// Storage rent period: an order's term must stay below it.
pub const STORAGE_PERIOD: i32 = 1_051_200;
/// The order contract insists on a term strictly above 30 blocks.
pub const MIN_TERM_BLOCKS: i32 = 31;
/// Contract fee to SigmaFi's developer on every fill: 0.5% of the loan.
pub const DEV_FEE_NUM: u64 = 500;
/// Fee to whoever built the filling transaction: 0.4% of the loan.
pub const UI_FEE_NUM: u64 = 400;
pub const FEE_DENOM: u64 = 100_000;

/// The developer fee on a loan of `principal` units.
pub fn dev_fee(principal: u64) -> u64 {
    principal / FEE_DENOM * DEV_FEE_NUM + principal % FEE_DENOM * DEV_FEE_NUM / FEE_DENOM
}

/// The interface fee on a loan of `principal` units.
pub fn ui_fee(principal: u64) -> u64 {
    principal / FEE_DENOM * UI_FEE_NUM + principal % FEE_DENOM * UI_FEE_NUM / FEE_DENOM
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fees_match_the_contract_arithmetic() {
        // (500 * amount) / 100000 exactly, without the u64 overflow the
        // naive product would risk on large token amounts.
        assert_eq!(dev_fee(10_000_000_000), 50_000_000);
        assert_eq!(ui_fee(10_000_000_000), 40_000_000);
        assert_eq!(dev_fee(199_999), 999);
        assert_eq!(ui_fee(199_999), 799);
        assert_eq!(dev_fee(u64::MAX / 2), (u64::MAX / 2) / 200);
    }
}
