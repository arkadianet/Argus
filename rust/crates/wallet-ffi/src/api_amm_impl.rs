//! Spectrum AMM direct-swap integration for Argus mobile.
//!
//! Wraps the vendored Citadel `amm` protocol crate. Pool discovery and quotes
//! never touch the wallet handle; the build function reuses the existing
//! prepare → confirm → sign & broadcast flow.

#[cfg(test)]
mod tests {
    /// ErgoTree of the Citadel dev-fee P2PK (`ergo-tx/src/dev_fee.rs:29`).
    /// Argus must never pay it.
    const CITADEL_DEV_FEE_TREE: &str =
        "0008cd0224f3a8909d624e7c584f215956370278324c9b3bfc206a4605a27c952121e68c";

    /// `init_app` disables the inherited Citadel fee. This pins that guard:
    /// `resolved_dev_fee_config` caches into a process-global `OnceLock` on
    /// first call, so this must be the only test in the crate that resolves it.
    #[test]
    fn argus_never_levies_the_citadel_dev_fee() {
        crate::api::init_app();

        let cfg = ergo_tx::resolved_dev_fee_config();

        assert!(!cfg.enabled, "Citadel dev fee must stay disabled in Argus");
        assert_eq!(cfg.budget(), 0, "disabled fee must budget 0 nanoERG");
        assert_ne!(
            cfg.recipient_ergo_tree, CITADEL_DEV_FEE_TREE,
            "Argus must never target the Citadel fee address"
        );
    }
}
