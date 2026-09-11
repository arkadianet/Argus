//! Relationships between authenticated inputs, before any outputs are built.

use crate::{boxes::canonical_box, PaideiaProxyBox, Pool, RecoveryError, StakeBox, StakeStateBox};
use ergo_tx::Eip12InputBox;
use std::collections::HashSet;

/// Validate every input's contents and reject the same box used twice.
pub fn validate_unique_inputs(inputs: &[Eip12InputBox]) -> Result<(), RecoveryError> {
    let mut ids = HashSet::new();
    for input in inputs {
        let b = canonical_box(input)?;
        if !ids.insert(b.box_id()) {
            return Err(RecoveryError::Invalid(format!(
                "duplicate input {}",
                input.box_id
            )));
        }
    }
    Ok(())
}

/// Figures after removing a whole position, computed only from decoded boxes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FullUnstake {
    pub payout: i64,
    pub remaining_staked: i64,
    pub remaining_stakers: i64,
    pub returned_stake_tokens: i64,
}

/// A full unstake requires the position to have reached the state's checkpoint.
/// This is accounting eligibility, not proof of wallet control or unspentness.
pub fn validate_full_unstake(
    state: &StakeStateBox,
    stake: &StakeBox,
) -> Result<FullUnstake, RecoveryError> {
    if state.pool() != stake.pool() || state.checkpoint() != stake.checkpoint() {
        return Err(RecoveryError::Invalid("pool or checkpoint mismatch".into()));
    }
    let payout = stake.reward_amount();
    if payout <= 0 || state.total_staked() < payout || state.stakers() < 1 {
        return Err(RecoveryError::Invalid(
            "insufficient state totals/counts or nonpositive payout".into(),
        ));
    }
    Ok(FullUnstake {
        payout,
        remaining_staked: state
            .total_staked()
            .checked_sub(payout)
            .ok_or(RecoveryError::Overflow("total staked"))?,
        remaining_stakers: state
            .stakers()
            .checked_sub(1)
            .ok_or(RecoveryError::Overflow("staker count"))?,
        returned_stake_tokens: state
            .stake_token_amount()
            .checked_add(1)
            .ok_or(RecoveryError::Overflow("stake token reserve"))?,
    })
}

/// Bind a proxy to the actual Paideia position and its entire reward balance.
pub fn validate_proxy_unstake(
    state: &StakeStateBox,
    stake: &StakeBox,
    proxy: &PaideiaProxyBox,
) -> Result<FullUnstake, RecoveryError> {
    let result = validate_full_unstake(state, stake)?;
    if stake.pool() != Pool::Paideia
        || proxy.key_id() != stake.key_id()
        || proxy.amount() != result.payout
    {
        return Err(RecoveryError::Invalid(
            "proxy pool, key or full-unstake amount mismatch".into(),
        ));
    }
    Ok(result)
}

/// Find exactly one position for a key. Multiple matches are an error, even if
/// a caller supplied the same decoded position twice.
pub fn unique_position<'a>(
    positions: &'a [StakeBox],
    pool: Pool,
    key: &[u8; 32],
) -> Result<Option<&'a StakeBox>, RecoveryError> {
    let mut matching = positions
        .iter()
        .filter(|s| s.pool() == pool && s.key_id() == key);
    let first = matching.next();
    if matching.next().is_some() {
        return Err(RecoveryError::Invalid(
            "ambiguous positions for stake key".into(),
        ));
    }
    Ok(first)
}

/// Check the key quantity without imposing an asset order on an ordinary wallet
/// box. Unrelated funding assets must later be preserved by transaction accounting.
pub fn validate_key_box(input: &Eip12InputBox, key: &[u8; 32]) -> Result<(), RecoveryError> {
    canonical_box(input)?;
    let id = hex::encode(key);
    let found = input
        .assets
        .iter()
        .find(|a| a.token_id.eq_ignore_ascii_case(&id));
    if found.map(|a| a.amount.parse::<i64>()) != Some(Ok(1)) {
        return Err(RecoveryError::Invalid(
            "wallet box must carry exactly one stake key".into(),
        ));
    }
    Ok(())
}
