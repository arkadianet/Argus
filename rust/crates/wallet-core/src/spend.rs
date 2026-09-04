use ergo_tx::{Eip12InputBox, SelectedInputs};

/// Boxes that are safe to spend for this payment.
/// ERG-only boxes are always eligible. Boxes that hold tokens are only
/// eligible if every token is the one being sent (avoids sweeping NFTs).
pub fn filter_spendable(utxos: &[Eip12InputBox], send_token: Option<&str>) -> Vec<Eip12InputBox> {
    utxos
        .iter()
        .filter(|b| is_spendable(b, send_token))
        .cloned()
        .collect()
}

pub fn is_spendable(utxo: &Eip12InputBox, send_token: Option<&str>) -> bool {
    if utxo.assets.is_empty() {
        return true;
    }
    match send_token {
        None => false,
        Some(id) => utxo.assets.iter().all(|a| a.token_id == id),
    }
}

pub fn select_for_send(
    utxos: &[Eip12InputBox],
    required_erg: u64,
    send_token: Option<(&str, u64)>,
) -> Result<SelectedInputs, ergo_tx::BoxSelectorError> {
    let token_id = send_token.map(|(id, _)| id);
    let safe = filter_spendable(utxos, token_id);
    match send_token {
        Some((id, amt)) => ergo_tx::select_token_boxes(&safe, id, amt, required_erg),
        None => match ergo_tx::select_erg_boxes(&safe, required_erg) {
            Ok(selected) => Ok(selected),
            Err(_) => ergo_tx::select_erg_boxes(utxos, required_erg),
        },
    }
}

/// Selection that avoids linking pockets unless it must.
///
/// A send allowed to draw on both ordinary and stealth boxes should still
/// prefer to satisfy the amount from one of them alone: two pockets in one
/// input list tells an observer they share an owner. Ordinary boxes are
/// tried first, then stealth alone, and only when neither suffices are the
/// two combined — the one case where linking is unavoidable.
///
/// Returns the selection and whether it mixes the two pockets.
pub fn select_preferring_one_pocket(
    utxos: &[Eip12InputBox],
    stealth_box_ids: &[String],
    required_erg: u64,
    send_token: Option<(&str, u64)>,
) -> Result<(SelectedInputs, bool), ergo_tx::BoxSelectorError> {
    if stealth_box_ids.is_empty() {
        return select_for_send(utxos, required_erg, send_token).map(|s| (s, false));
    }
    let is_stealth = |b: &Eip12InputBox| stealth_box_ids.iter().any(|id| id == &b.box_id);
    let ordinary: Vec<Eip12InputBox> = utxos.iter().filter(|b| !is_stealth(b)).cloned().collect();
    let stealth: Vec<Eip12InputBox> = utxos.iter().filter(|b| is_stealth(b)).cloned().collect();

    if !ordinary.is_empty() {
        if let Ok(s) = select_for_send(&ordinary, required_erg, send_token) {
            return Ok((s, false));
        }
    }
    if !stealth.is_empty() {
        if let Ok(s) = select_for_send(&stealth, required_erg, send_token) {
            return Ok((s, false));
        }
    }
    select_for_send(utxos, required_erg, send_token).map(|s| (s, true))
}

#[cfg(test)]
mod pocket_preference_tests {
    use super::*;
    use ergo_tx::Eip12Asset;

    fn boxx(id: &str, value: u64) -> Eip12InputBox {
        Eip12InputBox {
            box_id: id.to_string(),
            transaction_id: "0".repeat(64),
            index: 0,
            ergo_tree: "0008cd".to_string(),
            creation_height: 1,
            value: value.to_string(),
            assets: Vec::<Eip12Asset>::new(),
            additional_registers: Default::default(),
            extension: Default::default(),
        }
    }

    /// The stealth box is the largest, so plain largest-first selection
    /// would take it and link the pockets for no reason.
    #[test]
    fn prefers_ordinary_boxes_even_when_a_stealth_box_is_larger() {
        let utxos = vec![boxx("pub", 2_000_000_000), boxx("ste", 9_000_000_000)];
        let (s, mixed) =
            select_preferring_one_pocket(&utxos, &["ste".into()], 1_000_000_000, None).unwrap();
        assert_eq!(
            s.boxes
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["pub"]
        );
        assert!(!mixed);
    }

    #[test]
    fn falls_back_to_stealth_alone_rather_than_mixing() {
        let utxos = vec![boxx("pub", 100), boxx("ste", 9_000_000_000)];
        let (s, mixed) =
            select_preferring_one_pocket(&utxos, &["ste".into()], 1_000_000_000, None).unwrap();
        assert_eq!(
            s.boxes
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["ste"]
        );
        assert!(!mixed, "one pocket only, so nothing is linked");
    }

    /// Only when neither pocket can pay alone are they combined, and the
    /// caller is told so it can say as much.
    #[test]
    fn combines_only_when_neither_pocket_can_pay_alone() {
        let utxos = vec![boxx("pub", 600_000_000), boxx("ste", 600_000_000)];
        let (s, mixed) =
            select_preferring_one_pocket(&utxos, &["ste".into()], 1_000_000_000, None).unwrap();
        assert_eq!(s.boxes.len(), 2);
        assert!(mixed);
    }

    #[test]
    fn without_stealth_boxes_it_is_the_ordinary_selector() {
        let utxos = vec![boxx("a", 2_000_000_000)];
        let (s, mixed) = select_preferring_one_pocket(&utxos, &[], 1_000_000_000, None).unwrap();
        assert_eq!(s.boxes.len(), 1);
        assert!(!mixed);
    }
}

/// Coin control: use exactly the boxes the user chose, in the order given.
///
/// Unlike [`select_for_send`] this never adds or drops a box. Spending a
/// subset would defeat the point — the user picked these to control what
/// their transaction links together — so a shortfall is an error, not a
/// reason to reach for another box.
pub fn select_exact(
    utxos: &[Eip12InputBox],
    ids: &[String],
    required_erg: u64,
    send_token: Option<(&str, u64)>,
) -> Result<SelectedInputs, ExactSelectionError> {
    if ids.is_empty() {
        return Err(ExactSelectionError::Empty);
    }
    let by_id: std::collections::HashMap<&str, &Eip12InputBox> =
        utxos.iter().map(|b| (b.box_id.as_str(), b)).collect();
    let mut seen = std::collections::BTreeSet::new();
    let mut boxes = Vec::with_capacity(ids.len());
    for id in ids {
        if !seen.insert(id.as_str()) {
            return Err(ExactSelectionError::Duplicate(id.clone()));
        }
        let b = by_id
            .get(id.as_str())
            .ok_or_else(|| ExactSelectionError::Unknown(id.clone()))?;
        boxes.push((*b).clone());
    }

    let mut total_erg: u64 = 0;
    for b in &boxes {
        let v = b
            .value
            .parse::<u64>()
            .map_err(|_| ExactSelectionError::Unknown(b.box_id.clone()))?;
        total_erg = total_erg
            .checked_add(v)
            .ok_or(ExactSelectionError::Overflow)?;
    }
    if total_erg < required_erg {
        return Err(ExactSelectionError::InsufficientErg {
            have: total_erg,
            need: required_erg,
        });
    }

    let mut token_amount: u64 = 0;
    if let Some((id, amount)) = send_token {
        for b in &boxes {
            for a in &b.assets {
                if a.token_id == id {
                    token_amount =
                        token_amount.saturating_add(a.amount.parse::<u64>().unwrap_or(0));
                }
            }
        }
        if token_amount < amount {
            return Err(ExactSelectionError::InsufficientToken {
                token_id: id.to_string(),
                have: token_amount,
                need: amount,
            });
        }
    }

    Ok(SelectedInputs {
        boxes,
        total_erg,
        token_amount,
    })
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ExactSelectionError {
    #[error("choose at least one box to spend")]
    Empty,
    #[error("box {0} was chosen more than once")]
    Duplicate(String),
    #[error("box {0} is not spendable by this wallet")]
    Unknown(String),
    #[error("the chosen boxes hold {have} nanoERG, this send needs {need}")]
    InsufficientErg { have: u64, need: u64 },
    #[error("the chosen boxes hold {have} of token {token_id}, this send needs {need}")]
    InsufficientToken {
        token_id: String,
        have: u64,
        need: u64,
    },
    #[error("the chosen boxes total more than can be represented")]
    Overflow,
}

#[cfg(test)]
mod exact_selection_tests {
    use super::*;
    use ergo_tx::Eip12Asset;

    fn boxx(id: &str, value: u64, assets: Vec<(&str, u64)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: id.to_string(),
            transaction_id: "0".repeat(64),
            index: 0,
            ergo_tree: "0008cd".to_string(),
            creation_height: 1,
            value: value.to_string(),
            assets: assets
                .into_iter()
                .map(|(t, a)| Eip12Asset {
                    token_id: t.to_string(),
                    amount: a.to_string(),
                })
                .collect(),
            additional_registers: Default::default(),
            extension: Default::default(),
        }
    }

    fn wallet() -> Vec<Eip12InputBox> {
        vec![
            boxx("a", 1_000_000_000, vec![]),
            boxx("b", 2_000_000_000, vec![("tok", 5)]),
            boxx("c", 500_000_000, vec![]),
        ]
    }

    #[test]
    fn uses_every_chosen_box_and_keeps_their_order() {
        let s = select_exact(&wallet(), &["c".into(), "a".into()], 1_000_000_000, None).unwrap();
        assert_eq!(
            s.boxes
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["c", "a"],
            "a chosen box is never dropped, even when an earlier one already covers the amount"
        );
        assert_eq!(s.total_erg, 1_500_000_000);
    }

    /// The point of coin control is that nothing else is pulled in, so a
    /// shortfall must be reported rather than quietly topped up.
    #[test]
    fn refuses_to_reach_for_an_unchosen_box() {
        let err = select_exact(&wallet(), &["c".into()], 1_000_000_000, None).unwrap_err();
        assert_eq!(
            err,
            ExactSelectionError::InsufficientErg {
                have: 500_000_000,
                need: 1_000_000_000
            }
        );
    }

    #[test]
    fn counts_tokens_only_from_the_chosen_boxes() {
        let ok = select_exact(&wallet(), &["b".into()], 1_000_000, Some(("tok", 5))).unwrap();
        assert_eq!(ok.token_amount, 5);
        let err = select_exact(&wallet(), &["a".into()], 1_000_000, Some(("tok", 1))).unwrap_err();
        assert!(matches!(err, ExactSelectionError::InsufficientToken { .. }));
    }

    #[test]
    fn rejects_unknown_duplicate_and_empty_selections() {
        assert_eq!(
            select_exact(&wallet(), &["zz".into()], 1, None).unwrap_err(),
            ExactSelectionError::Unknown("zz".into())
        );
        assert_eq!(
            select_exact(&wallet(), &["a".into(), "a".into()], 1, None).unwrap_err(),
            ExactSelectionError::Duplicate("a".into())
        );
        assert_eq!(
            select_exact(&wallet(), &[], 1, None).unwrap_err(),
            ExactSelectionError::Empty
        );
    }

    /// Automatic selection takes the largest eligible box first, so it can
    /// spend one the user wanted left alone — the linking problem coin
    /// control exists to solve. Exact selection spends only what was
    /// chosen, even when one bigger box would mean fewer inputs.
    #[test]
    fn automatic_selection_may_take_a_box_the_user_wanted_left_alone() {
        let mut utxos = wallet();
        utxos.push(boxx("private", 3_000_000_000, vec![]));

        let auto = select_for_send(&utxos, 1_200_000_000, None).unwrap();
        assert_eq!(
            auto.boxes
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["private"],
            "largest first: the box the user wanted untouched pays the whole amount"
        );

        let chosen = select_exact(&utxos, &["a".into(), "c".into()], 1_200_000_000, None).unwrap();
        assert_eq!(
            chosen
                .boxes
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "c"],
            "coin control keeps the private box out of the transaction"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_tx::Eip12Asset;
    use std::collections::HashMap;

    fn box_with(value: &str, assets: Vec<(&str, &str)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: "b".into(),
            transaction_id: "t".into(),
            index: 0,
            value: value.into(),
            ergo_tree: "00".into(),
            assets: assets
                .into_iter()
                .map(|(id, amt)| Eip12Asset {
                    token_id: id.into(),
                    amount: amt.into(),
                })
                .collect(),
            creation_height: 1,
            additional_registers: HashMap::new(),
            extension: HashMap::new(),
        }
    }

    #[test]
    fn skips_nft_when_sending_erg() {
        let boxes = vec![
            box_with("2000000000", vec![]),
            box_with("1000000000", vec![("nft", "1")]),
        ];
        let safe = filter_spendable(&boxes, None);
        assert_eq!(safe.len(), 1);
        assert_eq!(safe[0].value, "2000000000");
    }

    #[test]
    fn erg_send_retries_token_boxes_when_plain_erg_is_short() {
        let boxes = vec![box_with("5000000000", vec![("tok", "1")])];
        let selected = select_for_send(&boxes, 2_000_000_000, None).unwrap();
        assert_eq!(selected.boxes.len(), 1);
        assert_eq!(selected.boxes[0].value, "5000000000");
    }

    #[test]
    fn erg_send_prefers_plain_boxes_before_token_boxes() {
        let boxes = vec![
            box_with("5000000000", vec![]),
            box_with("8000000000", vec![("nft", "1")]),
        ];
        let selected = select_for_send(&boxes, 2_000_000_000, None).unwrap();
        assert_eq!(selected.boxes.len(), 1);
        assert!(selected.boxes[0].assets.is_empty());
    }

    #[test]
    fn allows_matching_token_box() {
        let boxes = vec![
            box_with("1000000", vec![("tok", "50")]),
            box_with("1000000", vec![("tok", "10"), ("nft", "1")]),
        ];
        let safe = filter_spendable(&boxes, Some("tok"));
        assert_eq!(safe.len(), 1);
        assert_eq!(safe[0].assets.len(), 1);
    }
}
