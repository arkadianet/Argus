//! The receiver side: the stealth secret `x`, its published key `u = g^x`,
//! detection of incoming boxes and the DHT prover input used to spend them.

use zeroize::Zeroize;
use ergo_chain_types::ec_point::{exponentiate, exponentiate_gen};
use ergo_chain_types::EcPoint;
use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergotree_interpreter::sigma_protocol::private_input::DhTupleProverInput;
use ergotree_interpreter::sigma_protocol::wscalar::Wscalar;
use ergotree_ir::sigma_protocol::sigma_boolean::ProveDhTuple;

use crate::address::encode_stealth_address;
use crate::error::StealthError;
use crate::tree::{parse_stealth_tree, StealthTuple};

/// Dedicated hardened branch for the stealth secret.
///
/// EIP-3 payment keys live at `m/44'/429'/0'/0/i`; the fourth element there is
/// the normal-derivation `change` index, fixed at 0. Using a *hardened* `3'`
/// in that position puts the stealth key on a branch no EIP-3 wallet ever
/// walks, so `x` can never double as a signing key for an address the wallet
/// shows. sigma-rust's `DerivationPath` parser accepts arbitrary index
/// sequences, so the path is expressible verbatim.
pub const STEALTH_DERIVATION_PATH: &str = "m/44'/429'/0'/3'/0";

/// A wallet's stealth identity: the secret `x` and everything derived from it.
///
/// `x` never leaves this struct; `Debug` deliberately hides it.
#[derive(Clone)]
pub struct StealthSecret {
    scalar: Wscalar,
    public: EcPoint,
}

impl core::fmt::Debug for StealthSecret {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("StealthSecret")
            .field("secret", &"*****")
            .field("public", &self.public)
            .finish()
    }
}

impl StealthSecret {
    /// Derive from a wallet root key on [`STEALTH_DERIVATION_PATH`].
    pub fn derive(root: &ExtSecretKey) -> Result<Self, StealthError> {
        let path = STEALTH_DERIVATION_PATH
            .parse::<ergo_lib::wallet::derivation_path::DerivationPath>()
            .map_err(|e| StealthError::Derivation(e.to_string()))?;
        let child = root
            .derive(path)
            .map_err(|e| StealthError::Derivation(e.to_string()))?;
        let mut bytes = child.secret_key_bytes();
        let scalar = Wscalar::from_bytes(&bytes);
        bytes.zeroize();
        let scalar = scalar.ok_or_else(|| {
            StealthError::Derivation("derived stealth key is not a valid scalar".into())
        })?;
        Ok(Self::from_scalar(scalar))
    }

    /// Build from a raw scalar. Used by tests and by fixed test vectors.
    pub fn from_scalar(scalar: Wscalar) -> Self {
        let public = exponentiate_gen(scalar.as_scalar_ref());
        Self { scalar, public }
    }

    /// The published key `u = g^x`.
    pub fn public_key(&self) -> &EcPoint {
        &self.public
    }

    /// The published `stealth…` string.
    pub fn stealth_address(&self) -> Result<String, StealthError> {
        encode_stealth_address(&self.public)
    }

    /// Does this secret own the box guarded by `tuple`?
    ///
    /// The ErgoMixer check: `gr^x == ur && gy^x == uy`.
    pub fn owns_tuple(&self, tuple: &StealthTuple) -> bool {
        exponentiate(&tuple.gr, self.scalar.as_scalar_ref()) == tuple.ur
            && exponentiate(&tuple.gy, self.scalar.as_scalar_ref()) == tuple.uy
    }

    /// Does this secret own the box with this ErgoTree hex?
    ///
    /// Non-stealth trees are simply not ours; this never errors so it can be
    /// mapped over a whole box list.
    pub fn owns_tree(&self, tree_hex: &str) -> bool {
        parse_stealth_tree(tree_hex)
            .map(|t| self.owns_tuple(&t))
            .unwrap_or(false)
    }

    /// The secret sigma-rust needs to prove `proveDHTuple(gr, gy, ur, uy)`.
    ///
    /// Errors when the tuple is not ours, so a caller cannot accidentally
    /// stage a proof that will fail at signing time.
    pub fn dht_prover_input(
        &self,
        tuple: &StealthTuple,
    ) -> Result<DhTupleProverInput, StealthError> {
        if !self.owns_tuple(tuple) {
            return Err(StealthError::NotStealthTree);
        }
        Ok(DhTupleProverInput {
            w: self.scalar.clone(),
            common_input: ProveDhTuple::new(
                tuple.gr.clone(),
                tuple.gy.clone(),
                tuple.ur.clone(),
                tuple.uy.clone(),
            ),
        })
    }

    /// Prover input straight from a box's ErgoTree hex.
    pub fn dht_prover_input_for_tree(
        &self,
        tree_hex: &str,
    ) -> Result<DhTupleProverInput, StealthError> {
        self.dht_prover_input(&parse_stealth_tree(tree_hex)?)
    }
}

/// Build a one-time payment script for a receiver key `u`.
///
/// Picks fresh `r` and `y`, returns only the resulting ErgoTree hex — the two
/// scalars are dropped here and never surface to a caller, so they cannot be
/// logged or persisted.
pub fn build_payment_tree_hex(u: &EcPoint) -> Result<String, StealthError> {
    use ergotree_ir::sigma_protocol::dlog_group::random_scalar_in_group_range;

    let r = random_scalar_in_group_range(rand::rngs::OsRng);
    let y = random_scalar_in_group_range(rand::rngs::OsRng);
    let tuple = StealthTuple {
        gr: exponentiate_gen(&r),
        gy: exponentiate_gen(&y),
        ur: exponentiate(u, &r),
        uy: exponentiate(u, &y),
    };
    tuple.to_ergo_tree_hex()
}

/// One-time payment P2S address for a published `stealth…` string.
pub fn payment_address_for_stealth_address(stealth_address: &str) -> Result<String, StealthError> {
    let u = crate::address::decode_stealth_address(stealth_address)?;
    let tree = build_payment_tree_hex(&u)?;
    crate::tree::stealth_tree_to_address(&tree)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_lib::wallet::mnemonic::Mnemonic;

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    fn secret_from(mnemonic: &str) -> StealthSecret {
        let seed = Mnemonic::to_seed(mnemonic, "");
        let root = ExtSecretKey::derive_master(seed).unwrap();
        StealthSecret::derive(&root).unwrap()
    }

    #[test]
    fn derivation_is_deterministic_and_off_the_payment_branch() {
        let a = secret_from(APPKIT);
        let b = secret_from(APPKIT);
        assert_eq!(a.public_key(), b.public_key());
        assert_eq!(a.stealth_address().unwrap(), b.stealth_address().unwrap());
        assert!(a.stealth_address().unwrap().starts_with("stealth"));

        // Different seed, different identity.
        let other = secret_from(
            "race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty",
        );
        assert_ne!(a.public_key(), other.public_key());

        // And it is not the index-0 payment key.
        let seed = Mnemonic::to_seed(APPKIT, "");
        let root = ExtSecretKey::derive_master(seed).unwrap();
        let payment = root
            .derive("m/44'/429'/0'/0/0".parse().unwrap())
            .unwrap()
            .secret_key_bytes();
        let stealth = root
            .derive(STEALTH_DERIVATION_PATH.parse().unwrap())
            .unwrap()
            .secret_key_bytes();
        assert_ne!(payment, stealth);
    }

    #[test]
    fn payment_to_my_address_is_detected_and_matches_the_ergomixer_regex() {
        let me = secret_from(APPKIT);
        let addr = me.stealth_address().unwrap();
        let tree = build_payment_tree_hex(&crate::address::decode_stealth_address(&addr).unwrap())
            .unwrap();

        assert!(crate::tree::is_stealth_tree(&tree));
        assert!(tree.starts_with("1004"));
        assert!(tree.ends_with("ceee7300ee7301ee7302ee7303"));
        assert_eq!(tree.len(), 310);

        assert!(me.owns_tree(&tree));
        let input = me.dht_prover_input_for_tree(&tree).unwrap();
        let tuple = parse_stealth_tree(&tree).unwrap();
        assert_eq!(*input.public_image().g, tuple.gr);
        assert_eq!(*input.public_image().h, tuple.gy);
        assert_eq!(*input.public_image().u, tuple.ur);
        assert_eq!(*input.public_image().v, tuple.uy);
    }

    #[test]
    fn someone_elses_payment_is_not_ours() {
        let me = secret_from(APPKIT);
        let them = secret_from(
            "race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty",
        );
        let tree = build_payment_tree_hex(them.public_key()).unwrap();
        assert!(them.owns_tree(&tree));
        assert!(!me.owns_tree(&tree));
        assert!(me.dht_prover_input_for_tree(&tree).is_err());
    }

    #[test]
    fn two_payments_to_the_same_address_look_unrelated() {
        let me = secret_from(APPKIT);
        let a = build_payment_tree_hex(me.public_key()).unwrap();
        let b = build_payment_tree_hex(me.public_key()).unwrap();
        assert_ne!(a, b);
        assert!(me.owns_tree(&a) && me.owns_tree(&b));
    }

    #[test]
    fn payment_address_round_trip() {
        let me = secret_from(APPKIT);
        let addr = payment_address_for_stealth_address(&me.stealth_address().unwrap()).unwrap();
        let tree =
            ergo_tree_hex_of_address(&addr).expect("payment address decodes back to a tree");
        assert!(me.owns_tree(&tree));
    }

    fn ergo_tree_hex_of_address(address: &str) -> Option<String> {
        use ergo_lib::ergotree_ir::chain::address::{AddressEncoder, NetworkPrefix};
        use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
        let addr = AddressEncoder::new(NetworkPrefix::Mainnet)
            .parse_address_from_str(address)
            .ok()?;
        addr.script().ok()?.sigma_serialize_bytes().ok().map(hex::encode)
    }

    #[test]
    fn stealth_secret_debug_hides_the_key() {
        let me = secret_from(APPKIT);
        let printed = format!("{me:?}");
        assert!(printed.contains("*****"));
        assert!(!printed.contains(&hex::encode(me.scalar.to_bytes())));
    }
}
