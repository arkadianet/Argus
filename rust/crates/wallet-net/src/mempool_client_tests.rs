//! The mempool reads against a local stand-in node: status handling, paging,
//! and the box-by-box checks. A failed read must never look like an empty
//! mempool, because "nothing pending" means "every confirmed box is free".

use super::*;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};

/// Answers every request with `reply(method_and_path)` until dropped.
struct Node {
    port: String,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    seen: Arc<std::sync::Mutex<Vec<String>>>,
}

impl Node {
    fn start(reply: impl Fn(&str) -> (u16, String) + Send + Sync + 'static) -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port().to_string();
        forget_mempool_routes(&format!("http://127.0.0.1:{port}/"));
        let stop = Arc::new(AtomicBool::new(false));
        let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let (stopped, log) = (stop.clone(), seen.clone());
        let thread = std::thread::spawn(move || {
            while !stopped.load(Ordering::SeqCst) {
                let Ok((mut stream, _)) = listener.accept() else {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                    continue;
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                let mut buf = [0; 4096];
                loop {
                    let n = stream.read(&mut buf).unwrap();
                    assert!(n > 0);
                    request.extend_from_slice(&buf[..n]);
                    if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&request[..end]).to_string();
                        let length: usize = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length: ")
                                    .map(|v| v.parse().unwrap())
                            })
                            .unwrap_or(0);
                        if request.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                let line = String::from_utf8_lossy(&request)
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .to_string();
                let target = line.rsplit_once(' ').map(|(l, _)| l).unwrap_or(&line).to_string();
                log.lock().unwrap().push(target.clone());
                let (status, body) = reply(&target);
                // A bodiless answer has no content type, as the Rust node's
                // unrouted paths and a proxy's refusals have none.
                let kind = match body.is_empty() {
                    true => "",
                    false => "Content-Type: application/json\r\n",
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} Test\r\n{kind}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        Self {
            port,
            stop,
            thread: Some(thread),
            seen,
        }
    }

    fn client(&self) -> ErgoNodeClient {
        let inner = NodeInterface::new_without_probe("", "127.0.0.1", &self.port).unwrap();
        ErgoNodeClient {
            inner: Arc::new(inner),
            url: String::new(),
        }
    }

    fn requests(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

const TREE: &str = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

/// A Scala node's answer for a box its mempool (or UTXO set) does not hold.
const NOT_FOUND: &str = r#"{"error":404,"reason":"not-found","detail":null}"#;

fn page(from: usize, n: usize) -> String {
    serde_json::to_string(
        &(from..from + n)
            .map(|i| serde_json::json!({"id": format!("{i:064x}"), "inputs": [], "outputs": []}))
            .collect::<Vec<_>>(),
    )
    .unwrap()
}

fn offset_of(target: &str) -> usize {
    target
        .split("offset=")
        .nth(1)
        .and_then(|s| s.split('&').next())
        .and_then(|s| s.parse().ok())
        .unwrap()
}

#[tokio::test]
async fn an_error_status_is_a_failed_read_not_an_empty_mempool() {
    // A JSON error body parses fine; only the status says it failed.
    let node = Node::start(|_| (500, r#"{"error":500,"reason":"oops"}"#.into()));
    let client = node.client();
    assert!(client.mempool_txs_for(TREE).await.is_err());
    assert!(client.mempool_txs_complete(TREE).await.is_err());
}

#[tokio::test]
async fn pages_are_read_until_a_short_one() {
    let node = Node::start(|target| match offset_of(target) {
        0 => (200, page(0, 100)),
        100 => (200, page(100, 3)),
        _ => (500, String::new()),
    });
    let client = node.client();
    // The display read takes one pass.
    assert_eq!(client.mempool_txs_for(TREE).await.unwrap().len(), 103);
    let offsets = || {
        node.requests()
            .iter()
            .map(|r| offset_of(r))
            .collect::<Vec<_>>()
    };
    assert_eq!(offsets(), [0, 100]);
    // The spending read takes a second to see that the list held still.
    assert_eq!(client.mempool_txs_complete(TREE).await.unwrap().len(), 103);
    assert_eq!(offsets(), [0, 100, 0, 100, 0, 100]);
}

#[tokio::test]
async fn a_list_past_the_cap_shows_but_cannot_be_spent_from() {
    let node = Node::start(|target| (200, page(offset_of(target), 100)));
    let client = node.client();
    assert_eq!(client.mempool_txs_for(TREE).await.unwrap().len(), MEMPOOL_MAX_TXS);
    let error = client.mempool_txs_complete(TREE).await.unwrap_err();
    assert!(error.contains("cannot all be checked"), "{error}");
}

#[tokio::test]
async fn a_pending_spend_is_read_by_box_id() {
    let node = Node::start(|target| {
        if target.ends_with("/spent") {
            (200, r#"{"boxId":"spent","spendingProof":{}}"#.into())
        } else if target.ends_with("/free") {
            (404, NOT_FOUND.into())
        } else if target.ends_with("/nothing") {
            (200, "null".into())
        } else if target.ends_with("/other") {
            (200, r#"{"boxId":"someone-else"}"#.into())
        } else {
            (503, String::new())
        }
    });
    let client = node.client();
    assert!(client.mempool_spends("spent").await.unwrap());
    assert!(!client.mempool_spends("free").await.unwrap());
    // A success without the box is "not found", never "spent".
    assert!(!client.mempool_spends("nothing").await.unwrap());
    // An answer about another box is an error, not a guess either way.
    assert!(client.mempool_spends("other").await.is_err());
    assert!(client.mempool_spends("broken").await.is_err());
    assert!(node
        .requests()
        .iter()
        .all(|r| r.starts_with("GET /transactions/unconfirmed/inputs/byBoxId/")));
}

#[tokio::test]
async fn box_status_tells_pending_confirmed_and_gone_apart() {
    let node = Node::start(|target| {
        let (kind, id) = target.rsplit_once('/').unwrap();
        let found = match (kind, id) {
            (k, "pending-spent") if k.ends_with("inputs/byBoxId") => true,
            (k, "settled") if k.ends_with("/utxo/byId") => true,
            (k, "fresh") if k.ends_with("outputs/byBoxId") => true,
            _ => false,
        };
        if found {
            (200, format!(r#"{{"boxId":"{id}","ergoTree":"{TREE}"}}"#))
        } else {
            (404, NOT_FOUND.into())
        }
    });
    let client = node.client();
    assert_eq!(client.box_status("pending-spent").await.unwrap(), BoxStatus::SpentInMempool);
    assert_eq!(client.box_status("settled").await.unwrap(), BoxStatus::Confirmed);
    match client.box_status("fresh").await.unwrap() {
        BoxStatus::Unconfirmed(b) => assert_eq!(b["ergoTree"], TREE),
        other => panic!("expected an unconfirmed box, got {other:?}"),
    }
    assert_eq!(client.box_status("gone").await.unwrap(), BoxStatus::Unknown);
}

#[tokio::test]
async fn a_spending_read_fails_when_the_mempool_cannot_be_read() {
    let address = "9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ";
    let node = Node::start(|target| {
        if target.contains("unspent/byAddress") {
            (200, "[]".into())
        } else {
            (502, "bad gateway".into())
        }
    });
    let error = node.client().read_for_spending(address).await.unwrap_err();
    assert!(error.contains("Could not check pending transactions"), "{error}");
}

#[tokio::test]
async fn only_unconfirmed_boxes_nothing_pending_spends_stay_offered() {
    let node = Node::start(|target| {
        let id = target.rsplit('/').next().unwrap_or_default();
        match id {
            "free" | "still-coming" => (404, NOT_FOUND.into()),
            "spent" | "forwarded" => (200, format!(r#"{{"boxId":"{id}"}}"#)),
            _ => (500, String::new()),
        }
    });
    let fixture = |index: u16| -> ErgoBox {
        serde_json::from_value(serde_json::json!({
            "transactionId": "91".repeat(32), "index": index, "value": 1000000,
            "ergoTree": TREE, "creationHeight": 1, "assets": [], "additionalRegisters": {}
        }))
        .unwrap()
    };
    let mut spendable = crate::mempool::Spendable::default();
    let mut ids = Vec::new();
    for (i, name) in ["confirmed", "free", "spent", "unreadable"].iter().enumerate() {
        let b = fixture(i as u16);
        let mut input = ergo_tx::Eip12InputBox::from_ergo_box(&b, b.transaction_id.to_string(), b.index);
        input.box_id = name.to_string();
        if *name != "confirmed" {
            spendable.unconfirmed.insert(name.to_string());
        }
        ids.push(name.to_string());
        spendable.boxes.push(b);
        spendable.inputs.push(input);
    }
    // What waiting held back is checked the same way: a box a pending
    // transaction paying elsewhere already spent is not "still confirming".
    for name in ["still-coming", "forwarded", "unknown"] {
        let b = fixture(9);
        let mut input =
            ergo_tx::Eip12InputBox::from_ergo_box(&b, b.transaction_id.to_string(), b.index);
        input.box_id = name.to_string();
        spendable.held_back.push(input);
    }
    node.client().drop_spent_unconfirmed(&mut spendable, 4).await;
    assert_eq!(
        spendable.inputs.iter().map(|i| i.box_id.as_str()).collect::<Vec<_>>(),
        ["confirmed", "free"]
    );
    assert_eq!(spendable.boxes.len(), 2);
    assert_eq!(spendable.unconfirmed, ["free".to_string()].into());
    assert_eq!(
        spendable.held_back.iter().map(|i| i.box_id.as_str()).collect::<Vec<_>>(),
        ["still-coming"]
    );
    // Confirmed boxes are not looked up one by one.
    assert!(!node.requests().iter().any(|r| r.ends_with("/confirmed")));
}

#[tokio::test]
async fn a_long_list_is_read_until_it_holds_still() {
    // Two pages; a transaction arrives between the first and second pass,
    // and the third pass agrees with the second.
    let passes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = passes.clone();
    let node = Node::start(move |target| {
        let offset = offset_of(target);
        if offset == 0 {
            seen.fetch_add(1, Ordering::SeqCst);
        }
        let extra = usize::from(seen.load(Ordering::SeqCst) >= 2);
        match offset {
            0 => (200, page(0, 100)),
            100 => (200, page(100, 3 + extra)),
            _ => (500, String::new()),
        }
    });
    let txs = node.client().mempool_txs_complete(TREE).await.unwrap();
    assert_eq!(txs.len(), 104, "the settled list, not the first pass");
    assert_eq!(passes.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn a_list_that_never_holds_still_is_not_trusted() {
    let passes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = passes.clone();
    let node = Node::start(move |target| {
        let offset = offset_of(target);
        if offset == 0 {
            seen.fetch_add(1, Ordering::SeqCst);
        }
        match offset {
            0 => (200, page(0, 100)),
            // A different tail on every pass.
            100 => (200, page(100 + 10 * seen.load(Ordering::SeqCst), 3)),
            _ => (500, String::new()),
        }
    });
    let error = node.client().mempool_txs_complete(TREE).await.unwrap_err();
    assert!(error.contains("kept changing"), "{error}");
    // A single page is one answer and needs no second pass.
    let one = Node::start(|_| (200, page(0, 7)));
    assert_eq!(one.client().mempool_txs_complete(TREE).await.unwrap().len(), 7);
    assert_eq!(one.requests().len(), 1);
}

// ─── Nodes that do not answer by id ──────────────────────────────────────
//
// The Rust node serves neither `/transactions/unconfirmed/{inputs,outputs}/
// byBoxId`: both answer 404 with no body. Its own API answers spends at
// `/api/v1/mempool/by-box-id`, unless a proxy shuts `/api/v1` with a
// bodiless 403. None of those may read as "nothing pending".

fn id_of(target: &str) -> &str {
    target.rsplit('/').next().unwrap_or_default()
}

fn is_scala_by_id(target: &str) -> bool {
    target.contains("/transactions/unconfirmed/inputs/byBoxId/")
        || target.contains("/transactions/unconfirmed/outputs/byBoxId/")
}

fn is_native(target: &str) -> bool {
    target.contains("/api/v1/mempool/by-box-id/")
}

fn is_whole_mempool(target: &str) -> bool {
    target.starts_with("GET /transactions/unconfirmed?")
}

/// A pending transaction spending `inputs` and creating `outputs`.
fn pending_tx(id: &str, inputs: &[&str], outputs: &[&str]) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "inputs": inputs.iter().map(|b| serde_json::json!({"boxId": b})).collect::<Vec<_>>(),
        "outputs": outputs
            .iter()
            .map(|b| serde_json::json!({"boxId": b, "value": 1000000, "ergoTree": TREE}))
            .collect::<Vec<_>>(),
    })
}

/// The Rust node behind its proxy today: by-id routes 404 with no body,
/// `/api/v1` shut with a bodiless 403, and the whole mempool `txs`.
fn rust_node(txs: Vec<serde_json::Value>) -> Node {
    let list = serde_json::to_string(&txs).unwrap();
    Node::start(move |target| {
        if is_scala_by_id(target) {
            (404, String::new())
        } else if is_native(target) {
            (403, String::new())
        } else if is_whole_mempool(target) {
            (200, list.clone())
        } else if target.contains("/utxo/byId/") {
            match id_of(target) {
                "settled" => (200, r#"{"boxId":"settled"}"#.into()),
                _ => (404, NOT_FOUND.into()),
            }
        } else {
            (403, String::new())
        }
    })
}

#[tokio::test]
async fn a_scala_not_found_is_not_spent_and_the_route_is_remembered() {
    let node = Node::start(|target| match is_scala_by_id(target) {
        true => (404, NOT_FOUND.into()),
        false => (500, String::new()),
    });
    let client = node.client();
    assert_eq!(client.spend_route(), None);
    assert!(!client.mempool_spends("free").await.unwrap());
    assert_eq!(client.spend_route(), Some(SpendRoute::InputsByBoxId));
    // Remembered per node: a later client for it asks the same route only.
    assert!(!node.client().mempool_spends("also-free").await.unwrap());
    assert_eq!(
        node.requests(),
        [
            "GET /transactions/unconfirmed/inputs/byBoxId/free",
            "GET /transactions/unconfirmed/inputs/byBoxId/also-free",
        ]
    );
}

#[tokio::test]
async fn an_empty_404_is_not_read_as_not_spent() {
    let node = rust_node(vec![pending_tx("t1", &["forwarded"], &["fresh"])]);
    let client = node.client();
    // The by-id route and the shut native one are passed over; the whole
    // mempool finds the spend.
    assert!(client.mempool_spends("forwarded").await.unwrap());
    assert_eq!(
        node.requests(),
        [
            "GET /transactions/unconfirmed/inputs/byBoxId/forwarded",
            "GET /api/v1/mempool/by-box-id/forwarded",
            "GET /transactions/unconfirmed?offset=0&limit=100",
        ]
    );
    assert_eq!(client.spend_route(), Some(SpendRoute::WholeMempool));
    // Remembered: the next lookup goes straight to the mempool.
    assert!(!node.client().mempool_spends("free").await.unwrap());
    assert_eq!(node.requests().len(), 4);
    assert!(is_whole_mempool(&node.requests()[3]));
}

#[tokio::test]
async fn when_the_whole_mempool_cannot_be_read_the_lookup_fails() {
    for (status, body) in [(500, r#"{"error":500}"#), (200, ""), (200, r#"{"error":1}"#)] {
        let node = Node::start(move |target| {
            if is_scala_by_id(target) {
                (404, String::new())
            } else if is_native(target) {
                (403, String::new())
            } else {
                (status, body.into())
            }
        });
        let client = node.client();
        let error = client.mempool_spends("free").await.unwrap_err();
        assert!(error.contains("Mempool"), "{status} {body:?}: {error}");
        // Nothing learned from a failure.
        assert_eq!(client.spend_route(), None);
    }
    // A transaction listed without its inputs' ids could hide the spend.
    let node = Node::start(|target| match is_whole_mempool(target) {
        true => (200, r#"[{"id":"t1","inputs":[{}],"outputs":[]}]"#.into()),
        false => (404, String::new()),
    });
    let error = node.client().mempool_spends("free").await.unwrap_err();
    assert!(error.contains("without its box ids"), "{error}");
}

#[tokio::test]
async fn a_404_needs_the_nodes_not_found_to_mean_not_found() {
    // JSON, but not the node's not-found: a proxy's or a stand-in's page.
    for body in [r#"{"error":404}"#, r#"{"reason":"not-found"}"#, "<html>404</html>"] {
        let node = Node::start(move |target| {
            if is_scala_by_id(target) {
                (404, body.into())
            } else if is_native(target) {
                (404, String::new())
            } else {
                (200, serde_json::to_string(&[pending_tx("t1", &["gone"], &[])]).unwrap())
            }
        });
        assert!(node.client().mempool_spends("gone").await.unwrap(), "{body}");
        assert_eq!(node.client().spend_route(), Some(SpendRoute::WholeMempool));
    }
}

#[tokio::test]
async fn the_rust_nodes_own_lookup_answers_when_it_is_reachable() {
    let node = Node::start(|target| {
        if is_scala_by_id(target) {
            (404, String::new())
        } else if is_native(target) {
            match id_of(target) {
                "forwarded" => (
                    200,
                    r#"{"items":[{"tx_id":"t1","fee":"1000000","fee_per_byte":"4000","size_bytes":250,"input_count":1,"output_count":2}],"page":{"limit":50,"next_cursor":null}}"#.into(),
                ),
                _ => (200, r#"{"items":[],"page":{"limit":50,"next_cursor":null}}"#.into()),
            }
        } else {
            (500, String::new())
        }
    });
    let client = node.client();
    assert!(client.mempool_spends("forwarded").await.unwrap());
    assert_eq!(client.spend_route(), Some(SpendRoute::Native));
    assert!(!client.mempool_spends("free").await.unwrap());
    assert_eq!(
        node.requests(),
        [
            "GET /transactions/unconfirmed/inputs/byBoxId/forwarded",
            "GET /api/v1/mempool/by-box-id/forwarded",
            "GET /api/v1/mempool/by-box-id/free",
        ]
    );
}

#[tokio::test]
async fn a_rust_node_that_cannot_filter_its_mempool_is_read_whole() {
    let node = Node::start(|target| {
        if is_scala_by_id(target) {
            (404, String::new())
        } else if is_native(target) {
            (409, r#"{"error":"Mempool filtering not wired on this node"}"#.into())
        } else if is_whole_mempool(target) {
            (200, serde_json::to_string(&[pending_tx("t1", &["forwarded"], &[])]).unwrap())
        } else {
            (500, String::new())
        }
    });
    let client = node.client();
    assert!(client.mempool_spends("forwarded").await.unwrap());
    assert!(!client.mempool_spends("free").await.unwrap());
    assert_eq!(client.spend_route(), Some(SpendRoute::WholeMempool));
}

#[tokio::test]
async fn the_rust_nodes_odd_answers_are_errors_not_guesses() {
    let node = Node::start(|target| {
        if is_scala_by_id(target) {
            (404, String::new())
        } else if target.ends_with("/refused") {
            (400, r#"{"error":"invalid box id"}"#.into())
        } else {
            // No spender here, but another page to come.
            (200, r#"{"items":[],"page":{"limit":50,"next_cursor":"abc"}}"#.into())
        }
    });
    let client = node.client();
    assert!(client.mempool_spends("refused").await.unwrap_err().contains("refused"));
    assert!(client.mempool_spends("paged").await.unwrap_err().contains("more to come"));
    assert_eq!(client.spend_route(), None);
}

#[tokio::test]
async fn box_status_on_a_node_without_by_id_lookups() {
    let node = rust_node(vec![pending_tx("t1", &["pending-spent"], &["fresh"])]);
    let client = node.client();
    assert_eq!(client.box_status("pending-spent").await.unwrap(), BoxStatus::SpentInMempool);
    assert_eq!(client.box_status("settled").await.unwrap(), BoxStatus::Confirmed);
    let before = node.requests().len();
    match client.box_status("fresh").await.unwrap() {
        BoxStatus::Unconfirmed(b) => assert_eq!(b["ergoTree"], TREE),
        other => panic!("expected an unconfirmed box, got {other:?}"),
    }
    assert_eq!(client.output_route(), Some(OutputRoute::WholeMempool));
    // One read of the mempool answered both questions for this box.
    let whole_reads = node.requests()[before..]
        .iter()
        .filter(|r| is_whole_mempool(r))
        .count();
    assert_eq!(whole_reads, 1, "{:?}", &node.requests()[before..]);
    assert_eq!(client.box_status("gone").await.unwrap(), BoxStatus::Unknown);
}

#[tokio::test]
async fn box_status_fails_when_nothing_answers_about_pending_outputs() {
    // Spends are answered by id; outputs by nothing.
    let node = Node::start(|target| {
        if target.contains("/inputs/byBoxId/") || target.contains("/utxo/byId/") {
            (404, NOT_FOUND.into())
        } else if target.contains("/outputs/byBoxId/") {
            (404, String::new())
        } else {
            (503, String::new())
        }
    });
    let error = node.client().box_status("fresh").await.unwrap_err();
    assert!(error.contains("503"), "{error}");
    // And a UTXO lookup without the node's not-found is no answer either.
    let node = Node::start(|target| match target.contains("/inputs/byBoxId/") {
        true => (404, NOT_FOUND.into()),
        false => (404, String::new()),
    });
    let error = node.client().box_status("fresh").await.unwrap_err();
    assert!(error.contains("UTXO lookup"), "{error}");
}

#[tokio::test]
async fn a_route_that_stops_answering_is_worked_out_again() {
    // A proxy starts shutting the by-id route after it was learned.
    let shut = Arc::new(AtomicBool::new(false));
    let shut_now = shut.clone();
    let node = Node::start(move |target| {
        if is_scala_by_id(target) {
            match shut_now.load(Ordering::SeqCst) {
                true => (404, String::new()),
                false => (404, NOT_FOUND.into()),
            }
        } else if is_native(target) {
            (403, String::new())
        } else {
            (200, serde_json::to_string(&[pending_tx("t1", &["forwarded"], &[])]).unwrap())
        }
    });
    let client = node.client();
    assert!(!client.mempool_spends("free").await.unwrap());
    assert_eq!(client.spend_route(), Some(SpendRoute::InputsByBoxId));
    shut.store(true, Ordering::SeqCst);
    assert!(client.mempool_spends("forwarded").await.unwrap());
    assert_eq!(client.spend_route(), Some(SpendRoute::WholeMempool));
}

#[tokio::test]
async fn one_read_of_the_whole_mempool_answers_every_box() {
    let node = rust_node(vec![pending_tx("t1", &["b", "d"], &[])]);
    let ids = ["a", "b", "c", "d", "e"].map(String::from).to_vec();
    let answers = node.client().mempool_spends_each(ids, 2).await;
    let spent: Vec<&str> = ["a", "b", "c", "d", "e"]
        .into_iter()
        .filter(|id| answers[*id] == Ok(true))
        .collect();
    assert_eq!(spent, ["b", "d"]);
    assert!(answers.values().all(|a| a.is_ok()));
    let whole_reads = node.requests().iter().filter(|r| is_whole_mempool(r)).count();
    assert_eq!(whole_reads, 1, "{:?}", node.requests());
}

#[tokio::test]
async fn the_whole_mempool_is_read_until_two_passes_agree() {
    // Two pages; a transaction spending the box arrives between the first
    // and second pass, and the third pass agrees with the second.
    let passes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = passes.clone();
    let node = Node::start(move |target| {
        if !is_whole_mempool(target) {
            return (404, String::new());
        }
        let offset = offset_of(target);
        if offset == 0 {
            seen.fetch_add(1, Ordering::SeqCst);
        }
        match offset {
            0 => (200, page(0, 100)),
            100 if seen.load(Ordering::SeqCst) >= 2 => (
                200,
                serde_json::to_string(&[pending_tx("late", &["forwarded"], &[])]).unwrap(),
            ),
            100 => (200, "[]".into()),
            _ => (500, String::new()),
        }
    });
    assert!(node.client().mempool_spends("forwarded").await.unwrap());
    assert_eq!(passes.load(Ordering::SeqCst), 3);
}
