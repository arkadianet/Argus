//! Blobs already on users' devices must keep opening after crypto crate
//! updates. Both fixtures were sealed by pin.rs and encryption.rs built with
//! aes-gcm 0.10.3 and argon2 0.5.3, the versions before the 0.11/0.6 update.
use wallet_core::{EncryptedSeed, PinWrappedKey};

const PIN_WRAP_JSON: &str = r#"{"ct":"6763b03ffc5b88c4d8dde72464950772ce7784a0875960bb7ced3e1b2a5ea55afccf750e6d206d71ca91479b30b3ee15","m":19456,"nonce":"79b864ce1a2f49f747e9ab8d","p":1,"salt":"46795585496f2f1c7652e88eaa122555","t":2,"v":1}"#;
const PIN: &str = "246810";
const WRAPPED_KEY_HEX: &str = "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186";

const SEED_JSON: &str = r#"{"ct":"5a8bebbcbffbd7653e839cd1f1d4f841f31eaaedad05700e4ce2e3f1f7be39042c4674aa5ebcae86ce5043e8aa682f3b875434545293b81e78c8caf6e7bc2876dc0759e013d8e4d555c4ce8d1d59fe7ba4","nonce":"a39cae4e3029f956bfa127e3","v":2}"#;
const SEED_WRAP_KEY_HEX: &str = "464dd814543179d181df3dd9ac628a71a5820dab0c9dda6a12932b27ec309f41";
const SEED: &[u8] = b"argus-fixture-seed-0123456789abcdef-0123456789abcdef-0123456789ab";

#[test]
fn pin_wrapped_key_from_earlier_crates_unwraps() {
    let json: serde_json::Value = serde_json::from_str(PIN_WRAP_JSON).unwrap();
    let wrapped = PinWrappedKey::from_json(&json).unwrap();
    assert_eq!(hex::encode(wrapped.unwrap(PIN).unwrap()), WRAPPED_KEY_HEX);
    assert!(wrapped.unwrap("246811").is_err());
}

#[test]
fn sealed_seed_from_earlier_crates_decrypts() {
    let json: serde_json::Value = serde_json::from_str(SEED_JSON).unwrap();
    let sealed = EncryptedSeed::from_json(&json, Some(SEED_WRAP_KEY_HEX)).unwrap();
    assert_eq!(sealed.decrypt().unwrap(), SEED);
}
