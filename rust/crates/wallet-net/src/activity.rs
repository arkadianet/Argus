//! One transaction read from the whole wallet's point of view.
//!
//! The node's `byAddress` listing is per address, but a wallet is many
//! addresses: index 0, the pinned one, every other derived index. Reading a
//! transaction against only the address whose listing returned it calls a
//! move between two of the wallet's own addresses a payment, and a burn a
//! send to the address that took the change. Here every box is checked
//! against the full set of addresses the wallet owns.
//!
//! Besides the summary fields the activity list has always read
//! (`value_nano_erg`, `tokens_*`, `counterparty`, now all wallet-wide), each
//! transaction carries a compact [`TxIo`]: its inputs and outputs grouped by
//! owner, with assets and any protocol a box belongs to. The app classifies
//! from that (swap, burn, mint, LP, …) and can re-read it against a larger
//! set of its own scripts (stealth boxes, a watched account's later
//! addresses) without another request.

use std::collections::{BTreeMap, HashMap, HashSet};

use ergo_lib::ergotree_ir::chain::address::{Address, AddressEncoder, NetworkPrefix};
use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use serde::{Deserialize, Serialize};

use crate::client::{TokenReceived, TxSummary};

/// Owners listed per side before the rest are summed into one entry. The
/// wallet's own addresses and boxes a protocol is recognised on are always
/// listed; only plain foreign addresses are folded (a 100-party CoinJoin
/// is still one row).
pub const MAX_PARTIES_PER_SIDE: usize = 24;

/// Names a protocol box: `"spectrum_pool"`, `"sigmausd_bank"`, … `None`
/// for an ordinary box. Gets the node's box JSON (`ergoTree`, `assets`,
/// `additionalRegisters`, `value`).
pub type Tagger<'a> = &'a (dyn Fn(&serde_json::Value) -> Option<String> + Sync);

/// Tags nothing: a plain wallet-level summary.
pub fn no_tags(_: &serde_json::Value) -> Option<String> {
    None
}

/// Every box of one owner on one side of a transaction, summed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Party {
    /// Base58 address. Empty for the folded remainder of many foreign
    /// owners.
    pub address: String,
    pub value: u64,
    #[serde(default)]
    pub assets: Vec<TokenReceived>,
    /// How many boxes were summed.
    pub boxes: u32,
    /// The protocol these boxes belong to, when one is recognised:
    /// `"spectrum:pool"`, `"sigmausd:bank"`, `"argus_fee"`, …
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    /// The address is one of the wallet's own.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub mine: bool,
}

/// A transaction's flows, compact enough to keep on every history row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TxIo {
    pub inputs: Vec<Party>,
    /// Outputs other than the miner fee.
    pub outputs: Vec<Party>,
    /// The miner fee output(s), in nanoERG.
    pub miner_fee: u64,
    /// The first input's box id: a token minted here takes this id.
    pub first_input: String,
    /// False when some inputs could not be read (a pending transaction
    /// spending a box nothing returned); the input side is then partial.
    pub complete: bool,
}

/// The base58 address of a box, from its `address` field or else its tree.
pub fn box_address(b: &serde_json::Value) -> Option<String> {
    if let Some(a) = b["address"].as_str().filter(|a| !a.is_empty()) {
        return Some(a.to_string());
    }
    let tree = b["ergoTree"].as_str()?;
    tree_hex_to_address(tree)
}

/// Base58 (mainnet) for an ErgoTree in hex; None when it does not parse.
pub fn tree_hex_to_address(tree: &str) -> Option<String> {
    let bytes = base16::decode(tree).ok()?;
    let tree = ErgoTree::sigma_parse_bytes(&bytes).ok()?;
    let addr = Address::recreate_from_ergo_tree(&tree).ok()?;
    Some(AddressEncoder::new(NetworkPrefix::Mainnet).address_to_str(&addr))
}

fn is_miner_fee(b: &serde_json::Value) -> bool {
    b["ergoTree"].as_str() == Some(ergo_lib::wallet::miner_fee::MINERS_FEE_BASE16_BYTES)
}

fn assets_of(b: &serde_json::Value) -> Vec<(String, u64)> {
    b["assets"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|t| Some((t["tokenId"].as_str()?.to_string(), t["amount"].as_u64()?)))
                .collect()
        })
        .unwrap_or_default()
}

/// Whether a box JSON is a whole box rather than a bare input reference.
fn is_resolved(b: &serde_json::Value) -> bool {
    b["value"].is_number() && (b["ergoTree"].is_string() || b["address"].is_string())
}

#[derive(Default)]
struct Acc {
    value: u64,
    assets: BTreeMap<String, u64>,
    boxes: u32,
    order: Vec<String>,
}

impl Acc {
    fn add(&mut self, value: u64, assets: &[(String, u64)]) {
        self.value = self.value.saturating_add(value);
        self.boxes += 1;
        for (id, amount) in assets {
            if !self.assets.contains_key(id) {
                self.order.push(id.clone());
            }
            let e = self.assets.entry(id.clone()).or_insert(0);
            *e = e.saturating_add(*amount);
        }
    }

    fn party(self, address: String, tag: Option<String>, mine: bool) -> Party {
        let mut assets = self.assets;
        Party {
            address,
            value: self.value,
            assets: self
                .order
                .iter()
                .filter_map(|id| {
                    assets.remove(id).map(|amount| TokenReceived {
                        token_id: id.clone(),
                        amount,
                    })
                })
                .collect(),
            boxes: self.boxes,
            tag,
            mine,
        }
    }
}

/// What boxes are grouped by: owner and protocol tag, and for a tagged box
/// its first token too, so two pools sharing one script (every N2T pool
/// does) stay two parties, each with its NFT and LP token first.
type PartyKey = (String, Option<String>, Option<String>);

/// Groups boxes by [`PartyKey`], in first-seen order, folding plain foreign
/// owners past [`MAX_PARTIES_PER_SIDE`].
fn parties<'a>(
    boxes: impl Iterator<Item = &'a serde_json::Value>,
    owned: &HashSet<String>,
    tagger: Tagger<'_>,
) -> Vec<Party> {
    let mut order: Vec<PartyKey> = Vec::new();
    let mut groups: HashMap<PartyKey, Acc> = HashMap::new();
    for b in boxes {
        let address = box_address(b).unwrap_or_default();
        let assets = assets_of(b);
        let tag = tagger(b);
        let first = tag
            .as_ref()
            .and_then(|_| assets.first().map(|(id, _)| id.clone()));
        let key = (address, tag, first);
        let acc = groups.entry(key.clone()).or_insert_with(|| {
            order.push(key.clone());
            Acc::default()
        });
        acc.add(b["value"].as_u64().unwrap_or(0), &assets);
    }
    let foreign_plain = order
        .iter()
        .filter(|(a, t, _)| t.is_none() && !owned.contains(a))
        .count();
    let keep_plain = MAX_PARTIES_PER_SIDE.saturating_sub(order.len() - foreign_plain);
    let mut kept = 0usize;
    let mut out = Vec::new();
    let mut rest = Acc::default();
    let mut folded = false;
    for key in order {
        let acc = groups.remove(&key).expect("grouped");
        let mine = owned.contains(&key.0);
        let plain_foreign = key.1.is_none() && !mine;
        if plain_foreign {
            if kept >= keep_plain {
                folded = true;
                rest.value = rest.value.saturating_add(acc.value);
                rest.boxes += acc.boxes;
                for id in &acc.order {
                    if !rest.assets.contains_key(id) {
                        rest.order.push(id.clone());
                    }
                    let e = rest.assets.entry(id.clone()).or_insert(0);
                    *e = e.saturating_add(acc.assets[id]);
                }
                continue;
            }
            kept += 1;
        }
        out.push(acc.party(key.0, key.1, mine));
    }
    if folded {
        out.push(rest.party(String::new(), None, false));
    }
    out
}

/// The compact flows of `tx`. `inputs` are the input boxes as far as they
/// are known (a confirmed listing carries them whole; a pending one only by
/// id, resolved by the caller); bare references are left out and make the
/// result incomplete.
pub fn tx_io(
    tx: &serde_json::Value,
    inputs: &[serde_json::Value],
    owned: &HashSet<String>,
    tagger: Tagger<'_>,
) -> TxIo {
    let outs = tx["outputs"]
        .as_array()
        .map(|a| a.as_slice())
        .unwrap_or(&[]);
    let first_input = tx["inputs"][0]["boxId"]
        .as_str()
        .or_else(|| inputs.first().and_then(|i| i["boxId"].as_str()))
        .unwrap_or_default()
        .to_string();
    TxIo {
        inputs: parties(inputs.iter().filter(|b| is_resolved(b)), owned, tagger),
        outputs: parties(outs.iter().filter(|o| !is_miner_fee(o)), owned, tagger),
        miner_fee: outs
            .iter()
            .filter(|o| is_miner_fee(o))
            .map(|o| o["value"].as_u64().unwrap_or(0))
            .sum(),
        first_input,
        complete: inputs.iter().all(is_resolved),
    }
}

/// Summary of `tx` for a wallet owning `owned` (base58 addresses).
///
/// `inputs` overrides the transaction's own input list, for a pending
/// transaction whose inputs the caller resolved; None reads `tx["inputs"]`.
/// Every amount is the wallet's net change: a box moving between two owned
/// addresses changes nothing, and the counterparty is never one of them.
pub fn summarize_for_wallet(
    tx: &serde_json::Value,
    inputs: Option<&[serde_json::Value]>,
    owned: &HashSet<String>,
    tagger: Tagger<'_>,
) -> Option<TxSummary> {
    let tx_id = tx["id"].as_str()?.to_string();
    let ins: &[serde_json::Value] = match inputs {
        Some(i) => i,
        None => tx["inputs"].as_array().map(|a| a.as_slice()).unwrap_or(&[]),
    };
    let outs = tx["outputs"]
        .as_array()
        .map(|a| a.as_slice())
        .unwrap_or(&[]);
    let mine = |b: &serde_json::Value| box_address(b).is_some_and(|a| owned.contains(&a));

    let mut token_ids: Vec<String> = Vec::new();
    for o in outs {
        for (id, _) in assets_of(o) {
            if !token_ids.contains(&id) {
                token_ids.push(id);
            }
        }
    }

    // Net per token and in nanoERG, over owned boxes only.
    let mut net: BTreeMap<String, i128> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut value: i128 = 0;
    let mut apply = |b: &serde_json::Value, sign: i128| {
        value += sign * b["value"].as_u64().unwrap_or(0) as i128;
        for (id, amount) in assets_of(b) {
            if !net.contains_key(&id) {
                order.push(id.clone());
            }
            *net.entry(id).or_insert(0) += sign * amount as i128;
        }
    };
    for o in outs.iter().filter(|o| mine(o)) {
        apply(o, 1);
    }
    for i in ins.iter().filter(|i| is_resolved(i) && mine(i)) {
        apply(i, -1);
    }
    let clamp = |v: i128| v.clamp(0, u64::MAX as i128) as u64;
    let tokens_received = order
        .iter()
        .filter(|id| net[*id] > 0)
        .map(|id| TokenReceived {
            token_id: id.clone(),
            amount: clamp(net[id]),
        })
        .collect();
    let tokens_sent: Vec<TokenReceived> = order
        .iter()
        .filter(|id| net[*id] < 0)
        .map(|id| TokenReceived {
            token_id: id.clone(),
            amount: clamp(-net[id]),
        })
        .collect();
    let value_nano_erg = value.clamp(i64::MIN as i128, i64::MAX as i128) as i64;

    let fee_from_output: u64 = outs
        .iter()
        .filter(|o| is_miner_fee(o))
        .map(|o| o["value"].as_u64().unwrap_or(0))
        .sum();
    let inputs_valued = !ins.is_empty() && ins.iter().all(|i| i["value"].is_number());
    let fee_nano_erg = if fee_from_output > 0 {
        Some(fee_from_output)
    } else if inputs_valued {
        let in_total: u64 = ins.iter().map(|i| i["value"].as_u64().unwrap_or(0)).sum();
        let out_total: u64 = outs.iter().map(|o| o["value"].as_u64().unwrap_or(0)).sum();
        Some(in_total.saturating_sub(out_total))
    } else {
        None
    };

    let outgoing = value_nano_erg < 0 || !tokens_sent.is_empty();
    let foreign = |b: &&serde_json::Value| !mine(b);
    let counterparty = if outgoing {
        outs.iter()
            .filter(|o| !is_miner_fee(o))
            .filter(|o| tagger(o).as_deref() != Some(ARGUS_FEE_TAG))
            .filter(foreign)
            .find_map(box_address)
    } else {
        ins.iter().filter(foreign).find_map(box_address)
    };

    let io = tx_io(tx, ins, owned, tagger);
    Some(TxSummary {
        tx_id,
        height: tx["inclusionHeight"].as_u64().unwrap_or(0),
        timestamp: tx["timestamp"].as_u64().unwrap_or(0),
        value_nano_erg,
        token_ids,
        tokens_received,
        tokens_sent,
        fee_nano_erg,
        counterparty,
        num_inputs: tx["inputs"].as_array().map(|a| a.len() as u32).unwrap_or(0),
        num_outputs: outs.len() as u32,
        io: Some(io),
    })
}

/// The tag the app-fee box carries, so it is never named as the
/// counterparty of a payment.
pub const ARGUS_FEE_TAG: &str = "argus_fee";

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const A: &str = "9iArkadiaZAPVxbUp2XQ8SVA1zGA29rCPhbpVuUaaKW6fWspUZA";
    const B: &str = "9hQTG5EspKUxjhmnFRdzhethHaFmnW4PvjobckSrTSNRYhQLhCZ";

    fn owned(a: &[&str]) -> HashSet<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn many_foreign_owners_fold_but_the_wallet_and_protocols_never_do() {
        let mut outputs: Vec<serde_json::Value> = (0..40)
            .map(|i| json!({"address": format!("9foreign{i:02}"), "value": 10, "assets": [{"tokenId": "t", "amount": 1}]}))
            .collect();
        outputs.push(json!({"address": A, "value": 7, "assets": []}));
        outputs.push(
            json!({"address": "pool", "value": 5, "assets": [{"tokenId": "nft", "amount": 1}]}),
        );
        let tx = json!({"id": "t", "inputs": [{"boxId": "i", "address": B, "value": 500}], "outputs": outputs});
        let tagger =
            |b: &serde_json::Value| (b["address"] == "pool").then(|| "spectrum:pool".to_string());
        let io = tx_io(
            &tx,
            tx["inputs"].as_array().unwrap(),
            &owned(&[A, B]),
            &tagger,
        );
        assert_eq!(io.outputs.len(), MAX_PARTIES_PER_SIDE + 1);
        let folded = io.outputs.last().unwrap();
        assert_eq!(folded.address, "");
        assert_eq!(folded.boxes, 40 - (MAX_PARTIES_PER_SIDE as u32 - 2));
        // Folding keeps every amount: the totals still balance.
        let total: u64 = io.outputs.iter().map(|p| p.value).sum();
        assert_eq!(total, 40 * 10 + 7 + 5);
        let tokens: u64 = io
            .outputs
            .iter()
            .flat_map(|p| &p.assets)
            .filter(|t| t.token_id == "t")
            .map(|t| t.amount)
            .sum();
        assert_eq!(tokens, 40);
        assert!(io.outputs.iter().any(|p| p.mine && p.address == A));
        assert!(io
            .outputs
            .iter()
            .any(|p| p.tag.as_deref() == Some("spectrum:pool")));
        assert!(io.inputs[0].mine);
    }

    #[test]
    fn an_unread_pending_input_leaves_the_flows_incomplete() {
        // A mempool input is a box id only; the caller resolved the
        // wallet's own, not the pool's.
        let tx = json!({"id": "p", "inputs": [{"boxId": "pool-box"}, {"boxId": "mine"}],
            "outputs": [{"ergoTree": "00", "address": A, "value": 90, "assets": [{"tokenId": "x", "amount": 3}]}]});
        let inputs = vec![
            json!({"boxId": "pool-box"}),
            json!({"boxId": "mine", "address": B, "value": 100, "assets": []}),
        ];
        let s = summarize_for_wallet(&tx, Some(&inputs), &owned(&[A, B]), &no_tags).unwrap();
        assert_eq!(s.value_nano_erg, -10);
        assert_eq!(s.tokens_received.len(), 1);
        let io = s.io.unwrap();
        assert!(!io.complete);
        assert_eq!(
            io.inputs.len(),
            1,
            "the unread input is left out, not guessed"
        );
        assert_eq!(io.first_input, "pool-box");
    }

    #[test]
    fn a_box_without_an_address_is_read_from_its_tree() {
        let tree = crate::address_to_ergo_tree(A).unwrap();
        assert_eq!(box_address(&json!({"ergoTree": tree})).as_deref(), Some(A));
    }
}
