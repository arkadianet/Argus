use super::*;
use std::{hint::black_box, time::Instant};

const TREE: &str = "0008cd03986ae12afbc27b9436ce23cb90faf7864376c5250b6a019d45a7aabfc7c910c9";
type Pair = (Vec<ErgoBox>, Vec<ergo_tx::Eip12InputBox>);

fn fixture(index: u16, rich: bool) -> ErgoBox {
    serde_json::from_value(serde_json::json!({
        "transactionId": "91".repeat(32), "index": index,
        "value": 10000000, "ergoTree": TREE,
        "creationHeight": 1,
        "assets": if rich { serde_json::json!([{ "tokenId": "ab".repeat(32), "amount": 42 }]) } else { serde_json::json!([]) },
        "additionalRegisters": if rich { serde_json::json!({"R4": "0402"}) } else { serde_json::json!({}) }
    })).unwrap()
}

fn pair(boxes: Vec<ErgoBox>) -> Pair {
    let inputs = boxes
        .iter()
        .map(|b| ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index))
        .collect();
    (boxes, inputs)
}

// Independent pre-change nonempty-mempool path, including discarded conversion.
fn old(confirmed_boxes: Pair, txs: &[serde_json::Value], tree: &str) -> Pair {
    let spent = spent_box_ids(txs);
    let (confirmed, _) = confirmed_boxes;
    let mut boxes: Vec<ErgoBox> = confirmed
        .into_iter()
        .filter(|b| !spent.contains(&b.box_id().to_string()))
        .collect();
    for b in owned_outputs(txs, tree) {
        if !spent.contains(&b.box_id().to_string()) {
            boxes.push(b);
        }
    }
    let inputs = boxes
        .iter()
        .map(|b| ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index))
        .collect();
    (boxes, inputs)
}

#[test]
fn merge_matches_old_tuple_bytes() {
    let confirmed = vec![fixture(0, true), fixture(1, false), fixture(0, true)];
    let pending = fixture(2, true);
    let final_output = fixture(3, false);
    let cases = [
        vec![serde_json::json!({})],
        vec![serde_json::json!({"inputs": [{"boxId": confirmed[0].box_id().to_string()}]})],
        vec![
            serde_json::json!({"inputs": confirmed.iter().map(|b| serde_json::json!({"boxId": b.box_id().to_string()})).collect::<Vec<_>>()}),
        ],
        vec![
            serde_json::json!({"id": "91".repeat(32), "inputs": [{"boxId": confirmed[0].box_id().to_string()}], "outputs": [pending, confirmed[1]]}),
            serde_json::json!({"id": "91".repeat(32), "inputs": [{"boxId": pending.box_id().to_string()}], "outputs": [final_output, {"ergoTree": TREE}, {"ergoTree": "00"}]}),
            serde_json::json!({"outputs": [final_output]}),
        ],
    ];
    for boxes in [vec![], confirmed] {
        for txs in &cases {
            let before = old(pair(boxes.clone()), txs, TREE);
            let after = merge_confirmed(pair(boxes.clone()), txs, TREE);
            assert_eq!(
                serde_json::to_vec(&before).unwrap(),
                serde_json::to_vec(&after).unwrap()
            );
        }
    }
}

#[test]
#[ignore = "release local benchmark; includes initial confirmed EIP-12 conversion"]
fn mempool_merge_benchmark() {
    for n in [1, 100, 500, 1000, 10000] {
        let boxes: Vec<_> = (0..n).map(|i| fixture(i, false)).collect();
        let txs = vec![
            serde_json::json!({"id": "91".repeat(32), "inputs": [{"boxId": boxes[0].box_id().to_string()}], "outputs": [fixture(10001, false)]}),
        ];
        assert_eq!(
            serde_json::to_vec(&old(pair(boxes.clone()), &txs, TREE)).unwrap(),
            serde_json::to_vec(&merge_confirmed(pair(boxes.clone()), &txs, TREE)).unwrap()
        );
        for trial in 0..3 {
            let mut times = [0.0; 2];
            for which in if trial % 2 == 0 { [0, 1] } else { [1, 0] } {
                let owned = boxes.clone(); // setup excluded; conversions included
                let start = Instant::now();
                let confirmed = pair(black_box(owned));
                let result = if which == 0 {
                    old(confirmed, &txs, TREE)
                } else {
                    merge_confirmed(confirmed, &txs, TREE)
                };
                times[which] = start.elapsed().as_secs_f64() * 1000.0;
                black_box(result);
            }
            println!(
                "merge N={n} trial={trial} old_ms={:.6} reuse_ms={:.6}",
                times[0], times[1]
            );
        }
    }
}
