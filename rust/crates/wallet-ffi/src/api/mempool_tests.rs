//! The spending policy end to end, against a stand-in node that answers each
//! endpoint the way a real one does: confirmed listings, mempool lists per
//! script (an input matches only while its box is confirmed), and lookups by
//! box id. Every spending path is driven through the one gathering point.

use super::*;
use crate::api::{err_str, register_handle, wallet_lock};
use std::io::{Read, Write};
use std::sync::atomic::AtomicUsize;
use std::sync::Arc;
use wallet_core::wallet::WalletHandle;

// ─── The policy is process-wide: tests that depend on it hold this ─────

static POLICY_LOCK: Mutex<()> = Mutex::new(());

/// Holds the unconfirmed-spending policy at one value for a test. The
/// setting is global to the test binary, so every test whose outcome
/// depends on it takes this lock; dropping it restores the default.
pub(crate) struct Policy(#[allow(dead_code)] std::sync::MutexGuard<'static, ()>);

pub(crate) fn policy(allow: bool) -> Policy {
    let guard = POLICY_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    set_spend_unconfirmed(allow);
    Policy(guard)
}

impl Drop for Policy {
    fn drop(&mut self) {
        set_spend_unconfirmed(true);
    }
}

// ─── A stand-in node ─────────────────────────────────────────────────────

#[derive(Clone, Default)]
pub(crate) struct Chain {
    /// Confirmed unspent boxes by address.
    pub(crate) unspent: HashMap<String, Vec<ErgoBox>>,
    /// What `/transactions/unconfirmed/byErgoTree` lists, per script.
    pub(crate) listed: HashMap<String, Vec<serde_json::Value>>,
    /// Box ids some mempool transaction spends.
    pub(crate) spent_in_mempool: HashSet<String>,
    /// Outputs of mempool transactions, by id.
    pub(crate) pending_outputs: HashMap<String, serde_json::Value>,
    pub(crate) mempool_down: bool,
}

impl Chain {
    fn confirmed_ids(&self) -> HashSet<String> {
        self.unspent
            .values()
            .flatten()
            .map(|b| b.box_id().to_string())
            .collect()
    }

    /// Add a pending transaction and list it the way a node would: under
    /// the script of every confirmed input box and of every output.
    pub(crate) fn pend(&mut self, tx: &serde_json::Value) {
        let confirmed: HashMap<String, String> = self
            .unspent
            .values()
            .flatten()
            .map(|b| (b.box_id().to_string(), tree_of(b)))
            .collect();
        let mut trees = HashSet::new();
        for input in tx["inputs"].as_array().unwrap() {
            let id = input["boxId"].as_str().unwrap().to_string();
            if let Some(tree) = confirmed.get(&id) {
                trees.insert(tree.clone());
            }
            self.spent_in_mempool.insert(id);
        }
        for output in tx["outputs"].as_array().unwrap() {
            trees.insert(output["ergoTree"].as_str().unwrap().to_string());
            self.pending_outputs
                .insert(output["boxId"].as_str().unwrap().to_string(), output.clone());
        }
        for tree in trees {
            self.listed.entry(tree).or_default().push(tx.clone());
        }
    }

    fn answer(&self, target: &str, body: &str) -> (u16, String) {
        let first_page = !target.contains("offset=") || target.contains("offset=0&");
        let id = target.rsplit('/').next().unwrap_or_default();
        if target.contains("/info") {
            (200, r#"{"fullHeight":1500000,"headersHeight":1500000}"#.into())
        } else if target.contains("/blockchain/box/unspent/byAddress") {
            let address: String = serde_json::from_str(body).unwrap();
            let boxes = match first_page {
                true => self.unspent.get(&address).cloned().unwrap_or_default(),
                false => Vec::new(),
            };
            (200, serde_json::to_string(&boxes).unwrap())
        } else if target.contains("/transactions/unconfirmed/byErgoTree") {
            if self.mempool_down {
                return (500, r#"{"error":500,"reason":"mempool unavailable"}"#.into());
            }
            let tree: String = serde_json::from_str(body).unwrap();
            let txs = match first_page {
                true => self.listed.get(&tree).cloned().unwrap_or_default(),
                false => Vec::new(),
            };
            (200, serde_json::to_string(&txs).unwrap())
        } else if target.contains("/transactions/unconfirmed/inputs/byBoxId/") {
            match self.spent_in_mempool.contains(id) {
                true => (200, format!(r#"{{"boxId":"{id}"}}"#)),
                false => (404, r#"{"error":404}"#.into()),
            }
        } else if target.contains("/utxo/byId/") {
            match self.confirmed_ids().contains(id) && !self.spent_in_mempool.contains(id) {
                true => (200, format!(r#"{{"boxId":"{id}"}}"#)),
                false => (404, r#"{"error":404}"#.into()),
            }
        } else if target.contains("/transactions/unconfirmed/outputs/byBoxId/") {
            match self.pending_outputs.get(id) {
                Some(output) => (200, output.to_string()),
                None => (404, r#"{"error":404}"#.into()),
            }
        } else {
            (404, r#"{"error":404}"#.into())
        }
    }
}

pub(crate) struct Node {
    pub(crate) url: String,
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    peak: Arc<AtomicUsize>,
    log: Arc<Mutex<Vec<String>>>,
}

impl Node {
    pub(crate) fn start(chain: Chain) -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let peak = Arc::new(AtomicUsize::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let log = Arc::new(Mutex::new(Vec::new()));
        let chain = Arc::new(chain);
        let (stopped, peak_c, log_c) = (stop.clone(), peak.clone(), log.clone());
        let thread = std::thread::spawn(move || {
            let mut workers = Vec::new();
            while !stopped.load(Ordering::SeqCst) {
                let Ok((mut socket, _)) = listener.accept() else {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                    continue;
                };
                socket.set_nonblocking(false).unwrap();
                let (chain, peak, active, log) =
                    (chain.clone(), peak_c.clone(), active.clone(), log_c.clone());
                workers.push(std::thread::spawn(move || {
                    let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(now, Ordering::SeqCst);
                    socket
                        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                        .unwrap();
                    let mut bytes = Vec::new();
                    let (head_end, length) = loop {
                        let mut chunk = [0; 4096];
                        let n = socket.read(&mut chunk).unwrap_or(0);
                        if n == 0 {
                            active.fetch_sub(1, Ordering::SeqCst);
                            return;
                        }
                        bytes.extend_from_slice(&chunk[..n]);
                        if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&bytes[..end]).to_string();
                            let length = head
                                .lines()
                                .find_map(|l| {
                                    l.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|v| v.trim().parse::<usize>().unwrap())
                                })
                                .unwrap_or(0);
                            break (end + 4, length);
                        }
                    };
                    while bytes.len() < head_end + length {
                        let mut chunk = [0; 4096];
                        let n = socket.read(&mut chunk).unwrap_or(0);
                        if n == 0 {
                            break;
                        }
                        bytes.extend_from_slice(&chunk[..n]);
                    }
                    let head = String::from_utf8_lossy(&bytes[..head_end]).to_string();
                    let target = head.split_whitespace().nth(1).unwrap_or_default().to_string();
                    let body = String::from_utf8_lossy(&bytes[head_end..]).to_string();
                    log.lock().unwrap().push(target.clone());
                    // Long enough for overlapping requests to overlap.
                    std::thread::sleep(std::time::Duration::from_millis(3));
                    let (status, reply) = chain.answer(&target, &body);
                    active.fetch_sub(1, Ordering::SeqCst);
                    let _ = write!(
                        socket,
                        "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                        reply.len()
                    );
                }));
            }
            for worker in workers {
                let _ = worker.join();
            }
        });
        Self {
            url,
            stop,
            thread: Some(thread),
            peak,
            log,
        }
    }

    pub(crate) async fn client(&self) -> ErgoNodeClient {
        node_client(Some(self.url.clone())).await.unwrap()
    }

    fn requests(&self) -> Vec<String> {
        self.log.lock().unwrap().clone()
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

// ─── Fixtures ────────────────────────────────────────────────────────────

pub(crate) const ERG: u64 = 1_000_000_000;

pub(crate) fn tree_of(b: &ErgoBox) -> String {
    hex::encode(b.ergo_tree.sigma_serialize_bytes().unwrap())
}

pub(crate) fn tx_id(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

pub(crate) fn boxed(tree: &str, tx: &str, index: u16, value: u64) -> ErgoBox {
    serde_json::from_value(serde_json::json!({
        "transactionId": tx, "index": index, "value": value, "ergoTree": tree,
        "creationHeight": 1_000, "assets": [], "additionalRegisters": {}
    }))
    .unwrap()
}

pub(crate) fn pending_tx(id: &str, spends: &[&ErgoBox], outputs: &[&ErgoBox]) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "inputs": spends.iter().map(|b| serde_json::json!({"boxId": b.box_id().to_string()})).collect::<Vec<_>>(),
        "outputs": outputs.iter().map(|b| serde_json::to_value(b).unwrap()).collect::<Vec<_>>(),
    })
}

/// A wallet that sent 0.3 ERG from its 1 ERG box a moment ago: the box is
/// spent in the mempool, 0.6989 ERG of change is unconfirmed, and a 0.05 ERG
/// box is confirmed and free.
struct Sent {
    handle: u64,
    address: String,
    foreign: String,
    spent: ErgoBox,
    free: ErgoBox,
    change: ErgoBox,
    chain: Chain,
}

impl Sent {
    fn new(seed: u8) -> Self {
        let handle = register_handle(WalletHandle::restore_from_seed(&[seed; 64]).unwrap());
        let address = with_handle(handle, "test", |h| h.derive_address(0).map_err(err_str)).unwrap();
        let foreign = WalletHandle::restore_from_seed(&[seed.wrapping_add(100); 64])
            .unwrap()
            .derive_address(0)
            .unwrap();
        let tree = address_to_ergo_tree(&address).unwrap();
        let foreign_tree = address_to_ergo_tree(&foreign).unwrap();
        let spent = boxed(&tree, &tx_id(1), 0, ERG);
        let free = boxed(&tree, &tx_id(2), 0, 50_000_000);
        let paid = boxed(&foreign_tree, &tx_id(3), 0, 300_000_000);
        let change = boxed(&tree, &tx_id(3), 1, 698_900_000);
        let mut chain = Chain::default();
        chain.unspent.insert(address.clone(), vec![spent.clone(), free.clone()]);
        chain.pend(&pending_tx(&tx_id(3), &[&spent], &[&paid, &change]));
        Self {
            handle,
            address,
            foreign,
            spent,
            free,
            change,
            chain,
        }
    }

    fn id(b: &ErgoBox) -> String {
        b.box_id().to_string()
    }
}

impl Drop for Sent {
    fn drop(&mut self) {
        let _ = wallet_lock(self.handle);
    }
}

fn ids(inputs: &[ergo_tx::Eip12InputBox]) -> Vec<String> {
    inputs.iter().map(|i| i.box_id.clone()).collect()
}

fn message(error: &str) -> String {
    serde_json::from_str::<serde_json::Value>(error).unwrap()["message"]
        .as_str()
        .unwrap()
        .to_string()
}

async fn send(w: &Sent, node: &Node, amount: i64) -> Result<String, String> {
    super::super::prepare_send(
        w.handle,
        w.address.clone(),
        vec![w.address.clone()],
        w.address.clone(),
        w.foreign.clone(),
        amount,
        None,
        None,
        Some(node.url.clone()),
        None,
        None,
        None,
        None,
    )
    .await
}

// ─── Every gathering path ────────────────────────────────────────────────

#[tokio::test]
async fn every_gathering_path_skips_the_spent_box_and_follows_the_policy() {
    for allow in [true, false] {
        let _policy = policy(allow);
        let w = Sent::new(11);
        let node = Node::start(w.chain.clone());
        let client = node.client().await;
        let addresses = vec![w.address.clone()];
        let (spent, free, change) = (Sent::id(&w.spent), Sent::id(&w.free), Sent::id(&w.change));
        let expected = if allow {
            vec![free.clone(), change.clone()]
        } else {
            vec![free.clone()]
        };

        // Sends, multi-sends, mint/burn, Rosen, Duckpools, SigmaFi, stake
        // recovery and the UTXO tools gather here.
        let (boxes, inputs) = super::super::gather_unspent(w.handle, &client, &addresses)
            .await
            .unwrap();
        assert_eq!(ids(&inputs), expected, "allow={allow}");
        assert_eq!(boxes.len(), inputs.len());
        // The mix entry gathers here.
        let (_, inputs) = super::super::gather_unspent_all(w.handle, &client, &addresses)
            .await
            .unwrap();
        assert_eq!(ids(&inputs), expected, "allow={allow}");
        // Dexy, AgeUSD and Spectrum swaps and LP gather here.
        let (_, inputs) =
            super::super::gather_wallet_boxes(w.handle, &addresses, Some(node.url.clone()))
                .await
                .unwrap();
        assert_eq!(ids(&inputs), expected, "allow={allow}");

        // A dApp page's get_utxos: unconfirmed boxes say so.
        let utxos: serde_json::Value = serde_json::from_str(
            &super::super::dapp_utxos(w.handle, addresses.clone(), Some(node.url.clone()))
                .await
                .unwrap(),
        )
        .unwrap();
        let listed: Vec<(String, bool)> = utxos
            .as_array()
            .unwrap()
            .iter()
            .map(|u| {
                (
                    u["boxId"].as_str().unwrap().to_string(),
                    u["confirmed"].as_bool().unwrap(),
                )
            })
            .collect();
        let mut want = vec![(free.clone(), true)];
        if allow {
            want.push((change.clone(), false));
        }
        assert_eq!(listed, want, "allow={allow}");

        // Coin control and the UTXO tools list boxes here; the mix funding
        // finder asks for confirmed ones only.
        for confirmed_only in [false, true] {
            let listing: serde_json::Value = serde_json::from_str(
                &list_spendable_boxes(
                    w.handle,
                    addresses.clone(),
                    Some(node.url.clone()),
                    confirmed_only,
                )
                .await
                .unwrap(),
            )
            .unwrap();
            let listed: Vec<String> = listing
                .as_array()
                .unwrap()
                .iter()
                .map(|b| b["box_id"].as_str().unwrap().to_string())
                .collect();
            let want = if allow && !confirmed_only { expected.clone() } else { vec![free.clone()] };
            assert_eq!(listed, want, "allow={allow} confirmed_only={confirmed_only}");
            for b in listing.as_array().unwrap() {
                assert_eq!(b["address"], w.address.as_str());
                assert_eq!(b["confirmed"], b["box_id"] != change.as_str());
                // Each box carries the size storage rent is charged on, so
                // the rent report needs no second listing.
                let listed = [&w.free, &w.change]
                    .into_iter()
                    .find(|x| x.box_id().to_string() == b["box_id"].as_str().unwrap())
                    .unwrap();
                assert_eq!(
                    b["size_bytes"].as_u64().unwrap() as usize,
                    wallet_core::rent::box_size(listed).unwrap()
                );
            }
        }
        assert!(!expected.contains(&spent));
    }
}

#[tokio::test]
async fn a_pending_spend_that_pays_elsewhere_is_found_by_box_id() {
    let _policy = policy(true);
    let mut w = Sent::new(12);
    // The change is forwarded whole to someone else. That transaction's
    // input was never confirmed and it pays nothing to the wallet, so no
    // list the wallet reads contains it.
    let onward = boxed(&address_to_ergo_tree(&w.foreign).unwrap(), &tx_id(4), 0, 697_800_000);
    let forward = pending_tx(&tx_id(4), &[&w.change], &[&onward]);
    w.chain.spent_in_mempool.insert(Sent::id(&w.change));
    w.chain.pending_outputs.insert(Sent::id(&onward), serde_json::to_value(&onward).unwrap());
    w.chain
        .listed
        .entry(address_to_ergo_tree(&w.foreign).unwrap())
        .or_default()
        .push(forward);
    let node = Node::start(w.chain.clone());
    let client = node.client().await;
    let (_, inputs) = super::super::gather_unspent(w.handle, &client, &[w.address.clone()])
        .await
        .unwrap();
    assert_eq!(ids(&inputs), vec![Sent::id(&w.free)]);

    // The balance agrees: nothing is on its way in any more.
    let raw = super::super::get_sync_inputs(vec![w.address.clone()], Some(node.url.clone()))
        .await
        .unwrap();
    let summary = &serde_json::from_str::<serde_json::Value>(&raw).unwrap()["summary"];
    assert_eq!(summary["pending_in_nano_erg"], 0);
    assert_eq!(summary["balance_nano_erg"], 50_000_000);
}

#[tokio::test]
async fn a_mempool_that_cannot_be_read_fails_the_spend_instead_of_guessing() {
    let _policy = policy(true);
    let mut w = Sent::new(13);
    w.chain.mempool_down = true;
    let node = Node::start(w.chain.clone());
    let client = node.client().await;
    let error = super::super::gather_unspent(w.handle, &client, &[w.address.clone()])
        .await
        .unwrap_err();
    assert!(message(&error).contains("Could not check pending transactions"), "{error}");
    let error = send(&w, &node, 5_000_000).await.unwrap_err();
    assert!(message(&error).contains("Could not check pending transactions"), "{error}");

    // The view degrades instead: confirmed figures, nothing pending.
    let raw = super::super::get_sync_inputs(vec![w.address.clone()], Some(node.url.clone()))
        .await
        .unwrap();
    let summary = &serde_json::from_str::<serde_json::Value>(&raw).unwrap()["summary"];
    assert_eq!(summary["confirmed_nano_erg"], ERG + 50_000_000);
    assert_eq!(summary["pending_out_nano_erg"], 0);
}

// ─── Sending ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn waiting_names_the_confirming_funds_and_allowing_chains_on_change() {
    let w = Sent::new(14);
    let node = Node::start(w.chain.clone());

    {
        let _policy = policy(false);
        let error = send(&w, &node, 500_000_000).await.unwrap_err();
        let text = message(&error);
        assert!(text.starts_with("0.6989 ERG is still confirming"), "{text}");
        assert!(text.contains("Settings → Security"), "{text}");
        // Confirmed funds still go out while waiting.
        let small: serde_json::Value =
            serde_json::from_str(&send(&w, &node, 5_000_000).await.unwrap()).unwrap();
        let used: Vec<&str> = small["input_boxes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["box_id"].as_str().unwrap())
            .collect();
        assert_eq!(used, vec![Sent::id(&w.free).as_str()]);
        // More than the change could cover: no claim that waiting helps.
        let error = send(&w, &node, 2 * ERG as i64).await.unwrap_err();
        assert!(!message(&error).contains("still confirming"), "{error}");
    }

    let _policy = policy(true);
    let sent: serde_json::Value =
        serde_json::from_str(&send(&w, &node, 500_000_000).await.unwrap()).unwrap();
    let inputs = sent["input_boxes"].as_array().unwrap();
    let used: Vec<&str> = inputs.iter().map(|b| b["box_id"].as_str().unwrap()).collect();
    assert!(used.contains(&Sent::id(&w.change).as_str()), "{used:?}");
    assert!(!used.contains(&Sent::id(&w.spent).as_str()), "a spent box is never an input");
    // Nothing is created or lost: inputs pay the recipient, the change, the
    // miner and the app fee exactly.
    let total_in: u64 = inputs
        .iter()
        .map(|b| b["value_nano_erg"].as_str().unwrap().parse::<u64>().unwrap())
        .sum();
    let total_out = sent["amount_nano_erg"].as_u64().unwrap()
        + sent["change_nano_erg"].as_u64().unwrap()
        + sent["miner_fee"].as_u64().unwrap()
        + sent["citadel_fee_nano"].as_u64().unwrap();
    assert_eq!(total_in, total_out);
}

#[tokio::test]
async fn waiting_explains_an_empty_wallet_in_multi_send_and_the_utxo_tools() {
    let _policy = policy(false);
    let mut w = Sent::new(19);
    // Nothing confirmed is left: the only confirmed box is the one the
    // pending send spends, and its change is still confirming.
    w.chain.unspent.insert(w.address.clone(), vec![w.spent.clone()]);
    let node = Node::start(w.chain.clone());
    let url = Some(node.url.clone());

    let recipients = serde_json::json!([{
        "address": w.foreign,
        "amount_nano_erg": 100_000_000,
    }])
    .to_string();
    let error = super::super::prepare_send_multi(
        w.handle,
        w.address.clone(),
        vec![w.address.clone()],
        w.address.clone(),
        recipients,
        url.clone(),
        None,
        None,
        None,
        None,
    )
    .await
    .unwrap_err();
    assert!(message(&error).starts_with("0.6989 ERG is still confirming"), "{error}");

    let error = super::super::prepare_consolidate(
        w.handle,
        vec![w.address.clone()],
        vec![],
        w.address.clone(),
        url.clone(),
        None,
    )
    .await
    .unwrap_err();
    assert!(message(&error).starts_with("0.6989 ERG is still confirming"), "{error}");
}

#[tokio::test]
async fn hand_picked_inputs_are_not_told_to_wait() {
    let _policy = policy(false);
    let w = Sent::new(21);
    let node = Node::start(w.chain.clone());
    // The user chose the free box alone; the confirming change was never
    // among the boxes to choose from, so waiting would not help this send.
    let error = super::super::prepare_send(
        w.handle,
        w.address.clone(),
        vec![w.address.clone()],
        w.address.clone(),
        w.foreign.clone(),
        500_000_000,
        None,
        None,
        Some(node.url.clone()),
        None,
        Some(vec![Sent::id(&w.free)]),
        None,
        None,
    )
    .await
    .unwrap_err();
    assert!(!message(&error).contains("still confirming"), "{error}");
}

#[tokio::test]
async fn waiting_never_promises_change_already_forwarded() {
    let _policy = policy(false);
    let mut w = Sent::new(22);
    // The change was forwarded whole to someone else by a second pending
    // transaction that no list of the wallet's shows.
    let onward = boxed(&address_to_ergo_tree(&w.foreign).unwrap(), &tx_id(7), 0, 697_800_000);
    let forward = pending_tx(&tx_id(7), &[&w.change], &[&onward]);
    w.chain.spent_in_mempool.insert(Sent::id(&w.change));
    w.chain
        .listed
        .entry(address_to_ergo_tree(&w.foreign).unwrap())
        .or_default()
        .push(forward);
    let node = Node::start(w.chain.clone());
    let error = send(&w, &node, 500_000_000).await.unwrap_err();
    assert!(!message(&error).contains("still confirming"), "{error}");
}

#[tokio::test]
async fn each_address_is_valued_over_the_whole_wallet() {
    let handle = register_handle(WalletHandle::restore_from_seed(&[23; 64]).unwrap());
    let address = |i| with_handle(handle, "test", |h| h.derive_address(i).map_err(err_str)).unwrap();
    let (a, b) = (address(0), address(1));
    let (tree_a, tree_b) = (address_to_ergo_tree(&a).unwrap(), address_to_ergo_tree(&b).unwrap());
    // A pays B (pending); B's unconfirmed box is spent back to A (pending).
    // The node lists the second transaction under A only.
    let root = boxed(&tree_a, &tx_id(1), 0, 5 * ERG);
    let middle = boxed(&tree_b, &tx_id(8), 0, 4_998_900_000);
    let end = boxed(&tree_a, &tx_id(9), 0, 4_997_800_000);
    let mut chain = Chain::default();
    chain.unspent.insert(a.clone(), vec![root.clone()]);
    chain.pend(&pending_tx(&tx_id(8), &[&root], &[&middle]));
    chain.pend(&pending_tx(&tx_id(9), &[&middle], &[&end]));
    assert!(!chain.listed[&tree_b].iter().any(|t| t["id"] == tx_id(9).as_str()));
    let node = Node::start(chain);

    let sync: serde_json::Value = serde_json::from_str(
        &super::super::get_sync_inputs(vec![a.clone(), b.clone()], Some(node.url.clone()))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(sync["balances"][&b]["balance_nano_erg"], 0, "the middle box is spent");
    assert_eq!(sync["balances"][&a]["balance_nano_erg"], 4_997_800_000u64);
    assert_eq!(sync["summary"]["balance_nano_erg"], 4_997_800_000u64);
    // Once it settles the wallet holds one box: the end of the chain.
    assert_eq!(sync["utxo_count"], 1);
    let _ = wallet_lock(handle);
}

// ─── What the sync shows ─────────────────────────────────────────────────

#[tokio::test]
async fn the_sync_splits_confirmed_and_pending_and_locked_wallets_read_in_turn() {
    let w = Sent::new(15);
    let node = Node::start(w.chain.clone());
    let live: serde_json::Value = serde_json::from_str(
        &super::super::get_sync_inputs(vec![w.address.clone()], Some(node.url.clone()))
            .await
            .unwrap(),
    )
    .unwrap();
    let summary = &live["summary"];
    assert_eq!(summary["confirmed_nano_erg"], ERG + 50_000_000);
    assert_eq!(summary["pending_out_nano_erg"], ERG);
    assert_eq!(summary["pending_in_nano_erg"], 698_900_000);
    assert_eq!(summary["balance_nano_erg"], 748_900_000);
    assert_eq!(summary["pending_transactions"], 1);
    assert_eq!(live["balances"][&w.address]["balance_nano_erg"], 748_900_000);
    assert_eq!(live["balances"][&w.address]["summary"], *summary);
    assert_eq!(live["pending"][0]["value_nano_erg"], 698_900_000i64 - ERG as i64);

    let public = Node::start(w.chain.clone());
    let read: serde_json::Value = serde_json::from_str(
        &get_public_sync_inputs(
            vec![w.address.clone(), w.address.clone(), String::new()],
            Some(public.url.clone()),
        )
        .await
        .unwrap(),
    )
    .unwrap();
    assert_eq!(read["summary"], *summary);
    assert_eq!(read["pending"], live["pending"]);
    assert_eq!(public.peak.load(Ordering::SeqCst), 1, "one request at a time");
    assert_eq!(
        public
            .requests()
            .iter()
            .filter(|r| r.contains("unspent/byAddress"))
            .count(),
        1,
        "an address listed twice is read once"
    );
}

// ─── Transactions built elsewhere ────────────────────────────────────────

fn eip12_input(b: &ErgoBox) -> serde_json::Value {
    serde_json::json!({
        "boxId": b.box_id().to_string(),
        "transactionId": b.transaction_id.to_string(),
        "index": b.index,
        "ergoTree": tree_of(b),
        "creationHeight": b.creation_height,
        "value": b.value.as_u64().to_string(),
        "assets": [],
        "additionalRegisters": {},
        "extension": {}
    })
}

fn dapp_tx(input: &ErgoBox, to: &str) -> String {
    let value = *input.value.as_u64();
    serde_json::json!({
        "inputs": [eip12_input(input)],
        "dataInputs": [],
        "outputs": [{
            "value": (value - 1_100_000).to_string(),
            "ergoTree": address_to_ergo_tree(to).unwrap(),
            "creationHeight": 1_000,
            "assets": [],
            "additionalRegisters": {}
        }, {
            "value": "1100000",
            "ergoTree": citadel_core::constants::MINER_FEE_ERGO_TREE,
            "creationHeight": 1_000,
            "assets": [],
            "additionalRegisters": {}
        }]
    })
    .to_string()
}

#[tokio::test]
async fn dapp_requests_cannot_double_spend_or_spend_confirming_funds_while_waiting() {
    let w = Sent::new(16);
    let node = Node::start(w.chain.clone());
    let url = Some(node.url.clone());
    for allow in [true, false] {
        let _policy = policy(allow);
        // A page built on the box the pending send already spends.
        let error = super::super::dapp_prepare_sign(w.handle, dapp_tx(&w.spent, &w.foreign), url.clone())
            .await
            .unwrap_err();
        assert!(message(&error).contains("pending transaction already spends"), "{error}");
        // The free box is fine either way.
        super::super::dapp_prepare_sign(w.handle, dapp_tx(&w.free, &w.foreign), url.clone())
            .await
            .unwrap();
        // The unconfirmed change: only when unconfirmed funds are allowed.
        let change = super::super::dapp_prepare_sign(w.handle, dapp_tx(&w.change, &w.foreign), url.clone()).await;
        match allow {
            true => {
                change.unwrap();
            }
            false => {
                let error = change.unwrap_err();
                assert!(message(&error).contains("0.6989 ERG of yours that is still confirming"), "{error}");
            }
        }
    }
}

/// An ErgoPay request as a dApp would hand it over: a reduced transaction
/// spending `input` to `to`, minus the miner fee.
fn ergopay_request(input: &ErgoBox, to: &str) -> Vec<u8> {
    use ergo_lib::chain::ergo_box::box_builder::ErgoBoxCandidateBuilder;
    use ergo_lib::chain::transaction::unsigned::UnsignedTransaction;
    use ergo_lib::chain::transaction::{DataInput, TxIoVec, UnsignedInput};
    use ergo_lib::ergotree_ir::chain::context_extension::ContextExtension;
    use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
    use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;

    let fee = 1_100_000u64;
    let tree = |hex_tree: &str| ErgoTree::sigma_parse_bytes(&hex::decode(hex_tree).unwrap()).unwrap();
    let paid = ErgoBoxCandidateBuilder::new(
        BoxValue::try_from(*input.value.as_u64() - fee).unwrap(),
        tree(&address_to_ergo_tree(to).unwrap()),
        2000,
    );
    let fee_out = ErgoBoxCandidateBuilder::new(
        BoxValue::try_from(fee).unwrap(),
        ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS.script().unwrap(),
        2000,
    );
    let unsigned = UnsignedTransaction::new(
        TxIoVec::from_vec(vec![UnsignedInput::new(input.box_id(), ContextExtension::empty())])
            .unwrap(),
        None::<TxIoVec<DataInput>>,
        TxIoVec::from_vec(vec![paid.build().unwrap(), fee_out.build().unwrap()]).unwrap(),
    )
    .unwrap();
    let reduced = wallet_core::transaction::build_reduced_transaction(
        unsigned,
        vec![input.clone()],
        vec![],
        &wallet_net::client::make_state_context(2000),
    )
    .unwrap();
    wallet_core::transaction::serialize_reduced(&reduced).unwrap()
}

#[tokio::test]
async fn ergopay_requests_cannot_double_spend_or_spend_confirming_funds_while_waiting() {
    let w = Sent::new(20);
    let node = Node::start(w.chain.clone());
    let url = Some(node.url.clone());
    for allow in [true, false] {
        let _policy = policy(allow);
        let describe = |input: &ErgoBox| {
            super::super::describe_reduced_transaction(
                w.handle,
                ergopay_request(input, &w.foreign),
                url.clone(),
            )
        };
        let error = describe(&w.spent).await.unwrap_err();
        assert!(message(&error).contains("pending transaction already spends"), "{error}");
        let summary: serde_json::Value =
            serde_json::from_str(&describe(&w.free).await.unwrap()).unwrap();
        assert!(summary.is_object());
        let change = describe(&w.change).await;
        match allow {
            true => {
                change.unwrap();
            }
            false => {
                let error = change.unwrap_err();
                assert!(message(&error).contains("still confirming"), "{error}");
            }
        }
    }
}

#[tokio::test]
async fn stealth_coins_already_being_spent_are_never_broadcast_again() {
    let w = Sent::new(17);
    // Any script stands in for a one-time stealth script here.
    let stealth = boxed(&address_to_ergo_tree(&w.foreign).unwrap(), &tx_id(5), 0, ERG);
    let mut chain = w.chain.clone();
    chain.spent_in_mempool.insert(Sent::id(&stealth));
    let node = Node::start(chain);
    let client = node.client().await;
    let stealth_tree = vec![tree_of(&stealth)];

    let error = check_stealth_inputs(&client, &[w.free.clone(), stealth.clone()], &stealth_tree)
        .await
        .unwrap_err();
    assert!(message(&error).contains("already spends these stealth coins"), "{error}");
    // Ordinary inputs are not looked up one by one, and a send without
    // stealth inputs asks nothing.
    check_stealth_inputs(&client, &[w.spent.clone()], &[]).await.unwrap();
    assert!(!node.requests().iter().any(|r| r.ends_with(&Sent::id(&w.free))));
    assert!(!node.requests().iter().any(|r| r.ends_with(&Sent::id(&w.spent))));

    let fresh = Node::start(w.chain.clone());
    check_stealth_inputs(&fresh.client().await, &[stealth], &stealth_tree)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_watched_account_gathers_under_the_same_rules() {
    let w = Sent::new(18);
    let node = Node::start(w.chain.clone());
    let client = node.client().await;
    for allow in [true, false] {
        let _policy = policy(allow);
        let s = gather_watched(&client, &[w.address.clone()]).await.unwrap();
        let mut expected = vec![Sent::id(&w.free)];
        if allow {
            expected.push(Sent::id(&w.change));
        }
        assert_eq!(ids(&s.inputs), expected, "allow={allow}");
        assert_eq!(s.held_back.len(), usize::from(!allow));
        let explained = explain_held(
            &s.held_back,
            "Insufficient ERG: need 500000000 nanoERG, have 50000000".into(),
        );
        assert_eq!(explained.contains("0.6989 ERG is still confirming"), !allow, "{explained}");
    }
}

// ─── Explaining a shortfall ──────────────────────────────────────────────

fn held(nano: u64, tokens: &[(&str, u64)]) -> HeldBack {
    HeldBack {
        nano,
        tokens: tokens.iter().map(|(t, n)| (t.to_string(), *n)).collect(),
    }
}

fn json_error(code: &str, message: &str) -> String {
    serde_json::json!({"code": code, "message": message}).to_string()
}

#[test]
fn a_shortfall_waiting_would_cover_is_explained() {
    let error = json_error(
        "TX_BUILD_FAILED",
        "Transaction build failed: Insufficient ERG: need 3000000000 nanoERG, have 1000000000",
    );
    let out: serde_json::Value =
        serde_json::from_str(&explain_with(&held(2_500_000_000, &[]), error)).unwrap();
    assert_eq!(out["code"], "TX_BUILD_FAILED");
    let text = out["message"].as_str().unwrap();
    assert!(text.starts_with("2.5 ERG is still confirming."), "{text}");
    assert!(text.ends_with("need 3000000000 nanoERG, have 1000000000)"), "{text}");
}

#[test]
fn a_shortfall_waiting_would_not_cover_stands() {
    let error = json_error(
        "TX_BUILD_FAILED",
        "Insufficient ERG: have 1000000000 nanoERG, need 9000000000 nanoERG",
    );
    assert_eq!(explain_with(&held(2_500_000_000, &[]), error.clone()), error);
}

#[test]
fn other_errors_and_nothing_held_back_stand() {
    let unrelated = json_error("INVALID_ADDRESS", "Invalid address: bad checksum");
    assert_eq!(explain_with(&held(ERG, &[]), unrelated.clone()), unrelated);
    let shortfall = json_error("TX_BUILD_FAILED", "Insufficient ERG: need 3, have 1");
    assert_eq!(explain_with(&HeldBack::nothing(), shortfall.clone()), shortfall);
    // No figures at all: the funds confirming are named, nothing more.
    let none = json_error("NO_UTXOS", "No UTXOs available for address 9f...");
    let out = explain_with(&held(1_000_000, &[]), none);
    assert!(message(&out).starts_with("0.001 ERG is still confirming"), "{out}");
}

#[test]
fn a_token_shortfall_is_explained_only_for_that_token() {
    let token = "ab".repeat(32);
    let error = json_error(
        "TX_BUILD_FAILED",
        &format!("Insufficient token balance: need 50 of {token}, have 20"),
    );
    let out = explain_with(&held(0, &[(&token, 40)]), error.clone());
    assert!(message(&out).starts_with("40 base units of token abababab… are still confirming"), "{out}");
    // Too few confirming, or a different token: unchanged.
    assert_eq!(explain_with(&held(0, &[(&token, 10)]), error.clone()), error);
    assert_eq!(explain_with(&held(ERG, &[(&"cd".repeat(32), 99)]), error.clone()), error);
}

#[test]
fn plain_text_errors_keep_their_shape() {
    let out = explain_with(&held(ERG, &[]), "inputs hold 5 nanoERG but the transfer needs 9".into());
    assert!(out.starts_with("1 ERG is still confirming."), "{out}");
    assert!(serde_json::from_str::<serde_json::Value>(&out).is_err());
}

#[test]
fn shortfall_figures_are_read_from_the_common_wordings() {
    assert_eq!(number_after("insufficient erg: need 3 nanoerg, have 1", &["need"]), Some(3));
    assert_eq!(number_after("inputs hold 5 nanoerg but the transfer needs 9", &["need"]), Some(9));
    assert_eq!(
        number_after("this order needs 7 nanoerg; automatic selection can use 2.", &["have", "hold", "can use"]),
        Some(2)
    );
    assert_eq!(number_after("need more than 1100000", &["need"]), None);
    assert_eq!(token_in(&format!("of {} have", "0a".repeat(32))), Some("0a".repeat(32)));
    assert_eq!(token_in("abab1234: need 5 have 2"), None);
    assert_eq!(erg_text(2_500_000_000), "2.5");
    assert_eq!(erg_text(698_900_000), "0.6989");
    assert_eq!(erg_text(3 * ERG), "3");
}

#[test]
fn the_policy_round_trips_and_waiting_is_remembered_per_wallet() {
    let _policy = policy(false);
    assert!(!spend_unconfirmed());
    set_spend_unconfirmed(true);
    assert!(spend_unconfirmed());
    let b = boxed(
        "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        &tx_id(6),
        0,
        ERG,
    );
    let input = ergo_tx::Eip12InputBox::from_ergo_box(&b, b.transaction_id.to_string(), b.index);
    record_held_back(4242, &[input]);
    let error = json_error("NO_UTXOS", "No UTXOs available");
    assert!(message(&explain_shortfall(4242, error.clone())).contains("1 ERG is still confirming"));
    record_held_back(4242, &[]);
    assert_eq!(explain_shortfall(4242, error.clone()), error);
    record_held_back(4242, &[ergo_tx::Eip12InputBox::from_ergo_box(&b, b.transaction_id.to_string(), b.index)]);
    forget_held_back(4242);
    assert_eq!(explain_shortfall(4242, error.clone()), error);
}
