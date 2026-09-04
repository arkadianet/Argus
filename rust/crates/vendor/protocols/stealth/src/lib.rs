//! Stealth addresses for Ergo, wire-compatible with ErgoMixer.
//!
//! A receiver keeps a secret `x` and publishes `u = g^x` as a `stealth…`
//! string. A sender picks random `r` and `y` and pays a one-time box guarded
//! by `proveDHTuple(g^r, g^y, u^r, u^y)`. Only the receiver can recognise the
//! box (`gr^x == ur && gy^x == uy`) and only the receiver can spend it.
//! Every payment lands on a different script, so nothing on chain links two
//! payments to the same receiver or to the published key.
//!
//! Reference implementation: ErgoMixer's `mixer/app/stealth/StealthContract.scala`
//! and `mixer/app/helpers/StealthUtils.scala`.

pub mod address;
pub mod detect;
pub mod error;
pub mod secret;
pub mod tree;

pub use address::{
    decode_stealth_address, encode_stealth_address, is_stealth_address,
    looks_like_stealth_address, STEALTH_PREFIX,
};
pub use detect::{detect_owned, parse_explorer_boxes, totals, StealthAsset, StealthBox};
pub use error::StealthError;
pub use secret::{
    build_payment_tree_hex, payment_address_for_stealth_address, StealthSecret,
    STEALTH_DERIVATION_PATH,
};
pub use tree::{
    is_stealth_tree, parse_stealth_tree, stealth_template_hash_hex, stealth_tree_to_address,
    StealthTuple, STEALTH_TEMPLATE_HEX,
};
