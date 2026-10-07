//! What the Spectrum CFMM v1 pool contracts actually enforce, read from the
//! deployed ErgoTrees rather than from documentation or other code.
//!
//! Every pool of a kind shares one ErgoTree (nothing is substituted per
//! pool), so the trees double as the discovery query. Decoding their
//! constants and body gives the facts the math must respect:
//!
//! - `FeeDenom` is the constant `1000` (N2T constant 8, T2T constant 10).
//!   The numerator is each pool's own `R4: Int`, and the successor box must
//!   carry the same value, so a box without an `Int` in R4 can never be
//!   spent and is not a pool.
//! - A swap is valid when `reservesOut0 * deltaIn * feeNum >= -deltaOut *
//!   (reservesIn0 * FeeDenom + deltaIn * feeNum)`. The largest output for
//!   an input is therefore the floor of the CFMM formula, and the smallest
//!   input for a wanted output its ceiling.
//! - An N2T pool's ERG reserve is the whole box value (`SELF.value`), and
//!   the successor must keep `value > 10_000_000` (constant 14 under a
//!   strict `>`). A swap can take out at most `value - 10_000_001`
//!   nanoERG; the vendored calculator and Pantheon both stop at a
//!   1_000_000 floor instead, which the contract rejects.
//! - A T2T successor must keep `value >= SELF.value`: swaps never move a
//!   T2T pool's ERG, which is storage rent and not a reserve.
//! - LP supply is `0x7fffffffffffffff` minus the LP tokens held by the pool
//!   box. Pool creation never mints the last 1000 units, so the supply the
//!   contract divides by is always at least 1000 more than holders own.

/// ErgoTree of every Spectrum N2T (ERG/token) pool box.
pub const N2T_POOL_TREE: &str = "1999030f0400040204020404040405feffffffffffffffff0105feffffffffffffffff01050004d00f040004000406050005000580dac409d819d601b2a5730000d602e4c6a70404d603db63087201d604db6308a7d605b27203730100d606b27204730200d607b27203730300d608b27204730400d6099973058c720602d60a999973068c7205027209d60bc17201d60cc1a7d60d99720b720cd60e91720d7307d60f8c720802d6107e720f06d6117e720d06d612998c720702720fd6137e720c06d6147308d6157e721206d6167e720a06d6177e720906d6189c72117217d6199c72157217d1ededededededed93c27201c2a793e4c672010404720293b27203730900b27204730a00938c7205018c720601938c7207018c72080193b17203730b9593720a730c95720e929c9c721072117e7202069c7ef07212069a9c72137e7214067e9c720d7e72020506929c9c721372157e7202069c7ef0720d069a9c72107e7214067e9c72127e7202050695ed720e917212730d907216a19d721872139d72197210ed9272189c721672139272199c7216721091720b730e";

/// ErgoTree of every Spectrum T2T (token/token) pool box.
pub const T2T_POOL_TREE: &str = "19a9030f040004020402040404040406040605feffffffffffffffff0105feffffffffffffffff01050004d00f0400040005000500d81ad601b2a5730000d602e4c6a70404d603db63087201d604db6308a7d605b27203730100d606b27204730200d607b27203730300d608b27204730400d609b27203730500d60ab27204730600d60b9973078c720602d60c999973088c720502720bd60d8c720802d60e998c720702720dd60f91720e7309d6108c720a02d6117e721006d6127e720e06d613998c7209027210d6147e720d06d615730ad6167e721306d6177e720c06d6187e720b06d6199c72127218d61a9c72167218d1edededededed93c27201c2a793e4c672010404720292c17201c1a793b27203730b00b27204730c00938c7205018c720601ed938c7207018c720801938c7209018c720a019593720c730d95720f929c9c721172127e7202069c7ef07213069a9c72147e7215067e9c720e7e72020506929c9c721472167e7202069c7ef0720e069a9c72117e7215067e9c72137e7202050695ed720f917213730e907217a19d721972149d721a7211ed9272199c7217721492721a9c72177211";

/// The pool contracts' fee denominator.
pub const FEE_DENOM: u32 = 1000;

/// An N2T successor must hold strictly more than this many nanoERG.
pub const N2T_MIN_VALUE_EXCLUSIVE: u64 = 10_000_000;

/// LP tokens initially locked in a pool; supply is this minus what the
/// pool box still holds.
pub const LP_EMISSION: u64 = 0x7fff_ffff_ffff_ffff;

#[cfg(test)]
mod tests {
    use super::*;

    /// The constants above are only true of these exact trees. Pin the
    /// encoded pieces they were read from, so editing a tree without
    /// re-deriving the facts fails here.
    #[test]
    fn facts_match_the_encoded_trees() {
        // Int 1000 (zigzag VLQ d00f) is the fee denominator in both.
        assert!(N2T_POOL_TREE.contains("04d00f"));
        assert!(T2T_POOL_TREE.contains("04d00f"));
        // Long 10_000_000 (zigzag VLQ 80dac409) is N2T constant 14, and the
        // body ends with GT(successor.value, constant 14).
        assert!(
            N2T_POOL_TREE.starts_with("1999030f"),
            "15 segregated constants"
        );
        assert!(N2T_POOL_TREE.contains("0580dac409"));
        assert!(N2T_POOL_TREE.ends_with("91720b730e"));
        assert!(
            N2T_POOL_TREE.contains("d60bc17201"),
            "$11 is OUTPUTS(0).value"
        );
        // T2T: GE(successor.value, SELF.value).
        assert!(T2T_POOL_TREE.contains("92c17201c1a7"));
        // Both read the fee numerator from R4 as an Int and require the
        // successor to repeat it.
        assert!(N2T_POOL_TREE.contains("d602e4c6a70404"));
        assert!(N2T_POOL_TREE.contains("93e4c6720104047202"));
        assert!(T2T_POOL_TREE.contains("93e4c6720104047202"));
        // InitiallyLockedLP = Long.MaxValue (zigzag VLQ feffffffffffffffff01).
        assert!(N2T_POOL_TREE.contains("05feffffffffffffffff01"));
        assert_eq!(LP_EMISSION, i64::MAX as u64);
    }
}
