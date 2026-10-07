use ergo_lib::ergotree_ir::chain::address::{Address, NetworkAddress, NetworkPrefix};
use ergo_lib::ergotree_interpreter::sigma_protocol::wscalar::Wscalar;
use ergo_lib::wallet::derivation_path::{DerivationPath, DerivationPathError};
use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergo_lib::wallet::mnemonic::Mnemonic;
use sha2::{Digest, Sha512};
use zeroize::Zeroize;

use crate::CoreError;

pub const ACCOUNT_PATH: &str = "m/44'/429'/0'/0";

/// The EIP-3 account key, `m/44'/429'/0'`: the last hardened step on the
/// way to every receive address, and so the last key where the two
/// derivation modes can part.
pub const ACCOUNT_KEY_PATH: &str = "m/44'/429'/0'";

const HARDENED: u32 = 0x8000_0000;
/// The hardened indices of [`ACCOUNT_KEY_PATH`].
const ACCOUNT_HARDENED_INDICES: [u32; 3] = [44 | HARDENED, 429 | HARDENED, HARDENED];

/// How a seed becomes keys.
///
/// `Pre1627` reproduces the BIP-32 deviation in the Scala Ergo wallet
/// stack (ergo node, ergo-appkit, sigma-state's `ExtendedSecretKey`) before
/// ergoplatform/ergo#1627 was fixed: a derived secret key with a leading
/// zero byte was kept as fewer than 32 bytes, and those shorter bytes were
/// what the next *hardened* derivation fed to HMAC-SHA512. Wallets created
/// with that code carry `usePre1627KeyDerivation = true`; a phrase from
/// one of them restores to different addresses under standard BIP-32 when
/// `m/44'` or `m/44'/429'` happens to start with a zero byte (about 1 seed
/// in 128). See docs/security-design.md, "Legacy (pre-1627) derivation".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DerivationMode {
    #[default]
    Standard,
    Pre1627,
}

impl DerivationMode {
    /// The stored spelling: the `d` field of a sealed seed and the wallet
    /// metadata. Standard is never written into a sealed seed, so blobs
    /// from before this mode existed read back as what they always were.
    pub const fn as_str(self) -> &'static str {
        match self {
            DerivationMode::Standard => "standard",
            DerivationMode::Pre1627 => "pre1627",
        }
    }

    /// Parses a stored spelling. Unknown values are refused rather than
    /// read as standard: a mode Argus does not know would derive the wrong
    /// keys without a word.
    pub fn parse(value: &str) -> Result<Self, CoreError> {
        match value {
            "standard" => Ok(DerivationMode::Standard),
            "pre1627" => Ok(DerivationMode::Pre1627),
            other => Err(CoreError::Derivation(format!(
                "unknown key derivation mode {other:?}"
            ))),
        }
    }

    pub const fn from_pre1627_flag(use_pre1627: bool) -> Self {
        if use_pre1627 {
            DerivationMode::Pre1627
        } else {
            DerivationMode::Standard
        }
    }
}

fn path(s: &str) -> Result<DerivationPath, CoreError> {
    s.parse()
        .map_err(|e: DerivationPathError| CoreError::Derivation(e.to_string()))
}

/// The EIP-3 account key `m/44'/429'/0'` of `seed` under `mode`.
///
/// Everything below it (`/0/i`) is non-hardened, which hashes the public
/// key rather than the secret bytes, so the two modes agree from here
/// down: this key is the only thing the mode decides.
pub fn account_key(seed: &[u8; 64], mode: DerivationMode) -> Result<ExtSecretKey, CoreError> {
    match mode {
        DerivationMode::Standard => {
            ExtSecretKey::derive_master(*seed)
                .map_err(|e| CoreError::Derivation(e.to_string()))?
                .derive(path(ACCOUNT_KEY_PATH)?)
                .map_err(|e| CoreError::Derivation(e.to_string()))
        }
        DerivationMode::Pre1627 => legacy_account_key(seed),
    }
}

/// `m/44'/429'/0'` the way sigma-state's `ExtendedSecretKey` derives it
/// with `usePre1627KeyDerivation = true`.
///
/// The master key keeps all 32 bytes of the HMAC output (Scala's
/// `deriveMasterKey` stores the slice as is). Each derived child is stored
/// as `BigIntegers.asUnsignedByteArray(childKey)`: big-endian with leading
/// zero bytes dropped. A hardened step hashes `0x00 || keyBytes || ser32(i)`,
/// so a short parent changes every key below it.
fn legacy_account_key(seed: &[u8; 64]) -> Result<ExtSecretKey, CoreError> {
    let mut master = hmac_sha512(b"Bitcoin seed", seed);
    let mut key_bytes = master[..32].to_vec();
    let mut chain_code = [0u8; 32];
    chain_code.copy_from_slice(&master[32..]);
    master.zeroize();

    for &index in &ACCOUNT_HARDENED_INDICES {
        let step = legacy_hardened_child(&key_bytes, &chain_code, index);
        key_bytes.zeroize();
        let (child, child_chain) = step?;
        key_bytes = child;
        chain_code = child_chain;
    }

    let mut padded = [0u8; 32];
    padded[32 - key_bytes.len()..].copy_from_slice(&key_bytes);
    key_bytes.zeroize();
    let key = ExtSecretKey::new(padded, chain_code, path(ACCOUNT_KEY_PATH)?)
        .map_err(|e| CoreError::Derivation(e.to_string()));
    padded.zeroize();
    chain_code.zeroize();
    key
}

/// One hardened step of Scala's `deriveChildSecretKey` in pre-1627 mode.
/// Returns the child's variable-length key bytes and its chain code.
///
/// The BIP-32 retry (`I_L >= n` or a zero child) moves to `index + 1`, as
/// Scala does; leaving the hardened range would take 2^31 retries.
fn legacy_hardened_child(
    parent: &[u8],
    chain_code: &[u8; 32],
    mut index: u32,
) -> Result<(Vec<u8>, [u8; 32]), CoreError> {
    let parent_scalar = scalar_from_unsigned(parent)?;
    loop {
        let mut data = Vec::with_capacity(1 + parent.len() + 4);
        data.push(0u8);
        data.extend_from_slice(parent);
        data.extend_from_slice(&index.to_be_bytes());
        let mut mac = hmac_sha512(chain_code, &data);
        data.zeroize();

        let mut il = [0u8; 32];
        il.copy_from_slice(&mac[..32]);
        let mut child_chain = [0u8; 32];
        child_chain.copy_from_slice(&mac[32..]);
        mac.zeroize();
        let tweak = Wscalar::from_bytes(&il);
        il.zeroize();

        if let Some(tweak) = tweak {
            let child = Wscalar::from(*tweak.as_scalar_ref() + *parent_scalar.as_scalar_ref());
            if !child.is_zero() {
                let mut full = child.to_bytes();
                let leading = full.iter().take(31).take_while(|b| **b == 0).count();
                let trimmed = full[leading..].to_vec();
                full.zeroize();
                return Ok((trimmed, child_chain));
            }
        }
        index = index
            .checked_add(1)
            .ok_or_else(|| CoreError::Derivation("child index overflow".into()))?;
    }
}

fn scalar_from_unsigned(bytes: &[u8]) -> Result<Wscalar, CoreError> {
    if bytes.is_empty() || bytes.len() > 32 {
        return Err(CoreError::Derivation("secret key must be 1-32 bytes".into()));
    }
    let mut padded = [0u8; 32];
    padded[32 - bytes.len()..].copy_from_slice(bytes);
    let scalar = Wscalar::from_bytes(&padded)
        .ok_or_else(|| CoreError::Derivation("secret key out of range".into()));
    padded.zeroize();
    scalar
}

/// HMAC-SHA512 (RFC 2104). Written out because the workspace's locked
/// `hmac` release pairs with a different `sha2` than this crate builds
/// against; the RFC 4231 vectors and the standard-mode cross-check in the
/// tests pin it.
fn hmac_sha512(key: &[u8], data: &[u8]) -> [u8; 64] {
    const BLOCK: usize = 128;
    let mut block_key = [0u8; BLOCK];
    if key.len() > BLOCK {
        block_key[..64].copy_from_slice(&Sha512::digest(key));
    } else {
        block_key[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; BLOCK];
    let mut opad = [0x5cu8; BLOCK];
    for i in 0..BLOCK {
        ipad[i] ^= block_key[i];
        opad[i] ^= block_key[i];
    }
    let mut inner = Sha512::new();
    inner.update(ipad);
    inner.update(data);
    let mut inner_hash = inner.finalize();
    let mut outer = Sha512::new();
    outer.update(opad);
    outer.update(inner_hash);
    let mut out = [0u8; 64];
    out.copy_from_slice(&outer.finalize());
    block_key.zeroize();
    ipad.zeroize();
    opad.zeroize();
    inner_hash.as_mut_slice().zeroize();
    out
}

/// Addresses `0..count` of `seed` under `mode`.
pub fn first_addresses(
    seed: &[u8; 64],
    mode: DerivationMode,
    count: u32,
) -> Result<Vec<String>, CoreError> {
    let account = account_key(seed, mode)?;
    (0..count)
        .map(|i| derive_address_from_ext_secret_key(&account, i))
        .collect()
}

/// The mode a restore should use, given whether each mode's first
/// addresses have on-chain history.
///
/// Legacy only when legacy alone has history. Both or neither means
/// standard: it is what every current Ergo wallet derives, and a phrase
/// with history under both was evidently also used somewhere modern.
pub fn choose_restore_mode(standard_used: bool, legacy_used: bool) -> DerivationMode {
    if legacy_used && !standard_used {
        DerivationMode::Pre1627
    } else {
        DerivationMode::Standard
    }
}

pub fn derive_address_with_mode(
    mnemonic_phrase: &str,
    mnemonic_pass: &str,
    mode: DerivationMode,
    index: u32,
) -> Result<String, CoreError> {
    let mut seed = Mnemonic::to_seed(mnemonic_phrase, mnemonic_pass);
    let account = account_key(&seed, mode);
    seed.zeroize();
    derive_address_from_ext_secret_key(&account?, index)
}

pub fn ergo_path(index: u32) -> String {
    format!("{ACCOUNT_PATH}/{index}")
}

pub fn derive_child(ext_sk: &ExtSecretKey, index: u32) -> Result<ExtSecretKey, CoreError> {
    let path = ergo_path(index).parse().map_err(
        |e: ergo_lib::wallet::derivation_path::DerivationPathError| {
            CoreError::Derivation(e.to_string())
        },
    )?;
    ext_sk
        .derive(path)
        .map_err(|e| CoreError::Derivation(e.to_string()))
}

pub fn derive_address_from_seed(seed: [u8; 64], index: u32) -> Result<String, CoreError> {
    let root =
        ExtSecretKey::derive_master(seed).map_err(|e| CoreError::Derivation(e.to_string()))?;
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

    const RACE: &str = "race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty";

    /// ergo node ExtendedSecretKeySpec "1627 BIP32 key derivation fix (31 bit
    /// child key)": the same phrase gives 9ewv8… with
    /// `usePre1627KeyDerivation = true` and 9eYMpb… without. Also in
    /// sigma-rust's `ergo_wallet_incorrect_bip32_derivation` comment.
    #[test]
    fn pre1627_matches_the_ergo_node_vector() {
        assert_eq!(
            derive_address_with_mode(RACE, "", DerivationMode::Pre1627, 0).unwrap(),
            "9ewv8sxJ1jfr6j3WUSbGPMTVx3TZgcJKdnjKCbJWhiJp5U62uhP"
        );
        assert_eq!(
            derive_address_with_mode(RACE, "", DerivationMode::Standard, 0).unwrap(),
            "9eYMpbGgBf42bCcnB2nG3wQdqPzpCCw5eB1YaWUUen9uCaW3wwm"
        );
    }

    /// Intermediate keys from sigma-state 6.0.6 for the same phrase (the
    /// `legacyDerivation` fixture in arkadianet/ergo test-vectors). Depth 2,
    /// `m/44'/429'`, is the 31-byte key whose missing zero changes `0'`.
    #[test]
    fn pre1627_intermediate_keys_match_sigma_state() {
        let seed = Mnemonic::to_seed(RACE, "");
        let master = hmac_sha512(b"Bitcoin seed", &seed);
        assert_eq!(
            hex::encode(&master[..32]),
            "3527de3227326920720f394281ac182689a7d7e29951d837e96612e4d4bbcfde"
        );
        let expected = [
            (
                "1368432076b443c9ed3110b6ed3f1973072c95a2999c7178014acc67cc60cdc3",
                "23c7ea7175611b914f331a545559c7b770f93150249224467855ef140656b1b4",
            ),
            (
                "6795ba06412cb46add55c13b480dbed4a4433ef6c79b2d7002c0462c09372e",
                "eeb77cc0472c8420b2ff25df16be02c9fd93e6bc57eae53d1f17364b0d05df37",
            ),
            (
                "2f2baceb97081f3ecdf5c083482bb2561e7cc183e0cbe172ab801a5e3d1a4b58",
                "9728b21aeab5feae2f55a204050c25aba5c98ca4b64bf8ae713c342feb4a73b5",
            ),
        ];
        let mut key = master[..32].to_vec();
        let mut chain: [u8; 32] = master[32..].try_into().unwrap();
        for (i, (secret, chain_code)) in expected.iter().enumerate() {
            let (k, c) = legacy_hardened_child(&key, &chain, ACCOUNT_HARDENED_INDICES[i]).unwrap();
            assert_eq!(hex::encode(&k), *secret, "depth {}", i + 1);
            assert_eq!(hex::encode(c), *chain_code, "depth {}", i + 1);
            key = k;
            chain = c;
        }
        let account = account_key(&seed, DerivationMode::Pre1627).unwrap();
        assert_eq!(
            hex::encode(account.secret_key_bytes()),
            "2f2baceb97081f3ecdf5c083482bb2561e7cc183e0cbe172ab801a5e3d1a4b58"
        );
    }

    /// A master key with a leading zero byte is *not* trimmed by Scala, so
    /// the modes agree for this seed (sigma-state 6.0.6 vectors,
    /// arkadianet/ergo test-vectors/wallet/leading-zero-master).
    #[test]
    fn pre1627_keeps_a_leading_zero_master_whole() {
        let seed: [u8; 64] = hex::decode(
            "4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c64d2e8a1e7d1457df2e5a3c51c73235be",
        )
        .unwrap()
        .try_into()
        .unwrap();
        for mode in [DerivationMode::Standard, DerivationMode::Pre1627] {
            assert_eq!(
                first_addresses(&seed, mode, 1).unwrap()[0],
                "9f19HySXxsrVyG1C6xwCdpMYkM7mHCzv3VocVpdNx51vxcXCuVp"
            );
        }
    }

    /// With no short keys on the way, the legacy steps must be exactly
    /// standard BIP-32: the appkit vector agrees in both modes, and on
    /// the account key itself, not just the address.
    #[test]
    fn modes_agree_when_no_key_is_short() {
        let phrase =
            "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";
        let seed = Mnemonic::to_seed(phrase, "");
        let std = account_key(&seed, DerivationMode::Standard).unwrap();
        let legacy = account_key(&seed, DerivationMode::Pre1627).unwrap();
        assert_eq!(std.secret_key_bytes(), legacy.secret_key_bytes());
        assert_eq!(
            std.public_key().unwrap().chain_code,
            legacy.public_key().unwrap().chain_code
        );
        assert_eq!(
            first_addresses(&seed, DerivationMode::Pre1627, 2).unwrap(),
            vec![
                "9eatpGQdYNjTi5ZZLK7Bo7C3ms6oECPnxbQTRn6sDcBNLMYSCa8".to_string(),
                "9iBhwkjzUAVBkdxWvKmk7ab7nFgZRFbGpXA9gP6TAoakFnLNomk".to_string(),
            ]
        );
    }

    /// Over many seeds, legacy and standard disagree exactly when
    /// `m/44'` or `m/44'/429'` starts with a zero byte, and agree on
    /// every other seed — the 1-in-128 estimate in the docs.
    #[test]
    fn modes_differ_exactly_when_a_hardened_parent_is_short() {
        let mut differing = 0;
        for n in 0u32..600 {
            let mut seed = [0u8; 64];
            seed[..4].copy_from_slice(&n.to_be_bytes());
            let root = ExtSecretKey::derive_master(seed).unwrap();
            let k44 = root.derive(path("m/44'").unwrap()).unwrap();
            let k429 = root.derive(path("m/44'/429'").unwrap()).unwrap();
            let short = k44.secret_key_bytes()[0] == 0 || k429.secret_key_bytes()[0] == 0;
            let std = account_key(&seed, DerivationMode::Standard).unwrap();
            let legacy = account_key(&seed, DerivationMode::Pre1627).unwrap();
            assert_eq!(
                std.secret_key_bytes() != legacy.secret_key_bytes(),
                short,
                "seed {n}"
            );
            differing += short as u32;
        }
        assert!(differing > 0, "the sample must cover a differing seed");
    }

    #[test]
    fn hmac_sha512_matches_rfc4231() {
        // Test case 2 and test case 6 (key longer than the block).
        assert_eq!(
            hex::encode(hmac_sha512(b"Jefe", b"what do ya want for nothing?")),
            "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"
        );
        assert_eq!(
            hex::encode(hmac_sha512(
                &[0xaa; 131],
                b"Test Using Larger Than Block-Size Key - Hash Key First"
            )),
            "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f3526b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598"
        );
    }

    #[test]
    fn restore_mode_is_legacy_only_when_legacy_alone_has_history() {
        assert_eq!(choose_restore_mode(false, true), DerivationMode::Pre1627);
        assert_eq!(choose_restore_mode(true, true), DerivationMode::Standard);
        assert_eq!(choose_restore_mode(true, false), DerivationMode::Standard);
        assert_eq!(choose_restore_mode(false, false), DerivationMode::Standard);
    }

    #[test]
    fn mode_spellings_round_trip_and_unknown_is_refused() {
        for m in [DerivationMode::Standard, DerivationMode::Pre1627] {
            assert_eq!(DerivationMode::parse(m.as_str()).unwrap(), m);
        }
        assert!(DerivationMode::parse("pre1628").is_err());
    }

    #[test]
    fn test_ergo_node_test_vector() {
        let mnemonic = "race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty";
        let addr = derive_address(mnemonic, "", 0).unwrap();
        assert_eq!(addr, "9eYMpbGgBf42bCcnB2nG3wQdqPzpCCw5eB1YaWUUen9uCaW3wwm");
    }
}
