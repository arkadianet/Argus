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
