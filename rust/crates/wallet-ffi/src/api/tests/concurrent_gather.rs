use super::*;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn wallet(count: u32) -> (u64, Vec<String>) {
    let h = WalletHandle::restore_from_seed(&[42; 64]).unwrap();
    let mut addresses: Vec<_> = (0..count).map(|i| h.derive_address(i).unwrap()).collect();
    addresses.sort();
    (register_handle(h), addresses)
}

fn fixture(index: u16, tree: &str) -> ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox {
    serde_json::from_value(serde_json::json!({
        "transactionId": "91".repeat(32), "index": index,
        "value": 10000000, "ergoTree": tree,
        "creationHeight": 1, "assets": [], "additionalRegisters": {}
    }))
    .unwrap()
}

fn pair(boxes: Vec<ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox>) -> GatheredBoxes {
    let inputs = boxes
        .iter()
        .map(|b| ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index))
        .collect();
    (boxes, inputs)
}

// Independent reference: the pre-change serial gather, including first-ID wins.
async fn serial<F, Fut>(addresses: &[String], fetch: F) -> GatheredBoxes
where
    F: Fn(&str) -> Fut,
    Fut: std::future::Future<Output = GatheredBoxes>,
{
    let mut out = (Vec::new(), Vec::new());
    let mut seen = HashSet::new();
    for addr in addresses.iter().filter(|a| !a.is_empty()) {
        let (boxes, inputs) = fetch(addr).await;
        for (b, e) in boxes.into_iter().zip(inputs) {
            if seen.insert(e.box_id.clone()) {
                out.0.push(b);
                out.1.push(e);
            }
        }
    }
    out
}

#[tokio::test]
async fn reverse_completion_is_byte_identical_to_serial_and_reservations_still_apply() {
    let (handle, addresses) = wallet(10);
    let tree = address_to_ergo_tree(&addresses[0]).unwrap();
    let data: Vec<_> = (0..10)
        .map(|i| pair(vec![fixture(i, &tree), fixture(99, &tree)]))
        .collect();
    let expected = serial(&addresses, |a| {
        std::future::ready(data[addresses.iter().position(|v| v == a).unwrap()].clone())
    })
    .await;
    let completed = Arc::new(Mutex::new(Vec::new()));
    let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let peak = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let result = gather_unspent_ordered(handle, &addresses, GATHER_ADDRESS_CONCURRENCY, |a| {
        let i = addresses.iter().position(|v| v == a).unwrap();
        let (completed, active, peak, data) = (
            completed.clone(),
            active.clone(),
            peak.clone(),
            data[i].clone(),
        );
        async move {
            use std::sync::atomic::Ordering::SeqCst;
            let n = active.fetch_add(1, SeqCst) + 1;
            peak.fetch_max(n, SeqCst);
            tokio::time::sleep(Duration::from_millis((4 - i % 4) as u64 * 10)).await;
            active.fetch_sub(1, SeqCst);
            completed.lock().unwrap().push(i);
            Ok(data)
        }
    })
    .await
    .unwrap();
    assert_ne!(*completed.lock().unwrap(), (0..10).collect::<Vec<_>>());
    assert_eq!(peak.load(std::sync::atomic::Ordering::SeqCst), 4);
    assert_eq!(
        serde_json::to_vec(&result).unwrap(),
        serde_json::to_vec(&expected).unwrap()
    );
    assert_eq!(result.0.len(), 11);
    let reserved_id = result.1[0].box_id.clone();
    mix_set_reserved_funding(
        handle,
        serde_json::json!([{
            "box_ids": [reserved_id], "value_nano_erg": 10000000
        }])
        .to_string(),
    )
    .unwrap();
    let filtered = without_reserved(handle, result.0, result.1);
    assert_eq!(filtered.0.len(), 10);
    assert!(filtered.1.iter().all(|e| e.box_id != reserved_id));
    mix_set_reserved_funding(handle, "[]".into()).unwrap();
    wallet_lock(handle).unwrap();
}

#[tokio::test]
async fn single_and_empty_addresses_preserve_bytes_and_fetch_count() {
    let (handle, mut addresses) = wallet(1);
    let data = pair(vec![fixture(
        0,
        &address_to_ergo_tree(&addresses[0]).unwrap(),
    )]);
    addresses.insert(0, String::new());
    addresses.push(String::new());
    let calls = std::cell::Cell::new(0);
    let actual = gather_unspent_ordered(handle, &addresses, GATHER_ADDRESS_CONCURRENCY, |_| {
        calls.set(calls.get() + 1);
        std::future::ready(Ok(data.clone()))
    })
    .await
    .unwrap();
    assert_eq!(calls.get(), 1);
    assert_eq!(
        serde_json::to_vec(&actual).unwrap(),
        serde_json::to_vec(&data).unwrap()
    );
    wallet_lock(handle).unwrap();
}

#[tokio::test]
async fn failure_aborts_in_address_order_and_drops_pending_fetches() {
    let (handle, addresses) = wallet(10);
    let dropped = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    struct Guard(Arc<std::sync::atomic::AtomicUsize>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    }
    let calls = std::cell::Cell::new(0);
    let result = gather_unspent_ordered(handle, &addresses, GATHER_ADDRESS_CONCURRENCY, |a| {
        calls.set(calls.get() + 1);
        let i = addresses.iter().position(|v| v == a).unwrap();
        let guard = Guard(dropped.clone());
        async move {
            let _guard = guard;
            match i {
                0 => {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                    Ok((vec![], vec![]))
                }
                1 => {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    Err("first failure".into())
                }
                2 => Err("later failure finishes first".into()),
                _ => std::future::pending().await,
            }
        }
    })
    .await;
    assert_eq!(result.unwrap_err(), "first failure");
    assert_eq!(
        dropped.load(std::sync::atomic::Ordering::SeqCst),
        calls.get()
    );
    assert!(calls.get() < addresses.len());
    wallet_lock(handle).unwrap();
}

#[tokio::test]
async fn foreign_address_stops_admission_without_fetching_it_or_later_addresses() {
    let (handle, mut addresses) = wallet(3);
    let foreign = WalletHandle::restore_from_seed(&[43; 64])
        .unwrap()
        .derive_address(0)
        .unwrap();
    addresses.insert(1, foreign);
    for earlier_failure in [false, true] {
        let fetched = Mutex::new(Vec::new());
        let result = gather_unspent_ordered(handle, &addresses, GATHER_ADDRESS_CONCURRENCY, |a| {
            fetched.lock().unwrap().push(a.to_owned());
            std::future::ready(if earlier_failure {
                Err("earlier node error".into())
            } else {
                Ok((vec![], vec![]))
            })
        })
        .await;
        let error = result.unwrap_err();
        if earlier_failure {
            assert_eq!(error, "earlier node error");
        } else {
            assert!(error.contains("spend address is not an address of this wallet"));
        }
        assert_eq!(*fetched.lock().unwrap(), vec![addresses[0].clone()]);
    }
    wallet_lock(handle).unwrap();
}

struct Server {
    url: String,
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Server {
    fn new(reply: impl Fn(&str, &str) -> String + Send + Sync + 'static) -> Self {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopped = stop.clone();
        let reply = Arc::new(reply);
        let thread = std::thread::spawn(move || {
            let mut workers = Vec::new();
            while !stopped.load(std::sync::atomic::Ordering::SeqCst) {
                let Ok((mut socket, _)) = listener.accept() else {
                    std::thread::sleep(Duration::from_millis(1));
                    continue;
                };
                let reply = reply.clone();
                workers.push(std::thread::spawn(move || {
                    socket
                        .set_read_timeout(Some(Duration::from_secs(5)))
                        .unwrap();
                    let mut bytes = Vec::new();
                    let (header_end, length) = loop {
                        let mut chunk = [0; 4096];
                        let n = socket.read(&mut chunk).unwrap();
                        assert!(n > 0);
                        bytes.extend_from_slice(&chunk[..n]);
                        if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                            let headers = String::from_utf8_lossy(&bytes[..end]);
                            let length = headers
                                .lines()
                                .find_map(|l| {
                                    l.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|n| n.trim().parse::<usize>().unwrap())
                                })
                                .unwrap_or(0);
                            break (end + 4, length);
                        }
                    };
                    while bytes.len() < header_end + length {
                        let mut chunk = [0; 4096];
                        let n = socket.read(&mut chunk).unwrap();
                        assert!(n > 0);
                        bytes.extend_from_slice(&chunk[..n]);
                    }
                    let headers = String::from_utf8_lossy(&bytes[..header_end]);
                    let path = headers.split_whitespace().nth(1).unwrap();
                    let body = String::from_utf8_lossy(&bytes[header_end..header_end + length]);
                    let response = reply(path, &body);
                    // Cancellation may close the socket before the response.
                    let _ = write!(
                        socket,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        response.len(),
                        response
                    );
                }));
            }
            for worker in workers {
                worker.join().unwrap();
            }
        });
        Self {
            url,
            stop,
            thread: Some(thread),
        }
    }
    async fn client(&self) -> ErgoNodeClient {
        ErgoNodeClient::new(citadel_core::NodeConfig {
            url: self.url.clone(),
            api_key: String::new(),
        })
        .await
        .unwrap()
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::SeqCst);
        self.thread.take().unwrap().join().unwrap();
    }
}

#[tokio::test]
async fn real_client_keeps_pages_before_mempool_and_cross_address_chain_matches_serial() {
    let (handle, addresses) = wallet(2);
    let trees: Vec<_> = addresses
        .iter()
        .map(|a| address_to_ergo_tree(a).unwrap())
        .collect();
    let confirmed: Vec<_> = (0..500).map(|i| fixture(i, &trees[0])).collect();
    let intermediate = fixture(501, &trees[1]);
    let terminal = fixture(502, &trees[0]);
    let txs = serde_json::json!([
        {"id": "91".repeat(32), "inputs": [{"boxId": confirmed[0].box_id().to_string()}], "outputs": [intermediate.clone()]},
        {"id": "91".repeat(32), "inputs": [{"boxId": intermediate.box_id().to_string()}], "outputs": [terminal.clone()]}
    ]);
    let events = Arc::new(Mutex::new(Vec::new()));
    let (a, t, log, page) = (
        addresses.clone(),
        trees.clone(),
        events.clone(),
        serde_json::to_string(&confirmed).unwrap(),
    );
    let server = Server::new(move |path, body| {
        if path.contains("unspent/byAddress") {
            let address: String = serde_json::from_str(body).unwrap();
            let i = a.iter().position(|v| v == &address).unwrap();
            let second = path.contains("offset=500");
            if i == 0 {
                std::thread::sleep(Duration::from_millis(10));
            }
            log.lock()
                .unwrap()
                .push(format!("{i}:page{}", if second { 1 } else { 0 }));
            if i == 0 && !second {
                page.clone()
            } else {
                "[]".into()
            }
        } else if path.contains("unconfirmed/byErgoTree") {
            let tree: String = serde_json::from_str(body).unwrap();
            let i = t.iter().position(|v| v == &tree).unwrap();
            log.lock().unwrap().push(format!("{i}:mempool"));
            txs.to_string()
        } else {
            "[]".into()
        }
    });
    let client = server.client().await;
    let expected = serial(&addresses, |a| {
        let a = a.to_owned();
        let client = client.clone();
        async move { client.get_effective_unspent(&a).await.unwrap() }
    })
    .await;
    events.lock().unwrap().clear();
    let actual = gather_unspent_all(handle, &client, &addresses)
        .await
        .unwrap();
    assert_eq!(
        serde_json::to_vec(&actual).unwrap(),
        serde_json::to_vec(&expected).unwrap()
    );
    assert_eq!(actual.0.len(), 500);
    assert!(actual.0.iter().any(|b| b.box_id() == terminal.box_id()));
    assert!(actual
        .0
        .iter()
        .all(|b| b.box_id() != intermediate.box_id() && b.box_id() != confirmed[0].box_id()));
    let log = events.lock().unwrap();
    assert_eq!(
        log.iter()
            .filter(|e| e.starts_with("0:"))
            .cloned()
            .collect::<Vec<_>>(),
        ["0:page0", "0:page1", "0:mempool"]
    );
    assert_eq!(
        log.iter()
            .filter(|e| e.starts_with("1:"))
            .cloned()
            .collect::<Vec<_>>(),
        ["1:page0", "1:mempool"]
    );
    assert!(log.iter().position(|e| e == "1:mempool") < log.iter().position(|e| e == "0:mempool"));
    wallet_lock(handle).unwrap();
}

// Explicitly opt in: performs read-only requests for deterministic test addresses.
// Connection and ownership warmup excluded; alternating order limits warmup bias.
#[tokio::test]
#[ignore = "live node latency benchmark; run alone with --ignored --nocapture"]
async fn live_gather_benchmark() {
    let (handle, addresses) = wallet(10);
    for url in ["https://node.kadia.io", "https://ergo-node.eutxo.de"] {
        let client = ErgoNodeClient::new(citadel_core::NodeConfig {
            url: url.into(),
            api_key: String::new(),
        })
        .await
        .unwrap();
        gather_unspent_all(handle, &client, &addresses)
            .await
            .unwrap();
        for count in [1, 10] {
            for trial in 0..3 {
                let mut reference = None;
                for limit in if trial % 2 == 0 { [1, 4] } else { [4, 1] } {
                    let start = Instant::now();
                    let result = gather_unspent_ordered(handle, &addresses[..count], limit, |a| {
                        client.get_effective_unspent(a)
                    })
                    .await
                    .unwrap();
                    println!("{url} addresses={count} trial={trial} concurrency={limit} ms={:.3} boxes={}", start.elapsed().as_secs_f64() * 1000.0, result.0.len());
                    let bytes = serde_json::to_vec(&result).unwrap();
                    if let Some(previous) = &reference {
                        assert_eq!(&bytes, previous);
                    } else {
                        reference = Some(bytes);
                    }
                }
            }
        }
    }
    wallet_lock(handle).unwrap();
}

#[tokio::test]
async fn caller_cancellation_drops_every_admitted_fetch() {
    let (handle, addresses) = wallet(10);
    let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    struct Guard(Arc<std::sync::atomic::AtomicUsize>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        }
    }
    let fetch = |_| {
        active.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let guard = Guard(active.clone());
        async move {
            let _guard = guard;
            std::future::pending::<Result<GatheredBoxes, String>>().await
        }
    };
    let mut gather = Box::pin(gather_unspent_ordered(
        handle,
        &addresses,
        GATHER_ADDRESS_CONCURRENCY,
        fetch,
    ));
    assert!(futures::poll!(gather.as_mut()).is_pending());
    assert_eq!(active.load(std::sync::atomic::Ordering::SeqCst), 4);
    drop(gather);
    assert_eq!(active.load(std::sync::atomic::Ordering::SeqCst), 0);
    wallet_lock(handle).unwrap();
}
