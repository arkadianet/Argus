//! Direct swap tx builder -- spends pool box directly (no proxy/bot).
//!
//! N2T: inputs[pool, user...] -> outputs[pool', user_out, fee]
//! T2T: same structure, but ERG stays unchanged (storage rent only)
//!
//! Pool contract validates: same ErgoTree, same R4, same NFT/LP,
//! updated reserves, constant product invariant.

mod n2t;
mod t2t;

#[cfg(test)]
mod tests;

use serde::{Deserialize, Serialize};

use crate::state::{AmmError, AmmPool, PoolType, SwapInput};
use ergo_tx::{ChangeOutputError, Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};

use self::n2t::build_n2t_direct_swap;
use self::t2t::build_t2t_direct_swap;

pub(crate) const TX_FEE: u64 = citadel_core::constants::TX_FEE_NANO as u64;
pub(crate) const MIN_BOX_VALUE: u64 = citadel_core::constants::MIN_BOX_VALUE_NANO as u64;

#[derive(Debug)]
pub struct DirectSwapBuildResult {
    pub unsigned_tx: Eip12UnsignedTx,
    pub summary: DirectSwapSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectSwapSummary {
    pub input_amount: u64,
    pub input_token: String,
    pub output_amount: u64,
    pub min_output: u64,
    pub output_token: String,
    pub miner_fee: u64,
    pub citadel_fee_nano: u64,
    pub total_erg_cost: u64,
}

/// Pool box must be inputs[0], new pool box must be outputs[0].
#[allow(clippy::too_many_arguments)]
pub fn build_direct_swap_eip12(
    pool_box: &Eip12InputBox,
    pool: &AmmPool,
    input: &SwapInput,
    min_output: u64,
    user_utxos: &[Eip12InputBox],
    user_ergo_tree: &str,
    current_height: i32,
    recipient_ergo_tree: Option<&str>,
    // Miner fee in nanoERG. `None` uses the network default (`TX_FEE`).
    // A custom fee must be at least the network minimum (1_000_000 nano).
    miner_fee_nano: Option<u64>,
) -> Result<DirectSwapBuildResult, AmmError> {
    build_direct_swap_eip12_with_held(
        pool_box,
        pool,
        input,
        min_output,
        user_utxos,
        user_ergo_tree,
        current_height,
        recipient_ergo_tree,
        miner_fee_nano,
        0,
    )
}

/// Like [`build_direct_swap_eip12`], but an ERG-funded N2T swap can also
/// forward `recipient_held_tokens` of the output token that the user already
/// holds, so the recipient receives `output + held` in one box. Held tokens
/// are taken from the user's inputs and never duplicated into change.
#[allow(clippy::too_many_arguments)]
pub fn build_direct_swap_eip12_with_held(
    pool_box: &Eip12InputBox,
    pool: &AmmPool,
    input: &SwapInput,
    min_output: u64,
    user_utxos: &[Eip12InputBox],
    user_ergo_tree: &str,
    current_height: i32,
    recipient_ergo_tree: Option<&str>,
    miner_fee_nano: Option<u64>,
    recipient_held_tokens: u64,
) -> Result<DirectSwapBuildResult, AmmError> {
    let miner_fee = resolve_miner_fee(miner_fee_nano)?;
    if recipient_held_tokens > 0 && pool.pool_type != PoolType::N2T {
        return Err(AmmError::TxBuildError(
            "held tokens can only be forwarded on an ERG-funded N2T swap".to_string(),
        ));
    }
    match pool.pool_type {
        PoolType::N2T => build_n2t_direct_swap(
            pool_box,
            pool,
            input,
            min_output,
            user_utxos,
            user_ergo_tree,
            current_height,
            recipient_ergo_tree,
            miner_fee,
            recipient_held_tokens,
        ),
        PoolType::T2T => build_t2t_direct_swap(
            pool_box,
            pool,
            input,
            min_output,
            user_utxos,
            user_ergo_tree,
            current_height,
            recipient_ergo_tree,
            miner_fee,
        ),
    }
}

/// Minimum a fee output can be (Ergo protocol's per-byte rule effectively
/// puts the floor at ≥ 1_000_000 nano for any output with the miner-fee tree).
const MIN_FEE_NANO: u64 = 1_000_000;

fn resolve_miner_fee(custom: Option<u64>) -> Result<u64, AmmError> {
    match custom {
        None => Ok(TX_FEE),
        Some(v) if v < MIN_FEE_NANO => Err(AmmError::TxBuildError(format!(
            "Miner fee {v} nano is below the network minimum {MIN_FEE_NANO} nano"
        ))),
        Some(v) => Ok(v),
    }
}

/// Selection passes a builder makes before giving up: each extra change box
/// costs ERG the previous pass did not budget for, and the boxes that ERG
/// comes from can carry tokens of their own.
const MAX_SELECTION_PASSES: usize = 4;

/// The user's side of the swap: the swap output, merged with the change when
/// it pays to the user's own tree, followed by the change laid out under the
/// per-box token cap. The error carries how much ERG the layout is short.
fn user_outputs(
    swap_output: Eip12Output,
    merge_change: bool,
    user_ergo_tree: &str,
    change_erg: u64,
    change_tokens: Vec<Eip12Asset>,
    current_height: i32,
) -> Result<Vec<Eip12Output>, ChangeOutputError> {
    if merge_change {
        let base: u64 = swap_output.value.parse().unwrap_or(0);
        let mut tokens = swap_output.assets;
        tokens.extend(change_tokens);
        return ergo_tx::token_outputs(
            base + change_erg,
            user_ergo_tree,
            tokens,
            current_height,
            MIN_BOX_VALUE,
        );
    }

    let min_change = crate::tx_builder::MIN_CHANGE_VALUE;
    // Change ERG too small for its own box and no tokens to carry: fold it
    // into the swap output rather than lose it to the miner.
    let swap_output = if change_erg > 0 && change_erg < min_change && change_tokens.is_empty() {
        let base: u64 = swap_output.value.parse().unwrap_or(0);
        Eip12Output {
            value: (base + change_erg).to_string(),
            ..swap_output
        }
    } else {
        swap_output
    };
    let mut outputs = vec![swap_output];
    if change_erg >= min_change || !change_tokens.is_empty() {
        outputs.extend(ergo_tx::token_outputs(
            change_erg,
            user_ergo_tree,
            change_tokens,
            current_height,
            min_change,
        )?);
    }
    Ok(outputs)
}
