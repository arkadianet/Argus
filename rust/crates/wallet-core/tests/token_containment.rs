use citadel_core::constants::{MIN_BOX_VALUE_NANO as MIN, TX_FEE_NANO as FEE};
use ergo_tx::{dev_fee::DevFeeConfig, Eip12Asset, Eip12InputBox, Eip12UnsignedTx, RecipientSpec};
use std::collections::BTreeMap;
use wallet_core::spend::select_for_send;

fn input(id: &str, value: i64, amount: i64, extras: usize) -> Eip12InputBox {
    let mut assets = vec![Eip12Asset::new("receipt", amount)];
    assets.extend((0..extras).map(|i| Eip12Asset::new(format!("extra{i}"), (i + 1) as i64)));
    Eip12InputBox {
        box_id: id.into(),
        transaction_id: "tx".into(),
        index: 0,
        value: value.to_string(),
        ergo_tree: "wallet".into(),
        assets,
        creation_height: 1,
        additional_registers: Default::default(),
        extension: Default::default(),
    }
}

fn totals<'a>(assets: impl Iterator<Item = &'a Eip12Asset>) -> BTreeMap<String, u64> {
    let mut result = BTreeMap::new();
    for a in assets {
        *result.entry(a.token_id.clone()).or_default() += a.amount.parse::<u64>().unwrap();
    }
    result
}

fn check(tx: &Eip12UnsignedTx, sent: u64, extras: usize) {
    let incoming = totals(tx.inputs.iter().flat_map(|b| &b.assets));
    let outgoing = totals(tx.outputs.iter().flat_map(|b| &b.assets));
    assert_eq!(
        incoming, outgoing,
        "every token is conserved across all outputs including change"
    );
    let change = totals(
        tx.outputs
            .iter()
            .filter(|b| b.ergo_tree == "wallet")
            .flat_map(|b| &b.assets),
    );
    for i in 0..extras {
        assert_eq!(change[&format!("extra{i}")], (i + 1) as u64);
    }
    assert_eq!(
        change.get("receipt").copied().unwrap_or(0),
        incoming["receipt"] - sent
    );
    assert_eq!(
        totals(
            tx.outputs
                .iter()
                .filter(|b| b.ergo_tree == "recipient")
                .flat_map(|b| &b.assets)
        ),
        BTreeMap::from([("receipt".into(), sent)])
    );
    assert_eq!(
        tx.inputs
            .iter()
            .map(|b| b.value.parse::<i64>().unwrap())
            .sum::<i64>(),
        tx.outputs
            .iter()
            .map(|b| b.value.parse::<i64>().unwrap())
            .sum::<i64>()
    );
    assert!(tx.outputs.iter().filter(|b| !b.assets.is_empty()).all(|b| b
        .value
        .parse::<i64>()
        .unwrap()
        >= MIN));
}

#[test]
fn selected_colocated_tokens_are_conserved_by_both_send_builders() {
    for extras in [1, 3] {
        for split in [false, true] {
            for sent in [80, 100] {
                let mut inputs = vec![input("a", 10_000_000, if split { 30 } else { 100 }, extras)];
                if split {
                    inputs.push(input("b", 10_000_000, 70, 0));
                }
                let selected =
                    select_for_send(&inputs, (2 * MIN + FEE) as u64, Some(("receipt", sent)))
                        .unwrap();
                assert_eq!(selected.boxes.len(), if split { 2 } else { 1 });
                let single = ergo_tx::build_send_tx_with_fee(
                    &selected.boxes,
                    "recipient",
                    "wallet",
                    MIN,
                    Some(("receipt", sent)),
                    1,
                    &DevFeeConfig::disabled(),
                )
                .unwrap();
                check(&single.unsigned_tx, sent, extras);
                let multi = ergo_tx::build_multi_send_tx_with_fee(
                    &selected.boxes,
                    &[
                        RecipientSpec::with_token(
                            "recipient".into(),
                            MIN,
                            Some(("receipt".into(), sent / 2)),
                        ),
                        RecipientSpec::with_token(
                            "recipient".into(),
                            MIN,
                            Some(("receipt".into(), sent - sent / 2)),
                        ),
                    ],
                    "wallet",
                    FEE,
                    1,
                )
                .unwrap();
                check(&multi.unsigned_tx, sent, extras);
            }
        }
    }
}

#[test]
fn extra_tokens_require_funded_change_instead_of_being_burned_or_reported_missing() {
    for multi in [false, true] {
        // Account for the configured app fee in the multi-send builder.
        let app_fee = if multi {
            ergo_tx::resolved_dev_fee_config().budget()
        } else {
            0
        };
        let base = MIN + FEE + app_fee;
        for remainder in [0, MIN - 1, MIN] {
            for extras in [0, 1, 3] {
                let inputs = [input("a", base + remainder, 100, extras)];
                let selected =
                    select_for_send(&inputs, base as u64, Some(("receipt", 100))).unwrap();
                let result = if multi {
                    ergo_tx::build_multi_send_tx_with_fee(&selected.boxes, &[RecipientSpec::with_token("recipient".into(), MIN, Some(("receipt".into(), 100)))], "wallet", FEE, 1)
                        .map(|b| b.unsigned_tx).map_err(|e| {
                            assert!(matches!(e, ergo_tx::MultiSendError::TokenChangeInsufficientErg { have, min } if have == remainder && min == MIN));
                            e.to_string()
                        })
                } else {
                    ergo_tx::build_send_tx_with_fee(&selected.boxes, "recipient", "wallet", MIN, Some(("receipt", 100)), 1, &DevFeeConfig::disabled())
                        .map(|b| b.unsigned_tx).map_err(|e| {
                            assert!(matches!(e, ergo_tx::SendError::TokenChangeInsufficientErg { have, min } if have == remainder && min == MIN));
                            e.to_string()
                        })
                };
                if extras > 0 && remainder < MIN {
                    let message = result.unwrap_err();
                    assert!(message.contains("Token change requires at least"));
                    assert!(!message.contains("Insufficient token"));
                } else {
                    let tx = result.unwrap();
                    check(&tx, 100, extras);
                    assert_eq!(
                        tx.outputs
                            .iter()
                            .filter(|b| b.ergo_tree == "wallet")
                            .count(),
                        usize::from(remainder >= MIN)
                    );
                }
            }
        }
    }
}
