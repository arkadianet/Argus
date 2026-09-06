//! Whether a target-chain address is well formed, so a typo is caught
//! before anything is locked. Mirrors what the bridge's own address
//! codec accepts for each chain, with checksums verified where the
//! encoding has one.

use sha2::{Digest, Sha256};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum AddressError {
    #[error("no chain named {0}")]
    UnknownChain(String),
    #[error("empty address")]
    Empty,
    #[error("not a {chain} address: {why}")]
    Invalid { chain: String, why: String },
}

fn invalid(chain: &str, why: &str) -> AddressError {
    AddressError::Invalid {
        chain: chain.into(),
        why: why.into(),
    }
}

const BECH32_ALPHABET: &[u8; 32] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";

fn bech32_polymod(values: &[u8]) -> u32 {
    const GEN: [u32; 5] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3];
    let mut chk: u32 = 1;
    for v in values {
        let top = chk >> 25;
        chk = ((chk & 0x1ff_ffff) << 5) ^ u32::from(*v);
        for (i, g) in GEN.iter().enumerate() {
            if (top >> i) & 1 == 1 {
                chk ^= g;
            }
        }
    }
    chk
}

/// The human-readable part and the data (5-bit groups, checksum
/// removed) of a bech32 or bech32m string, and which of the two it is.
/// `max_len` is 90 for Bitcoin (BIP-173); Cardano addresses run longer.
fn bech32_decode(s: &str, max_len: usize) -> Option<(String, Vec<u8>, bool)> {
    if s.len() < 8 || s.len() > max_len || !s.is_ascii() {
        return None;
    }
    let lower = s.to_ascii_lowercase();
    if lower != s && s.to_ascii_uppercase() != s {
        return None; // mixed case
    }
    let sep = lower.rfind('1')?;
    if sep == 0 || sep + 7 > lower.len() {
        return None;
    }
    let (hrp, data) = (&lower[..sep], &lower[sep + 1..]);
    let mut values = Vec::with_capacity(data.len());
    for c in data.bytes() {
        values.push(BECH32_ALPHABET.iter().position(|a| *a == c)? as u8);
    }
    let mut expanded: Vec<u8> = hrp.bytes().map(|b| b >> 5).collect();
    expanded.push(0);
    expanded.extend(hrp.bytes().map(|b| b & 0x1f));
    expanded.extend_from_slice(&values);
    let m = match bech32_polymod(&expanded) {
        1 => false,
        0x2bc8_30a3 => true,
        _ => return None,
    };
    Some((hrp.to_string(), values[..values.len() - 6].to_vec(), m))
}

/// A base58check payload's version byte, when the checksum holds.
fn base58check_version(s: &str) -> Option<u8> {
    let bytes = bs58::decode(s).into_vec().ok()?;
    if bytes.len() < 5 {
        return None;
    }
    let (payload, check) = bytes.split_at(bytes.len() - 4);
    let hash = Sha256::digest(Sha256::digest(payload));
    (hash[..4] == *check).then(|| payload[0])
}

fn segwit(s: &str, hrp_wanted: &str, chain: &str) -> Result<(), AddressError> {
    let (hrp, data, bech32m) = bech32_decode(s, 90).ok_or_else(|| invalid(chain, "bad bech32 checksum"))?;
    if hrp != hrp_wanted {
        return Err(invalid(chain, "wrong network prefix"));
    }
    let version = *data.first().ok_or_else(|| invalid(chain, "no witness version"))?;
    // Witness version 0 is bech32, later versions bech32m (BIP-350); the
    // program is 20 or 32 bytes for v0, 2 to 40 otherwise.
    let bits = data.len() - 1;
    let bytes = bits * 5 / 8;
    if version == 0 && bech32m || version > 0 && !bech32m {
        return Err(invalid(chain, "wrong checksum kind for the witness version"));
    }
    if version > 16 || !(2..=40).contains(&bytes) || (version == 0 && bytes != 20 && bytes != 32) {
        return Err(invalid(chain, "bad witness program"));
    }
    Ok(())
}

fn evm(s: &str, chain: &str) -> Result<(), AddressError> {
    let hex_part = s.strip_prefix("0x").ok_or_else(|| invalid(chain, "must start with 0x"))?;
    if hex_part.len() != 40 || !hex_part.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(invalid(chain, "must be 0x and 40 hex characters"));
    }
    Ok(())
}

/// Check `address` for `chain` (the bridge's chain keys).
pub fn validate_address(chain: &str, address: &str) -> Result<(), AddressError> {
    let s = address.trim();
    if s.is_empty() {
        return Err(AddressError::Empty);
    }
    match chain {
        "ergo" => ergo_tx::address_to_ergo_tree(s)
            .map(|_| ())
            .map_err(|_| invalid(chain, "not a mainnet Ergo address")),
        "cardano" => {
            let (hrp, data, _) = bech32_decode(s, 150).ok_or_else(|| invalid(chain, "bad bech32 checksum"))?;
            if hrp != "addr" {
                return Err(invalid(chain, "must start with addr1 (mainnet)"));
            }
            // A Shelley address is at least a header byte and a 28-byte
            // payment credential.
            if data.len() * 5 / 8 < 29 {
                return Err(invalid(chain, "too short"));
            }
            Ok(())
        }
        "bitcoin" | "bitcoin-runes" => {
            if s.to_ascii_lowercase().starts_with("bc1") {
                segwit(s, "bc", chain)
            } else {
                match base58check_version(s) {
                    Some(0x00) | Some(0x05) => Ok(()),
                    Some(_) => Err(invalid(chain, "not a mainnet address")),
                    None => Err(invalid(chain, "bad checksum")),
                }
            }
        }
        "doge" => match base58check_version(s) {
            Some(0x1e) | Some(0x16) => Ok(()),
            Some(_) => Err(invalid(chain, "not a mainnet Dogecoin address")),
            None => Err(invalid(chain, "bad checksum")),
        },
        "firo" => match base58check_version(s) {
            Some(0x52) | Some(0x07) => Ok(()),
            Some(_) => Err(invalid(chain, "not a mainnet Firo address")),
            None => Err(invalid(chain, "bad checksum")),
        },
        "ethereum" | "binance" | "base" => evm(s, chain),
        other => Err(AddressError::UnknownChain(other.into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bitcoin_addresses_of_every_kind_are_told_from_typos() {
        assert!(validate_address("bitcoin", "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2").is_ok(), "legacy");
        assert!(validate_address("bitcoin", "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy").is_ok(), "p2sh");
        assert!(validate_address("bitcoin", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4").is_ok(), "segwit v0");
        assert!(validate_address("bitcoin", "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0").is_ok(), "taproot");
        assert!(validate_address("bitcoin-runes", "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0").is_ok());
        assert!(validate_address("bitcoin", "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN3").is_err(), "one character off");
        assert!(validate_address("bitcoin", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5").is_err());
        assert!(validate_address("bitcoin", "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx").is_err(), "testnet");
    }

    #[test]
    fn cardano_evm_doge_and_firo_shapes() {
        assert!(validate_address("cardano", "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x").is_ok());
        assert!(validate_address("cardano", "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3y").is_err());
        assert!(validate_address("cardano", "addr_test1vz").is_err());
        assert!(validate_address("ethereum", "0x742d35Cc6634C0532925a3b844Bc454e4438f44e").is_ok());
        assert!(validate_address("binance", "0x742d35cc6634c0532925a3b844bc454e4438f44e").is_ok());
        assert!(validate_address("ethereum", "742d35Cc6634C0532925a3b844Bc454e4438f44e").is_err());
        assert!(validate_address("ethereum", "0x742d").is_err());
        assert!(validate_address("doge", "DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L").is_ok());
        assert!(validate_address("doge", "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2").is_err(), "a Bitcoin address is not a Dogecoin one");
        assert!(validate_address("ergo", "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8").is_ok());
        assert!(validate_address("ergo", "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa9").is_err());
        assert_eq!(validate_address("mars", "x"), Err(AddressError::UnknownChain("mars".into())));
        assert_eq!(validate_address("bitcoin", "  "), Err(AddressError::Empty));
    }
}
