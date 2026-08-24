//! Multi-recipient wallet send (ERG and/or tokens) transaction builder.
//!
//! Builds an EIP-12 unsigned tx for Nautilus/ErgoPay signing from already-selected
//! inputs. Centralizes per-recipient min-box validation, token change handling,
//! and balance conservation so callers do not hand-roll output construction.

use std::collections::HashMap;

use crate::eip12::{Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};

use citadel_core::constants::MIN_BOX_VALUE_NANO as MIN_BOX_VALUE;

#[derive(Debug, thiserror::Error)]
pub enum MultiSendError {
    #[error("No inputs provided")]
    NoInputs,

    #[error("At least one recipient is required")]
    NoRecipients,

    #[error("Must send ERG and/or a token")]
    EmptySend,

    #[error("Recipient amount must be at least {min} nanoERG (min box value)")]
    RecipientBelowMin { min: i64 },

    #[error("Token amount must be greater than zero")]
    ZeroTokenAmount,

    #[error("Insufficient ERG: have {have} nanoERG, need {need} nanoERG")]
    InsufficientErg { have: i64, need: i64 },

    #[error("Token change requires at least {min} nanoERG leftover, have {have}")]
    TokenChangeInsufficientErg { have: i64, min: i64 },

    #[error("Change {change} nanoERG is below minimum box value of {min} nanoERG")]
    ChangeBelowMin { change: i64, min: i64 },

    #[error("Input ERG total exceeds the representable range")]
    ErgTotalOverflow,

    #[error("Total held amount of token {token_id} exceeds the representable range")]
    TokenTotalOverflow { token_id: String },
}

#[derive(Debug, Clone)]
pub struct RecipientSpec {
    pub ergo_tree: String,
    pub amount_nano_erg: i64,
    pub token: Option<(String, u64)>,
}

#[derive(Debug)]
pub struct MultiSendSummary {
    pub recipient_erg: i64,
    pub change_erg: i64,
    pub miner_fee: i64,
    pub input_count: usize,
}

#[derive(Debug)]
pub struct MultiSendBuildResult {
    pub unsigned_tx: Eip12UnsignedTx,
    pub summary: MultiSendSummary,
}

/// Build an EIP-12 unsigned multi-recipient send tx from already-selected inputs.
///
/// - Every recipient is emitted as an output box; token-bearing recipients carry
///   their token assets. Each `amount_nano_erg` must be at least `MIN_BOX_VALUE`.
/// - Leftover ERG and unspent tokens go to `change_ergo_tree`.
/// - `fee_nano` is used as the miner-fee output. Balance is conserved.
pub fn build_multi_send_tx_with_fee(
    user_inputs: &[Eip12InputBox],
    recipients: &[RecipientSpec],
    change_ergo_tree: &str,
    fee_nano: i64,
    current_height: i32,
) -> Result<MultiSendBuildResult, MultiSendError> {
    if user_inputs.is_empty() {
        return Err(MultiSendError::NoInputs);
    }
    if recipients.is_empty() {
        return Err(MultiSendError::NoRecipients);
    }

    let has_sent_tokens = recipients.iter().any(|r| r.token.is_some());
    let total_send_erg: i64 = recipients
        .iter()
        .map(|r| r.amount_nano_erg)
        .try_fold(0i64, i64::checked_add)
        .ok_or(MultiSendError::InsufficientErg {
            have: i64::MAX,
            need: 0,
        })?;
    if total_send_erg <= 0 && !has_sent_tokens {
        return Err(MultiSendError::EmptySend);
    }
    for r in recipients {
        if r.amount_nano_erg < MIN_BOX_VALUE {
            return Err(MultiSendError::RecipientBelowMin { min: MIN_BOX_VALUE });
        }
        if let Some((_, amt)) = r.token {
            if amt == 0 {
                return Err(MultiSendError::ZeroTokenAmount);
            }
        }
    }

    let total_erg: i64 = user_inputs
        .iter()
        .map(|b| b.value.parse::<i64>().unwrap_or(0))
        .try_fold(0i64, i64::checked_add)
        .ok_or(MultiSendError::ErgTotalOverflow)?;

    // Aggregate input token balances.
    let mut input_tokens: HashMap<String, u64> = HashMap::new();
    for input in user_inputs {
        for asset in &input.assets {
            let entry = input_tokens.entry(asset.token_id.clone()).or_insert(0);
            *entry = entry.checked_add(asset.amount.parse::<u64>().unwrap_or(0)).ok_or_else(|| {
                MultiSendError::TokenTotalOverflow {
                    token_id: asset.token_id.clone(),
                }
            })?;
        }
    }

    let required_erg = i64::checked_add(total_send_erg, fee_nano)
        .ok_or(MultiSendError::InsufficientErg {
            have: total_erg,
            need: i64::MAX,
        })?;
    if total_erg < required_erg {
        return Err(MultiSendError::InsufficientErg {
            have: total_erg,
            need: required_erg,
        });
    }

    // Subtract sent tokens to compute change tokens.
    for r in recipients {
        if let Some((id, amt)) = &r.token {
            if let Some(balance) = input_tokens.get_mut(id) {
                *balance = balance.saturating_sub(*amt);
                if *balance == 0 {
                    input_tokens.remove(id);
                }
            }
        }
    }

    let has_token_change = !input_tokens.is_empty();
    let raw_change = total_erg - total_send_erg - fee_nano;
    // Dust change folds into the miner fee instead of failing the send.
    let dust_to_fee = if !has_token_change && raw_change > 0 && raw_change < MIN_BOX_VALUE {
        raw_change
    } else {
        0
    };
    let change_erg = raw_change - dust_to_fee;
    let effective_fee = fee_nano + dust_to_fee;
    let need_change = change_erg > 0 || has_token_change;

    if need_change && has_token_change && change_erg < MIN_BOX_VALUE {
        return Err(MultiSendError::TokenChangeInsufficientErg {
            have: change_erg,
            min: MIN_BOX_VALUE,
        });
    }

    // Recipient outputs.
    let mut outputs = Vec::with_capacity(recipients.len() + 2);
    for r in recipients {
        let assets = match &r.token {
            Some((id, amt)) => vec![Eip12Asset::new(id.clone(), *amt as i64)],
            None => vec![],
        };
        outputs.push(Eip12Output {
            value: r.amount_nano_erg.to_string(),
            ergo_tree: r.ergo_tree.clone(),
            assets,
            creation_height: current_height,
            additional_registers: HashMap::new(),
        });
    }

    // Change output.
    if need_change {
        let change_value = if change_erg > 0 {
            change_erg
        } else {
            MIN_BOX_VALUE
        };
        let change_assets: Vec<Eip12Asset> = input_tokens
            .iter()
            .map(|(id, amt)| Eip12Asset::new(id.clone(), *amt as i64))
            .collect();
        outputs.push(Eip12Output::change(
            change_value,
            change_ergo_tree,
            change_assets,
            current_height,
        ));
    }

    outputs.push(Eip12Output::fee(effective_fee, current_height));

    let unsigned_tx = Eip12UnsignedTx {
        inputs: user_inputs.to_vec(),
        data_inputs: vec![],
        outputs,
    };

    Ok(MultiSendBuildResult {
        unsigned_tx,
        summary: MultiSendSummary {
            recipient_erg: total_send_erg,
            change_erg,
            miner_fee: effective_fee,
            input_count: user_inputs.len(),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHANGE_TREE: &str = "0008cdchange";
    const RECIPIENT_TREE: &str = "0008cdrecip";

    fn make_box(value: &str, assets: Vec<(&str, &str)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: "b".to_string(),
            transaction_id: "tx".to_string(),
            index: 0,
            value: value.to_string(),
            ergo_tree: CHANGE_TREE.to_string(),
            assets: assets
                .into_iter()
                .map(|(id, amt)| Eip12Asset {
                    token_id: id.to_string(),
                    amount: amt.to_string(),
                })
                .collect(),
            creation_height: 1,
            additional_registers: HashMap::new(),
            extension: HashMap::new(),
        }
    }

    #[test]
    fn multi_erg_recipients_conserve_balance() {
        let inputs = vec![make_box("10000000000", vec![])];
        let result = build_multi_send_tx_with_fee(
            &inputs,
            &[
                RecipientSpec {
                    ergo_tree: RECIPIENT_TREE.to_string(),
                    amount_nano_erg: 2_000_000_000,
                    token: None,
                },
                RecipientSpec {
                    ergo_tree: RECIPIENT_TREE.to_string(),
                    amount_nano_erg: 1_000_000_000,
                    token: None,
                },
            ],
            CHANGE_TREE,
            1_000_000,
            50000,
        )
        .unwrap();

        assert_eq!(result.summary.recipient_erg, 3_000_000_000);
        assert_eq!(result.summary.change_erg, 7_000_000_000 - 1_000_000);
        assert_eq!(result.summary.input_count, 1);
        // recipients + change + fee
        assert_eq!(result.unsigned_tx.outputs.len(), 4);
    }

    #[test]
    fn token_change_requires_min_box_leftover() {
        let fee = 1_000_000i64;
        let inputs = vec![make_box(
            &(MIN_BOX_VALUE + fee).to_string(),
            vec![("tok_a", "100")],
        )];
        let err = build_multi_send_tx_with_fee(
            &inputs,
            &[RecipientSpec {
                ergo_tree: RECIPIENT_TREE.to_string(),
                amount_nano_erg: MIN_BOX_VALUE,
                token: Some(("tok_a".to_string(), 50)),
            }],
            CHANGE_TREE,
            fee,
            50000,
        )
        .unwrap_err();
        assert!(matches!(
            err,
            MultiSendError::TokenChangeInsufficientErg { .. }
        ));
    }

    #[test]
    fn reject_below_min_recipient() {
        let inputs = vec![make_box("10000000000", vec![])];
        let err = build_multi_send_tx_with_fee(
            &inputs,
            &[RecipientSpec {
                ergo_tree: RECIPIENT_TREE.to_string(),
                amount_nano_erg: 500_000,
                token: None,
            }],
            CHANGE_TREE,
            1_000_000,
            50000,
        )
        .unwrap_err();
        assert!(matches!(err, MultiSendError::RecipientBelowMin { .. }));
    }

    #[test]
    fn exact_spend_no_change() {
        let send = 1_000_000_000i64;
        let fee = 1_000_000i64;
        let inputs = vec![make_box(&(send + fee).to_string(), vec![])];
        let result = build_multi_send_tx_with_fee(
            &inputs,
            &[RecipientSpec {
                ergo_tree: RECIPIENT_TREE.to_string(),
                amount_nano_erg: send,
                token: None,
            }],
            CHANGE_TREE,
            fee,
            50000,
        )
        .unwrap();
        assert_eq!(result.summary.change_erg, 0);
        // recipient + fee only
        assert_eq!(result.unsigned_tx.outputs.len(), 2);
    }
}
