//! ZeroJoin mixing for Ergo, wire-compatible with the live ErgoMixer pool.
//!
//! ZeroJoin is a non-custodial, non-interactive two-party mix with no
//! coordinator. Alice posts a *half-mix box* holding `gX = g^x`. Bob spends it
//! together with an input of the same denomination and creates two *full-mix
//! boxes*, each holding a pair `(c1, c2)` that is either `(g^y, gX^y)` or the
//! swap, in an order only he knows; a DH-tuple proof shows one ordering is
//! honest without revealing which. Each output now belongs to one of the two,
//! and nobody watching can say which. Repeat, and the anonymity set doubles
//! per round.
//!
//! ## Interoperability is the point
//!
//! This crate does **not** deploy its own contracts. It reproduces the four
//! ErgoMixer contracts byte for byte from mainnet, so an Argus box is
//! indistinguishable from an ErgoMixer box and shares the same anonymity set.
//! A mixer whose pool contained only Argus users would hide nothing. Where
//! this crate's model and the deployed contract disagree, the contract wins;
//! see [`contracts::verify_contract_wiring`].
//!
//! ## What is here, and what is not
//!
//! - [`contracts`]: the four ErgoTrees, their hashes and the operator
//!   identities, verified against mainnet.
//! - [`boxes`]: typed views over half-mix, full-mix, fee-emission and
//!   token-emission boxes, plus ring (denomination) discovery.
//! - [`secret`]: `x` and `y` derived from the seed on a dedicated hardened
//!   branch, never stored.
//! - [`round`]: the round model as pure functions, including the mixing-token
//!   accounting the contracts enforce.
//! - [`tx_builder`]: the five moves, as `Eip12UnsignedTx` plus prover inputs.
//!
//! There is no state machine, no persistence, no scanning and no UI yet: a
//! later change adds the per-mix state machine, background advancement and
//! the Mix screen. Nothing in Argus calls this crate yet.
//!
//! ## The operator dependency
//!
//! The fee-emission and token-emission boxes belong to ErgoMixer's operator.
//! If they are not refilled, mixing stops — no new rounds can be built. Funds
//! already in half- and full-mix boxes stay spendable by their owners
//! regardless, via [`tx_builder::build_reclaim_half_mix`] (which pays its own
//! fee) and, while a fee box exists, [`tx_builder::build_withdraw`].

pub mod boxes;
pub mod contracts;
pub mod error;
pub mod round;
pub mod secret;
pub mod tx_builder;

#[cfg(test)]
pub(crate) mod testing;

pub use boxes::{
    discover_rings, parse_explorer_boxes, FeeEmissionBox, FullMixBox, HalfMixBox, Ring,
    TokenEmissionBox,
};
pub use contracts::{
    verify_contract_wiring, FEE_EMISSION_ERGO_TREE_HEX, FULL_MIX_ERGO_TREE_HEX,
    HALF_MIX_ERGO_TREE_HEX, MIXING_TOKEN_ID, TOKEN_EMISSION_ERGO_TREE_HEX,
};
pub use error::ZeroJoinError;
pub use round::{MixTokenSplit, PairOrder};
pub use secret::{MixSecret, Role, MIX_DERIVATION_BRANCH};
pub use tx_builder::{
    build_alice_entry, build_bob_entry, build_reclaim_half_mix, build_remix_as_alice,
    build_remix_as_bob, build_withdraw, AliceEntry, BobEntry, MixProverInput, MixTx, MixTxSummary,
    ReclaimHalfMix, RemixAsAlice, RemixAsBob, Withdraw,
};
