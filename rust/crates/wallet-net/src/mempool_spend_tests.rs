//! What a wallet may spend while transactions are pending, and how pending
//! movements are valued. Fixtures are real boxes, so every id is the one the
//! node would report.

use super::*;

// Three valid P2PK scripts: the secp256k1 generator G, 2G and another key.
const A: &str = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
const B: &str = "0008cd02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";
const FOREIGN: &str = "0008cd03986ae12afbc27b9436ce23cb90faf7864376c5250b6a019d45a7aabfc7c910c9";
const TOKEN: &str = "abababababababababababababababababababababababababababababababab";

const ERG: u64 = 1_000_000_000;

fn tx_id(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

/// A box created by transaction `tx` at `index`, holding `tokens`.
fn boxed(tree: &str, tx: &str, index: u16, value: u64, tokens: u64) -> ErgoBox {
    let assets = if tokens > 0 {
        serde_json::json!([{ "tokenId": TOKEN, "amount": tokens }])
    } else {
        serde_json::json!([])
    };
    serde_json::from_value(serde_json::json!({
        "transactionId": tx, "index": index, "value": value, "ergoTree": tree,
        "creationHeight": 1_000, "assets": assets, "additionalRegisters": {}
    }))
    .unwrap()
}

fn id(b: &ErgoBox) -> String {
    b.box_id().to_string()
}

fn pair(boxes: Vec<ErgoBox>) -> (Vec<ErgoBox>, Vec<ergo_tx::Eip12InputBox>) {
    let inputs = boxes
        .iter()
        .map(|b| ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index))
        .collect();
    (boxes, inputs)
}

/// A mempool transaction as the node lists it: inputs by id only.
fn pending(id: &str, spends: &[&ErgoBox], outputs: &[&ErgoBox]) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "inputs": spends.iter().map(|b| serde_json::json!({"boxId": b.box_id().to_string()})).collect::<Vec<_>>(),
        "outputs": outputs.iter().map(|b| serde_json::to_value(b).unwrap()).collect::<Vec<_>>(),
    })
}

fn read(tree: &str, confirmed: Vec<ErgoBox>, mempool: Vec<serde_json::Value>) -> AddressRead {
    AddressRead {
        tree: tree.to_string(),
        confirmed: pair(confirmed),
        mempool,
    }
}

fn offered(s: &Spendable) -> Vec<String> {
    s.inputs.iter().map(|i| i.box_id.clone()).collect()
}

fn total(inputs: &[ergo_tx::Eip12InputBox]) -> u64 {
    inputs.iter().map(|i| i.value.parse::<u64>().unwrap()).sum()
}

/// The user sent 0.4 ERG from a 1 ERG box: a pending send with change.
struct SentWithChange {
    spent: ErgoBox,
    kept: ErgoBox,
    change: ErgoBox,
    tx: serde_json::Value,
}

fn sent_with_change() -> SentWithChange {
    let spent = boxed(A, &tx_id(1), 0, ERG, 0);
    let kept = boxed(A, &tx_id(2), 0, 3 * ERG, 0);
    let t = tx_id(3);
    let paid = boxed(FOREIGN, &t, 0, 400_000_000, 0);
    let change = boxed(A, &t, 1, 598_900_000, 0);
    let tx = pending(&t, &[&spent], &[&paid, &change]);
    SentWithChange { spent, kept, change, tx }
}

#[test]
fn a_box_a_pending_transaction_spends_is_never_offered_under_either_policy() {
    for allow in [true, false] {
        let s = sent_with_change();
        let spendable = spendable_across(
            vec![read(A, vec![s.spent.clone(), s.kept.clone()], vec![s.tx.clone()])],
            allow,
        );
        assert!(
            !offered(&spendable).contains(&id(&s.spent)),
            "allow={allow}: the spent box must not be offered"
        );
        assert!(offered(&spendable).contains(&id(&s.kept)));
        assert_eq!(spendable.boxes.len(), spendable.inputs.len());
    }
}

#[test]
fn own_change_is_spendable_only_when_unconfirmed_funds_are_allowed() {
    let s = sent_with_change();
    let reads = || vec![read(A, vec![s.spent.clone(), s.kept.clone()], vec![s.tx.clone()])];

    let allowed = spendable_across(reads(), true);
    assert_eq!(offered(&allowed), vec![id(&s.kept), id(&s.change)]);
    assert!(allowed.unconfirmed.contains(&id(&s.change)));
    assert!(!allowed.unconfirmed.contains(&id(&s.kept)));
    assert!(allowed.held_back.is_empty());

    let waiting = spendable_across(reads(), false);
    assert_eq!(offered(&waiting), vec![id(&s.kept)]);
    assert!(waiting.unconfirmed.is_empty());
    assert_eq!(
        waiting.held_back.iter().map(|i| i.box_id.clone()).collect::<Vec<_>>(),
        vec![id(&s.change)],
        "unconfirmed change waits like any incoming payment"
    );
}

#[test]
fn incoming_payments_wait_too_and_amounts_are_conserved() {
    let mine = boxed(A, &tx_id(1), 0, 2 * ERG, 0);
    let theirs = boxed(FOREIGN, &tx_id(2), 0, 9 * ERG, 0);
    let t = tx_id(4);
    let incoming = boxed(A, &t, 0, 2_500_000_000, 7);
    let their_change = boxed(FOREIGN, &t, 1, 6_498_900_000, 0);
    let tx = pending(&t, &[&theirs], &[&incoming, &their_change]);
    let reads = || vec![read(A, vec![mine.clone()], vec![tx.clone()])];

    let allowed = spendable_across(reads(), true);
    let waiting = spendable_across(reads(), false);
    let summary = pending_summary(&[mine.clone()], &[tx.clone()], &[A.to_string()].into());

    // Nothing is created or lost between the views: what waiting leaves out
    // is exactly what allowing adds, and both agree with the valuation.
    assert_eq!(total(&allowed.inputs), summary.balance_nano_erg());
    assert_eq!(
        total(&waiting.inputs) + total(&waiting.held_back),
        total(&allowed.inputs)
    );
    assert_eq!(total(&waiting.inputs), summary.confirmed_nano_erg - summary.pending_out_nano_erg);
    assert_eq!(total(&waiting.held_back), summary.pending_in_nano_erg);
    assert_eq!(waiting.held_back[0].assets[0].amount, "7");
}

#[test]
fn a_chained_spend_listed_under_another_address_still_counts() {
    // A's confirmed box pays B (pending); a second pending transaction then
    // spends that unconfirmed box back to A. The node lists the second one
    // under A only: its input was never confirmed, so B's script does not
    // match it, and it pays nothing to B.
    let root = boxed(A, &tx_id(1), 0, 5 * ERG, 0);
    let t1 = tx_id(5);
    let middle = boxed(B, &t1, 0, 4_998_900_000, 0);
    let first = pending(&t1, &[&root], &[&middle]);
    let t2 = tx_id(6);
    let end = boxed(A, &t2, 0, 4_997_800_000, 0);
    let second = pending(&t2, &[&middle], &[&end]);

    let reads = vec![
        read(A, vec![root.clone()], vec![first.clone(), second.clone()]),
        read(B, vec![], vec![first.clone()]),
    ];
    let s = spendable_across(reads, true);
    assert_eq!(
        offered(&s),
        vec![id(&end)],
        "the middle box is spent even though B's own list does not say so"
    );

    // Valued once over the union, the chain nets to the two fees.
    let trees = [A.to_string(), B.to_string()].into();
    let summary = pending_summary(&[root.clone()], &unique_transactions([
        [first.clone(), second.clone()].as_slice(),
        [first.clone()].as_slice(),
    ]), &trees);
    assert_eq!(summary.pending_out_nano_erg, 5 * ERG);
    assert_eq!(summary.pending_in_nano_erg, 4_997_800_000);
    assert_eq!(summary.pending_transactions, 2);
    assert_eq!(summary.balance_nano_erg(), 4_997_800_000);
}

#[test]
fn a_transaction_listed_by_two_addresses_is_kept_once() {
    let t = tx_id(7);
    let a = vec![serde_json::json!({"id": t, "inputs": [], "outputs": []})];
    let b = a.clone();
    let anonymous = vec![serde_json::json!({"inputs": [{"boxId": "x"}]})];
    let union = unique_transactions([a.as_slice(), b.as_slice(), anonymous.as_slice()]);
    assert_eq!(union.len(), 2, "one per id, and an id-less one still counts");
}

#[test]
fn a_box_seen_twice_is_offered_once_and_the_confirmed_copy_wins() {
    // A block lands between the listing and the mempool read: the output is
    // confirmed already but its transaction is still listed as pending.
    let t = tx_id(8);
    let landed = boxed(A, &t, 0, ERG, 0);
    let tx = pending(&t, &[], &[&landed]);
    for allow in [true, false] {
        let s = spendable_across(
            vec![
                read(A, vec![landed.clone()], vec![tx.clone()]),
                read(A, vec![landed.clone()], vec![tx.clone()]),
            ],
            allow,
        );
        assert_eq!(offered(&s), vec![id(&landed)]);
        assert!(s.unconfirmed.is_empty(), "allow={allow}");
        assert!(s.held_back.is_empty(), "allow={allow}");
    }
    let summary = pending_summary(&[landed.clone()], &[tx], &[A.to_string()].into());
    assert_eq!(summary.pending_in_nano_erg, 0, "not counted twice");
    assert_eq!(summary.balance_nano_erg(), ERG);
}

#[test]
fn removing_boxes_keeps_the_pair_aligned() {
    let s = sent_with_change();
    let mut spendable = spendable_across(
        vec![read(A, vec![s.spent.clone(), s.kept.clone()], vec![s.tx.clone()])],
        true,
    );
    spendable.remove(&[id(&s.change)].into());
    assert_eq!(offered(&spendable), vec![id(&s.kept)]);
    assert_eq!(id(&spendable.boxes[0]), id(&s.kept));
    assert!(spendable.unconfirmed.is_empty());
}

#[test]
fn a_self_transfer_shows_on_both_sides_and_nets_to_the_fee() {
    let from = boxed(A, &tx_id(1), 0, 2 * ERG, 10);
    let t = tx_id(9);
    let to = boxed(B, &t, 0, 1_998_900_000, 10);
    let tx = pending(&t, &[&from], &[&to]);
    let trees = [A.to_string(), B.to_string()].into();
    let summary = pending_summary(&[from.clone()], &[tx.clone()], &trees);
    assert_eq!(summary.confirmed_nano_erg, 2 * ERG);
    assert_eq!(summary.pending_out_nano_erg, 2 * ERG);
    assert_eq!(summary.pending_in_nano_erg, 1_998_900_000);
    assert_eq!(summary.balance_nano_erg(), 1_998_900_000);
    assert_eq!(
        summary.tokens,
        vec![TokenFlow {
            token_id: TOKEN.into(),
            confirmed: 10,
            pending_in: 10,
            pending_out: 10
        }]
    );
    assert_eq!(summary.tokens[0].amount(), 10);

    // The same arithmetic the activity rows use for one transaction.
    let values = [(id(&from), (2 * ERG) as i64)].into_iter().collect();
    let delta = wallet_balance_delta(&[tx], &trees, &values);
    assert_eq!(
        summary.balance_nano_erg() as i64,
        summary.confirmed_nano_erg as i64 + delta
    );
}

#[test]
fn tokens_received_only_in_the_mempool_are_listed() {
    let theirs = boxed(FOREIGN, &tx_id(1), 0, ERG, 0);
    let t = tx_id(10);
    let gift = boxed(A, &t, 0, 1_000_000, 50);
    let tx = pending(&t, &[&theirs], &[&gift]);
    let summary = pending_summary(&[], &[tx], &[A.to_string()].into());
    assert_eq!(summary.confirmed_nano_erg, 0);
    assert_eq!(summary.pending_in_nano_erg, 1_000_000);
    assert_eq!(summary.tokens.len(), 1);
    assert_eq!(summary.tokens[0].confirmed, 0);
    assert_eq!(summary.tokens[0].pending_in, 50);
    let json = summary.to_json();
    assert_eq!(json["balance_nano_erg"], 1_000_000);
    assert_eq!(json["tokens"][0]["amount"], 50);
    assert_eq!(json["pending_transactions"], 1);
}

#[test]
fn nothing_pending_leaves_the_confirmed_figures() {
    let only = boxed(A, &tx_id(1), 0, ERG, 3);
    let summary = pending_summary(&[only.clone(), only.clone()], &[], &[A.to_string()].into());
    assert_eq!(summary.confirmed_nano_erg, ERG, "a box listed twice counts once");
    assert_eq!(summary.pending_in_nano_erg + summary.pending_out_nano_erg, 0);
    assert_eq!(summary.pending_transactions, 0);
    assert_eq!(summary.tokens[0].amount(), 3);
}
