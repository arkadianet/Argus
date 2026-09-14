use super::*;
use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use std::{hint::black_box, time::Instant};

fn fixture(index: u16) -> ErgoBox {
    serde_json::from_value(serde_json::json!({
        "transactionId": "91".repeat(32), "index": index,
        "value": 10000000,
        "ergoTree": "0008cd03986ae12afbc27b9436ce23cb90faf7864376c5250b6a019d45a7aabfc7c910c9",
        "creationHeight": 1, "assets": [], "additionalRegisters": {}
    }))
    .unwrap()
}

// Independent copy of both ordinary send paths before this change.
fn old(boxes: &[ErgoBox], selected: &[ergo_tx::Eip12InputBox]) -> Vec<ErgoBox> {
    selected
        .iter()
        .filter_map(|eip| {
            boxes
                .iter()
                .find(|b| b.box_id().to_string() == eip.box_id)
                .cloned()
        })
        .collect()
}

fn indexed(boxes: &[ErgoBox], selected: &[ergo_tx::Eip12InputBox]) -> Vec<ErgoBox> {
    let mut index = HashMap::with_capacity(boxes.len());
    for b in boxes {
        index.entry(b.box_id().to_string()).or_insert(b);
    }
    selected
        .iter()
        .filter_map(|e| index.get(&e.box_id).map(|b| (*b).clone()))
        .collect()
}

#[test]
#[ignore = "release microbenchmark; includes index construction and selected box clones"]
fn selected_lookup_benchmark() {
    for n in [1, 100, 500, 1000, 10000] {
        let boxes: Vec<_> = (0..n).map(|i| fixture(i as u16)).collect();
        for k in [1, 4, 10, n] {
            if k > n {
                continue;
            }
            for late in [false, true] {
                let selected: Vec<_> = (0..k)
                    .map(|i| {
                        let b = &boxes[if late { n - 1 - i } else { i }];
                        ergo_tx::Eip12InputBox::from_ergo_box(
                            b,
                            b.transaction_id.to_string(),
                            b.index,
                        )
                    })
                    .collect();
                assert_eq!(
                    serde_json::to_vec(&old(&boxes, &selected)).unwrap(),
                    serde_json::to_vec(&indexed(&boxes, &selected)).unwrap()
                );
                assert_eq!(
                    serde_json::to_vec(&old(&boxes, &selected)).unwrap(),
                    serde_json::to_vec(&selected_ergo_boxes(&boxes, &selected)).unwrap()
                );
                for trial in 0..3 {
                    let repeats = if k == n && n >= 1000 { 1 } else { 20 };
                    let mut times = [0.0; 3];
                    for which in if trial % 2 == 0 { [0, 1, 2] } else { [2, 1, 0] } {
                        let start = Instant::now();
                        for _ in 0..repeats {
                            black_box(if which == 0 {
                                old(black_box(&boxes), black_box(&selected))
                            } else if which == 1 {
                                indexed(black_box(&boxes), black_box(&selected))
                            } else {
                                selected_ergo_boxes(black_box(&boxes), black_box(&selected))
                            });
                        }
                        times[which] = start.elapsed().as_secs_f64() * 1000.0 / repeats as f64;
                    }
                    println!("lookup N={n} K={k} late={late} trial={trial} old_ms={:.6} index_ms={:.6} adaptive_ms={:.6}", times[0], times[1], times[2]);
                }
            }
        }
    }
}

#[test]
fn selected_lookup_matches_old_bytes_and_missing_count() {
    let a = fixture(0);
    let b = fixture(1);
    let c = fixture(2);
    let input = |b: &ErgoBox| {
        ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index)
    };
    // Repeated selected IDs, repeated candidates, reverse order, missing IDs,
    // and empty/single-input paths. Caller retains the same length/error check.
    for boxes in [
        vec![],
        vec![a.clone()],
        vec![a.clone(), b.clone(), a.clone(), c.clone()],
    ] {
        for selected in [
            vec![],
            vec![input(&a)],
            vec![input(&c), input(&a), input(&b), input(&a)],
            vec![input(&fixture(99)), input(&a), input(&fixture(98))],
        ] {
            let before = old(&boxes, &selected);
            let after = selected_ergo_boxes(&boxes, &selected);
            assert_eq!(
                serde_json::to_vec(&before).unwrap(),
                serde_json::to_vec(&after).unwrap()
            );
            assert_eq!(
                before.len() != selected.len(),
                after.len() != selected.len()
            );
        }
    }
}
