//! N2T direct swap builder.

use crate::calculator;
use crate::constants::fees;
use crate::state::{AmmError, AmmPool, SwapInput};
use ergo_tx::{
    append_dev_fee_output, collect_change_tokens, resolved_dev_fee_config, select_inputs_for_spend,
    Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx,
};

use super::{DirectSwapBuildResult, DirectSwapSummary, MIN_BOX_VALUE};

#[allow(clippy::too_many_arguments)]
pub(crate) fn build_n2t_direct_swap(
    pool_box: &Eip12InputBox,
    pool: &AmmPool,
    input: &SwapInput,
    min_output: u64,
    user_utxos: &[Eip12InputBox],
    user_ergo_tree: &str,
    current_height: i32,
    recipient_ergo_tree: Option<&str>,
    miner_fee: u64,
    recipient_held_tokens: u64,
) -> Result<DirectSwapBuildResult, AmmError> {
    let pool_erg: u64 = pool_box
        .value
        .parse()
        .map_err(|_| AmmError::TxBuildError("Invalid pool box ERG value".to_string()))?;

    if pool_box.assets.len() < 3 {
        return Err(AmmError::TxBuildError(format!(
            "Pool box has {} tokens, expected at least 3",
            pool_box.assets.len()
        )));
    }

    let pool_nft = &pool_box.assets[0];
    let pool_lp = &pool_box.assets[1];
    let pool_token_y = &pool_box.assets[2];

    let pool_token_y_amount: u64 = pool_token_y
        .amount
        .parse()
        .map_err(|_| AmmError::TxBuildError("Invalid pool token Y amount".to_string()))?;

    // fee_num from R4 is the ground truth for the constant product check
    let fee_num = crate::constants::parse_fee_num_from_r4(&pool_box.additional_registers)?;
    let fee_denom = fees::DEFAULT_FEE_DENOM;

    let (output_amount, is_erg_to_token) = match input {
        SwapInput::Erg { amount } => {
            let output = calculator::calculate_output(
                pool_erg,
                pool_token_y_amount,
                *amount,
                fee_num,
                fee_denom,
            );
            if output == 0 {
                return Err(AmmError::InsufficientLiquidity);
            }
            (output, true)
        }
        SwapInput::Token { amount, .. } => {
            let output = calculator::calculate_token_to_erg_output(
                pool_token_y_amount,
                pool_erg,
                *amount,
                fee_num,
                fee_denom,
            );
            if output == 0 {
                let max_out = calculator::max_erg_extractable(pool_erg);
                return Err(AmmError::TxBuildError(format!(
                    "Swap would leave pool below minimum ERG (pool has {} nanoERG, \
                     max extractable {}, need at least {} dust reserved). Try a smaller amount.",
                    pool_erg,
                    max_out,
                    calculator::MIN_BOX_VALUE
                )));
            }
            (output, false)
        }
    };

    if output_amount < min_output {
        return Err(AmmError::SlippageExceeded {
            got: output_amount,
            min: min_output,
        });
    }

    let input_amount = match input {
        SwapInput::Erg { amount } => *amount,
        SwapInput::Token { amount, .. } => *amount,
    };

    let (new_pool_erg, new_pool_token_y_amount) = if is_erg_to_token {
        let new_erg = pool_erg
            .checked_add(input_amount)
            .ok_or_else(|| AmmError::TxBuildError("Pool ERG overflow".to_string()))?;
        let new_token_y = pool_token_y_amount
            .checked_sub(output_amount)
            .ok_or_else(|| AmmError::TxBuildError("Pool token Y underflow".to_string()))?;
        (new_erg, new_token_y)
    } else {
        let new_erg = pool_erg
            .checked_sub(output_amount)
            .ok_or_else(|| AmmError::TxBuildError("Pool ERG underflow".to_string()))?;
        // Defensive: calculate_token_to_erg_output already enforces this.
        if new_erg < calculator::MIN_BOX_VALUE {
            return Err(AmmError::TxBuildError(format!(
                "New pool box would have less than minimum ERG ({} < {})",
                new_erg,
                calculator::MIN_BOX_VALUE
            )));
        }
        let new_token_y = pool_token_y_amount
            .checked_add(input_amount)
            .ok_or_else(|| AmmError::TxBuildError("Pool token Y overflow".to_string()))?;
        (new_erg, new_token_y)
    };

    let new_pool_output = Eip12Output {
        value: new_pool_erg.to_string(),
        ergo_tree: pool_box.ergo_tree.clone(),
        assets: vec![
            Eip12Asset {
                token_id: pool_nft.token_id.clone(),
                amount: pool_nft.amount.clone(),
            },
            Eip12Asset {
                token_id: pool_lp.token_id.clone(),
                amount: pool_lp.amount.clone(),
            },
            Eip12Asset {
                token_id: pool_token_y.token_id.clone(),
                amount: new_pool_token_y_amount.to_string(),
            },
        ],
        creation_height: current_height,
        additional_registers: pool_box.additional_registers.clone(),
    };

    // Held tokens ride only on the ERG-funded leg: the user already owns
    // them and they leave with the swapped ones in a single box.
    let held = if is_erg_to_token {
        recipient_held_tokens
    } else {
        0
    };
    if !is_erg_to_token && recipient_held_tokens > 0 {
        return Err(AmmError::TxBuildError(
            "held tokens can only be forwarded when paying with ERG".to_string(),
        ));
    }
    let output_tree = recipient_ergo_tree.unwrap_or(user_ergo_tree);
    let user_swap_output = if is_erg_to_token {
        Eip12Output::change(
            MIN_BOX_VALUE as i64,
            output_tree,
            vec![Eip12Asset {
                token_id: pool.token_y.token_id.clone(),
                amount: (output_amount + held).to_string(),
            }],
            current_height,
        )
    } else {
        Eip12Output::change(output_amount as i64, output_tree, vec![], current_height)
    };

    let fee_cfg = resolved_dev_fee_config();
    let citadel_fee = fee_cfg.budget() as u64;
    let fee_output = Eip12Output::fee(miner_fee as i64, current_height);

    let user_erg_needed = if is_erg_to_token {
        input_amount
            .checked_add(MIN_BOX_VALUE)
            .and_then(|v| v.checked_add(miner_fee))
            .and_then(|v| v.checked_add(citadel_fee))
            .ok_or_else(|| AmmError::TxBuildError("ERG cost overflow".to_string()))?
    } else {
        miner_fee
            .checked_add(citadel_fee)
            .ok_or_else(|| AmmError::TxBuildError("ERG cost overflow".to_string()))?
    };

    let token_requirement = match input {
        SwapInput::Erg { .. } if held > 0 => Some((pool.token_y.token_id.as_str(), held)),
        SwapInput::Erg { .. } => None,
        SwapInput::Token { token_id, amount } => Some((token_id.as_str(), *amount)),
    };
    // The held amount is spent into the recipient box, so it must be
    // subtracted from change or it would be duplicated.
    let spent_token = match input {
        SwapInput::Erg { .. } if held > 0 => Some((pool.token_y.token_id.as_str(), held)),
        SwapInput::Erg { .. } => None,
        SwapInput::Token { token_id, amount } => Some((token_id.as_str(), *amount)),
    };

    // Change tokens are laid out under the per-box cap, and every extra box
    // costs ERG the selection has not budgeted for; reselect with it.
    let mut extra_erg: u64 = 0;
    let mut passes = 0;
    let (selected, user_side) = loop {
        let selected =
            select_inputs_for_spend(user_utxos, user_erg_needed + extra_erg, token_requirement)
                .map_err(|e| AmmError::TxBuildError(e.to_string()))?;
        let change_erg = selected.total_erg - user_erg_needed;
        let change_tokens = collect_change_tokens(&selected.boxes, spent_token);
        match super::user_outputs(
            user_swap_output.clone(),
            recipient_ergo_tree.is_none(),
            user_ergo_tree,
            change_erg,
            change_tokens,
            current_height,
        ) {
            Ok(outputs) => break (selected, outputs),
            Err(short) => {
                passes += 1;
                if passes >= super::MAX_SELECTION_PASSES {
                    return Err(AmmError::TxBuildError(short.to_string()));
                }
                extra_erg += short.min_value - short.available;
            }
        }
    };

    let mut outputs = vec![new_pool_output];
    outputs.extend(user_side);

    append_dev_fee_output(&mut outputs, &fee_cfg, current_height)
        .map_err(|e| AmmError::TxBuildError(e.to_string()))?;
    outputs.push(fee_output);

    let mut inputs = vec![pool_box.clone()];
    inputs.extend(selected.boxes);

    let unsigned_tx = Eip12UnsignedTx {
        inputs,
        data_inputs: vec![],
        outputs,
    };

    let (input_token_name, output_token_name) = match input {
        SwapInput::Erg { .. } => (
            "ERG".to_string(),
            pool.token_y
                .name
                .clone()
                .unwrap_or_else(|| pool.token_y.token_id[..8].to_string()),
        ),
        SwapInput::Token { .. } => (
            pool.token_y
                .name
                .clone()
                .unwrap_or_else(|| pool.token_y.token_id[..8].to_string()),
            "ERG".to_string(),
        ),
    };

    let summary = DirectSwapSummary {
        input_amount,
        input_token: input_token_name,
        output_amount,
        min_output,
        output_token: output_token_name,
        miner_fee,
        citadel_fee_nano: citadel_fee,
        total_erg_cost: user_erg_needed,
    };

    Ok(DirectSwapBuildResult {
        unsigned_tx,
        summary,
    })
}
