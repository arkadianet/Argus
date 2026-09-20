//! Shared transaction building helpers.

use crate::box_selector::{self, BoxSelectorError, SelectedInputs};
use crate::eip12::{Eip12Asset, Eip12InputBox, Eip12Output};
use std::collections::HashMap;

pub const MIN_CHANGE_VALUE: u64 = 1_000_000;

/// Distinct tokens one change box is packed with, at most. The node's
/// `ErgoBox.MaxTokens` is 255, but sigma-rust refuses to build a candidate
/// above `ErgoBox::MAX_TOKENS_COUNT = 122`, and the binding limit is bytes:
/// `MAX_BOX_BYTES` is reached well before 122 tokens with real amounts, so
/// `token_outputs` packs by size and this count is only the ceiling.
pub const MAX_TOKENS_PER_BOX: usize = 122;

/// Selection passes a builder makes before giving up: each extra change box
/// costs ERG the previous pass did not budget for, and the boxes that ERG
/// comes from can carry tokens of their own.
pub const MAX_SELECTION_PASSES: usize = 4;

/// The node's box-size limit (`MaxBoxSize`), counting the whole serialized
/// box: candidate plus transaction id and index.
pub const MAX_BOX_BYTES: usize = 4096;

/// The node's dust rule (`minValuePerByte`): a box must carry at least this
/// many nanoERG per serialized byte.
pub const NANO_PER_BYTE: u64 = 360;

/// Headroom kept under `MAX_BOX_BYTES`, since `box_bytes` is an estimate.
const BOX_BYTES_MARGIN: usize = 64;

fn vlq_len(mut n: u64) -> usize {
    let mut bytes = 1;
    while n >= 0x80 {
        n >>= 7;
        bytes += 1;
    }
    bytes
}

/// Upper bound on the serialized size of a box paying to `ergo_tree_hex`
/// with these tokens and registers: the value at its widest, the tree, the
/// creation height, each token's 32-byte id and VLQ amount, the registers,
/// and the 34 bytes of transaction id and index the node counts too.
pub fn box_bytes(
    ergo_tree_hex: &str,
    tokens: &[Eip12Asset],
    registers: &HashMap<String, String>,
) -> usize {
    let value = 9;
    let tree = ergo_tree_hex.len() / 2;
    let height = 5;
    let token_bytes: usize = tokens
        .iter()
        .map(|t| 32 + vlq_len(t.amount.parse::<u64>().unwrap_or(u64::MAX)))
        .sum();
    let register_bytes: usize = registers.values().map(|v| v.len() / 2).sum();
    let id_and_index = 34;
    value
        + tree
        + height
        + vlq_len(tokens.len() as u64)
        + token_bytes
        + 1
        + register_bytes
        + id_and_index
}

/// The least ERG a box of `bytes` may carry: the per-byte floor, or
/// `min_box_value` when that is higher.
pub fn min_value_for(bytes: usize, min_box_value: u64) -> u64 {
    (bytes as u64 * NANO_PER_BYTE).max(min_box_value)
}

/// Split `tokens` into boxes that each stay under the token cap and, with
/// headroom, under the byte limit. Always returns at least one (possibly
/// empty) chunk.
fn pack_tokens(ergo_tree: &str, tokens: Vec<Eip12Asset>) -> Vec<Vec<Eip12Asset>> {
    let empty = HashMap::new();
    let limit = MAX_BOX_BYTES - BOX_BYTES_MARGIN;
    let mut chunks: Vec<Vec<Eip12Asset>> = vec![vec![]];
    for token in tokens {
        let current = chunks.last_mut().expect("one chunk always exists");
        current.push(token);
        let too_many = current.len() > MAX_TOKENS_PER_BOX;
        let too_big = box_bytes(ergo_tree, current, &empty) > limit;
        if (too_many || too_big) && current.len() > 1 {
            let token = current.pop().expect("just pushed");
            chunks.push(vec![token]);
        }
    }
    chunks
}

/// Lay `tokens` out over as many boxes as the node's limits require, all
/// paying to `ergo_tree` and worth `value` in total. A box stops taking
/// tokens at the count cap or the byte limit, whichever comes first. Every
/// extra box gets the least it may carry for its size (`min_value_for`);
/// the first box carries the remainder, so callers that lead with a
/// specific asset (a swap output) keep it in the first box. Fails when
/// `value` cannot fund the extra boxes plus the first box's own floor.
pub fn token_outputs(
    value: u64,
    ergo_tree: &str,
    tokens: Vec<Eip12Asset>,
    current_height: i32,
    min_box_value: u64,
) -> Result<Vec<Eip12Output>, ChangeOutputError> {
    let empty = HashMap::new();
    let mut chunks = pack_tokens(ergo_tree, tokens);
    let first = chunks.remove(0);
    let extras: Vec<(Vec<Eip12Asset>, u64)> = chunks
        .into_iter()
        .map(|chunk| {
            let floor = min_value_for(box_bytes(ergo_tree, &chunk, &empty), min_box_value);
            (chunk, floor)
        })
        .collect();
    let reserved: u64 = extras.iter().map(|(_, floor)| floor).sum();
    let first_min = if first.is_empty() {
        0
    } else {
        min_value_for(box_bytes(ergo_tree, &first, &empty), min_box_value)
    };
    if value < reserved + first_min {
        return Err(ChangeOutputError {
            min_value: reserved + first_min,
            available: value,
        });
    }
    let mut outputs = Vec::with_capacity(extras.len() + 1);
    outputs.push(Eip12Output::change(
        (value - reserved) as i64,
        ergo_tree,
        first,
        current_height,
    ));
    for (chunk, floor) in extras {
        outputs.push(Eip12Output::change(
            floor as i64,
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
            merge_assets(change_tokens),
            current_height,
            min_change_value,
        )?);
    }

    Ok(())
}

/// Sum amounts that share a token id, keeping first-appearance order, so a
/// box never lists the same token twice.
pub fn merge_assets(assets: Vec<Eip12Asset>) -> Vec<Eip12Asset> {
    let mut order: Vec<String> = Vec::new();
    let mut totals: HashMap<String, u64> = HashMap::new();
    for a in assets {
        let amount = a.amount.parse::<u64>().unwrap_or(0);
        match totals.get_mut(&a.token_id) {
            Some(t) => *t = t.saturating_add(amount),
            None => {
                order.push(a.token_id.clone());
                totals.insert(a.token_id, amount);
            }
        }
    }
    // Kept as the u64 string: a sum past `i64::MAX` cannot come from valid
    // inputs (a token's whole supply fits an i64), and if it ever did the
    // later conversion rejects it instead of a wrapped negative slipping by.
    order
        .into_iter()
        .map(|id| Eip12Asset {
            amount: totals[&id].to_string(),
            token_id: id,
        })
        .collect()
}

/// The user's side of a protocol action: `base` is the action's output to
/// the user (a swap output, LP tokens, a redeemed amount). With
/// `merge_change` the change rides in the same box, laid out under the
/// token cap with `base`'s assets first; otherwise `base` is followed by
/// the change boxes, and change ERG too small for a box of its own is
/// folded into `base` rather than lost to the miner.
pub fn user_outputs(
    base: Eip12Output,
    merge_change: bool,
    user_ergo_tree: &str,
    change_erg: u64,
    change_tokens: Vec<Eip12Asset>,
    current_height: i32,
    min_box_value: u64,
) -> Result<Vec<Eip12Output>, ChangeOutputError> {
    let base_value: u64 = base.value.parse().unwrap_or(0);
    if merge_change {
        let mut tokens = base.assets;
        tokens.extend(change_tokens);
        return token_outputs(
            base_value + change_erg,
            user_ergo_tree,
            merge_assets(tokens),
            current_height,
            min_box_value,
        );
    }

    let base = if change_erg > 0 && change_erg < min_box_value && change_tokens.is_empty() {
        Eip12Output {
            value: (base_value + change_erg).to_string(),
            ..base
        }
    } else {
        base
    };
    let mut outputs = vec![base];
    if change_erg >= min_box_value || !change_tokens.is_empty() {
        outputs.extend(token_outputs(
            change_erg,
            user_ergo_tree,
            merge_assets(change_tokens),
            current_height,
            min_box_value,
        )?);
    }
    Ok(outputs)
}

/// Why `select_and_lay_out` gave up.
#[derive(Debug, Clone)]
pub enum LayoutError {
    Selection(BoxSelectorError),
    Change(ChangeOutputError),
}

impl std::fmt::Display for LayoutError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LayoutError::Selection(e) => write!(f, "{e}"),
            LayoutError::Change(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for LayoutError {}

/// Select inputs for `erg_needed`, collect their change tokens, and lay the
/// user's outputs out under the token cap. Every extra change box costs ERG
/// the selection did not budget for, so when the layout is short the
/// selection is rerun with the shortfall added, up to `MAX_SELECTION_PASSES`.
/// `lay_out` receives the change ERG left over after `erg_needed` and the
/// change tokens.
pub fn select_and_lay_out(
    erg_needed: u64,
    select: impl Fn(u64) -> Result<SelectedInputs, BoxSelectorError>,
    change_tokens: impl Fn(&[Eip12InputBox]) -> Vec<Eip12Asset>,
    lay_out: impl Fn(u64, Vec<Eip12Asset>) -> Result<Vec<Eip12Output>, ChangeOutputError>,
) -> Result<(SelectedInputs, Vec<Eip12Output>), LayoutError> {
    let mut extra_erg: u64 = 0;
    for pass in 1..=MAX_SELECTION_PASSES {
        let selected = select(erg_needed + extra_erg).map_err(LayoutError::Selection)?;
        let change_erg = selected.total_erg.saturating_sub(erg_needed);
        let tokens = change_tokens(&selected.boxes);
        match lay_out(change_erg, tokens) {
            Ok(outputs) => return Ok((selected, outputs)),
            Err(short) if pass < MAX_SELECTION_PASSES => {
                extra_erg += short.min_value.saturating_sub(short.available);
            }
            Err(short) => return Err(LayoutError::Change(short)),
        }
    }
    unreachable!("the loop returns on its last pass")
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

    fn big_tokens(n: usize, amount: u64) -> Vec<Eip12Asset> {
        (0..n)
            .map(|i| Eip12Asset::new(format!("tok{i:04}"), amount as i64))
            .collect()
    }

    fn all_ids(outputs: &[Eip12Output]) -> Vec<&str> {
        let mut ids: Vec<&str> = outputs
            .iter()
            .flat_map(|o| o.assets.iter().map(|a| a.token_id.as_str()))
            .collect();
        ids.sort();
        ids.dedup();
        ids
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
        assert!(outputs.iter().all(|o| o.assets.len() <= MAX_TOKENS_PER_BOX));
        let extra_min = min_value_for(
            box_bytes("0008cd...", &outputs[1].assets, &HashMap::new()),
            MIN_CHANGE_VALUE,
        );
        assert_eq!(outputs[1].value, extra_min.to_string());
        assert_eq!(outputs[0].value, (4_000_000_000 - extra_min).to_string());
        assert_eq!(
            all_ids(&outputs).len(),
            150,
            "every token lands in exactly one box"
        );
    }

    #[test]
    fn a_change_box_never_exceeds_the_protocol_byte_limit() {
        // 122 tokens fit the count cap; with real amounts they do not fit
        // 4096 bytes. The node rejects the box, not the count.
        let outs = token_outputs(
            10_000_000_000,
            "0008cd...",
            big_tokens(122, 1_000_000_000),
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();
        assert!(outs.len() >= 2, "{} box(es)", outs.len());
        for o in &outs {
            let bytes = box_bytes("0008cd...", &o.assets, &o.additional_registers);
            assert!(bytes <= MAX_BOX_BYTES, "{bytes} bytes");
            let value: u64 = o.value.parse().unwrap();
            assert!(
                value >= bytes as u64 * NANO_PER_BYTE,
                "{value} nano for {bytes} bytes"
            );
        }
        assert_eq!(all_ids(&outs).len(), 122);
    }

    #[test]
    fn extra_boxes_carry_the_per_byte_floor_not_the_flat_minimum() {
        let outs = token_outputs(
            10_000_000_000,
            "0008cd...",
            big_tokens(200, 1_000_000_000),
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();
        let extra = &outs[1];
        let bytes = box_bytes("0008cd...", &extra.assets, &extra.additional_registers);
        assert!(
            bytes as u64 * NANO_PER_BYTE > MIN_CHANGE_VALUE,
            "the test box must be over the flat floor"
        );
        assert_eq!(extra.value, (bytes as u64 * NANO_PER_BYTE).to_string());
    }

    #[test]
    fn split_change_needs_the_floor_of_every_box() {
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
        let ok = token_outputs(
            10_000_000,
            "0008cd...",
            many_tokens(123)
                .into_iter()
                .map(|(id, a)| Eip12Asset::new(id, a as i64))
                .collect(),
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();
        let floors: u64 = ok
            .iter()
            .map(|o| {
                min_value_for(
                    box_bytes("0008cd...", &o.assets, &o.additional_registers),
                    MIN_CHANGE_VALUE,
                )
            })
            .sum();
        assert_eq!(err.min_value, floors);
        assert_eq!(err.available, 1_500_000);
    }

    #[test]
    fn token_outputs_puts_the_remainder_in_the_first_box() {
        let outs = token_outputs(
            10_000_000,
            "0008cd...",
            big_tokens(245, 1),
            1000,
            MIN_CHANGE_VALUE,
        )
        .unwrap();
        assert!(outs.len() >= 3);
        let extras: u64 = outs[1..]
            .iter()
            .map(|o| o.value.parse::<u64>().unwrap())
            .sum();
        assert_eq!(outs[0].value, (10_000_000 - extras).to_string());
        assert!(outs.last().unwrap().assets.len() < outs[0].assets.len());
        assert_eq!(all_ids(&outs).len(), 245);
        assert_eq!(
            token_outputs(2_999_999, "0008cd...", vec![], 1000, MIN_CHANGE_VALUE)
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn box_bytes_counts_the_id_and_index_and_the_vlq_amounts() {
        let one = vec![Eip12Asset::new("t", 1)];
        let big = vec![Eip12Asset::new("t", i64::MAX)];
        let tree = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
        let base = box_bytes(tree, &[], &HashMap::new());
        assert_eq!(box_bytes(tree, &one, &HashMap::new()), base + 33);
        assert_eq!(box_bytes(tree, &big, &HashMap::new()), base + 32 + 9);
        assert!(base > 36 + 34, "tree, tx id and index are all counted");
    }
}
