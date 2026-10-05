use super::*;
use ergo_tx::{Eip12Asset, Eip12InputBox, RecipientSpec};

fn input(id: &str, height: i32, value: u64, assets: Vec<Eip12Asset>) -> Eip12InputBox {
    Eip12InputBox {
        box_id: id.into(),
        transaction_id: "00".repeat(32),
        index: 0,
        ergo_tree: address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap(),
        creation_height: height,
        value: value.to_string(),
        assets,
        additional_registers: Default::default(),
        extension: Default::default(),
    }
}

#[test]
fn automatic_multi_send_funds_all_unsent_colocated_tokens() {
    ergo_tx::with_test_dev_fee(DevFeeConfig::disabled(), || {
        let tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        let recipients = vec![RecipientSpec::with_token(
            tree.clone(),
            MIN_BOX_VALUE_NANO,
            Some(("00".repeat(32), 1)),
        )];
        let required = multi_send_required_erg(MIN_BOX_VALUE_NANO, TX_FEE_NANO, false).unwrap();
        let assets = (0..180)
            .map(|i| Eip12Asset::new(format!("{i:064x}"), 2))
            .collect();
        let inputs = vec![
            input("new-funding", 200, 10_000_000, vec![]),
            input("old-tokens", 100, required, assets),
        ];
        let needed = HashMap::from([("00".repeat(32), 1)]);
        let mut budgets = Vec::new();
        let (selected, built, _) = build_funded_multi_send(
            &recipients,
            &tree,
            TX_FEE_NANO,
            300,
            required,
            true,
            None,
            |budget| {
                budgets.push(budget);
                select_for_multi_send(&inputs, budget, &needed)
            },
        )
        .unwrap();
        assert_eq!(
            budgets.len(),
            2,
            "the real multi-box change floor triggers one funding pass"
        );
        assert!(budgets[1] > budgets[0]);
        assert_eq!(selected.len(), 2);
        for i in 0..180 {
            let id = format!("{i:064x}");
            let total: u64 = built
                .unsigned_tx
                .outputs
                .iter()
                .flat_map(|o| &o.assets)
                .filter(|a| a.token_id == id)
                .map(|a| a.amount.parse::<u64>().unwrap())
                .sum();
            assert_eq!(total, 2, "sent and unsent token {i} are both conserved");
        }
        assert_eq!(
            built
                .unsigned_tx
                .outputs
                .iter()
                .map(|o| o.value.parse::<u64>().unwrap())
                .sum::<u64>(),
            selected
                .iter()
                .map(|b| b.value.parse::<u64>().unwrap())
                .sum::<u64>()
        );
    });
}

#[test]
fn manual_multi_send_never_tops_up_an_underfunded_selection() {
    ergo_tx::with_test_dev_fee(DevFeeConfig::disabled(), || {
        let tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        let recipients = vec![RecipientSpec::with_token(
            tree.clone(),
            MIN_BOX_VALUE_NANO,
            Some(("00".repeat(32), 1)),
        )];
        let required = multi_send_required_erg(MIN_BOX_VALUE_NANO, TX_FEE_NANO, false).unwrap();
        let selected = vec![input(
            "chosen",
            100,
            required,
            (0..180)
                .map(|i| Eip12Asset::new(format!("{i:064x}"), 2))
                .collect(),
        )];
        let mut calls = 0;
        let error = build_funded_multi_send(
            &recipients,
            &tree,
            TX_FEE_NANO,
            300,
            required,
            false,
            None,
            |_| {
                calls += 1;
                Ok(selected.clone())
            },
        )
        .unwrap_err();
        assert_eq!(calls, 1);
        assert!(error.contains("Token change requires"));
    });
}

#[test]
fn repeated_change_shortfalls_are_bounded() {
    ergo_tx::with_test_dev_fee(DevFeeConfig::disabled(), || {
        let tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        let recipients = vec![RecipientSpec::with_token(
            tree.clone(),
            MIN_BOX_VALUE_NANO,
            Some(("00".repeat(32), 1)),
        )];
        let required = multi_send_required_erg(MIN_BOX_VALUE_NANO, TX_FEE_NANO, false).unwrap();
        let selected = vec![input(
            "chosen",
            100,
            required,
            (0..180)
                .map(|i| Eip12Asset::new(format!("{i:064x}"), 2))
                .collect(),
        )];
        let mut calls = 0;
        assert!(build_funded_multi_send(
            &recipients,
            &tree,
            TX_FEE_NANO,
            300,
            required,
            true,
            None,
            |_| {
                calls += 1;
                Ok(selected.clone())
            }
        )
        .is_err());
        assert_eq!(calls, ergo_tx::MAX_SELECTION_PASSES);
    });
}

#[test]
fn multi_send_leaves_unrelated_collectibles_when_eligible_funding_suffices() {
    let inputs = vec![
        input(
            "unrelated-old-nft",
            10,
            100_000_000,
            vec![Eip12Asset::new("ff".repeat(32), 1)],
        ),
        input(
            "old-token",
            20,
            2_000_000,
            vec![Eip12Asset::new("aa".repeat(32), 10)],
        ),
        input("old-erg", 30, 5_000_000, vec![]),
        input("new-erg", 40, 50_000_000, vec![]),
    ];
    let needed = HashMap::from([("aa".repeat(32), 1)]);
    let selected = select_for_multi_send(&inputs, 4_000_000, &needed).unwrap();
    assert_eq!(
        selected
            .iter()
            .map(|b| b.box_id.as_str())
            .collect::<Vec<_>>(),
        vec!["old-token", "old-erg"]
    );
}

#[test]
fn multi_send_with_a_token_fee_reselects_and_summarizes_split_change() {
    ergo_tx::with_test_dev_fee(DevFeeConfig::disabled(), || {
        let tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        let fee_token = "00".repeat(32);
        let sent_token = format!("{:064x}", 1);
        let recipients = vec![RecipientSpec::with_token(
            tree.clone(),
            MIN_BOX_VALUE_NANO,
            Some((sent_token.clone(), 1)),
        )];
        let required = multi_send_required_erg(MIN_BOX_VALUE_NANO, TX_FEE_NANO, true).unwrap();
        let mut sponsor = input(
            &"bb".repeat(32),
            10,
            1_000_000_000,
            vec![Eip12Asset::new(fee_token.clone(), 5)],
        );
        sponsor.ergo_tree = ergo_tx::babel::babel_ergo_tree(&fee_token);
        sponsor.additional_registers = HashMap::from([
            ("R4".into(), "08cd02aa".into()),
            ("R5".into(), "0580897a".into()),
        ]);
        let quote = ergo_tx::BabelBox::parse(&sponsor, &fee_token).unwrap();
        let inputs = vec![
            input("new-funding", 200, 5_000_000, vec![]),
            input(
                "old-tokens",
                100,
                required,
                (0..180)
                    .map(|i| Eip12Asset::new(format!("{i:064x}"), 2))
                    .collect(),
            ),
        ];
        let needed = HashMap::from([
            (sent_token, 1),
            (fee_token.clone(), quote.tokens_for(TX_FEE_NANO)),
        ]);
        let mut calls = 0;
        let (selected, built, fee_summary) = build_funded_multi_send(
            &recipients,
            &tree,
            TX_FEE_NANO,
            300,
            required,
            true,
            Some(&quote),
            |budget| {
                calls += 1;
                let mut selected = select_for_multi_send(&inputs, budget, &needed)?;
                selected.push(sponsor.clone());
                Ok(selected)
            },
        )
        .unwrap();
        assert_eq!(calls, 2);
        assert_eq!(selected.len(), 3);
        assert_eq!(
            built.summary.change_erg, 6_000_000,
            "summary excludes the Babel principal and preserves all split change"
        );
        assert!(built.summary.change_output_count > 1);
        assert_eq!(fee_summary.unwrap().tokens_paid, 2);
        assert_eq!(
            built.unsigned_tx.outputs[0].value,
            MIN_BOX_VALUE_NANO.to_string(),
            "the self-send recipient is untouched"
        );
        assert_eq!(built.unsigned_tx.outputs[0].assets[0].amount, "1");
        assert_eq!(
            built
                .unsigned_tx
                .outputs
                .iter()
                .map(|o| o.value.parse::<u64>().unwrap())
                .sum::<u64>(),
            selected
                .iter()
                .map(|b| b.value.parse::<u64>().unwrap())
                .sum::<u64>()
        );
        for i in 0..180 {
            let id = format!("{i:064x}");
            let total: u64 = built
                .unsigned_tx
                .outputs
                .iter()
                .flat_map(|o| &o.assets)
                .filter(|a| a.token_id == id)
                .map(|a| a.amount.parse::<u64>().unwrap())
                .sum();
            assert_eq!(total, if i == 0 { 7 } else { 2 });
        }
    });
}

fn token_heavy_public_pocket(required: u64) -> Vec<Eip12InputBox> {
    // Both input boxes respect the count, size and value limits. Their
    // combined unsent tokens require more than one funded change output.
    let inputs = vec![
        input(
            "public-a",
            100,
            required / 2,
            (0..90)
                .map(|i| Eip12Asset::new(format!("{i:064x}"), 2))
                .collect(),
        ),
        input(
            "public-b",
            101,
            required - required / 2,
            (90..180)
                .map(|i| Eip12Asset::new(format!("{i:064x}"), 2))
                .collect(),
        ),
    ];
    for input in &inputs {
        let bytes =
            ergo_tx::box_bytes(&input.ergo_tree, &input.assets, &input.additional_registers);
        assert!(input.assets.len() <= ergo_tx::MAX_TOKENS_PER_BOX);
        assert!(bytes <= ergo_tx::MAX_BOX_BYTES);
        assert!(
            input.value.parse::<u64>().unwrap()
                >= ergo_tx::min_value_for(bytes, MIN_BOX_VALUE_NANO as u64)
        );
    }
    inputs
}

#[test]
fn cheaper_stealth_change_does_not_inherit_the_public_funding_shortfall() {
    ergo_tx::with_test_dev_fee(DevFeeConfig::disabled(), || {
        let tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        let token_id = "00".repeat(32);
        let recipients = vec![RecipientSpec::with_token(
            tree.clone(),
            MIN_BOX_VALUE_NANO,
            Some((token_id.clone(), 1)),
        )];
        let required = multi_send_required_erg(MIN_BOX_VALUE_NANO, TX_FEE_NANO, false).unwrap();
        let mut inputs = token_heavy_public_pocket(required);
        inputs.push(input(
            "private",
            200,
            required,
            vec![Eip12Asset::new(token_id.clone(), 2)],
        ));
        let needed = HashMap::from([(token_id, 1)]);
        let mut attempts = Vec::new();
        let mut budgets = Vec::new();
        let (selected, built, _) =
            build_preferring_one_pocket(&inputs, &["private".into()], |pocket| {
                let attempt = attempts.len();
                attempts.push(pocket.iter().map(|b| b.box_id.clone()).collect::<Vec<_>>());
                build_funded_multi_send(
                    &recipients,
                    &tree,
                    TX_FEE_NANO,
                    300,
                    required,
                    true,
                    None,
                    |budget| {
                        budgets.push((attempt, budget));
                        select_for_multi_send(pocket, budget, &needed)
                    },
                )
            })
            .unwrap();
        assert_eq!(
            attempts,
            vec![vec!["public-a", "public-b"], vec!["private"]],
            "the complete stealth-only layout succeeds before any combined attempt"
        );
        assert!(
            budgets
                .iter()
                .any(|&(attempt, budget)| attempt == 0 && budget > required),
            "the public pocket was retried using its larger token-change floor"
        );
        assert_eq!(
            budgets.iter().find(|&&(attempt, _)| attempt == 1),
            Some(&(1, required)),
            "the stealth pocket starts with the original payment budget"
        );
        assert_eq!(
            selected
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["private"],
            "a failed public layout must not cause unnecessary pocket linking"
        );
        assert_eq!(built.summary.change_output_count, 1);
        assert_eq!(built.summary.change_erg, MIN_BOX_VALUE_NANO);
        assert_eq!(
            built
                .unsigned_tx
                .outputs
                .iter()
                .map(|o| o.value.parse::<u64>().unwrap())
                .sum::<u64>(),
            required
        );
    });
}

#[test]
fn multi_send_combines_pockets_only_after_both_complete_layouts_fail() {
    ergo_tx::with_test_dev_fee(DevFeeConfig::disabled(), || {
        let tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        let token_id = "00".repeat(32);
        let recipients = vec![RecipientSpec::with_token(
            tree.clone(),
            MIN_BOX_VALUE_NANO,
            Some((token_id.clone(), 1)),
        )];
        let required = multi_send_required_erg(MIN_BOX_VALUE_NANO, TX_FEE_NANO, false).unwrap();
        let mut inputs = token_heavy_public_pocket(required);
        inputs.push(input(
            "private",
            200,
            2_000_000,
            vec![Eip12Asset::new(token_id.clone(), 2)],
        ));
        let needed = HashMap::from([(token_id, 1)]);
        let mut attempts = Vec::new();
        let (selected, built, _) =
            build_preferring_one_pocket(&inputs, &["private".into()], |pocket| {
                attempts.push(pocket.iter().map(|b| b.box_id.clone()).collect::<Vec<_>>());
                build_funded_multi_send(
                    &recipients,
                    &tree,
                    TX_FEE_NANO,
                    300,
                    required,
                    true,
                    None,
                    |budget| select_for_multi_send(pocket, budget, &needed),
                )
            })
            .unwrap();
        assert_eq!(
            attempts,
            vec![
                vec!["public-a", "public-b"],
                vec!["private"],
                vec!["public-a", "public-b", "private"],
            ],
            "combining is a fallback after each pocket's own funding/layout attempt"
        );
        assert_eq!(
            selected
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            vec!["public-a", "private"],
            "the combined fallback still leaves unrelated tokens untouched when possible"
        );
        assert_eq!(
            built
                .unsigned_tx
                .outputs
                .iter()
                .map(|o| o.value.parse::<u64>().unwrap())
                .sum::<u64>(),
            selected
                .iter()
                .map(|b| b.value.parse::<u64>().unwrap())
                .sum::<u64>()
        );
        for i in 0..180 {
            let id = format!("{i:064x}");
            let sent_or_change: u64 = built
                .unsigned_tx
                .outputs
                .iter()
                .flat_map(|o| &o.assets)
                .filter(|a| a.token_id == id)
                .map(|a| a.amount.parse::<u64>().unwrap())
                .sum();
            let untouched: u64 = inputs
                .iter()
                .filter(|b| !selected.iter().any(|s| s.box_id == b.box_id))
                .flat_map(|b| &b.assets)
                .filter(|a| a.token_id == id)
                .map(|a| a.amount.parse::<u64>().unwrap())
                .sum();
            assert_eq!(sent_or_change + untouched, if i == 0 { 4 } else { 2 });
        }
    });
}
