//! Mempool parsing and filtering. Pure functions over node JSON — no I/O, so
//! every rule here is unit-testable without a node.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use std::collections::{HashMap, HashSet};

/// Every box id consumed by these transactions. A confirmed UTXO whose id is
/// in this set is already spent and must not be offered again.
pub fn spent_box_ids(txs: &[serde_json::Value]) -> HashSet<String> {
    let mut spent = HashSet::new();
    for tx in txs {
        if let Some(inputs) = tx["inputs"].as_array() {
            for input in inputs {
                if let Some(id) = input["boxId"].as_str() {
                    spent.insert(id.to_string());
                }
            }
        }
    }
    spent
}

/// Outputs of these transactions that pay `ergo_tree`, as spendable boxes.
/// Unparsable outputs are skipped rather than failing the batch.
pub fn owned_outputs(txs: &[serde_json::Value], ergo_tree: &str) -> Vec<ErgoBox> {
    let mut owned = Vec::new();
    for tx in txs {
        let tx_id = match tx["id"].as_str() {
            Some(id) => id,
            None => continue,
        };
        let outputs = match tx["outputs"].as_array() {
            Some(o) => o,
            None => continue,
        };
        for (idx, output) in outputs.iter().enumerate() {
            if output["ergoTree"].as_str() != Some(ergo_tree) {
                continue;
            }
            if let Some(b) = output_to_ergo_box(output, tx_id, idx as u16) {
                owned.push(b);
            }
        }
    }
    owned
}

/// The mempool transactions of several per-address reads, each once.
///
/// The node is asked once per address, so a transaction touching two of the
/// wallet's addresses arrives twice. Everything that decides what is spent
/// must look at this union rather than at one address's list: the node
/// matches an input to an address only while the input box is confirmed, so
/// a transaction spending an *unconfirmed* box of address B — change from an
/// earlier pending send — is listed under B only if it also pays B. Taken
/// address by address, B's view keeps offering a box another address's list
/// shows as spent. Transactions without an id are kept: their inputs still
/// count as spent.
pub fn unique_transactions<'a, I>(lists: I) -> Vec<serde_json::Value>
where
    I: IntoIterator<Item = &'a [serde_json::Value]>,
{
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for list in lists {
        for tx in list {
            match tx["id"].as_str() {
                Some(id) if !seen.insert(id.to_string()) => {}
                _ => out.push(tx.clone()),
            }
        }
    }
    out
}

/// One address as read for spending: its script, its confirmed boxes in the
/// pair `get_unspent` returns, and every mempool transaction the node lists
/// for the script.
#[derive(Clone, Debug)]
pub struct AddressRead {
    pub tree: String,
    pub confirmed: (Vec<ErgoBox>, Vec<ergo_tx::Eip12InputBox>),
    pub mempool: Vec<serde_json::Value>,
}

/// What coin selection may spend across a set of addresses.
#[derive(Debug, Default)]
pub struct Spendable {
    pub boxes: Vec<ErgoBox>,
    pub inputs: Vec<ergo_tx::Eip12InputBox>,
    /// Ids among `inputs` that a transaction still in the mempool created.
    pub unconfirmed: HashSet<String>,
    /// Unconfirmed outputs paying the set that were left out because the
    /// wallet waits for a confirmation before spending them.
    pub held_back: Vec<ergo_tx::Eip12InputBox>,
}

/// The wallet's spendable boxes: confirmed boxes no pending transaction
/// spends, then — only when `allow_unconfirmed` — the outputs pending
/// transactions pay to these addresses and nothing pending spends yet.
///
/// Spent and owned are judged over the union of every address's mempool
/// list ([`unique_transactions`]), never per address. A box already spent by
/// a pending transaction is never offered, whatever the policy: a second
/// transaction spending it is a double spend the node rejects, or worse,
/// accepts in place of the first. Order follows the reads, confirmed boxes
/// of an address before its unconfirmed ones, and a box seen twice (an
/// address listed twice, or a block landing between the two reads) is kept
/// once, first copy winning. The confirmed pairs are moved, not converted
/// again.
pub fn spendable_across(reads: Vec<AddressRead>, allow_unconfirmed: bool) -> Spendable {
    let txs = unique_transactions(reads.iter().map(|r| r.mempool.as_slice()));
    let spent = spent_box_ids(&txs);
    let mut seen = HashSet::new();
    let mut out = Spendable::default();
    for read in reads {
        let (boxes, inputs) = read.confirmed;
        for (b, input) in boxes.into_iter().zip(inputs) {
            if spent.contains(&input.box_id) || !seen.insert(input.box_id.clone()) {
                continue;
            }
            out.boxes.push(b);
            out.inputs.push(input);
        }
        for b in owned_outputs(&txs, &read.tree) {
            let id = b.box_id().to_string();
            if spent.contains(&id) || !seen.insert(id.clone()) {
                continue;
            }
            let input =
                ergo_tx::Eip12InputBox::from_ergo_box(&b, b.transaction_id.to_string(), b.index);
            if allow_unconfirmed {
                out.unconfirmed.insert(id);
                out.boxes.push(b);
                out.inputs.push(input);
            } else {
                out.held_back.push(input);
            }
        }
    }
    out
}

impl Spendable {
    /// Drop offered boxes by id, keeping the two lists paired.
    pub fn remove(&mut self, ids: &HashSet<String>) {
        if ids.is_empty() {
            return;
        }
        let boxes = std::mem::take(&mut self.boxes);
        let inputs = std::mem::take(&mut self.inputs);
        for (b, input) in boxes.into_iter().zip(inputs) {
            if ids.contains(&input.box_id) {
                self.unconfirmed.remove(&input.box_id);
            } else {
                self.boxes.push(b);
                self.inputs.push(input);
            }
        }
    }
}

/// How the mempool moves a set of addresses' holdings, valued once for the
/// whole set.
///
/// `pending_out` is what pending transactions take from the set's confirmed
/// boxes; `pending_in` is what they pay to the set's scripts and nothing
/// pending spends again. A self-transfer between two addresses of the set
/// therefore shows on both sides, and a chained spend of unconfirmed change
/// on neither — the change never settles anywhere.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PendingSummary {
    pub confirmed_nano_erg: u64,
    pub pending_in_nano_erg: u64,
    pub pending_out_nano_erg: u64,
    /// Per token, sorted by id: only tokens the set holds or receives.
    pub tokens: Vec<TokenFlow>,
    /// Pending transactions that take from or pay to the set.
    pub pending_transactions: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TokenFlow {
    pub token_id: String,
    pub confirmed: u64,
    pub pending_in: u64,
    pub pending_out: u64,
}

impl TokenFlow {
    /// The holding once everything pending confirms.
    pub fn amount(&self) -> u64 {
        self.confirmed
            .saturating_sub(self.pending_out)
            .saturating_add(self.pending_in)
    }
}

impl PendingSummary {
    /// The balance once everything pending confirms.
    pub fn balance_nano_erg(&self) -> u64 {
        self.confirmed_nano_erg
            .saturating_sub(self.pending_out_nano_erg)
            .saturating_add(self.pending_in_nano_erg)
    }

    /// The node-style JSON both sync paths return, so the app reads one shape.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "confirmed_nano_erg": self.confirmed_nano_erg,
            "pending_in_nano_erg": self.pending_in_nano_erg,
            "pending_out_nano_erg": self.pending_out_nano_erg,
            "balance_nano_erg": self.balance_nano_erg(),
            "pending_transactions": self.pending_transactions,
            "tokens": self.tokens.iter().map(|t| serde_json::json!({
                "id": t.token_id,
                "confirmed": t.confirmed,
                "pending_in": t.pending_in,
                "pending_out": t.pending_out,
                "amount": t.amount(),
            })).collect::<Vec<_>>(),
        })
    }
}

/// Value the set's pending movements: `confirmed` is every confirmed box of
/// the set, `txs` the union of their mempool transactions (see
/// [`unique_transactions`]) and `trees` the set's scripts.
///
/// Mempool inputs carry no value, so leaving amounts resolve against the
/// confirmed boxes, and the whole union is collected before anything is
/// valued — a chained spend's input is an unconfirmed output that no
/// confirmed set holds. An output already among the confirmed boxes is not
/// counted again: the block that carried it can land between the two reads.
pub fn pending_summary(
    confirmed: &[ErgoBox],
    txs: &[serde_json::Value],
    trees: &HashSet<String>,
) -> PendingSummary {
    let spent = spent_box_ids(txs);
    let mut summary = PendingSummary::default();
    let mut tokens: std::collections::BTreeMap<String, TokenFlow> = Default::default();
    let mut confirmed_ids = HashSet::new();
    for b in confirmed {
        let id = b.box_id().to_string();
        if !confirmed_ids.insert(id.clone()) {
            continue;
        }
        let leaving = spent.contains(&id);
        let value = *b.value.as_u64();
        summary.confirmed_nano_erg = summary.confirmed_nano_erg.saturating_add(value);
        if leaving {
            summary.pending_out_nano_erg = summary.pending_out_nano_erg.saturating_add(value);
        }
        for t in b.tokens.iter().flat_map(|held| held.iter()) {
            let id: String = t.token_id.into();
            let flow = tokens.entry(id.clone()).or_insert_with(|| TokenFlow {
                token_id: id,
                ..Default::default()
            });
            let amount = *t.amount.as_u64();
            flow.confirmed = flow.confirmed.saturating_add(amount);
            if leaving {
                flow.pending_out = flow.pending_out.saturating_add(amount);
            }
        }
    }

    let mut arrived = HashSet::new();
    for tx in txs {
        let spends_ours = tx["inputs"]
            .as_array()
            .map(|ins| {
                ins.iter()
                    .filter_map(|i| i["boxId"].as_str())
                    .any(|id| confirmed_ids.contains(id))
            })
            .unwrap_or(false);
        let mut pays_ours = false;
        for output in tx["outputs"].as_array().map(Vec::as_slice).unwrap_or(&[]) {
            if !output["ergoTree"].as_str().is_some_and(|t| trees.contains(t)) {
                continue;
            }
            pays_ours = true;
            let id = output["boxId"].as_str().unwrap_or_default();
            if spent.contains(id) || confirmed_ids.contains(id) || !arrived.insert(id.to_string())
            {
                continue;
            }
            let value = output["value"].as_u64().unwrap_or(0);
            summary.pending_in_nano_erg = summary.pending_in_nano_erg.saturating_add(value);
            for asset in output["assets"].as_array().map(Vec::as_slice).unwrap_or(&[]) {
                let Some(token_id) = asset["tokenId"].as_str() else {
                    continue;
                };
                let flow = tokens.entry(token_id.to_string()).or_insert_with(|| TokenFlow {
                    token_id: token_id.to_string(),
                    ..Default::default()
                });
                flow.pending_in = flow
                    .pending_in
                    .saturating_add(asset["amount"].as_u64().unwrap_or(0));
            }
        }
        if spends_ours || pays_ours {
            summary.pending_transactions += 1;
        }
    }
    summary.tokens = tokens.into_values().collect();
    summary
}

#[cfg(test)]
#[path = "mempool_merge_tests.rs"]
mod merge_tests;

#[cfg(test)]
#[path = "mempool_spend_tests.rs"]
mod spend_tests;

/// Net nanoERG change from unconfirmed transactions for `ergo_tree`.
///
/// Mempool inputs carry no value — only a `boxId` and a spending proof — so
/// the leaving amounts are resolved against `confirmed_values`, the map of the
/// caller's confirmed box ids to their nanoERG values.
///
/// Single pass over all transactions: collect every spent id first, then apply
/// deltas. Applying them transaction by transaction mis-nets a chained spend,
/// whose input references an unconfirmed output that is in no confirmed set.
pub fn balance_delta(
    txs: &[serde_json::Value],
    ergo_tree: &str,
    confirmed_values: &HashMap<String, i64>,
) -> i64 {
    let mut trees = HashSet::new();
    trees.insert(ergo_tree.to_string());
    wallet_balance_delta(txs, &trees, confirmed_values)
}

/// Net nanoERG change from unconfirmed transactions across a whole wallet —
/// every owned address tree at once.
///
/// The leaving side is tree-agnostic: an input counts as leaving whenever its
/// box id is in the combined confirmed set. Summing per-address deltas would
/// double-count a spend touching several owned addresses, so value a wallet
/// transaction exactly once through this function instead.
pub fn wallet_balance_delta(
    txs: &[serde_json::Value],
    trees: &HashSet<String>,
    confirmed_values: &HashMap<String, i64>,
) -> i64 {
    let spent = spent_box_ids(txs);

    // Confirmed boxes of ours consumed by mempool: leaving.
    let mut delta: i64 = 0;
    for id in &spent {
        if let Some(v) = confirmed_values.get(id) {
            delta -= v;
        }
    }

    // Our unconfirmed outputs that are not themselves already spent: arriving.
    for tx in txs {
        let outputs = match tx["outputs"].as_array() {
            Some(o) => o,
            None => continue,
        };
        for output in outputs {
            match output["ergoTree"].as_str() {
                Some(tree) if trees.contains(tree) => {}
                _ => continue,
            }
            let id = output["boxId"].as_str().unwrap_or_default();
            if spent.contains(id) {
                continue;
            }
            delta += output["value"].as_i64().unwrap_or(0);
        }
    }
    delta
}

/// Net per-token change from unconfirmed transactions for `ergo_tree`.
///
/// Same ownership and spent-set rules as [`balance_delta`]: leaving amounts
/// resolve against `confirmed_tokens`, the map of the caller's confirmed box
/// ids to the tokens each box holds, and unspent own outputs arrive.
pub fn token_deltas(
    txs: &[serde_json::Value],
    ergo_tree: &str,
    confirmed_tokens: &HashMap<String, Vec<(String, i64)>>,
) -> HashMap<String, i64> {
    let spent = spent_box_ids(txs);
    let mut deltas: HashMap<String, i64> = HashMap::new();

    for id in &spent {
        if let Some(held) = confirmed_tokens.get(id) {
            for (token_id, amount) in held {
                *deltas.entry(token_id.clone()).or_insert(0) -= amount;
            }
        }
    }

    for tx in txs {
        let outputs = match tx["outputs"].as_array() {
            Some(o) => o,
            None => continue,
        };
        for output in outputs {
            if output["ergoTree"].as_str() != Some(ergo_tree) {
                continue;
            }
            let id = output["boxId"].as_str().unwrap_or_default();
            if spent.contains(id) {
                continue;
            }
            if let Some(assets) = output["assets"].as_array() {
                for asset in assets {
                    let token_id = match asset["tokenId"].as_str() {
                        Some(t) => t.to_string(),
                        None => continue,
                    };
                    let amount = asset["amount"].as_i64().unwrap_or(0);
                    *deltas.entry(token_id).or_insert(0) += amount;
                }
            }
        }
    }
    deltas
}

/// Build an `ErgoBox` from one output of an unconfirmed transaction.
///
/// `ErgoBox`'s JSON form expects `transactionId` and `index`, which a mempool
/// output does not carry — the enclosing transaction does. Inject them before
/// deserialising, mirroring how `json_output_to_eip12` receives them.
///
/// Returns `None` for anything that will not parse: one bad box must never
/// abort a whole UTXO set.
pub fn output_to_ergo_box(
    output: &serde_json::Value,
    tx_id: &str,
    index: u16,
) -> Option<ErgoBox> {
    let mut enriched = output.clone();
    let obj = enriched.as_object_mut()?;
    obj.entry("transactionId")
        .or_insert_with(|| serde_json::Value::String(tx_id.to_string()));
    obj.entry("index")
        .or_insert_with(|| serde_json::Value::from(index));

    match serde_json::from_value::<ErgoBox>(enriched) {
        Ok(b) => Some(b),
        Err(e) => {
            tracing::warn!("Skipping unparsable mempool output: {}", e);
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
    use ergo_lib::ergotree_ir::chain::ergo_box::NonMandatoryRegisters;
    use ergo_lib::ergotree_ir::chain::tx_id::TxId;
    use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
    use std::str::FromStr;

    const OWN_TREE: &str =
        "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    /// A real-shaped transaction id (32 bytes hex): the box id is recomputed
    /// from contents *including* the injected transactionId, so the wrapping
    /// transaction in tests must carry exactly this id or conversion fails.
    const TX_ID: &str = "abababababababababababababababababababababababababababababababab";

    /// Shape of one output inside a `/transactions/unconfirmed` transaction:
    /// no `transactionId` and no `index` — the enclosing transaction carries
    /// those. The box id must be self-consistent with the contents, because
    /// deserialisation recomputes and verifies it, so the fixture is derived
    /// from a real `ErgoBox` rather than hand-written.
    fn mempool_output() -> serde_json::Value {
        let tree = ErgoTree::sigma_parse_bytes(&base16::decode(OWN_TREE).unwrap()).unwrap();
        let b = ErgoBox::new(
            BoxValue::try_from(1_000_000_000u64).unwrap(),
            tree,
            None,
            NonMandatoryRegisters::empty(),
            100_000,
            TxId::from_str(TX_ID).unwrap(),
            0,
        )
        .unwrap();
        let mut v = serde_json::to_value(&b).unwrap();
        let obj = v.as_object_mut().unwrap();
        obj.remove("transactionId");
        obj.remove("index");
        v
    }

    #[test]
    fn a_mempool_output_becomes_a_spendable_box() {
        let b = output_to_ergo_box(&mempool_output(), TX_ID, 0)
            .expect("mempool output must convert to an ErgoBox");

        assert_eq!(b.value.as_u64(), &1_000_000_000u64);
        assert_eq!(b.creation_height, 100_000);
    }

    #[test]
    fn a_malformed_output_is_skipped_not_fatal() {
        let junk = serde_json::json!({"boxId": "abc"});
        assert!(output_to_ergo_box(&junk, "tx", 0).is_none());
    }

    fn tx(id: &str, spends: &[&str], outputs: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "inputs": spends.iter().map(|b| serde_json::json!({"boxId": b})).collect::<Vec<_>>(),
            "outputs": outputs,
        })
    }

    #[test]
    fn every_input_box_counts_as_spent() {
        let txs = vec![tx("t1", &["boxA", "boxB"], vec![]), tx("t2", &["boxC"], vec![])];
        let spent = spent_box_ids(&txs);
        assert!(spent.contains("boxA") && spent.contains("boxB") && spent.contains("boxC"));
        assert!(!spent.contains("boxD"));
    }

    #[test]
    fn only_outputs_paying_this_tree_are_owned() {
        let mut theirs = mempool_output();
        theirs["ergoTree"] = serde_json::json!("0008cd03aaaa");
        theirs["boxId"] =
            serde_json::json!("3333333333333333333333333333333333333333333333333333333333333333");

        // The wrapping tx must carry the same id the fixture's box was built
        // with — the recomputed box id depends on it.
        let txs = vec![tx(TX_ID, &[], vec![mempool_output(), theirs])];
        let owned = owned_outputs(&txs, OWN_TREE);

        assert_eq!(owned.len(), 1, "only the output paying our tree is ours");
        assert_eq!(owned[0].value.as_u64(), &1_000_000_000u64);
    }

    #[test]
    fn a_chained_spend_nets_out_across_one_pass() {
        let mut confirmed = std::collections::HashMap::new();
        confirmed.insert("boxA".to_string(), 1_000_000_000i64);

        // t1 spends confirmed boxA (1 ERG), pays us back 0.6 as boxB.
        let mut b_out = mempool_output();
        b_out["boxId"] = serde_json::json!("boxB");
        b_out["value"] = serde_json::json!(600_000_000u64);
        let t1 = tx("t1", &["boxA"], vec![b_out]);

        // t2 chains: spends the still-unconfirmed boxB, pays us 0.4 back.
        let mut c_out = mempool_output();
        c_out["boxId"] = serde_json::json!("boxC");
        c_out["value"] = serde_json::json!(400_000_000u64);
        let t2 = tx("t2", &["boxB"], vec![c_out]);

        // Net: -1 ERG confirmed in, +0.4 ERG still ours. boxB must not be
        // counted as an asset while also being spent by t2.
        let delta = balance_delta(&[t1, t2], OWN_TREE, &confirmed);
        assert_eq!(delta, -600_000_000, "expected -1.0 spent + 0.4 returned");
    }

    fn plain_output(tree: &str, id: &str, value: u64) -> serde_json::Value {
        serde_json::json!({"boxId": id, "ergoTree": tree, "value": value, "assets": []})
    }

    #[test]
    fn a_wallet_transaction_is_valued_once_across_trees() {
        let other_tree = "0008cd03bbbb";

        let mut confirmed = std::collections::HashMap::new();
        confirmed.insert("boxA".to_string(), 1_000_000_000i64);

        // One mempool tx spends our boxA and pays the wallet's other address.
        let out = plain_output(other_tree, "boxX", 1_000_000_000);
        let txs = vec![tx("t1", &["boxA"], vec![out])];

        let trees: std::collections::HashSet<String> =
            [OWN_TREE.to_string(), other_tree.to_string()].into();

        // Leaving (-1.0) and arriving (+1.0) net to zero at wallet level;
        // per-address deltas would each have reported a full ±1.0.
        assert_eq!(wallet_balance_delta(&txs, &trees, &confirmed), 0);
    }

    #[test]
    fn token_deltas_follow_the_same_ownership_rules() {
        const TOKEN: &str = "tok";
        let mut confirmed_tokens = std::collections::HashMap::new();
        confirmed_tokens.insert(
            "boxA".to_string(),
            vec![(TOKEN.to_string(), 500i64)],
        );

        let incoming = serde_json::json!({
            "boxId": "boxC",
            "ergoTree": OWN_TREE,
            "value": 1u64,
            "assets": [{"tokenId": TOKEN, "amount": 100}],
        });
        // Pays a foreign tree — must not count as arriving for us.
        let outgoing_only = serde_json::json!({
            "boxId": "boxD",
            "ergoTree": "0008cd03cccc",
            "value": 1u64,
            "assets": [{"tokenId": TOKEN, "amount": 999}],
        });

        let txs = vec![
            tx("t1", &["boxA"], vec![incoming]),
            tx("t2", &[], vec![outgoing_only]),
        ];

        let deltas = token_deltas(&txs, OWN_TREE, &confirmed_tokens);
        assert_eq!(deltas.get(TOKEN), Some(&-400));
        assert_eq!(deltas.len(), 1);
    }
}
