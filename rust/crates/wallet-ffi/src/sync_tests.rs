use super::*;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar};
use std::time::Duration;

struct ReplayNode {
    url: String,
    reads: Arc<(Mutex<(usize, usize)>, Condvar)>,
    concurrent: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl ReplayNode {
    fn start(fail_boxes: bool, fail_mempool: bool) -> Self {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../vendor/protocols/zerojoin/test/fixtures/half_mix_boxes.json"
        ))
        .unwrap();
        let tree = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        let pending = serde_json::json!([{
            "id": "pending-test",
            "inputs": [{"boxId": fixture["items"][0]["boxId"]}],
            "outputs": [{"ergoTree": tree, "value": 123, "assets": []}]
        }]);
        let boxes = serde_json::json!([fixture["items"][0], fixture["items"][1]]);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let reads = Arc::new((Mutex::new((0, 0)), Condvar::new()));
        let concurrent = Arc::new(AtomicBool::new(true));
        let (stopped, counts, paired) = (stop.clone(), reads.clone(), concurrent.clone());
        let thread = std::thread::spawn(move || {
            let mut workers = Vec::new();
            while !stopped.load(Ordering::Relaxed) {
                let Ok((mut stream, _)) = listener.accept() else {
                    std::thread::sleep(Duration::from_millis(1));
                    continue;
                };
                let (counts, paired, boxes, pending) = (
                    counts.clone(),
                    paired.clone(),
                    boxes.clone(),
                    pending.clone(),
                );
                workers.push(std::thread::spawn(move || {
                    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                    let mut buffer = [0; 8192];
                    let n = stream.read(&mut buffer).unwrap();
                    let request = String::from_utf8_lossy(&buffer[..n]);
                    let unspent = request.contains("/blockchain/box/unspent/byAddress");
                    let mempool = request.contains("/transactions/unconfirmed/byErgoTree");
                    if unspent || mempool {
                        let (lock, ready) = &*counts;
                        let mut counts = lock.lock().unwrap();
                        if unspent { counts.0 += 1; } else { counts.1 += 1; }
                        ready.notify_all();
                        let (_counts, timeout) = ready.wait_timeout_while(counts, Duration::from_secs(2), |c| c.0 == 0 || c.1 == 0).unwrap();
                        if timeout.timed_out() { paired.store(false, Ordering::Relaxed); }
                    }
                    let failed = (unspent && fail_boxes) || (mempool && fail_mempool);
                    let reply = if failed { "unavailable".into() } else if unspent { boxes.to_string() }
                        else if mempool { pending.to_string() }
                        else if request.contains("/info") { r#"{"fullHeight":1500000,"headersHeight":1500000}"#.into() }
                        else { "1500000".into() };
                    let status = if failed { "500 Internal Server Error" } else { "200 OK" };
                    write!(stream, "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len()).unwrap();
                }));
            }
            for worker in workers {
                worker.join().unwrap();
            }
        });
        Self {
            url,
            reads,
            concurrent,
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for ReplayNode {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.thread.take().unwrap().join().unwrap();
    }
}

#[tokio::test]
async fn sync_reads_once_concurrently_and_shares_pending_valuation() {
    let node = ReplayNode::start(false, false);
    let raw = get_sync_inputs(
        vec![ARGUS_FEE_ADDRESS.into(), ARGUS_FEE_ADDRESS.into()],
        Some(node.url.clone()),
    )
    .await
    .unwrap();
    let result: serde_json::Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(*node.reads.0.lock().unwrap(), (1, 1));
    assert!(
        node.concurrent.load(Ordering::Relaxed),
        "UTXO and mempool requests must overlap"
    );
    assert_eq!(result["utxo_count"], 2);
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../vendor/protocols/zerojoin/test/fixtures/half_mix_boxes.json"
    ))
    .unwrap();
    let first = fixture["items"][0]["value"].as_i64().unwrap();
    let second = fixture["items"][1]["value"].as_i64().unwrap();
    assert_eq!(
        result["balances"][ARGUS_FEE_ADDRESS]["balance_nano_erg"],
        second + 123
    );
    assert_eq!(result["pending"][0]["value_nano_erg"], 123 - first);
    assert_eq!(result["pending"].as_array().unwrap().len(), 1);
    // A second explicit refresh must fetch again, even within the same second.
    get_sync_inputs(vec![ARGUS_FEE_ADDRESS.into()], Some(node.url.clone()))
        .await
        .unwrap();
    assert_eq!(*node.reads.0.lock().unwrap(), (2, 2));
}

#[tokio::test]
async fn sync_failed_listing_is_missing_not_a_zero_balance_or_count() {
    let node = ReplayNode::start(true, false);
    let raw = get_sync_inputs(vec![ARGUS_FEE_ADDRESS.into()], Some(node.url.clone()))
        .await
        .unwrap();
    let result: serde_json::Value = serde_json::from_str(&raw).unwrap();
    assert!(result["balances"].as_object().unwrap().is_empty());
    assert!(result["utxo_count"].is_null());
}

#[tokio::test]
async fn sync_mempool_failure_preserves_confirmed_balance() {
    let node = ReplayNode::start(false, true);
    let raw = get_sync_inputs(vec![ARGUS_FEE_ADDRESS.into()], Some(node.url.clone()))
        .await
        .unwrap();
    let result: serde_json::Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(result["utxo_count"], 2);
    assert!(
        result["balances"][ARGUS_FEE_ADDRESS]["balance_nano_erg"]
            .as_i64()
            .unwrap()
            > 0
    );
    assert!(result["pending"].as_array().unwrap().is_empty());
}
