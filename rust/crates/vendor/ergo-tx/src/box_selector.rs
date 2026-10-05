//! UTXO selection utilities

use std::fmt;

use crate::eip12::{Eip12Asset, Eip12InputBox};

#[derive(Debug, Clone)]
pub enum BoxSelectorError {
    InsufficientErg {
        required: u64,
        available: u64,
    },
    InsufficientTokens {
        token_id: String,
        required: u64,
        available: u64,
    },
    InsufficientMultiTokens {
        shortfalls: Vec<(String, u64, u64)>,
    },
    /// Input totals exceeded u64 while selecting — refuse instead of
    /// recording a wrapped/saturated amount.
    TotalOverflow,
}

impl fmt::Display for BoxSelectorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BoxSelectorError::InsufficientErg {
                required,
                available,
            } => {
                write!(
                    f,
                    "Insufficient ERG: need {required} nanoERG, have {available}"
                )
            }
            BoxSelectorError::InsufficientTokens {
                token_id,
                required,
                available,
            } => {
                write!(
                    f,
                    "Insufficient token balance: need {required} of {token_id}, have {available}"
                )
            }
            BoxSelectorError::InsufficientMultiTokens { shortfalls } => {
                write!(f, "Insufficient token balances: ")?;
                for (i, (token_id, required, available)) in shortfalls.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(
                        f,
                        "{}: need {} have {}",
                        &token_id[..8.min(token_id.len())],
                        required,
                        available
                    )?;
                }
                Ok(())
            }
            BoxSelectorError::TotalOverflow => {
                write!(f, "Input totals exceed the representable range")
            }
        }
    }
}

impl std::error::Error for BoxSelectorError {}

#[derive(Debug, Clone)]
pub struct SelectedInputs {
    pub boxes: Vec<Eip12InputBox>,
    pub total_erg: u64,
    pub token_amount: u64,
}

/// Confirmed boxes with a lower creation height are spent first. Unknown
/// heights come last so a missing height cannot masquerade as an old box.
/// At the same height, prefer more value to avoid unnecessary inputs.
pub fn compare_box_age(a: &Eip12InputBox, b: &Eip12InputBox) -> std::cmp::Ordering {
    let height = |b: &Eip12InputBox| {
        if b.creation_height > 0 {
            b.creation_height
        } else {
            i32::MAX
        }
    };
    height(a).cmp(&height(b))
}

fn compare_age_and_value(a: &Eip12InputBox, b: &Eip12InputBox) -> std::cmp::Ordering {
    compare_box_age(a, b)
        .then_with(|| {
            b.value
                .parse::<u64>()
                .unwrap_or(0)
                .cmp(&a.value.parse::<u64>().unwrap_or(0))
        })
        .then_with(|| a.box_id.cmp(&b.box_id))
}

/// Prefer older eligible boxes to refresh their storage-rent age.
pub fn select_erg_boxes(
    utxos: &[Eip12InputBox],
    required_erg: u64,
) -> Result<SelectedInputs, BoxSelectorError> {
    let mut indices: Vec<usize> = (0..utxos.len()).collect();
    indices.sort_by(|&a, &b| {
        compare_age_and_value(&utxos[a], &utxos[b])
    });

    let mut selected = Vec::new();
    let mut total_erg: u64 = 0;

    for &idx in &indices {
        if total_erg >= required_erg {
            break;
        }
        let erg = utxos[idx].value.parse::<u64>().unwrap_or(0);
        selected.push(utxos[idx].clone());
        total_erg = total_erg
            .checked_add(erg)
            .ok_or(BoxSelectorError::TotalOverflow)?;
    }

    if total_erg < required_erg {
        let total_available: u64 = utxos
            .iter()
            .map(|u| u.value.parse::<u64>().unwrap_or(0))
            .sum();
        return Err(BoxSelectorError::InsufficientErg {
            required: required_erg,
            available: total_available,
        });
    }

    Ok(SelectedInputs {
        boxes: selected,
        total_erg,
        token_amount: 0,
    })
}

/// Pass 1: select older boxes with the token. Pass 2: top up ERG oldest first.
pub fn select_token_boxes(
    utxos: &[Eip12InputBox],
    token_id: &str,
    required_tokens: u64,
    min_erg: u64,
) -> Result<SelectedInputs, BoxSelectorError> {
    let mut token_indices: Vec<(usize, u64)> = utxos
        .iter()
        .enumerate()
        .filter_map(|(i, u)| {
            let tok_amount: u64 = u
                .assets
                .iter()
                .filter(|a| a.token_id == token_id)
                .map(|a| a.amount.parse::<u64>().unwrap_or(0))
                .sum();
            if tok_amount > 0 {
                Some((i, tok_amount))
            } else {
                None
            }
        })
        .collect();
    token_indices.sort_by(|&(a, amount_a), &(b, amount_b)| {
        compare_box_age(&utxos[a], &utxos[b])
            .then_with(|| amount_b.cmp(&amount_a))
            .then_with(|| compare_age_and_value(&utxos[a], &utxos[b]))
    });

    let mut selected_indices = Vec::new();
    let mut total_tokens: u64 = 0;
    let mut total_erg: u64 = 0;

    for &(idx, tok_amt) in &token_indices {
        if total_tokens >= required_tokens {
            break;
        }
        selected_indices.push(idx);
        total_tokens = total_tokens
            .checked_add(tok_amt)
            .ok_or(BoxSelectorError::TotalOverflow)?;
        total_erg = total_erg
            .checked_add(utxos[idx].value.parse::<u64>().unwrap_or(0))
            .ok_or(BoxSelectorError::TotalOverflow)?;
    }

    if total_tokens < required_tokens {
        let total_available: u64 = token_indices.iter().map(|(_, amt)| amt).sum();
        return Err(BoxSelectorError::InsufficientTokens {
            token_id: token_id.to_string(),
            required: required_tokens,
            available: total_available,
        });
    }

    if total_erg < min_erg {
        let mut erg_indices: Vec<(usize, u64)> = utxos
            .iter()
            .enumerate()
            .filter(|(i, _)| !selected_indices.contains(i))
            .map(|(i, u)| (i, u.value.parse::<u64>().unwrap_or(0)))
            .collect();
        erg_indices.sort_by(|&(a, _), &(b, _)| compare_age_and_value(&utxos[a], &utxos[b]));

        for &(idx, erg) in &erg_indices {
            if total_erg >= min_erg {
                break;
            }
            selected_indices.push(idx);
            total_erg = total_erg
                .checked_add(erg)
                .ok_or(BoxSelectorError::TotalOverflow)?;
        }

        if total_erg < min_erg {
            let total_available: u64 = utxos
                .iter()
                .map(|u| u.value.parse::<u64>().unwrap_or(0))
                .sum();
            return Err(BoxSelectorError::InsufficientErg {
                required: min_erg,
                available: total_available,
            });
        }
    }

    selected_indices.sort_by(|&a, &b| compare_age_and_value(&utxos[a], &utxos[b]));
    let boxes: Vec<Eip12InputBox> = selected_indices.iter().map(|&i| utxos[i].clone()).collect();

    Ok(SelectedInputs {
        boxes,
        total_erg,
        token_amount: total_tokens,
    })
}

/// Like `select_token_boxes` but for multiple token requirements simultaneously.
pub fn select_multi_token_boxes(
    utxos: &[Eip12InputBox],
    required_tokens: &[(&str, u64)],
    min_erg: u64,
) -> Result<SelectedInputs, BoxSelectorError> {
    use std::collections::HashMap;

    let mut remaining: HashMap<&str, u64> = required_tokens.iter().cloned().collect();

    let mut selected_indices: Vec<usize> = Vec::new();
    let mut total_erg: u64 = 0;

    // Age takes priority; at the same height prefer more required tokens.
    let mut scored_indices: Vec<(usize, usize)> = utxos
        .iter()
        .enumerate()
        .map(|(i, u)| {
            let useful_count = u
                .assets
                .iter()
                .filter(|a| remaining.contains_key(a.token_id.as_str()))
                .count();
            (i, useful_count)
        })
        .filter(|(_, count)| *count > 0)
        .collect();
    scored_indices.sort_by(|&(a, count_a), &(b, count_b)| {
        compare_box_age(&utxos[a], &utxos[b])
            .then_with(|| count_b.cmp(&count_a))
            .then_with(|| compare_age_and_value(&utxos[a], &utxos[b]))
    });

    for &(idx, _) in &scored_indices {
        if remaining.is_empty() {
            break;
        }

        let utxo = &utxos[idx];
        let mut useful = false;
        for asset in &utxo.assets {
            if let Some(need) = remaining.get_mut(asset.token_id.as_str()) {
                let amt = asset.amount.parse::<u64>().unwrap_or(0);
                if amt > 0 && *need > 0 {
                    useful = true;
                    if amt >= *need {
                        remaining.remove(asset.token_id.as_str());
                    } else {
                        *need -= amt;
                    }
                }
            }
        }

        if useful {
            selected_indices.push(idx);
            total_erg = total_erg
                .checked_add(utxo.value.parse::<u64>().unwrap_or(0))
                .ok_or(BoxSelectorError::TotalOverflow)?;
        }
    }

    if !remaining.is_empty() {
        let mut shortfalls: Vec<(String, u64, u64)> = Vec::new();
        for (token_id, still_need) in &remaining {
            let required = required_tokens
                .iter()
                .find(|(id, _)| id == token_id)
                .map(|(_, amt)| *amt)
                .unwrap_or(0);
            let available = required - still_need;
            shortfalls.push((token_id.to_string(), required, available));
        }
        return Err(BoxSelectorError::InsufficientMultiTokens { shortfalls });
    }

    if total_erg < min_erg {
        let mut erg_indices: Vec<(usize, u64)> = utxos
            .iter()
            .enumerate()
            .filter(|(i, _)| !selected_indices.contains(i))
            .map(|(i, u)| (i, u.value.parse::<u64>().unwrap_or(0)))
            .collect();
        erg_indices.sort_by(|&(a, _), &(b, _)| compare_age_and_value(&utxos[a], &utxos[b]));

        for &(idx, erg) in &erg_indices {
            if total_erg >= min_erg {
                break;
            }
            selected_indices.push(idx);
            total_erg = total_erg
                .checked_add(erg)
                .ok_or(BoxSelectorError::TotalOverflow)?;
        }

        if total_erg < min_erg {
            let total_available: u64 = utxos
                .iter()
                .map(|u| u.value.parse::<u64>().unwrap_or(0))
                .sum();
            return Err(BoxSelectorError::InsufficientErg {
                required: min_erg,
                available: total_available,
            });
        }
    }

    selected_indices.sort_by(|&a, &b| compare_age_and_value(&utxos[a], &utxos[b]));
    let boxes: Vec<Eip12InputBox> = selected_indices.iter().map(|&i| utxos[i].clone()).collect();

    Ok(SelectedInputs {
        boxes,
        total_erg,
        token_amount: 0,
    })
}

pub fn collect_multi_change_tokens(
    selected: &[Eip12InputBox],
    spent_tokens: &[(&str, u64)],
) -> Vec<Eip12Asset> {
    use std::collections::HashMap;

    let mut token_totals: HashMap<String, u64> = HashMap::new();
    for utxo in selected {
        for asset in &utxo.assets {
            let amount = asset.amount.parse::<u64>().unwrap_or(0);
            let entry = token_totals.entry(asset.token_id.clone()).or_insert(0);
            *entry = entry.saturating_add(amount);
        }
    }

    for &(token_id, amount) in spent_tokens {
        if let Some(total) = token_totals.get_mut(token_id) {
            if *total > amount {
                *total -= amount;
            } else {
                token_totals.remove(token_id);
            }
        }
    }

    token_totals
        .into_iter()
        .filter(|(_, amount)| *amount > 0)
        .map(|(token_id, amount)| Eip12Asset {
            token_id,
            amount: amount.to_string(),
        })
        .collect()
}

/// Single-token variant of `collect_multi_change_tokens`.
pub fn collect_change_tokens(
    selected: &[Eip12InputBox],
    spent_token: Option<(&str, u64)>,
) -> Vec<Eip12Asset> {
    use std::collections::HashMap;

    let mut token_totals: HashMap<String, u64> = HashMap::new();
    for utxo in selected {
        for asset in &utxo.assets {
            let amount = asset.amount.parse::<u64>().unwrap_or(0);
            let entry = token_totals.entry(asset.token_id.clone()).or_insert(0);
            *entry = entry.saturating_add(amount);
        }
    }

    if let Some((token_id, amount)) = spent_token {
        if let Some(total) = token_totals.get_mut(token_id) {
            if *total > amount {
                *total -= amount;
            } else {
                token_totals.remove(token_id);
            }
        }
    }

    token_totals
        .into_iter()
        .filter(|(_, amount)| *amount > 0)
        .map(|(token_id, amount)| Eip12Asset {
            token_id,
            amount: amount.to_string(),
        })
        .collect()
}

pub fn select_inputs<'a>(
    utxos: &'a [Eip12InputBox],
    required_erg: i64,
    required_token: Option<(&str, i64)>,
) -> Vec<&'a Eip12InputBox> {
    let mut selected: Vec<&Eip12InputBox> = Vec::new();
    let mut total_erg: i64 = 0;
    let mut total_token: i64 = 0;

    if let Some((token_id, token_amount)) = required_token {
        for utxo in utxos {
            let has_token = utxo.assets.iter().any(|a| a.token_id == token_id);
            if has_token {
                selected.push(utxo);
                total_erg += utxo.value.parse::<i64>().unwrap_or(0);
                total_token += utxo
                    .assets
                    .iter()
                    .filter(|a| a.token_id == token_id)
                    .map(|a| a.amount.parse::<i64>().unwrap_or(0))
                    .sum::<i64>();
            }
            if total_token >= token_amount && total_erg >= required_erg {
                return selected;
            }
        }
    }

    for utxo in utxos {
        if selected.iter().any(|u| u.box_id == utxo.box_id) {
            continue;
        }
        selected.push(utxo);
        total_erg += utxo.value.parse::<i64>().unwrap_or(0);
        if total_erg >= required_erg {
            break;
        }
    }

    selected
}

pub fn total_erg_value(inputs: &[&Eip12InputBox]) -> i64 {
    inputs
        .iter()
        .map(|b| b.value.parse::<i64>().unwrap_or(0))
        .sum()
}

pub fn total_token_amount(inputs: &[&Eip12InputBox], token_id: &str) -> i64 {
    inputs
        .iter()
        .flat_map(|b| b.assets.iter())
        .filter(|a| a.token_id == token_id)
        .map(|a| a.amount.parse::<i64>().unwrap_or(0))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn mock_utxo(box_id: &str, value: i64, assets: Vec<(&str, i64)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: box_id.to_string(),
            transaction_id: "tx123".to_string(),
            index: 0,
            value: value.to_string(),
            ergo_tree: "0008cd...".to_string(),
            assets: assets
                .into_iter()
                .map(|(id, amt)| crate::eip12::Eip12Asset {
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
    fn test_select_erg_only() {
        let utxos = vec![
            mock_utxo("box1", 1_000_000_000, vec![]),
            mock_utxo("box2", 2_000_000_000, vec![]),
        ];

        let selected = select_inputs(&utxos, 1_500_000_000, None);
        assert_eq!(selected.len(), 2);
        assert_eq!(total_erg_value(&selected), 3_000_000_000);
    }

    #[test]
    fn test_select_with_token() {
        let utxos = vec![
            mock_utxo("box1", 1_000_000_000, vec![("token1", 100)]),
            mock_utxo("box2", 2_000_000_000, vec![]),
        ];

        let selected = select_inputs(&utxos, 500_000_000, Some(("token1", 50)));
        assert_eq!(selected.len(), 1);
        assert_eq!(total_token_amount(&selected, "token1"), 100);
    }

    #[test]
    fn test_select_needs_more_erg() {
        let utxos = vec![
            mock_utxo("box1", 500_000_000, vec![("token1", 100)]),
            mock_utxo("box2", 2_000_000_000, vec![]),
        ];

        let selected = select_inputs(&utxos, 1_500_000_000, Some(("token1", 50)));
        assert_eq!(selected.len(), 2);
        assert_eq!(total_erg_value(&selected), 2_500_000_000);
    }

    #[test]
    fn test_select_erg_boxes_single() {
        let utxos = vec![
            mock_utxo("box1", 5_000_000_000, vec![]),
            mock_utxo("box2", 3_000_000_000, vec![]),
        ];

        let result = select_erg_boxes(&utxos, 4_000_000_000).unwrap();
        // Should pick the largest box first (5 ERG) which is enough
        assert_eq!(result.boxes.len(), 1);
        assert_eq!(result.total_erg, 5_000_000_000);
        assert_eq!(result.boxes[0].box_id, "box1");
    }

    #[test]
    fn older_erg_boxes_are_refreshed_before_a_large_new_box() {
        let mut old = mock_utxo("old", 2_000_000, vec![]);
        old.creation_height = 10;
        let mut middle = mock_utxo("middle", 3_000_000, vec![]);
        middle.creation_height = 20;
        let mut new = mock_utxo("new", 100_000_000, vec![]);
        new.creation_height = 30;
        for inputs in [vec![new.clone(), middle.clone(), old.clone()], vec![old.clone(), new.clone(), middle.clone()]] {
            let selected = select_erg_boxes(&inputs, 4_000_000).unwrap();
            assert_eq!(selected.boxes.iter().map(|b| b.box_id.as_str()).collect::<Vec<_>>(), vec!["old", "middle"]);
            assert_eq!(selected.total_erg, 5_000_000);
        }
    }

    #[test]
    fn token_selection_and_erg_funding_both_prefer_older_boxes() {
        let mut old_token = mock_utxo("old-token", 1_000_000, vec![("T", 5)]);
        old_token.creation_height = 10;
        let mut new_token = mock_utxo("new-token", 1_000_000, vec![("T", 100)]);
        new_token.creation_height = 50;
        let mut old_funding = mock_utxo("old-funding", 2_000_000, vec![]);
        old_funding.creation_height = 20;
        let mut new_funding = mock_utxo("new-funding", 100_000_000, vec![]);
        new_funding.creation_height = 60;
        let selected = select_token_boxes(&[new_token, new_funding, old_funding, old_token], "T", 5, 3_000_000).unwrap();
        assert_eq!(selected.boxes.iter().map(|b| b.box_id.as_str()).collect::<Vec<_>>(), vec!["old-token", "old-funding"]);
        assert_eq!(selected.token_amount, 5);
    }

    #[test]
    fn multi_token_selection_prefers_age_over_a_new_combined_box() {
        let mut old_a = mock_utxo("old-a", 2_000_000, vec![("A", 5)]);
        old_a.creation_height = 10;
        let mut old_b = mock_utxo("old-b", 2_000_000, vec![("B", 6)]);
        old_b.creation_height = 20;
        let mut new = mock_utxo("new", 100_000_000, vec![("A", 100), ("B", 100)]);
        new.creation_height = 30;
        let selected = select_multi_token_boxes(&[new, old_b, old_a], &[("A", 5), ("B", 6)], 3_000_000).unwrap();
        assert_eq!(selected.boxes.iter().map(|b| b.box_id.as_str()).collect::<Vec<_>>(), vec!["old-a", "old-b"]);
    }

    #[test]
    fn unknown_heights_cannot_preempt_confirmed_boxes() {
        let unknown = mock_utxo("unknown", 100_000_000, vec![]);
        let known = mock_utxo("known", 2_000_000, vec![]);
        for height in [0, -1] {
            let mut unknown = unknown.clone();
            unknown.creation_height = height;
            let selected = select_erg_boxes(&[unknown, known.clone()], 1_000_000).unwrap();
            assert_eq!(selected.boxes[0].box_id, "known");
        }
    }

    #[test]
    fn test_select_erg_boxes_multiple() {
        let utxos = vec![
            mock_utxo("box1", 2_000_000_000, vec![]),
            mock_utxo("box2", 3_000_000_000, vec![]),
            mock_utxo("box3", 1_000_000_000, vec![]),
        ];

        let result = select_erg_boxes(&utxos, 4_000_000_000).unwrap();
        // Should pick box2 (3 ERG) then box1 (2 ERG) = 5 ERG
        assert_eq!(result.boxes.len(), 2);
        assert_eq!(result.total_erg, 5_000_000_000);
    }

    #[test]
    fn test_select_erg_boxes_insufficient() {
        let utxos = vec![mock_utxo("box1", 1_000_000_000, vec![])];

        let result = select_erg_boxes(&utxos, 5_000_000_000);
        assert!(result.is_err());
        match result.unwrap_err() {
            BoxSelectorError::InsufficientErg {
                required,
                available,
            } => {
                assert_eq!(required, 5_000_000_000);
                assert_eq!(available, 1_000_000_000);
            }
            _ => panic!("Wrong error type"),
        }
    }

    #[test]
    fn test_select_erg_boxes_exact() {
        let utxos = vec![mock_utxo("box1", 5_000_000_000, vec![])];

        let result = select_erg_boxes(&utxos, 5_000_000_000).unwrap();
        assert_eq!(result.boxes.len(), 1);
        assert_eq!(result.total_erg, 5_000_000_000);
    }

    #[test]
    fn test_select_token_boxes_basic() {
        let utxos = vec![
            mock_utxo("box1", 2_000_000_000, vec![("token1", 100)]),
            mock_utxo("box2", 5_000_000_000, vec![]),
        ];

        let result = select_token_boxes(&utxos, "token1", 50, 1_000_000_000).unwrap();
        // box1 has the token and enough ERG
        assert_eq!(result.boxes.len(), 1);
        assert_eq!(result.token_amount, 100);
        assert_eq!(result.total_erg, 2_000_000_000);
    }

    #[test]
    fn test_select_token_boxes_needs_erg() {
        let utxos = vec![
            mock_utxo("box1", 500_000, vec![("token1", 100)]),
            mock_utxo("box2", 5_000_000_000, vec![]),
        ];

        let result = select_token_boxes(&utxos, "token1", 50, 1_000_000_000).unwrap();
        // Needs box1 for tokens + box2 for ERG
        assert_eq!(result.boxes.len(), 2);
        assert_eq!(result.token_amount, 100);
        assert!(result.total_erg >= 1_000_000_000);
    }

    #[test]
    fn test_select_token_boxes_insufficient_tokens() {
        let utxos = vec![mock_utxo("box1", 5_000_000_000, vec![("token1", 10)])];

        let result = select_token_boxes(&utxos, "token1", 100, 1_000_000);
        assert!(result.is_err());
        match result.unwrap_err() {
            BoxSelectorError::InsufficientTokens {
                required,
                available,
                ..
            } => {
                assert_eq!(required, 100);
                assert_eq!(available, 10);
            }
            _ => panic!("Wrong error type"),
        }
    }

    #[test]
    fn test_select_token_boxes_no_token_boxes() {
        let utxos = vec![mock_utxo("box1", 5_000_000_000, vec![])];

        let result = select_token_boxes(&utxos, "token1", 100, 1_000_000);
        assert!(result.is_err());
        match result.unwrap_err() {
            BoxSelectorError::InsufficientTokens { available, .. } => {
                assert_eq!(available, 0);
            }
            _ => panic!("Wrong error type"),
        }
    }

    #[test]
    fn test_select_token_boxes_multiple_token_holders() {
        let utxos = vec![
            mock_utxo("box1", 1_000_000_000, vec![("token1", 30)]),
            mock_utxo("box2", 2_000_000_000, vec![("token1", 50)]),
            mock_utxo("box3", 3_000_000_000, vec![]),
        ];

        let result = select_token_boxes(&utxos, "token1", 60, 2_000_000_000).unwrap();
        // Should pick box2 (50 tokens, largest) then box1 (30 tokens) = 80 tokens
        assert_eq!(result.token_amount, 80);
        assert_eq!(result.total_erg, 3_000_000_000);
    }

    #[test]
    fn test_collect_change_tokens_no_spent() {
        let boxes = vec![mock_utxo(
            "box1",
            1_000_000,
            vec![("tokenA", 100), ("tokenB", 200)],
        )];

        let change = collect_change_tokens(&boxes, None);
        assert_eq!(change.len(), 2);
        let total_a: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenA")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        assert_eq!(total_a, 100);
    }

    #[test]
    fn test_collect_change_tokens_with_spent() {
        let boxes = vec![mock_utxo("box1", 1_000_000, vec![("tokenA", 100)])];

        let change = collect_change_tokens(&boxes, Some(("tokenA", 60)));
        assert_eq!(change.len(), 1);
        assert_eq!(change[0].amount, "40");
    }

    #[test]
    fn test_collect_change_tokens_exact_spend() {
        let boxes = vec![mock_utxo("box1", 1_000_000, vec![("tokenA", 100)])];

        let change = collect_change_tokens(&boxes, Some(("tokenA", 100)));
        assert!(change.is_empty());
    }

    #[test]
    fn test_collect_change_tokens_multiple_boxes() {
        let boxes = vec![
            mock_utxo("box1", 1_000_000, vec![("tokenA", 50)]),
            mock_utxo("box2", 2_000_000, vec![("tokenA", 70), ("tokenB", 30)]),
        ];

        let change = collect_change_tokens(&boxes, Some(("tokenA", 80)));
        // tokenA: 50 + 70 - 80 = 40
        // tokenB: 30
        let token_a: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenA")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        let token_b: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenB")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        assert_eq!(token_a, 40);
        assert_eq!(token_b, 30);
    }

    #[test]
    fn test_error_display() {
        let err = BoxSelectorError::InsufficientErg {
            required: 5_000_000_000,
            available: 1_000_000_000,
        };
        let msg = err.to_string();
        assert!(msg.contains("Insufficient ERG"));
        assert!(msg.contains("5000000000"));
        assert!(msg.contains("1000000000"));

        let err = BoxSelectorError::InsufficientTokens {
            token_id: "abc123".to_string(),
            required: 100,
            available: 50,
        };
        let msg = err.to_string();
        assert!(msg.contains("Insufficient token"));
        assert!(msg.contains("abc123"));
    }

    #[test]
    fn test_select_multi_token_basic() {
        let utxos = vec![
            mock_utxo("box1", 2_000_000_000, vec![("tokenA", 100)]),
            mock_utxo("box2", 3_000_000_000, vec![("tokenB", 200)]),
            mock_utxo("box3", 1_000_000_000, vec![]),
        ];

        let result =
            select_multi_token_boxes(&utxos, &[("tokenA", 50), ("tokenB", 100)], 1_000_000_000)
                .unwrap();
        // Should pick box1 (tokenA) and box2 (tokenB)
        assert_eq!(result.boxes.len(), 2);
        assert!(result.total_erg >= 1_000_000_000);
    }

    #[test]
    fn test_select_multi_token_same_box() {
        let utxos = vec![mock_utxo(
            "box1",
            5_000_000_000,
            vec![("tokenA", 100), ("tokenB", 200)],
        )];

        let result =
            select_multi_token_boxes(&utxos, &[("tokenA", 50), ("tokenB", 100)], 1_000_000_000)
                .unwrap();
        // Both tokens in one box
        assert_eq!(result.boxes.len(), 1);
    }

    #[test]
    fn test_select_multi_token_needs_erg() {
        let utxos = vec![
            mock_utxo("box1", 500_000, vec![("tokenA", 100)]),
            mock_utxo("box2", 500_000, vec![("tokenB", 200)]),
            mock_utxo("box3", 5_000_000_000, vec![]),
        ];

        let result =
            select_multi_token_boxes(&utxos, &[("tokenA", 50), ("tokenB", 100)], 2_000_000_000)
                .unwrap();
        // Needs all three boxes
        assert_eq!(result.boxes.len(), 3);
        assert!(result.total_erg >= 2_000_000_000);
    }

    #[test]
    fn test_select_multi_token_insufficient() {
        let utxos = vec![mock_utxo("box1", 5_000_000_000, vec![("tokenA", 10)])];

        let result =
            select_multi_token_boxes(&utxos, &[("tokenA", 50), ("tokenB", 100)], 1_000_000);
        assert!(result.is_err());
        match result.unwrap_err() {
            BoxSelectorError::InsufficientMultiTokens { shortfalls } => {
                assert!(!shortfalls.is_empty());
            }
            _ => panic!("Wrong error type"),
        }
    }

    #[test]
    fn test_collect_multi_change_basic() {
        let boxes = vec![mock_utxo(
            "box1",
            1_000_000,
            vec![("tokenA", 100), ("tokenB", 200), ("tokenC", 50)],
        )];

        let change = collect_multi_change_tokens(&boxes, &[("tokenA", 60), ("tokenB", 200)]);
        // tokenA: 100 - 60 = 40, tokenB: 200 - 200 = 0 (removed), tokenC: 50
        let token_a: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenA")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        let token_b: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenB")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        let token_c: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenC")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        assert_eq!(token_a, 40);
        assert_eq!(token_b, 0);
        assert_eq!(token_c, 50);
    }

    #[test]
    fn test_collect_multi_change_across_boxes() {
        let boxes = vec![
            mock_utxo("box1", 1_000_000, vec![("tokenA", 50)]),
            mock_utxo("box2", 2_000_000, vec![("tokenA", 70), ("tokenB", 30)]),
        ];

        let change = collect_multi_change_tokens(&boxes, &[("tokenA", 100), ("tokenB", 10)]);
        // tokenA: 50 + 70 - 100 = 20, tokenB: 30 - 10 = 20
        let token_a: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenA")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        let token_b: u64 = change
            .iter()
            .filter(|a| a.token_id == "tokenB")
            .map(|a| a.amount.parse::<u64>().unwrap())
            .sum();
        assert_eq!(token_a, 20);
        assert_eq!(token_b, 20);
    }
}
