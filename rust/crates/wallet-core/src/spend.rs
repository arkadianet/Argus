use ergo_tx::{Eip12InputBox, SelectedInputs};

/// Boxes that are safe to spend for this payment.
/// ERG-only boxes are always eligible. Boxes that hold tokens are only
/// eligible if every token is the one being sent (avoids sweeping NFTs).
pub fn filter_spendable(
    utxos: &[Eip12InputBox],
    send_token: Option<&str>,
) -> Vec<Eip12InputBox> {
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
