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

    #[error("Insufficient tokens: have {have} of {token_id}, need {need}")]
    InsufficientTokens {
        token_id: String,
        have: u64,
        need: u64,
    },

    #[error("Amount of token {token_id} exceeds the representable range")]
    TokenAmountOutOfRange { token_id: String },

    #[error("Miner fee must be at least {min} nanoERG")]
    FeeBelowMin { min: i64 },

    #[error("Recipient tokens require at least {min} nanoERG, have {have}")]
    RecipientTokensInsufficientErg { have: i64, min: i64 },

    #[error("Recipient box cannot be built: {0}")]
    RecipientBox(String),

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

    #[error("{0}")]
    ChangeBox(String),
}

#[derive(Debug, Clone)]
pub struct RecipientSpec {
    pub ergo_tree: String,
    pub amount_nano_erg: i64,
    /// Tokens this recipient gets, `(id, amount)`; the same id may appear
    /// more than once and is summed into one asset.
    pub tokens: Vec<(String, u64)>,
}

impl RecipientSpec {
    /// One token or none, the shape most sends have.
    pub fn with_token(
        ergo_tree: String,
        amount_nano_erg: i64,
        token: Option<(String, u64)>,
    ) -> Self {
        Self {
            ergo_tree,
            amount_nano_erg,
            tokens: token.into_iter().collect(),
        }
    }

    /// This recipient's tokens summed by id, in first-seen order.
    pub fn assets(&self) -> Result<Vec<(String, u64)>, MultiSendError> {
        let mut out: Vec<(String, u64)> = Vec::new();
        for (id, amt) in &self.tokens {
            if *amt == 0 {
                return Err(MultiSendError::ZeroTokenAmount);
            }
            match out.iter_mut().find(|(i, _)| i == id) {
                Some((_, n)) => {
                    *n = n
                        .checked_add(*amt)
                        .ok_or_else(|| MultiSendError::TokenTotalOverflow {
                            token_id: id.clone(),
                        })?
                }
                None => out.push((id.clone(), *amt)),
            }
        }
        for (id, amount) in &out {
            if *amount > i64::MAX as u64 {
                return Err(MultiSendError::TokenAmountOutOfRange {
                    token_id: id.clone(),
                });
            }
        }
        Ok(out)
    }

    /// Total ERG required to deliver these assets in boxes within the node's
    /// size and token limits. Preparation reserves this before selecting inputs.
    pub fn minimum_value(&self) -> Result<u64, MultiSendError> {
        let assets = self
            .assets()?
            .into_iter()
            .map(|(id, amount)| Eip12Asset::new(id, amount as i64))
            .collect();
        match crate::token_outputs(0, &self.ergo_tree, assets, 0, MIN_BOX_VALUE as u64) {
            Err(crate::ChangeOutputError::NotEnoughErg { min_value, .. }) => Ok(min_value),
            Err(other) => Err(MultiSendError::RecipientBox(other.to_string())),
            Ok(_) => Ok(crate::min_value_for(
                crate::box_bytes(&self.ergo_tree, &[], &HashMap::new()),
                MIN_BOX_VALUE as u64,
            )),
        }
    }
}

#[derive(Debug)]
pub struct MultiSendSummary {
    pub recipient_erg: i64,
    pub change_erg: i64,
    pub miner_fee: i64,
    pub input_count: usize,
    pub citadel_fee_nano: i64,
    /// Recipient outputs may span several boxes when delivering many tokens.
    pub recipient_output_count: usize,
    /// Change outputs occupy this range immediately after recipient outputs.
    pub change_output_count: usize,
}

#[derive(Debug)]
pub struct MultiSendBuildResult {
    pub unsigned_tx: Eip12UnsignedTx,
    pub summary: MultiSendSummary,
}

/// Build an EIP-12 unsigned multi-recipient send tx from already-selected inputs.
///
/// - Recipient assets are packed into as many outputs as the node's limits
///   require. Their total `amount_nano_erg` must fund every output's minimum.
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
    if fee_nano < MIN_BOX_VALUE {
        return Err(MultiSendError::FeeBelowMin { min: MIN_BOX_VALUE });
    }

    let has_sent_tokens = recipients.iter().any(|r| !r.tokens.is_empty());
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
        if r.tokens.iter().any(|(_, amt)| *amt == 0) {
            return Err(MultiSendError::ZeroTokenAmount);
        }
        let min = r.minimum_value()?;
        if (r.amount_nano_erg as u64) < min {
            return Err(MultiSendError::RecipientTokensInsufficientErg {
                have: r.amount_nano_erg,
                min: min as i64,
            });
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
            *entry = entry
                .checked_add(asset.amount.parse::<u64>().unwrap_or(0))
                .ok_or_else(|| MultiSendError::TokenTotalOverflow {
                    token_id: asset.token_id.clone(),
                })?;
        }
    }

    let fee_cfg = crate::dev_fee::resolved_config();
    let app_fee = fee_cfg.budget();
    let required_erg = i64::checked_add(total_send_erg, fee_nano)
        .and_then(|v| v.checked_add(app_fee))
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
        for (id, amt) in r.assets()? {
            let have = input_tokens.get(&id).copied().unwrap_or(0);
            if have < amt {
                return Err(MultiSendError::InsufficientTokens {
                    token_id: id,
                    have,
                    need: amt,
                });
            }
            if have == amt {
                input_tokens.remove(&id);
            } else {
                input_tokens.insert(id, have - amt);
            }
        }
    }

    let has_token_change = !input_tokens.is_empty();
    let raw_change = total_erg - total_send_erg - fee_nano - app_fee;
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
        let assets: Vec<Eip12Asset> = r
            .assets()?
            .into_iter()
            .map(|(id, amt)| Eip12Asset::new(id, amt as i64))
            .collect();
        outputs.extend(
            crate::token_outputs(
                r.amount_nano_erg as u64,
                &r.ergo_tree,
                assets,
                current_height,
                MIN_BOX_VALUE as u64,
            )
            .map_err(|e| MultiSendError::RecipientBox(e.to_string()))?,
        );
    }

    let recipient_output_count = outputs.len();
    // Change output.
    if need_change {
        let change_value = if change_erg > 0 {
            change_erg
        } else {
            MIN_BOX_VALUE
        };
        if let Some((id, _)) = input_tokens
            .iter()
            .find(|(_, amount)| **amount > i64::MAX as u64)
        {
            return Err(MultiSendError::TokenAmountOutOfRange {
                token_id: id.clone(),
            });
        }
        let change_assets: Vec<Eip12Asset> = input_tokens
            .iter()
            .map(|(id, amt)| Eip12Asset::new(id.clone(), *amt as i64))
            .collect();
        outputs.extend(
            crate::token_outputs(
                change_value as u64,
                change_ergo_tree,
                change_assets,
                current_height,
                MIN_BOX_VALUE as u64,
            )
            .map_err(|e| match e {
                crate::ChangeOutputError::NotEnoughErg {
                    min_value,
                    available,
                } => MultiSendError::TokenChangeInsufficientErg {
                    have: available as i64,
                    min: min_value as i64,
                },
                other => MultiSendError::ChangeBox(other.to_string()),
            })?,
        );
    }

    let change_output_count = outputs.len() - recipient_output_count;
    // Cannot fail once enabled with a tree; budget was reserved above.
    let _ = crate::dev_fee::append_dev_fee_output(&mut outputs, &fee_cfg, current_height);
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
            citadel_fee_nano: app_fee,
            recipient_output_count,
            change_output_count,
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
                    tokens: vec![],
                },
                RecipientSpec {
                    ergo_tree: RECIPIENT_TREE.to_string(),
                    amount_nano_erg: 1_000_000_000,
                    tokens: vec![],
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
                tokens: vec![("tok_a".to_string(), 50)],
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
                tokens: vec![],
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
                tokens: vec![],
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

    #[test]
    fn a_recipient_can_carry_erg_and_several_tokens_in_one_box() {
        let inputs = vec![make_box("5000000", vec![("tok_a", "100"), ("tok_b", "7")])];
        let recipients = vec![RecipientSpec {
            ergo_tree: "0008cd02".to_string(),
            amount_nano_erg: 2_000_000,
            tokens: vec![
                ("tok_a".to_string(), 30),
                ("tok_b".to_string(), 7),
                ("tok_a".to_string(), 10),
            ],
        }];
        let result =
            build_multi_send_tx_with_fee(&inputs, &recipients, CHANGE_TREE, 1_000_000, 100)
                .unwrap();
        let tx = result.unsigned_tx;
        let out = &tx.outputs[0];
        assert_eq!(out.value, "2000000");
        assert_eq!(out.assets.len(), 2, "the same token twice is one asset");
        assert_eq!(out.assets[0].amount, "40");
        assert_eq!(out.assets[1].amount, "7");
        // tok_a's remainder comes back as change; tok_b is spent entirely.
        let change = &tx.outputs[1];
        assert_eq!(change.assets.len(), 1);
        assert_eq!(change.assets[0].token_id, "tok_a");
        assert_eq!(change.assets[0].amount, "60");
    }

    #[test]
    fn a_wallet_with_more_tokens_than_a_box_holds_gets_split_change() {
        let ids: Vec<String> = (0..123).map(|i| format!("tok{i:04}")).collect();
        let assets: Vec<(&str, &str)> = ids.iter().map(|id| (id.as_str(), "7")).collect();
        let inputs = vec![make_box("5000000000", assets)];
        let recipients = vec![RecipientSpec {
            ergo_tree: RECIPIENT_TREE.into(),
            amount_nano_erg: 1_000_000_000,
            tokens: vec![],
        }];
        let built =
            build_multi_send_tx_with_fee(&inputs, &recipients, CHANGE_TREE, 1_100_000, 1).unwrap();
        let change: Vec<_> = built
            .unsigned_tx
            .outputs
            .iter()
            .filter(|o| o.ergo_tree == CHANGE_TREE)
            .collect();
        assert_eq!(change.len(), 2);
        assert!(change
            .iter()
            .all(|o| o.assets.len() <= crate::MAX_TOKENS_PER_BOX));
        assert_eq!(change.iter().map(|o| o.assets.len()).sum::<usize>(), 123);
        let out_total: i64 = built
            .unsigned_tx
            .outputs
            .iter()
            .map(|o| o.value.parse::<i64>().unwrap())
            .sum();
        assert_eq!(out_total, 5_000_000_000);
    }

    #[test]
    fn a_large_recipient_bundle_is_split_and_funded_at_each_box_floor() {
        let ids: Vec<String> = (0..123).map(|i| format!("{i:064x}")).collect();
        let inputs = vec![make_box(
            "5000000000",
            ids.iter().map(|id| (id.as_str(), "7")).collect(),
        )];
        let mut recipient = RecipientSpec {
            ergo_tree: RECIPIENT_TREE.into(),
            amount_nano_erg: MIN_BOX_VALUE,
            tokens: ids.iter().map(|id| (id.clone(), 7)).collect(),
        };
        let minimum = recipient.minimum_value().unwrap();
        assert!(minimum > 2 * MIN_BOX_VALUE as u64);
        let err = build_multi_send_tx_with_fee(
            &inputs,
            &[recipient.clone()],
            CHANGE_TREE,
            1_100_000,
            50000,
        )
        .unwrap_err();
        assert!(matches!(
            err,
            MultiSendError::RecipientTokensInsufficientErg { .. }
        ));
        recipient.amount_nano_erg = minimum as i64;
        let built =
            build_multi_send_tx_with_fee(&inputs, &[recipient], CHANGE_TREE, 1_100_000, 50000)
                .unwrap();
        let delivered: Vec<_> = built
            .unsigned_tx
            .outputs
            .iter()
            .filter(|output| output.ergo_tree == RECIPIENT_TREE)
            .collect();
        assert_eq!(delivered.len(), 2);
        assert_eq!(delivered.iter().map(|o| o.assets.len()).sum::<usize>(), 123);
        assert_eq!(
            delivered
                .iter()
                .map(|o| o.value.parse::<u64>().unwrap())
                .sum::<u64>(),
            minimum
        );
        for output in &delivered {
            let bytes = crate::box_bytes(
                &output.ergo_tree,
                &output.assets,
                &output.additional_registers,
            );
            assert!(bytes <= crate::MAX_BOX_BYTES);
            assert!(output.assets.len() <= crate::MAX_TOKENS_PER_BOX);
            assert!(
                output.value.parse::<u64>().unwrap()
                    >= crate::min_value_for(bytes, MIN_BOX_VALUE as u64)
            );
            assert!(output.assets.iter().all(|asset| asset.amount == "7"));
        }
        assert_eq!(
            built
                .unsigned_tx
                .outputs
                .iter()
                .map(|o| o.value.parse::<i64>().unwrap())
                .sum::<i64>(),
            5_000_000_000
        );
    }

    #[test]
    fn rejects_unheld_tokens_and_overspending_across_recipients() {
        let inputs = vec![make_box("5000000000", vec![("tok_a", "10")])];
        for recipients in [
            vec![RecipientSpec::with_token(
                RECIPIENT_TREE.into(),
                MIN_BOX_VALUE,
                Some(("missing".into(), 1)),
            )],
            vec![RecipientSpec::with_token(
                RECIPIENT_TREE.into(),
                MIN_BOX_VALUE,
                Some(("tok_a".into(), 11)),
            )],
            vec![
                RecipientSpec::with_token(
                    RECIPIENT_TREE.into(),
                    MIN_BOX_VALUE,
                    Some(("tok_a".into(), 6)),
                ),
                RecipientSpec::with_token(
                    RECIPIENT_TREE.into(),
                    MIN_BOX_VALUE,
                    Some(("tok_a".into(), 6)),
                ),
            ],
        ] {
            let err =
                build_multi_send_tx_with_fee(&inputs, &recipients, CHANGE_TREE, 1_100_000, 50000)
                    .unwrap_err();
            assert!(matches!(err, MultiSendError::InsufficientTokens { .. }));
        }
    }

    #[test]
    fn rejects_duplicate_amount_overflow_and_signed_amount_wrap() {
        let inputs = vec![make_box("5000000000", vec![("tok_a", "10")])];
        for amounts in [vec![u64::MAX, 1], vec![i64::MAX as u64 + 1]] {
            let recipient = RecipientSpec {
                ergo_tree: RECIPIENT_TREE.into(),
                amount_nano_erg: MIN_BOX_VALUE,
                tokens: amounts
                    .into_iter()
                    .map(|amount| ("tok_a".into(), amount))
                    .collect(),
            };
            let err =
                build_multi_send_tx_with_fee(&inputs, &[recipient], CHANGE_TREE, 1_100_000, 50000)
                    .unwrap_err();
            assert!(matches!(
                err,
                MultiSendError::TokenTotalOverflow { .. }
                    | MultiSendError::TokenAmountOutOfRange { .. }
            ));
        }
    }
}
