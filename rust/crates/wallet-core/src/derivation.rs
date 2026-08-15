use ergo_lib::ergotree_ir::chain::address::{Address, NetworkAddress, NetworkPrefix};
use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergo_lib::wallet::mnemonic::Mnemonic;

use crate::CoreError;

pub const ACCOUNT_PATH: &str = "m/44'/429'/0'/0";

pub fn ergo_path(index: u32) -> String {
    format!("{ACCOUNT_PATH}/{index}")
}

pub fn derive_child(ext_sk: &ExtSecretKey, index: u32) -> Result<ExtSecretKey, CoreError> {
    let path = ergo_path(index)
        .parse()
        .map_err(|e: ergo_lib::wallet::derivation_path::DerivationPathError| {
            CoreError::Derivation(e.to_string())
        })?;
    ext_sk
        .derive(path)
        .map_err(|e| CoreError::Derivation(e.to_string()))
}

pub fn derive_address_from_seed(seed: [u8; 64], index: u32) -> Result<String, CoreError> {
    let root = ExtSecretKey::derive_master(seed)
        .map_err(|e| CoreError::Derivation(e.to_string()))?;
    derive_address_from_ext_secret_key(&root, index)
}

pub fn derive_address_from_ext_secret_key(
    ext_sk: &ExtSecretKey,
    index: u32,
) -> Result<String, CoreError> {
    let child = derive_child(ext_sk, index)?;
    let ext_pub_key = child
        .public_key()
        .map_err(|e| CoreError::Derivation(e.to_string()))?;
    let address: Address = ext_pub_key.into();
    Ok(NetworkAddress::new(NetworkPrefix::Mainnet, &address).to_base58())
}

pub fn derive_address(
    mnemonic_phrase: &str,
    mnemonic_pass: &str,
    index: u32,
) -> Result<String, CoreError> {
    let seed = Mnemonic::to_seed(mnemonic_phrase, mnemonic_pass);
    derive_address_from_seed(seed, index)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_appkit_test_vector_address_0() {
        let mnemonic =
            "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";
        let addr = derive_address(mnemonic, "", 0).unwrap();
        assert_eq!(addr, "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8");
    }

    #[test]
    fn test_appkit_test_vector_address_1() {
        let mnemonic =
            "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";
        let addr = derive_address(mnemonic, "", 1).unwrap();
        assert_eq!(addr, "9iBhwkjzUAVBkdxWvKmk7ab7nFgZRFbGpXA9gP6TAoakFnLNomk");
    }

    #[test]
    fn test_ergo_node_test_vector() {
        let mnemonic = "race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty";
        let addr = derive_address(mnemonic, "", 0).unwrap();
        assert_eq!(addr, "9eYMpbGgBf42bCcnB2nG3wQdqPzpCCw5eB1YaWUUen9uCaW3wwm");
    }
}
