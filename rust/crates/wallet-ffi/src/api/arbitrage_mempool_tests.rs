//! The arbitrage chain against the mempool rules, on the stand-in node the
//! mempool tests use. The chain's first leg is funded through the one
//! gathering point every spend uses; later legs spend the previous leg's
//! unbroadcast outputs whatever the unconfirmed-spending setting; and the
//! sale of a stranded token gathers its box the ordinary way.

use super::*;
use crate::api::mempool::tests::{boxed, pending_tx, policy, tx_id, Chain, Node, ERG};
use crate::api::{err_str, register_handle, wallet_lock, with_handle};
use crate::arbitrage_chain::tests::{argus_fee, best_opportunity, in_route_order, skewed};
use wallet_core::wallet::WalletHandle;
use wallet_net::client::address_to_ergo_tree;

/// A wallet that sent from its 60 ERG box a moment ago: that box is spent
/// in the mempool, 30 ERG of change is unconfirmed, and 40 ERG sits
/// confirmed and free.
struct Funded {
    handle: u64,
    address: String,
    tree: String,
    spent: ErgoBox,
    free: ErgoBox,
    change: ErgoBox,
    chain: Chain,
}

impl Funded {
    fn new(seed: u8) -> Self {
        let handle = register_handle(WalletHandle::restore_from_seed(&[seed; 64]).unwrap());
        let address =
            with_handle(handle, "test", |h| h.derive_address(0).map_err(err_str)).unwrap();
        let elsewhere = WalletHandle::restore_from_seed(&[seed.wrapping_add(100); 64])
            .unwrap()
            .derive_address(0)
            .unwrap();
        let tree = address_to_ergo_tree(&address).unwrap();
        let spent = boxed(&tree, &tx_id(1), 0, 60 * ERG);
        let free = boxed(&tree, &tx_id(2), 0, 40 * ERG);
        let paid = boxed(&address_to_ergo_tree(&elsewhere).unwrap(), &tx_id(3), 0, 29 * ERG);
        let change = boxed(&tree, &tx_id(3), 1, 30 * ERG);
        let mut chain = Chain::default();
        chain
            .unspent
            .insert(address.clone(), vec![spent.clone(), free.clone()]);
        chain.pend(&pending_tx(&tx_id(3), &[&spent], &[&paid, &change]));
        Self {
            handle,
            address,
            tree,
            spent,
            free,
            change,
            chain,
        }
    }
}

impl Drop for Funded {
    fn drop(&mut self) {
        let _ = wallet_lock(self.handle);
    }
}

/// A box of `value` at `tree` holding `amount` of `token`, output `index`
/// of transaction `tx`.
fn token_box(tree: &str, tx: &str, index: u16, value: u64, token: &str, amount: u64) -> ErgoBox {
    serde_json::from_value(serde_json::json!({
        "transactionId": tx, "index": index, "value": value, "ergoTree": tree,
        "creationHeight": 1_000, "additionalRegisters": {},
        "assets": [{"tokenId": token, "amount": amount}],
    }))
    .unwrap()
}

fn ids(boxes: &[ErgoBox]) -> HashSet<String> {
    boxes.iter().map(id_of).collect()
}

/// (a) and (b): the first leg spends only what the gathering offers, under
/// either setting; the second leg spends the first leg's payout, which no
/// node has seen, also while the wallet waits for confirmations.
#[tokio::test]
async fn a_chain_is_funded_by_the_gathering_and_chains_on_its_own_outputs() {
    for allow in [true, false] {
        let _policy = policy(allow);
        let w = Funded::new(31);
        let node = Node::start(w.chain.clone());
        let funding = chain_funding(w.handle, &[w.address.clone()], Some(node.url.clone()))
            .await
            .unwrap();
        let mut expected = ids(&[w.free.clone()]);
        if allow {
            expected.insert(id_of(&w.change));
        }
        assert_eq!(ids(&funding), expected, "allow={allow}");
        assert!(!ids(&funding).contains(&id_of(&w.spent)));

        // A chain sized to what the gathering offered.
        let available: u64 = funding.iter().map(|b| u64::from(b.value)).sum();
        let pools = skewed();
        let opp = best_opportunity(&pools, available);
        let route = in_route_order(&pools, &opp);
        let chain = ergo_tx::with_test_dev_fee(argus_fee(), || {
            build_chain(&route, &opp, &funding, &w.tree, 1_000_100, 0)
        })
        .unwrap();

        let first: HashSet<String> = chain.legs[0].inputs.iter().skip(1).map(id_of).collect();
        assert!(!first.is_empty() && first.is_subset(&ids(&funding)), "allow={allow}");
        for leg in &chain.legs {
            assert!(
                leg.inputs.iter().all(|b| id_of(b) != id_of(&w.spent)),
                "a box a pending transaction spends is never used"
            );
        }
        // Leg two spends leg one's payout by its precomputed id: an output
        // the gathering never listed, accepted as the chain's own.
        let paid: HashSet<String> = chain.legs[0].wallet_outputs(&w.tree).map(id_of).collect();
        let second: HashSet<String> = chain.legs[1].inputs.iter().skip(1).map(id_of).collect();
        assert!(!paid.is_disjoint(&second), "allow={allow}");
        assert!(paid.is_disjoint(&ids(&funding)));
        assert_eq!(super::super::mempool::spend_unconfirmed(), allow);
    }
}

/// (a): waiting for confirmations, a chain the confirmed funds cannot pay
/// is refused as still confirming, not as a plain shortfall.
#[tokio::test]
async fn a_chain_short_only_of_confirming_funds_says_so() {
    let _policy = policy(false);
    let w = Funded::new(32);
    let node = Node::start(w.chain.clone());
    let funding = chain_funding(w.handle, &[w.address.clone()], Some(node.url.clone()))
        .await
        .unwrap();
    assert_eq!(ids(&funding), ids(&[w.free.clone()]));
    // Sized to the 70 ERG the wallet will have once its change confirms.
    let pools = skewed();
    let opp = best_opportunity(&pools, 70 * ERG);
    assert!(opp.capital_nano > 40 * ERG && opp.capital_nano <= 70 * ERG);
    let route = in_route_order(&pools, &opp);
    let err = ergo_tx::with_test_dev_fee(argus_fee(), || {
        build_chain(&route, &opp, &funding, &w.tree, 1_000_100, 0)
    })
    .err()
    .expect("refused");
    assert!(err.contains("NOT_ENOUGH_ERG"), "{err}");
    let explained = super::super::mempool::explain_shortfall(w.handle, err);
    assert!(explained.contains("30 ERG is still confirming"), "{explained}");
    assert!(explained.contains("NOT_ENOUGH_ERG"), "{explained}");
}

/// (c): the stranded box comes through the ordinary gathering. Allowed to
/// spend unconfirmed funds, the sale gets it and fee boxes nothing pending
/// spends; waiting for confirmations, it is STRANDED_CONFIRMING; spent by
/// something else meanwhile, NOTHING_STRANDED.
#[tokio::test]
async fn the_stranded_token_is_gathered_the_ordinary_way() {
    let token = "33".repeat(32);
    let stranded_with = |w: &Funded| {
        // The chain's accepted leg, still in the mempool: it spent the
        // free box and left the token at the wallet's address.
        let leg_tx = tx_id(4);
        let pool_out = boxed(
            &address_to_ergo_tree(crate::api::ARGUS_FEE_ADDRESS).unwrap(),
            &leg_tx,
            0,
            ERG,
        );
        let stranded = token_box(&w.tree, &leg_tx, 1, 2_000_000, &token, 55);
        let mut chain = w.chain.clone();
        chain.pend(&pending_tx(&leg_tx, &[&w.free], &[&pool_out, &stranded]));
        (chain, stranded)
    };

    {
        let _policy = policy(true);
        let w = Funded::new(33);
        let (chain, stranded) = stranded_with(&w);
        let node = Node::start(chain);
        let client = node.client().await;
        let (got, fees) =
            unwind_inputs(w.handle, &client, &[w.address.clone()], &id_of(&stranded))
                .await
                .unwrap();
        assert_eq!(id_of(&got), id_of(&stranded));
        assert!(holds(&got, &token));
        // The send's change pays the fee; the boxes the pending
        // transactions spend never do.
        assert_eq!(ids(&fees), ids(&[w.change.clone()]));
    }
    {
        let _policy = policy(false);
        let w = Funded::new(34);
        let (chain, stranded) = stranded_with(&w);
        let node = Node::start(chain);
        let client = node.client().await;
        let err = unwind_inputs(w.handle, &client, &[w.address.clone()], &id_of(&stranded))
            .await
            .err()
            .expect("waits for its confirmation");
        assert!(err.contains("STRANDED_CONFIRMING"), "{err}");
        assert!(err.contains("after one confirmation"), "{err}");
    }
    {
        let _policy = policy(true);
        let w = Funded::new(35);
        let (mut chain, stranded) = stranded_with(&w);
        // Sold elsewhere meanwhile: a pending transaction paying someone
        // else spends the stranded box.
        let buyer = boxed(
            &address_to_ergo_tree(crate::api::ARGUS_FEE_ADDRESS).unwrap(),
            &tx_id(5),
            0,
            2_000_000,
        );
        chain.pend(&pending_tx(&tx_id(5), &[&stranded], &[&buyer]));
        let node = Node::start(chain);
        let client = node.client().await;
        let err = unwind_inputs(w.handle, &client, &[w.address.clone()], &id_of(&stranded))
            .await
            .err()
            .expect("nothing left to sell");
        assert!(err.contains("NOTHING_STRANDED"), "{err}");
    }
}

/// (c): the status says when the sale has to wait for a confirmation, so
/// the screen can say so instead of offering a sale that fails.
#[test]
fn the_holding_says_when_the_sale_waits_for_a_confirmation() {
    let pools = skewed();
    let opp = best_opportunity(&pools, 100 * ERG);
    let route = in_route_order(&pools, &opp);
    let tree = crate::arbitrage_chain::tests::USER_TREE;
    let funds = vec![boxed(tree, &tx_id(9), 0, 100 * ERG)];
    let chain = ergo_tx::with_test_dev_fee(argus_fee(), || {
        build_chain(&route, &opp, &funds, tree, 1_000_100, 0)
    })
    .unwrap();
    let rec = ChainRecord {
        handle_id: 1,
        node_url: None,
        prepared_at: Instant::now(),
        opportunity: opp,
        change_tree: tree.to_string(),
        spend_addresses: vec![],
        legs: chain.legs,
        executing: false,
        executed: true,
        accepted: vec![],
        failed_leg: Some(1),
    };
    let waits = |confirmed: bool| holding_json(&rec, 1, confirmed)["sellable_after_confirmation"].clone();
    {
        let _policy = policy(false);
        assert_eq!(waits(false), true);
        assert_eq!(waits(true), false, "a confirmed leg's output is spendable");
        assert!(holding_json(&rec, 1, false)["box_id"].is_string());
    }
    {
        let _policy = policy(true);
        assert_eq!(waits(false), false, "spending unconfirmed funds is allowed");
    }
}
