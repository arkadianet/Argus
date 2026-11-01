/// Argus charges no application fee.
///
/// It used to pay a flat fee on every transaction the wallet built. That was
/// wrong for the privacy features in particular: a transaction spending a
/// stealth address, or paying the mixer's funding box, carried an output
/// identifying this wallet as the one that built it — the exact link those
/// features exist to break. The fee is now disabled in the Rust fee config
/// (`init_app` in `rust/crates/wallet-ffi/src/api.rs`), so no builder appends
/// one, and the only cost of a transaction is its miner fee.
///
/// Nothing in the app may budget for, reserve, or display a fee that is not
/// charged. [txOverheadNano] is the single place that says what a transaction
/// costs on top of what it sends.
int txOverheadNano({int minerFee = minerFeeDefaultNano}) => minerFee;

const minerFeeDefaultNano = 1100000;