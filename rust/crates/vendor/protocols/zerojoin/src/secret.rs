//! Mix secrets, derived from the wallet seed and never stored.
//!
//! ErgoMixer keeps every `x` and `y` in a SQL database; losing that database
//! loses the funds sitting in half- and full-mix boxes, because nothing else
//! can produce the proofs those contracts demand. Argus must not inherit that
//! failure mode, so a mix secret is a pure function of
//! `(seed, mix id, round)`. A restored wallet can walk its mixes forward from
//! the seed alone; nothing secret is ever written to disk or to a log.

use ergo_chain_types::ec_point::{exponentiate, exponentiate_gen};
use ergo_chain_types::EcPoint;
use ergo_lib::wallet::derivation_path::DerivationPath;
use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergotree_interpreter::sigma_protocol::private_input::{DhTupleProverInput, DlogProverInput};
use ergotree_interpreter::sigma_protocol::wscalar::Wscalar;
use ergotree_ir::sigma_protocol::sigma_boolean::ProveDhTuple;
use zeroize::Zeroize;

use crate::boxes::{FullMixBox, HalfMixBox};
use crate::error::ZeroJoinError;

/// Dedicated hardened branch for mixing secrets.
///
/// EIP-3 payment keys are `m/44'/429'/0'/0/i`; the merged stealth work took
/// the hardened `3'` in that fourth position. `4'` is the next free one, so a
/// mix secret can never double as a signing key for an address the wallet
/// displays, and vice versa.
///
/// The full path is `m/44'/429'/0'/4'/<mix id>/<round>`, both trailing
/// elements soft. One secret covers a round whichever role the wallet plays
/// in it — as Alice it is `x` (with `gX = g^x` in the half-mix box's R4), as
/// Bob it is `y` (with `c2 = g^y` in the wallet's full-mix box). A wallet is
/// never both in the same round, which is exactly ErgoMixer's own
/// one-secret-plus-`isAlice` model.
pub const MIX_DERIVATION_BRANCH: &str = "m/44'/429'/0'/4'";

/// Largest `mix id` / `round` a soft derivation index can hold.
pub const MAX_DERIVATION_INDEX: u32 = 0x7fff_ffff;

/// The derivation path for one round of one mix.
pub fn mix_derivation_path(mix_id: u32, round: u32) -> Result<String, ZeroJoinError> {
    if mix_id > MAX_DERIVATION_INDEX || round > MAX_DERIVATION_INDEX {
        return Err(ZeroJoinError::Derivation(format!(
            "mix id {mix_id} / round {round} exceeds the soft derivation range"
        )));
    }
    Ok(format!("{MIX_DERIVATION_BRANCH}/{mix_id}/{round}"))
}

/// Which side of a round a box belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Created the half-mix box; spends a full-mix box with
    /// `proveDHTuple(g, c1, gX, c2)`.
    Alice,
    /// Consumed a half-mix box; spends a full-mix box with `proveDlog(c2)`.
    Bob,
}

/// One round's secret and its public commitment `g^secret`.
///
/// The scalar never leaves this struct: `Debug` hides it, there is no getter,
/// and nothing here serializes.
#[derive(Clone)]
pub struct MixSecret {
    scalar: Wscalar,
    public: EcPoint,
    mix_id: u32,
    round: u32,
}

impl core::fmt::Debug for MixSecret {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("MixSecret")
            .field("secret", &"*****")
            .field("public", &self.public)
            .field("mix_id", &self.mix_id)
            .field("round", &self.round)
            .finish()
    }
}

impl MixSecret {
    /// Derive the secret for `(mix_id, round)` from a wallet root key.
    pub fn derive(root: &ExtSecretKey, mix_id: u32, round: u32) -> Result<Self, ZeroJoinError> {
        let path = mix_derivation_path(mix_id, round)?
            .parse::<DerivationPath>()
            .map_err(|e| ZeroJoinError::Derivation(e.to_string()))?;
        let child = root
            .derive(path)
            .map_err(|e| ZeroJoinError::Derivation(e.to_string()))?;
        let mut bytes = child.secret_key_bytes();
        let scalar = Wscalar::from_bytes(&bytes);
        bytes.zeroize();
        let scalar = scalar.ok_or_else(|| {
            ZeroJoinError::Derivation("derived mix key is not a valid scalar".into())
        })?;
        Ok(Self {
            public: exponentiate_gen(scalar.as_scalar_ref()),
            scalar,
            mix_id,
            round,
        })
    }

    /// Build from a raw scalar. For tests and fixed vectors only.
    pub fn from_scalar(scalar: Wscalar, mix_id: u32, round: u32) -> Self {
        Self {
            public: exponentiate_gen(scalar.as_scalar_ref()),
            scalar,
            mix_id,
            round,
        }
    }

    /// `g^secret`: `gX` when acting as Alice, `gY` when acting as Bob.
    pub fn public_key(&self) -> &EcPoint {
        &self.public
    }

    pub fn mix_id(&self) -> u32 {
        self.mix_id
    }

    pub fn round(&self) -> u32 {
        self.round
    }

    /// `point^secret`. Used for `gXY = gX^y` and for ownership tests.
    pub fn raise(&self, point: &EcPoint) -> EcPoint {
        exponentiate(point, self.scalar.as_scalar_ref())
    }

    /// The dlog secret: proves `proveDlog(g^secret)`.
    ///
    /// This is what Alice needs to reclaim her own half-mix box, and what Bob
    /// needs to spend his full-mix box (`c2 == g^y`).
    pub fn dlog_prover_input(&self) -> DlogProverInput {
        DlogProverInput::new(self.scalar.clone())
    }

    /// The DH-tuple secret for `proveDHTuple(g, h, u, v)`.
    ///
    /// Callers should prefer [`Self::spend_half_mix_as_bob`] and
    /// [`Self::spend_full_mix_as_alice`], which build the tuple from a box so
    /// the argument order cannot be got wrong.
    pub fn dht_prover_input(
        &self,
        g: EcPoint,
        h: EcPoint,
        u: EcPoint,
        v: EcPoint,
    ) -> DhTupleProverInput {
        DhTupleProverInput {
            w: self.scalar.clone(),
            common_input: ProveDhTuple::new(g, h, u, v),
        }
    }

    /// Does this secret own `full` as its Bob? True when `c2 == g^secret`.
    pub fn owns_as_bob(&self, full: &FullMixBox) -> bool {
        full.c2 == self.public
    }

    /// Does this secret own `full` as its Alice?
    ///
    /// True when `gX == g^secret` **and** `c2 == c1^secret`; the second check
    /// is what distinguishes Alice's box from the counterpart's, since both
    /// carry the same `gX`.
    pub fn owns_as_alice(&self, full: &FullMixBox) -> bool {
        full.g_x == self.public && full.c2 == self.raise(&full.c1)
    }

    /// The role this secret plays for `full`, if any.
    pub fn role_for(&self, full: &FullMixBox) -> Option<Role> {
        if self.owns_as_bob(full) {
            Some(Role::Bob)
        } else if self.owns_as_alice(full) {
            Some(Role::Alice)
        } else {
            None
        }
    }

    /// Prover input to spend a half-mix box as Bob: `proveDHTuple(g, gX, gY, gXY)`.
    ///
    /// This is the proof that one of the two `(c1, c2)` orderings is honest,
    /// without revealing which.
    pub fn spend_half_mix_as_bob(&self, half: &HalfMixBox) -> DhTupleProverInput {
        let g_y = self.public;
        let g_xy = self.raise(&half.g_x);
        self.dht_prover_input(ergo_chain_types::ec_point::generator(), half.g_x, g_y, g_xy)
    }

    /// Prover input to spend a full-mix box as its Alice:
    /// `proveDHTuple(g, c1, gX, c2)`.
    ///
    /// Errors when the box is not ours, so a caller cannot stage a proof that
    /// will only fail at signing time.
    pub fn spend_full_mix_as_alice(
        &self,
        full: &FullMixBox,
    ) -> Result<DhTupleProverInput, ZeroJoinError> {
        if !self.owns_as_alice(full) {
            return Err(ZeroJoinError::Invalid(format!(
                "full-mix box {} is not ours as Alice",
                full.input.box_id
            )));
        }
        Ok(self.dht_prover_input(
            ergo_chain_types::ec_point::generator(),
            full.c1,
            full.g_x,
            full.c2,
        ))
    }

    /// Dlog prover input to spend a full-mix box as its Bob.
    pub fn spend_full_mix_as_bob(
        &self,
        full: &FullMixBox,
    ) -> Result<DlogProverInput, ZeroJoinError> {
        if !self.owns_as_bob(full) {
            return Err(ZeroJoinError::Invalid(format!(
                "full-mix box {} is not ours as Bob",
                full.input.box_id
            )));
        }
        Ok(self.dlog_prover_input())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_lib::wallet::mnemonic::Mnemonic;

    const MNEMONIC: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

    fn root(mnemonic: &str) -> ExtSecretKey {
        ExtSecretKey::derive_master(Mnemonic::to_seed(mnemonic, "")).unwrap()
    }

    #[test]
    fn the_same_seed_and_round_reproduce_the_same_secret() {
        let a = MixSecret::derive(&root(MNEMONIC), 7, 3).unwrap();
        let b = MixSecret::derive(&root(MNEMONIC), 7, 3).unwrap();
        assert_eq!(a.public_key(), b.public_key());
    }

    #[test]
    fn a_different_round_or_mix_gives_a_different_secret() {
        let r = root(MNEMONIC);
        let base = MixSecret::derive(&r, 7, 3).unwrap();
        for (mix, round) in [(7u32, 4u32), (7, 2), (8, 3), (0, 0)] {
            let other = MixSecret::derive(&r, mix, round).unwrap();
            assert_ne!(
                base.public_key(),
                other.public_key(),
                "mix {mix} round {round} collided with mix 7 round 3"
            );
        }
    }

    #[test]
    fn a_different_seed_gives_a_different_secret() {
        let other = root(
            "race relax argue hair sorry riot there spirit ready fetch food hedgehog hybrid mobile pretty",
        );
        assert_ne!(
            MixSecret::derive(&root(MNEMONIC), 1, 1)
                .unwrap()
                .public_key(),
            MixSecret::derive(&other, 1, 1).unwrap().public_key()
        );
    }

    #[test]
    fn mix_keys_are_off_the_payment_and_stealth_branches() {
        let r = root(MNEMONIC);
        let mix = r
            .derive(mix_derivation_path(0, 0).unwrap().parse().unwrap())
            .unwrap()
            .secret_key_bytes();
        for other in ["m/44'/429'/0'/0/0", "m/44'/429'/0'/3'/0"] {
            let bytes = r.derive(other.parse().unwrap()).unwrap().secret_key_bytes();
            assert_ne!(mix, bytes, "mix key collides with {other}");
        }
    }

    #[test]
    fn out_of_range_indices_are_rejected_rather_than_wrapped() {
        assert!(mix_derivation_path(u32::MAX, 0).is_err());
        assert!(mix_derivation_path(0, u32::MAX).is_err());
        assert!(mix_derivation_path(MAX_DERIVATION_INDEX, MAX_DERIVATION_INDEX).is_ok());
    }

    #[test]
    fn debug_never_prints_the_scalar() {
        let s = MixSecret::derive(&root(MNEMONIC), 1, 1).unwrap();
        let printed = format!("{s:?}");
        assert!(printed.contains("*****"));
        assert!(!printed.contains(&hex::encode(s.scalar.to_bytes())));
    }

    #[test]
    fn dh_tuple_for_half_mix_is_g_gx_gy_gxy() {
        let y = MixSecret::derive(&root(MNEMONIC), 2, 0).unwrap();
        let x = MixSecret::derive(&root(MNEMONIC), 2, 1).unwrap();
        let half = crate::testing::synthetic_half_mix(*x.public_key(), 1_000_000_000, 20);
        let dht = y.spend_half_mix_as_bob(&half);
        assert_eq!(*dht.common_input.g, ergo_chain_types::ec_point::generator());
        assert_eq!(*dht.common_input.h, *x.public_key());
        assert_eq!(*dht.common_input.u, *y.public_key());
        // gXY is symmetric: (g^x)^y == (g^y)^x.
        assert_eq!(*dht.common_input.v, x.raise(y.public_key()));
    }
}
