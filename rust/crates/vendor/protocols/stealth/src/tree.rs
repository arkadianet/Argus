//! The stealth payment ErgoTree: `proveDHTuple(g^r, g^y, u^r, u^y)`.
//!
//! Layout, byte for byte as ErgoMixer emits it (see
//! `StealthContract.generateStealthErgoTree`):
//!
//! ```text
//! 1004 0e21<gr> 0e21<gy> 0e21<ur> 0e21<uy> ceee7300ee7301ee7302ee7303
//! ```
//!
//! `10` is the ErgoTree header (version 0, constant segregation), `04` the
//! constant count, each `0e21<33 bytes>` a `Coll[Byte]` holding a compressed
//! curve point, and the tail is
//! `CreateProveDHTuple(DecodePoint(ph0), …, DecodePoint(ph3))`.

use ergo_chain_types::EcPoint;
use sha2::{Digest, Sha256};
use sigma_ser::ScorexSerializable;

use crate::error::StealthError;

/// The constant-free part of every stealth ErgoTree. The explorer indexes
/// boxes by `sha256` of exactly these bytes.
pub const STEALTH_TEMPLATE_HEX: &str = "ceee7300ee7301ee7302ee7303";

/// Header + constant count that opens every stealth tree.
pub const STEALTH_TREE_PREFIX_HEX: &str = "1004";

/// Marker introducing each 33-byte `Coll[Byte]` constant.
const CONST_MARKER: &str = "0e21";

/// `sha256(STEALTH_TEMPLATE_HEX)` — the value to pass to the explorer's
/// `boxes/unspent/byErgoTreeTemplateHash/{hash}` endpoint.
pub fn stealth_template_hash_hex() -> String {
    let bytes = hex::decode(STEALTH_TEMPLATE_HEX).expect("static template hex");
    hex::encode(Sha256::digest(bytes))
}

/// The four group elements of a stealth payment script, in tree order.
///
/// `ur = gr^x` and `uy = gy^x` hold exactly for the receiver's secret `x`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StealthTuple {
    pub gr: EcPoint,
    pub gy: EcPoint,
    pub ur: EcPoint,
    pub uy: EcPoint,
}

fn point_hex(p: &EcPoint) -> Result<String, StealthError> {
    p.scorex_serialize_bytes()
        .map(hex::encode)
        .map_err(|e| StealthError::Serialization(e.to_string()))
}

fn point_from_hex(s: &str) -> Result<EcPoint, StealthError> {
    EcPoint::from_base16_str(s.to_string()).ok_or(StealthError::BadPoint)
}

impl StealthTuple {
    /// Render this tuple as the ErgoTree hex ErgoMixer would produce.
    pub fn to_ergo_tree_hex(&self) -> Result<String, StealthError> {
        let mut out = String::from(STEALTH_TREE_PREFIX_HEX);
        for p in [&self.gr, &self.gy, &self.ur, &self.uy] {
            out.push_str(CONST_MARKER);
            out.push_str(&point_hex(p)?);
        }
        out.push_str(STEALTH_TEMPLATE_HEX);
        Ok(out)
    }
}

/// True when `tree_hex` is shaped like a stealth payment script.
///
/// Mirrors ErgoMixer's `stealthPattern` regex
/// `(1004)((0e21)[a-fA-F0-9]{66}){4}(ceee7300ee7301ee7302ee7303)`, without
/// pulling in a regex engine: the layout is fixed-width.
pub fn is_stealth_tree(tree_hex: &str) -> bool {
    let t = tree_hex.trim();
    // 4 + 4 * (4 + 66) + 26 = 310 hex chars.
    if t.len() != 310 || !t.chars().all(|c| c.is_ascii_hexdigit()) {
        return false;
    }
    if !t[..4].eq_ignore_ascii_case(STEALTH_TREE_PREFIX_HEX) {
        return false;
    }
    if !t[284..].eq_ignore_ascii_case(STEALTH_TEMPLATE_HEX) {
        return false;
    }
    (0..4).all(|i| {
        let at = 4 + i * 70;
        t[at..at + 4].eq_ignore_ascii_case(CONST_MARKER)
    })
}

/// Pull the four group elements out of a stealth ErgoTree hex.
///
/// The slice offsets match `StealthUtils.getDHTDataFromErgoTree`.
pub fn parse_stealth_tree(tree_hex: &str) -> Result<StealthTuple, StealthError> {
    if !is_stealth_tree(tree_hex) {
        return Err(StealthError::NotStealthTree);
    }
    let t = tree_hex.trim();
    Ok(StealthTuple {
        gr: point_from_hex(&t[8..74])?,
        gy: point_from_hex(&t[78..144])?,
        ur: point_from_hex(&t[148..214])?,
        uy: point_from_hex(&t[218..284])?,
    })
}

/// Convert a stealth payment tree to the P2S address the send builders take.
pub fn stealth_tree_to_address(tree_hex: &str) -> Result<String, StealthError> {
    use ergo_lib::ergotree_ir::chain::address::{Address, AddressEncoder, NetworkPrefix};
    use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;

    let bytes = hex::decode(tree_hex).map_err(|e| StealthError::Serialization(e.to_string()))?;
    let tree = ErgoTree::sigma_parse_bytes(&bytes)
        .map_err(|e| StealthError::Serialization(e.to_string()))?;
    let address = Address::recreate_from_ergo_tree(&tree)
        .map_err(|e| StealthError::Serialization(e.to_string()))?;
    Ok(AddressEncoder::new(NetworkPrefix::Mainnet).address_to_str(&address))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIVE_TREE: &str = "10040e2103a61135dd122ff3b7a9a2529644f196cf22533ebe8b8e664fb9b84d9f003eccad0e2102def407e179e0b4550dd94ea38d7f6cf63d8a7f726f73d49b24d21bb4aa772b590e2103f78cf1f2e10b0ef224e88a84146a0646a5ca12f1aec79e5dc370549f91704da90e21022ed401b62c61706e2f96c2d2bba52b367b874981dc0f9ee1c7218dec755a40b9ceee7300ee7301ee7302ee7303";

    #[test]
    fn template_hash_matches_the_explorer_endpoint() {
        assert_eq!(
            stealth_template_hash_hex(),
            "210681f345e06655d54106373f6c401ebe35d17854ed7148bdcef50df24fd89b"
        );
    }

    #[test]
    fn live_tree_is_recognised_and_round_trips() {
        assert!(is_stealth_tree(LIVE_TREE));
        let tuple = parse_stealth_tree(LIVE_TREE).unwrap();
        assert_eq!(tuple.to_ergo_tree_hex().unwrap(), LIVE_TREE);
    }

    #[test]
    fn rejects_non_stealth_trees() {
        assert!(!is_stealth_tree("0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"));
        assert!(!is_stealth_tree(""));
        // Right length, wrong tail.
        let mut broken = LIVE_TREE.to_string();
        broken.replace_range(284.., "ceee7300ee7301ee7302ee73ff");
        assert!(!is_stealth_tree(&broken));
        assert_eq!(
            parse_stealth_tree(&broken).unwrap_err(),
            StealthError::NotStealthTree
        );
    }

    #[test]
    fn live_tree_becomes_a_p2s_address() {
        let addr = stealth_tree_to_address(LIVE_TREE).unwrap();
        // P2S mainnet addresses carry the 0x10 prefix byte.
        assert!(addr.len() > 50);
        assert_eq!(
            ergo_lib::ergotree_ir::chain::address::AddressEncoder::new(
                ergo_lib::ergotree_ir::chain::address::NetworkPrefix::Mainnet
            )
            .parse_address_from_str(&addr)
            .is_ok(),
            true
        );
    }
}
