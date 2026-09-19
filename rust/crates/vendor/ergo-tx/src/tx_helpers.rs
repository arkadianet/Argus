//! Shared transaction building helpers.

use crate::box_selector::{self, BoxSelectorError, SelectedInputs};
use crate::eip12::{Eip12Asset, Eip12InputBox, Eip12Output};

pub const MIN_CHANGE_VALUE: u64 = 1_000_000;

/// Distinct tokens one box can carry: `ErgoBox::MAX_TOKENS_COUNT` in
/// sigma-rust and `ErgoBox.MaxTokens` on the node. A candidate above it
/// fails to build, so every change box is laid out under this cap.
pub const MAX_TOKENS_PER_BOX: usize = 122;

/// How many boxes `token_count` distinct tokens need under the cap; at
/// least one, so a token-free change box still counts.
pub fn boxes_for_tokens(token_count: usize) -> usize {
    token_count.div_ceil(MAX_TOKENS_PER_BOX).max(1)
}

/// Lay `tokens` out over as many boxes as the cap requires, all paying to
/// `ergo_tree` and worth `value` in total. Every extra box gets
/// `min_box_value`; the first box carries the remainder, so callers that
/// lead with a specific asset (a swap output) keep it in the first box.
/// Fails when `value` cannot fund the extra boxes plus a first box worth
/// `min_box_value`.
pub fn token_outputs(
    value: u64,
    ergo_tree: &str,
    tokens: Vec<Eip12Asset>,
    current_height: i32,
    min_box_value: u64,
) -> Result<Vec<Eip12Output>, ChangeOutputError> {
    let boxes = boxes_for_tokens(tokens.len());
    let extras = (boxes - 1) as u64;
    let reserved = extras * min_box_value;
    let first_min = if tokens.is_empty() { 0 } else { min_box_value };
    if value < reserved + first_min {
        return Err(ChangeOutputError {
            min_value: reserved + first_min,
            available: value,
        });
    }
    let mut chunks = if tokens.is_empty() {
        vec![vec![]]
    } else {
        tokens
            .chunks(MAX_TOKENS_PER_BOX)
            .map(|c| c.to_vec())
            .collect::<Vec<_>>()
    };
    let first = chunks.remove(0);
    let mut outputs = Vec::with_capacity(boxes);
    outputs.push(Eip12Output::change(
        (value - reserved) as i64,
        ergo_tree,
        first,
        current_height,
    ));
    for chunk in chunks {
        outputs.push(Eip12Output::change(
            min_box_value as i64,
            ergo_tree,
            chunk,
            current_height,
        ));
    }
    Ok(outputs)
}

#[derive(Debug, Clone)]
pub struct ChangeOutputError {
    pub min_value: u64,
    pub available: u64,
}

impl std::fmt::Display for ChangeOutputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Change tokens exist but not enough ERG for change box (need {}, have {})",
            self.min_value, self.available
        )
    }
}

impl std::error::Error for ChangeOutputError {}

pub fn append_change_output(
    outputs: &mut Vec<Eip12Output>,
    selected: &SelectedInputs,
    erg_used: u64,
    spent_tokens: &[(&str, u64)],
    user_ergo_tree: &str,
    current_height: i32,
    min_change_value: u64,
) -> Result<(), ChangeOutputError> {
    let change_erg = selected.total_erg.saturating_sub(erg_used);

    let change_tokens = if spent_tokens.len() == 1 {
        box_selector::collect_change_tokens(
            &selected.boxes,
            Some((spent_tokens[0].0, spent_tokens[0].1)),
        )
    } else if spent_tokens.is_empty() {
        box_selector::collect_change_tokens(&selected.boxes, None)
    } else {
        box_selector::collect_multi_change_tokens(&selected.boxes, spent_tokens)
    };

    if change_erg >= min_change_value || !change_tokens.is_empty() {
        outputs.extend(token_outputs(
            change_erg,
            user_ergo_tree,
            change_tokens,
            current_height,
            min_change_value,
        )?);
    }

    Ok(())
}

pub fn select_inputs_for_spend(
    utxos: &[Eip12InputBox],
    required_erg: u64,
    token: Option<(&str, u64)>,
) -> Result<SelectedInputs, BoxSelectorError> {
    match token {
        Some((token_id, amount)) => {
            box_selector::select_token_boxes(utxos, token_id, amount, required_erg)
        }
        None => box_selector::select_erg_boxes(utxos, required_erg),
    }
}

pub fn select_inputs_for_multi_spend(
    utxos: &[Eip12InputBox],
    required_erg: u64,
    tokens: &[(&str, u64)],
) -> Result<SelectedInputs, BoxSelectorError> {
    match tokens.len() {
        0 => box_selector::select_erg_boxes(utxos, required_erg),
        1 => box_selector::select_token_boxes(utxos, tokens[0].0, tokens[0].1, required_erg),
        _ => box_selector::select_multi_token_boxes(utxos, tokens, required_erg),
    }
}

pub fn fee_output(fee: i64, height: i32) -> Eip12Output {
    Eip12Output::fee(fee, height)
}

pub use crate::dev_fee::{append_dev_fee_output, dev_fee_budget, DevFeeConfig, DevFeeError};

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn mock_utxo(box_id: &str, value: u64, assets: Vec<(&str, u64)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: box_id.to_string(),
            transaction_id: "tx123".to_string(),
            index: 0,
            value: value.to_string(),
            ergo_tree: "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
                .to_string(),
            assets: assets
                .into_iter()
                .map(|(id, amt)| Eip12Asset {
                    token_id: id.to_string(),
                    amount: amt.to_string(),
                })
                .collect(),
            creation_height: 1000,
            additional_registers: HashMap::new(),
            extension: HashMap::new(),
        }
    }

    #[test]
    fn test_append_change_output_erg_only() {
        let selected = SelectedInputs {
            boxes: vec![mock_utxo("box1", 5_000_000_000, vec![])],
            total_erg: 5_000_000_000,
            token_amount: 0,
        };

        let mut outputs = vec![];
        append_change_output(
            &mut outputs,
            &selected,
            3_000_000_000,
            &[],
            "0008cd...",
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();

        assert_eq!(outputs.len(), 1);
        assert_eq!(outputs[0].value, "2000000000");
    }

    #[test]
    fn test_append_change_output_no_change_needed() {
        let selected = SelectedInputs {
            boxes: vec![mock_utxo("box1", 2_100_000, vec![])],
            total_erg: 2_100_000,
            token_amount: 0,
        };

        let mut outputs = vec![];
        append_change_output(
            &mut outputs,
            &selected,
            2_100_000,
            &[],
            "0008cd...",
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();

        assert_eq!(outputs.len(), 0);
    }

    #[test]
    fn test_append_change_output_with_tokens() {
        let selected = SelectedInputs {
            boxes: vec![mock_utxo("box1", 5_000_000_000, vec![("tokenA", 100)])],
            total_erg: 5_000_000_000,
            token_amount: 100,
        };

        let mut outputs = vec![];
        append_change_output(
            &mut outputs,
            &selected,
            3_000_000_000,
            &[("tokenA", 60)],
            "0008cd...",
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();

        assert_eq!(outputs.len(), 1);
        assert_eq!(outputs[0].assets.len(), 1);
        assert_eq!(outputs[0].assets[0].amount, "40");
    }

    #[test]
    fn test_append_change_output_error_tokens_without_erg() {
        let selected = SelectedInputs {
            boxes: vec![mock_utxo("box1", 2_100_000, vec![("tokenA", 100)])],
            total_erg: 2_100_000,
            token_amount: 100,
        };

        let result = append_change_output(
            &mut vec![],
            &selected,
            2_100_000,         // all ERG used, 0 change
            &[("tokenA", 50)], // but 50 tokens left over
            "0008cd...",
            1000,
            MIN_CHANGE_VALUE,
        );

        assert!(result.is_err());
    }

    #[test]
    fn test_select_inputs_for_spend_erg() {
        let utxos = vec![mock_utxo("box1", 5_000_000_000, vec![])];
        let result = select_inputs_for_spend(&utxos, 2_000_000_000, None).unwrap();
        assert_eq!(result.total_erg, 5_000_000_000);
    }

    #[test]
    fn test_select_inputs_for_spend_token() {
        let utxos = vec![mock_utxo("box1", 5_000_000_000, vec![("tokenA", 100)])];
        let result = select_inputs_for_spend(&utxos, 1_000_000_000, Some(("tokenA", 50))).unwrap();
        assert_eq!(result.token_amount, 100);
    }

    #[test]
    fn test_select_inputs_for_multi_spend() {
        let utxos = vec![
            mock_utxo("box1", 3_000_000_000, vec![("tokenA", 100)]),
            mock_utxo("box2", 2_000_000_000, vec![("tokenB", 200)]),
        ];
        let result = select_inputs_for_multi_spend(
            &utxos,
            1_000_000_000,
            &[("tokenA", 50), ("tokenB", 100)],
        )
        .unwrap();
        assert_eq!(result.boxes.len(), 2);
    }

    fn many_tokens(n: usize) -> Vec<(String, u64)> {
        (0..n).map(|i| (format!("tok{i:04}"), 1)).collect()
    }

    #[test]
    fn change_with_more_tokens_than_a_box_holds_is_split_across_boxes() {
        let toks = many_tokens(150);
        let assets: Vec<(&str, u64)> = toks.iter().map(|(id, a)| (id.as_str(), *a)).collect();
        let selected = SelectedInputs {
            boxes: vec![mock_utxo("box1", 5_000_000_000, assets)],
            total_erg: 5_000_000_000,
            token_amount: 0,
        };
        let mut outputs = vec![];
        append_change_output(
            &mut outputs,
            &selected,
            1_000_000_000,
            &[],
            "0008cd...",
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();
        assert_eq!(outputs.len(), 2);
        assert_eq!(outputs[0].assets.len(), MAX_TOKENS_PER_BOX);
        assert_eq!(outputs[1].assets.len(), 150 - MAX_TOKENS_PER_BOX);
        assert_eq!(
            outputs[0].value,
            (4_000_000_000 - MIN_CHANGE_VALUE).to_string()
        );
        assert_eq!(outputs[1].value, MIN_CHANGE_VALUE.to_string());
        let mut ids: Vec<&str> = outputs
            .iter()
            .flat_map(|o| o.assets.iter().map(|a| a.token_id.as_str()))
            .collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), 150, "every token lands in exactly one box");
    }

    #[test]
    fn split_change_needs_a_min_box_value_per_extra_box() {
        let toks = many_tokens(123);
        let assets: Vec<(&str, u64)> = toks.iter().map(|(id, a)| (id.as_str(), *a)).collect();
        let selected = SelectedInputs {
            boxes: vec![mock_utxo("box1", 2_500_000, assets)],
            total_erg: 2_500_000,
            token_amount: 0,
        };
        let err = append_change_output(
            &mut vec![],
            &selected,
            1_000_000,
            &[],
            "0008cd...",
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap_err();
        assert_eq!(err.min_value, 2 * MIN_CHANGE_VALUE);
        assert_eq!(err.available, 1_500_000);
    }

    #[test]
    fn token_outputs_puts_the_remainder_in_the_first_box() {
        let assets: Vec<Eip12Asset> = many_tokens(245)
            .into_iter()
            .map(|(id, a)| Eip12Asset::new(id, a as i64))
            .collect();
        let outs = token_outputs(10_000_000, "0008cd...", assets, 1000, MIN_CHANGE_VALUE).unwrap();
        assert_eq!(outs.len(), 3);
        assert_eq!(outs[0].value, "8000000");
        assert_eq!(outs[1].value, "1000000");
        assert_eq!(outs[2].value, "1000000");
        assert_eq!(outs[2].assets.len(), 1);
        assert!(
            token_outputs(2_999_999, "0008cd...", vec![], 1000, MIN_CHANGE_VALUE)
                .unwrap()
                .len()
                == 1
        );
    }
}
