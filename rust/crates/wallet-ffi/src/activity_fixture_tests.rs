//! Real mainnet transactions read from the wallet's point of view.
//!
//! `activity_fixtures/mainnet_txs.json` holds transactions as the node's
//! `/blockchain/transaction/byAddress` returns them (trimmed to the fields
//! the summary reads), each with the addresses of the wallet that sees it.
//! The summaries these produce are the app's classifier fixtures
//! (`app/test/fixtures/activity_rows.json`): the Dart tests classify exactly
//! what this code emits. Regenerate them with
//! `ARGUS_UPDATE_ACTIVITY_GOLDEN=1 cargo test -p wallet-ffi activity_fixture`.

use std::collections::HashSet;

use wallet_net::activity::summarize_for_wallet;

const PINNED: &str = "9iArkadiaZAPVxbUp2XQ8SVA1zGA29rCPhbpVuUaaKW6fWspUZA";
const INDEX0: &str = "9hQTG5EspKUxjhmnFRdzhethHaFmnW4PvjobckSrTSNRYhQLhCZ";

fn fixture() -> serde_json::Value {
    serde_json::from_str(include_str!("activity_fixtures/mainnet_txs.json")).unwrap()
}

fn tx(f: &serde_json::Value, id_prefix: &str) -> serde_json::Value {
    f["txs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"].as_str().unwrap().starts_with(id_prefix))
        .cloned()
        .unwrap()
}

fn owned(addresses: &[&str]) -> HashSet<String> {
    addresses.iter().map(|a| a.to_string()).collect()
}

fn summary(f: &serde_json::Value, id: &str, addresses: &[&str]) -> wallet_net::TxSummary {
    summarize_for_wallet(
        &tx(f, id),
        None,
        &owned(addresses),
        &crate::activity_tags::tag_box,
    )
    .unwrap()
}

fn tags(s: &wallet_net::TxSummary) -> Vec<String> {
    let io = s.io.as_ref().unwrap();
    io.inputs
        .iter()
        .chain(&io.outputs)
        .filter_map(|p| p.tag.clone())
        .collect()
}

#[test]
fn the_burn_is_read_from_the_whole_wallet() {
    let f = fixture();
    // Index 0 held the tokens; the change went to the pinned #275.
    let s = summary(&f, "b827bc1d", &[INDEX0, PINNED]);
    assert_eq!(
        s.value_nano_erg, -1_100_000,
        "only the miner fee left the wallet"
    );
    assert_eq!(s.counterparty, None, "no one outside the wallet was paid");
    assert!(s.tokens_received.is_empty());
    assert_eq!(s.tokens_sent.len(), 6);
    let io = s.io.as_ref().unwrap();
    assert_eq!(io.miner_fee, 1_100_000);
    assert!(io.complete);
    assert!(io.inputs.iter().all(|p| p.mine));
    assert!(
        io.outputs.iter().all(|p| p.mine),
        "the change and the app fee both land on #275"
    );
    // No output holds any of the six tokens: they were burned.
    assert!(io.outputs.iter().all(|p| p.assets.is_empty()));

    // What the old per-address read saw, for the record: index 0 alone,
    // "Sent 2.09 ERG to 9iArka…pUZA". A watched account that has not yet
    // derived #275 still sees it this way until the app re-reads it with
    // the full address set.
    let old = wallet_net::summarize_tx_for_address(&tx(&f, "b827bc1d"), INDEX0).unwrap();
    assert_eq!(old.value_nano_erg, -2_094_715_058);
    assert_eq!(old.counterparty.as_deref(), Some(PINNED));
}

#[test]
fn spectrum_swaps_net_both_addresses_and_name_the_pool() {
    let f = fixture();
    // Old row: "Sent · contract 5vSUZR…SCqM · −0.0001 ERG · −2,000 …".
    let s = summary(&f, "e3e175d3", &[INDEX0, PINNED]);
    assert_eq!(
        s.value_nano_erg, 34_935_835,
        "the swap paid ERG into the wallet"
    );
    assert_eq!(s.tokens_sent.len(), 1);
    assert_eq!(s.tokens_sent[0].amount, 2_000);
    assert!(tags(&s).contains(&"spectrum:pool".to_string()));
    // Old row: "−0.1087 ERG · −57.32 Flux".
    let s = summary(&f, "cf2ec21b", &[INDEX0, PINNED]);
    assert_eq!(s.value_nano_erg, 316_034_223);
    assert_eq!(s.tokens_sent[0].amount, 5_732_202_792);
}

#[test]
fn moves_between_own_addresses_change_nothing_but_the_fee() {
    let f = fixture();
    for id in ["4ab7193c", "b3a64fba"] {
        let s = summary(&f, id, &[PINNED, INDEX0]);
        assert_eq!(s.value_nano_erg, -1_100_000, "{id}");
        assert_eq!(s.counterparty, None, "{id}");
        assert!(
            s.tokens_sent.is_empty() && s.tokens_received.is_empty(),
            "{id}"
        );
    }
}

#[test]
fn protocol_boxes_are_recognised_on_real_transactions() {
    let f = fixture();
    let cases: &[(&str, &str)] = &[
        ("132545d9", "sigmausd:bank"),
        ("bdeb8484", "dexy:bank"),
        ("20c7f321", "dexy:lp_mint"),
        ("dc100432", "dexy:lp_swap"),
        ("9a8d09be", "stake:proxy"),
        ("13e2659c", "stake:paideia"),
        ("d957a1f2", "stealth"),
        ("accfef63", "spectrum:redeem_order"),
        ("68ab842a", "argus_fee"),
    ];
    for (id, tag) in cases {
        let s = summary(&f, id, &[]);
        assert!(tags(&s).contains(&tag.to_string()), "{id}: {:?}", tags(&s));
    }
}

#[test]
fn activity_fixture_rows_match_the_app_fixtures() {
    let f = fixture();
    let mut rows = Vec::new();
    for case in f["cases"].as_array().unwrap() {
        let addresses: Vec<&str> = case["owned"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a.as_str().unwrap())
            .collect();
        let s = summary(&f, case["tx"].as_str().unwrap(), &addresses);
        rows.push(serde_json::json!({
            "name": case["name"],
            "owned": case["owned"],
            "row": s,
        }));
    }
    let golden = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../app/test/fixtures/activity_rows.json");
    let text = serde_json::to_string_pretty(&serde_json::json!({
        "generated_by": "rust/crates/wallet-ffi/src/activity_fixture_tests.rs",
        "rows": rows,
    }))
    .unwrap()
        + "\n";
    if std::env::var_os("ARGUS_UPDATE_ACTIVITY_GOLDEN").is_some() {
        std::fs::create_dir_all(golden.parent().unwrap()).unwrap();
        std::fs::write(&golden, &text).unwrap();
    }
    let on_disk = std::fs::read_to_string(&golden).expect("app fixture present");
    assert_eq!(
        on_disk, text,
        "app/test/fixtures/activity_rows.json is stale; regenerate it"
    );
}
