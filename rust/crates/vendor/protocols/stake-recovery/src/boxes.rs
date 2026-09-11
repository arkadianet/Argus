//! Stake, state and proxy boxes read from the same EIP-12 inputs Argus signs.
//!
//! Parsing checks the supplied id against the complete box contents. The typed
//! views keep their fields private so later checks cannot use an edited snapshot.

use std::collections::HashSet;

use ergo_tx::Eip12InputBox;
use ergotree_ir::{
    chain::ergo_box::ErgoBox,
    ergo_tree::ErgoTree,
    mir::constant::{Constant, TryExtractInto},
    serialization::SigmaSerializable,
};

use crate::{
    contracts::{parse_tree, tree_from_address, Pool, PAIDEIA_PROXY_ADDRESS},
    RecoveryError,
};

fn bad_box(b: &Eip12InputBox, why: impl Into<String>) -> RecoveryError {
    RecoveryError::Box {
        box_id: b.box_id.clone(),
        why: why.into(),
    }
}

fn bad_register(b: &Eip12InputBox, name: &str, expected: &str) -> RecoveryError {
    RecoveryError::Register {
        box_id: b.box_id.clone(),
        register: name.into(),
        expected: expected.into(),
    }
}

fn constant(b: &Eip12InputBox, name: &str) -> Result<Constant, RecoveryError> {
    let fail = || bad_register(b, name, "a complete, canonical Sigma constant");
    let raw = b.additional_registers.get(name).ok_or_else(fail)?;
    let bytes = hex::decode(raw).map_err(|_| fail())?;
    let c = Constant::sigma_parse_bytes(&bytes).map_err(|_| fail())?;
    if c.sigma_serialize_bytes().map_err(|_| fail())? != bytes {
        return Err(fail());
    }
    Ok(c)
}

fn longs<const N: usize>(b: &Eip12InputBox) -> Result<[i64; N], RecoveryError> {
    let fail = || bad_register(b, "R4", &format!("Coll[Long] of length {N}"));
    constant(b, "R4")?
        .try_extract_into::<Vec<i64>>()
        .map_err(|_| fail())?
        .try_into()
        .map_err(|_| fail())
}

fn bytes(b: &Eip12InputBox, name: &str) -> Result<Vec<u8>, RecoveryError> {
    constant(b, name)?
        .try_extract_into::<Vec<u8>>()
        .map_err(|_| bad_register(b, name, "Coll[Byte]"))
}

/// Reconstruct a canonical box, including its creation transaction and output
/// index. A caller-supplied id never substitutes for the contents.
///
/// Context extensions are checked separately: they are spending data, not part
/// of a box id. No malformed extension is silently dropped.
pub fn canonical_box(input: &Eip12InputBox) -> Result<ErgoBox, RecoveryError> {
    for name in input.additional_registers.keys() {
        if !matches!(name.as_str(), "R4" | "R5" | "R6" | "R7" | "R8" | "R9") {
            return Err(bad_box(input, "unknown register"));
        }
        constant(input, name)?;
    }
    let mut ids = HashSet::new();
    for asset in &input.assets {
        if !ids.insert(asset.token_id.to_ascii_lowercase()) {
            return Err(bad_box(input, "duplicate token id"));
        }
    }
    let mut extension_ids = HashSet::new();
    for (key, value) in &input.extension {
        let id = key
            .parse::<u8>()
            .map_err(|_| bad_box(input, "invalid context extension key"))?;
        if key != &id.to_string() || !extension_ids.insert(id) {
            return Err(bad_box(input, "noncanonical context extension key"));
        }
        let bytes =
            hex::decode(value).map_err(|_| bad_box(input, "invalid context extension hex"))?;
        let c = Constant::sigma_parse_bytes(&bytes)
            .map_err(|_| bad_box(input, "invalid context extension constant"))?;
        if c.sigma_serialize_bytes()
            .map_err(|e| RecoveryError::Serialization(e.to_string()))?
            != bytes
        {
            return Err(bad_box(input, "noncanonical context extension constant"));
        }
    }
    let tree = hex::decode(&input.ergo_tree).map_err(|_| bad_box(input, "invalid tree hex"))?;
    parse_tree(&tree)?;
    let json =
        serde_json::to_value(input).map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    // sigma-rust reconstructs the box id and rejects a mismatch during decoding.
    serde_json::from_value(json).map_err(|e| bad_box(input, e.to_string()))
}

fn shape(
    input: &Eip12InputBox,
    tree: ErgoTree,
    registers: usize,
    assets: usize,
) -> Result<(), RecoveryError> {
    let canonical = canonical_box(input)?;
    if canonical
        .ergo_tree
        .sigma_serialize_bytes()
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?
        != tree
            .sigma_serialize_bytes()
            .map_err(|e| RecoveryError::Serialization(e.to_string()))?
    {
        return Err(bad_box(input, "wrong full contract tree"));
    }
    if input.additional_registers.len() != registers || input.assets.len() != assets {
        return Err(bad_box(input, "unexpected register or asset count"));
    }
    Ok(())
}

fn token(
    input: &Eip12InputBox,
    index: usize,
    id: &str,
    singleton: bool,
) -> Result<i64, RecoveryError> {
    let asset = input
        .assets
        .get(index)
        .ok_or_else(|| bad_box(input, "missing token"))?;
    let amount = asset
        .amount
        .parse::<i64>()
        .map_err(|_| bad_box(input, "token amount outside Long range"))?;
    if !asset.token_id.eq_ignore_ascii_case(id) || amount <= 0 || (singleton && amount != 1) {
        return Err(bad_box(
            input,
            format!("wrong token or quantity at tokens({index})"),
        ));
    }
    Ok(amount)
}

fn ordinary_key(key: &[u8; 32]) -> Result<(), RecoveryError> {
    let id = hex::encode(key);
    for pool in [Pool::Ergopad, Pool::Paideia, Pool::Egio] {
        let c = pool.contracts();
        if [c.state_nft, c.stake_token, c.reward_token].contains(&id.as_str()) {
            return Err(RecoveryError::Invalid(
                "stake key is a registered protocol asset".into(),
            ));
        }
    }
    Ok(())
}

/// One stake token authenticates the position; R5 identifies its wallet-held key.
#[derive(Debug, Clone)]
pub struct StakeBox {
    input: Eip12InputBox,
    pool: Pool,
    key_id: [u8; 32],
    checkpoint: i64,
    stake_time_ms: i64,
    reward_amount: i64,
}

impl StakeBox {
    pub fn parse(input: &Eip12InputBox, pool: Pool) -> Result<Self, RecoveryError> {
        let c = pool.contracts();
        shape(input, c.stake_tree()?, 2, 2)?;
        token(input, 0, c.stake_token, true)?;
        let reward_amount = token(input, 1, c.reward_token, false)?;
        let [checkpoint, stake_time_ms] = longs::<2>(input)?;
        if checkpoint < 0 || stake_time_ms < 0 {
            return Err(bad_box(input, "negative checkpoint or stake time"));
        }
        let key_id = bytes(input, "R5")?
            .try_into()
            .map_err(|_| bad_register(input, "R5", "32-byte stake key id"))?;
        ordinary_key(&key_id)?;
        Ok(Self {
            input: input.clone(),
            pool,
            key_id,
            checkpoint,
            stake_time_ms,
            reward_amount,
        })
    }
    pub fn input(&self) -> &Eip12InputBox {
        &self.input
    }
    pub fn pool(&self) -> Pool {
        self.pool
    }
    pub fn key_id(&self) -> &[u8; 32] {
        &self.key_id
    }
    pub fn checkpoint(&self) -> i64 {
        self.checkpoint
    }
    pub fn stake_time_ms(&self) -> i64 {
        self.stake_time_ms
    }
    pub fn reward_amount(&self) -> i64 {
        self.reward_amount
    }
}

/// The state NFT and reserve stake tokens, with the five Longs in R4.
#[derive(Debug, Clone)]
pub struct StakeStateBox {
    input: Eip12InputBox,
    pool: Pool,
    total_staked: i64,
    checkpoint: i64,
    stakers: i64,
    last_checkpoint_ms: i64,
    cycle_duration_ms: i64,
    stake_token_amount: i64,
}

impl StakeStateBox {
    pub fn parse(input: &Eip12InputBox, pool: Pool) -> Result<Self, RecoveryError> {
        let c = pool.contracts();
        shape(input, c.state_tree()?, 1, 2)?;
        token(input, 0, c.state_nft, true)?;
        let stake_token_amount = token(input, 1, c.stake_token, false)?;
        let [total_staked, checkpoint, stakers, last_checkpoint_ms, cycle_duration_ms] =
            longs::<5>(input)?;
        if [total_staked, checkpoint, stakers, last_checkpoint_ms]
            .iter()
            .any(|n| *n < 0)
            || cycle_duration_ms <= 0
        {
            return Err(bad_box(
                input,
                "negative state counter/time or nonpositive cycle duration",
            ));
        }
        Ok(Self {
            input: input.clone(),
            pool,
            total_staked,
            checkpoint,
            stakers,
            last_checkpoint_ms,
            cycle_duration_ms,
            stake_token_amount,
        })
    }
    pub fn input(&self) -> &Eip12InputBox {
        &self.input
    }
    pub fn pool(&self) -> Pool {
        self.pool
    }
    pub fn total_staked(&self) -> i64 {
        self.total_staked
    }
    pub fn checkpoint(&self) -> i64 {
        self.checkpoint
    }
    pub fn stakers(&self) -> i64 {
        self.stakers
    }
    pub fn last_checkpoint_ms(&self) -> i64 {
        self.last_checkpoint_ms
    }
    pub fn cycle_duration_ms(&self) -> i64 {
        self.cycle_duration_ms
    }
    pub fn stake_token_amount(&self) -> i64 {
        self.stake_token_amount
    }
}

/// A Paideia request. R4 is the amount; R5 is the complete payout/refund tree.
/// Parsing proves its shape, not that the caller controls the recipient or key.
#[derive(Debug, Clone)]
pub struct PaideiaProxyBox {
    input: Eip12InputBox,
    key_id: [u8; 32],
    amount: i64,
    recipient: ErgoTree,
}

impl PaideiaProxyBox {
    /// Decode without discovering state or stake boxes, so refund stays independent.
    pub fn parse(input: &Eip12InputBox) -> Result<Self, RecoveryError> {
        shape(input, tree_from_address(PAIDEIA_PROXY_ADDRESS)?, 2, 1)?;
        let asset = &input.assets[0];
        token(input, 0, &asset.token_id, true)?;
        let key_id = hex::decode(&asset.token_id)
            .map_err(|_| bad_box(input, "key hex"))?
            .try_into()
            .map_err(|_| bad_box(input, "key id must be 32 bytes"))?;
        ordinary_key(&key_id)?;
        let [amount] = longs::<1>(input)?;
        if amount <= 0 {
            return Err(bad_box(input, "nonpositive unstake amount"));
        }
        let recipient = parse_tree(&bytes(input, "R5")?)?;
        Ok(Self {
            input: input.clone(),
            key_id,
            amount,
            recipient,
        })
    }
    pub fn input(&self) -> &Eip12InputBox {
        &self.input
    }
    pub fn key_id(&self) -> &[u8; 32] {
        &self.key_id
    }
    pub fn amount(&self) -> i64 {
        self.amount
    }
    pub fn recipient(&self) -> &ErgoTree {
        &self.recipient
    }

    /// Compare with the recipient established by wallet integration or persisted
    /// tracking. This equality check cannot establish wallet ownership itself.
    pub fn validate_recipient(&self, expected: &ErgoTree) -> Result<(), RecoveryError> {
        if &self.recipient != expected {
            return Err(RecoveryError::Invalid(
                "proxy recipient differs from expected wallet recipient".into(),
            ));
        }
        Ok(())
    }
}
