//! Register values as the proxy contracts read them, hex-encoded the way
//! EIP-12 carries them.

use ergo_lib::ergotree_ir::mir::constant::Constant;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;


use crate::state::PoolsError;

fn hex_of(c: Constant) -> Result<String, PoolsError> {
    c.sigma_serialize_bytes()
        .map(hex::encode)
        .map_err(|e| PoolsError::Serialization(e.to_string()))
}

/// A `Long` constant: `05` plus the zigzag varint.
pub fn long(v: i64) -> Result<String, PoolsError> {
    hex_of(Constant::from(v))
}

/// A `Coll[Byte]` constant: `0e`, the length, the bytes.
pub fn coll_byte(bytes: &[u8]) -> Result<String, PoolsError> {
    hex_of(Constant::from(bytes.to_vec()))
}

/// The `Coll[Byte]` register carrying a box id, as the fill and refund
/// outputs carry it.
pub fn box_id_register(box_id_hex: &str) -> Result<String, PoolsError> {
    let bytes = hex::decode(box_id_hex).map_err(|e| PoolsError::Serialization(e.to_string()))?;
    coll_byte(&bytes)
}

/// An `Int` constant.
pub fn int(v: i32) -> Result<String, PoolsError> {
    hex_of(Constant::from(v))
}

/// A `(Long, Long)` pair, as the collateral registers carry thresholds and
/// heights.
pub fn long_pair(a: i64, b: i64) -> Result<String, PoolsError> {
    let c: Constant = (a, b).into();
    hex_of(c)
}

/// A `GroupElement`: the borrower's public key, so the borrower can take a
/// borrow order back at any time with their own signature.
pub fn group_element(pk_hex: &str) -> Result<String, PoolsError> {
    let bytes = hex::decode(pk_hex).map_err(|e| PoolsError::Serialization(e.to_string()))?;
    let point = ergo_lib::ergo_chain_types::EcPoint::sigma_parse_bytes(&bytes)
        .map_err(|e| PoolsError::Serialization(format!("public key: {e}")))?;
    hex_of(Constant::from(point))
}

/// The 33-byte public key inside a P2PK ErgoTree (`0008cd` + key), or none.
pub fn p2pk_key(tree_hex: &str) -> Option<String> {
    let t = tree_hex.to_ascii_lowercase();
    if t.len() == 72 && t.starts_with("0008cd") {
        Some(t[6..].to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registers_encode_as_sigma_constants() {
        assert_eq!(long(0).unwrap(), "0500");
        assert_eq!(long(1).unwrap(), "0502");
        assert_eq!(long(-1).unwrap(), "0501");
        // zigzag(1_000_000) = 2_000_000 = 0x1e8480, VLQ 80 89 7a.
        assert_eq!(long(1_000_000).unwrap(), "0580897a");
        assert_eq!(coll_byte(&[0xab, 0xcd]).unwrap(), "0e02abcd");
        assert_eq!(
            box_id_register(&"ab".repeat(32)).unwrap(),
            format!("0e20{}", "ab".repeat(32))
        );
    }
}
