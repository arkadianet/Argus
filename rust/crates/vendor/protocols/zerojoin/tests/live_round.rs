//! Live acceptance test: build every ZeroJoin move against the boxes that are
//! on mainnet right now, and **reduce** each one offline.
//!
//! ```text
//! cargo test -p zerojoin zerojoin_live -- --ignored --nocapture
//! ```
//!
//! Nothing is signed and nothing is broadcast. Reduction runs the deployed
//! ErgoScript against the transaction we built and collapses every input to a
//! sigma proposition; a positional mistake, a wrong token burn or a value that
//! does not balance shows up as a reduction error or a `TrivialProp(false)`,
//! which is exactly the class of bug unit tests against our own model cannot
//! find. The Dexy work found two real bugs this way.
//!
//! The half-mix, fee-emission and token-emission boxes are live and belong to
//! other people. The wallet's own full-mix box is constructed locally from a
//! seed-derived secret — we do not own one on mainnet — but it is guarded by
//! the real deployed full-mix script, so the contract still runs.

use std::collections::HashMap;

use ergo_lib::chain::ergo_box::box_builder::ErgoBoxCandidateBuilder;
use ergo_lib::chain::transaction::TxId;
use ergo_lib::ergo_chain_types::Digest32;
use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
use ergo_lib::ergotree_ir::chain::ergo_box::{ErgoBox, NonMandatoryRegisterId};
use ergo_lib::ergotree_ir::chain::token::{Token, TokenAmount, TokenId};
use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
use ergo_lib::ergotree_ir::mir::constant::Constant;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergo_lib::wallet::mnemonic::Mnemonic;
use ergo_tx::{Eip12Asset, Eip12InputBox, Eip12UnsignedTx};

use zerojoin::boxes::{FeeEmissionBox, FullMixBox, HalfMixBox, TokenEmissionBox};
use zerojoin::contracts::{
    FEE_EMISSION_ERGO_TREE_HEX, HALF_MIX_ERGO_TREE_HEX, TOKEN_EMISSION_ERGO_TREE_HEX,
};
use zerojoin::round::{full_mix_outputs, MixTokenSplit, PairOrder};
use zerojoin::secret::MixSecret;
use zerojoin::tx_builder::{
    build_alice_entry, build_bob_entry, build_reclaim_half_mix, build_remix_as_alice,
    build_remix_as_bob, build_withdraw, erg_imbalance, mixing_tokens_burned, operator_fee,
    AliceEntry, BobEntry, MixTx, ReclaimHalfMix, RemixAsAlice, RemixAsBob, Withdraw,
};

const NODE: &str = "https://ergo-node.eutxo.de";
const MINER_FEE: i64 = 1_500_000;

/// A throwaway seed: this test signs nothing, so the keys never matter beyond
/// making the round model reproducible.
const MNEMONIC: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

fn root() -> ExtSecretKey {
    ExtSecretKey::derive_master(Mnemonic::to_seed(MNEMONIC, "")).unwrap()
}

fn secret(mix: u32, round: u32) -> MixSecret {
    MixSecret::derive(&root(), mix, round).unwrap()
}

// ---------------------------------------------------------------------------
// Live discovery
// ---------------------------------------------------------------------------

/// Unspent boxes guarded by exactly this ErgoTree, via the node's extra index.
async fn unspent_by_tree(tree_hex: &str, limit: usize) -> Vec<Eip12InputBox> {
    let url = format!("{NODE}/blockchain/box/unspent/byErgoTree?limit={limit}");
    let body = serde_json::Value::String(tree_hex.to_string());
    let text = reqwest::Client::new()
        .post(&url)
        .json(&body)
        .send()
        .await
        .expect("node reachable")
        .text()
        .await
        .expect("body");
    zerojoin::parse_explorer_boxes(&text).expect("node boxes parse")
}

async fn node_client() -> ergo_node_client::NodeClient {
    ergo_node_client::NodeClient::new(citadel_core::NodeConfig {
        url: NODE.to_string(),
        api_key: String::new(),
    })
    .await
    .expect("node client")
}

// ---------------------------------------------------------------------------
// EIP-12 → ErgoBox
// ---------------------------------------------------------------------------

fn register_id(name: &str) -> NonMandatoryRegisterId {
    match name {
        "R4" => NonMandatoryRegisterId::R4,
        "R5" => NonMandatoryRegisterId::R5,
        "R6" => NonMandatoryRegisterId::R6,
        "R7" => NonMandatoryRegisterId::R7,
        "R8" => NonMandatoryRegisterId::R8,
        "R9" => NonMandatoryRegisterId::R9,
        other => panic!("unexpected register {other}"),
    }
}

/// Rebuild an `ErgoBox` from the EIP-12 view, for boxes we invented locally.
///
/// Live boxes come straight from the node instead, because their real box id
/// matters: the half-mix contract checks `SELF.id == INPUTS(0).id`.
fn to_ergo_box(b: &Eip12InputBox, tag: u8, index: u16) -> ErgoBox {
    let tree = ErgoTree::sigma_parse_bytes(&hex::decode(&b.ergo_tree).unwrap()).unwrap();
    let value = BoxValue::try_from(b.value.parse::<u64>().unwrap()).unwrap();
    let mut builder = ErgoBoxCandidateBuilder::new(value, tree, b.creation_height as u32);
    for (name, hex_value) in &b.additional_registers {
        let c = Constant::sigma_parse_bytes(&hex::decode(hex_value).unwrap()).unwrap();
        builder.set_register_value(register_id(name), c);
    }
    for a in &b.assets {
        builder.add_token(Token {
            token_id: TokenId::from(Digest32::try_from(a.token_id.clone()).unwrap()),
            amount: TokenAmount::try_from(a.amount.parse::<u64>().unwrap()).unwrap(),
        });
    }
    let candidate = builder.build().unwrap();
    ErgoBox::from_box_candidate(
        &candidate,
        TxId::from(Digest32::from([tag; 32])),
        index,
    )
    .unwrap()
}

/// Every input of `tx`, as `ErgoBox`, taking the live ones from `live` (keyed
/// by box id) and rebuilding the rest.
fn input_boxes(tx: &Eip12UnsignedTx, live: &HashMap<String, ErgoBox>) -> Vec<ErgoBox> {
    tx.inputs
        .iter()
        .enumerate()
        .map(|(i, b)| match live.get(&b.box_id) {
            Some(real) => real.clone(),
            None => to_ergo_box(b, 0xc0 + i as u8, i as u16),
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Reduction
// ---------------------------------------------------------------------------

/// Reduce every input and report. Returns false if anything reduced to a
/// proposition that can never be satisfied.
async fn reduce_and_report(
    label: &str,
    tx: &MixTx,
    live: &HashMap<String, ErgoBox>,
    client: &ergo_node_client::NodeClient,
) -> bool {
    use ergo_lib::chain::transaction::reduced::ReducedTransaction;

    println!(
        "\n[{label}] inputs={} outputs={} burn={} imbalance={} summary={:?}",
        tx.unsigned_tx.inputs.len(),
        tx.unsigned_tx.outputs.len(),
        mixing_tokens_burned(&tx.unsigned_tx),
        erg_imbalance(&tx.unsigned_tx),
        tx.summary
    );
    assert_eq!(
        erg_imbalance(&tx.unsigned_tx),
        0,
        "[{label}] nanoERG must balance exactly"
    );

    let boxes = input_boxes(&tx.unsigned_tx, live);
    let bytes = match ergopay_core::reduce_transaction(&tx.unsigned_tx, boxes, vec![], client).await
    {
        Ok(b) => b,
        Err(e) => {
            println!("[{label}] REDUCTION FAILED: {e}");
            return false;
        }
    };
    let reduced = ReducedTransaction::sigma_parse_bytes(&bytes).expect("reduced parses");
    let mut ok = true;
    for (i, input) in reduced.reduced_inputs().iter().enumerate() {
        let prop = format!("{:?}", input.sigma_prop);
        // `TrivialProp(false)` means the script evaluated to false: the
        // transaction is invalid whatever we sign it with.
        let satisfiable = !prop.contains("TrivialProp(false)");
        println!(
            "[{label}] input {i}: {} {}",
            if satisfiable { "ok" } else { "FALSE" },
            prop.chars().take(120).collect::<String>()
        );
        ok &= satisfiable;
    }
    ok
}

// ---------------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore]
async fn zerojoin_live_round_reduces() {
    zerojoin::verify_contract_wiring().expect("pinned contracts still agree");

    let client = node_client().await;
    let height = client.current_height().await.expect("height") as i32;

    // --- discover the live pool -------------------------------------------
    let half_boxes = unspent_by_tree(HALF_MIX_ERGO_TREE_HEX, 50).await;
    let fee_boxes = unspent_by_tree(FEE_EMISSION_ERGO_TREE_HEX, 5).await;
    let token_boxes = unspent_by_tree(TOKEN_EMISSION_ERGO_TREE_HEX, 5).await;

    let rings = zerojoin::discover_rings(&half_boxes);
    println!("live rings ({} half-mix boxes waiting):", half_boxes.len());
    for r in &rings {
        println!(
            "  {} nanoERG  token={:?}  waiting={}  max level={}",
            r.value, r.token_id, r.waiting, r.max_mix_level
        );
    }
    assert!(!rings.is_empty(), "the live pool has no half-mix boxes");

    // An ERG ring, so no ring-token commission is involved.
    let half_input = half_boxes
        .iter()
        .find(|b| b.assets.len() == 1)
        .cloned()
        .expect("an ERG-denominated half-mix box");
    let half = HalfMixBox::parse(&half_input).expect("half-mix parses");
    let fee_box = FeeEmissionBox::parse(&fee_boxes[0]).expect("fee emission parses");
    let token_box = TokenEmissionBox::parse(&token_boxes[0]).expect("token emission parses");
    println!(
        "\nchosen ring: {} nanoERG, half-mix level {}; fee box {} nanoERG (max fee {}); \
         token box offers {:?} at rate {}",
        half.value, half.mix_level, fee_box.value, fee_box.max_fee, token_box.levels(), token_box.rate
    );

    // Live boxes must reduce against their real ids.
    let mut live: HashMap<String, ErgoBox> = HashMap::new();
    for id in [
        half.input.box_id.clone(),
        fee_box.input.box_id.clone(),
        token_box.input.box_id.clone(),
    ] {
        let b = client
            .get_box_by_id(&citadel_core::BoxId::new(&id))
            .await
            .expect("live box");
        live.insert(id, b);
    }

    let fee = MINER_FEE.min(fee_box.max_fee);

    // --- a full-mix box of our own, at the same denomination --------------
    // We were Bob in an earlier round, so `c2 == g^y0`.
    let y0 = secret(1, 0);
    let their_x = secret(1000, 0);
    let level = half.mix_level.max(2);
    let ours_out = full_mix_outputs(
        half.value,
        their_x.public_key(),
        &y0,
        PairOrder::BobFirst,
        MixTokenSplit {
            per_output: level,
            burned: 1,
        },
        &None,
        height,
    )
    .unwrap();
    let ours = FullMixBox::parse(&Eip12InputBox {
        box_id: hex::encode([0xd1; 32]),
        transaction_id: hex::encode([0xd2; 32]),
        index: 0,
        value: ours_out[0].value.clone(),
        ergo_tree: ours_out[0].ergo_tree.clone(),
        assets: ours_out[0].assets.clone(),
        creation_height: ours_out[0].creation_height,
        additional_registers: ours_out[0].additional_registers.clone(),
        extension: HashMap::new(),
    })
    .expect("our full-mix box parses");
    assert!(y0.owns_as_bob(&ours));

    let mut all_ok = true;

    // --- remix as Bob: half + full -> full + full -------------------------
    let tx = build_remix_as_bob(&RemixAsBob {
        half: &half,
        full: &ours,
        current: &y0,
        next_y: &secret(1, 1),
        fee_box: &fee_box,
        order: PairOrder::BobFirst,
        miner_fee: fee,
        height,
    })
    .expect("remix as bob builds");
    all_ok &= reduce_and_report("remix as Bob", &tx, &live, &client).await;

    // --- remix as Alice: full -> half -------------------------------------
    let tx = build_remix_as_alice(&RemixAsAlice {
        full: &ours,
        current: &y0,
        next_x: &secret(1, 1),
        fee_box: &fee_box,
        miner_fee: fee,
        height,
    })
    .expect("remix as alice builds");
    all_ok &= reduce_and_report("remix as Alice", &tx, &live, &client).await;

    // --- withdraw ---------------------------------------------------------
    let destination = "0008cd0385d10043e1ff4a3bef3f99961d5f16e1f2978f900e16421d3998f8d09fd6412c";
    let tx = build_withdraw(&Withdraw {
        full: &ours,
        current: &y0,
        fee_box: &fee_box,
        destination_ergo_tree: destination,
        miner_fee: fee,
        height,
    })
    .expect("withdraw builds");
    all_ok &= reduce_and_report("withdraw", &tx, &live, &client).await;

    // --- entering as Alice: buy a batch, post a half-mix box --------------
    let entry_level = token_box.levels()[0];
    let op = operator_fee(&token_box, half.value, entry_level).unwrap();
    let funding = Eip12InputBox {
        box_id: hex::encode([0xe1; 32]),
        transaction_id: hex::encode([0xe2; 32]),
        index: 0,
        value: (half.value + fee + op.total()).to_string(),
        ergo_tree: destination.to_string(),
        assets: vec![],
        creation_height: height,
        additional_registers: HashMap::new(),
        extension: HashMap::new(),
    };
    let x = secret(2, 0);
    let tx = build_alice_entry(&AliceEntry {
        funding: &funding,
        token_box: &token_box,
        x: &x,
        denomination: half.value,
        level: entry_level,
        ring_token: None,
        miner_fee: fee,
        height,
    })
    .expect("alice entry builds");
    all_ok &= reduce_and_report("enter as Alice", &tx, &live, &client).await;

    // --- entering as Bob: buy a batch, consume the waiting half-mix box ---
    let tx = build_bob_entry(&BobEntry {
        half: &half,
        funding: &funding,
        token_box: &token_box,
        y: &secret(3, 0),
        level: entry_level,
        order: PairOrder::AliceFirst,
        miner_fee: fee,
        height,
    })
    .expect("bob entry builds");
    all_ok &= reduce_and_report("enter as Bob", &tx, &live, &client).await;

    // --- reclaiming our own half-mix box ----------------------------------
    let mine = zerojoin::round::half_mix_output(half.value, &x, level, &None, height).unwrap();
    let mine = HalfMixBox::parse(&Eip12InputBox {
        box_id: hex::encode([0xf1; 32]),
        transaction_id: hex::encode([0xf2; 32]),
        index: 0,
        value: mine.value.clone(),
        ergo_tree: mine.ergo_tree.clone(),
        assets: mine.assets.clone(),
        creation_height: mine.creation_height,
        additional_registers: mine.additional_registers.clone(),
        extension: HashMap::new(),
    })
    .unwrap();
    let tx = build_reclaim_half_mix(&ReclaimHalfMix {
        half: &mine,
        x: &x,
        destination_ergo_tree: destination,
        miner_fee: fee,
        height,
    })
    .expect("reclaim builds");
    all_ok &= reduce_and_report("reclaim half-mix", &tx, &live, &client).await;

    assert!(all_ok, "at least one input reduced to an unsatisfiable proposition");
}

/// Sanity: the trees pinned in the crate are the trees the pool is using today.
#[tokio::test]
#[ignore]
async fn zerojoin_live_contracts_match_mainnet() {
    for (label, tree) in [
        ("half mix", HALF_MIX_ERGO_TREE_HEX),
        ("fee emission", FEE_EMISSION_ERGO_TREE_HEX),
        ("token emission", TOKEN_EMISSION_ERGO_TREE_HEX),
        (
            "full mix",
            zerojoin::contracts::FULL_MIX_ERGO_TREE_HEX,
        ),
    ] {
        let boxes = unspent_by_tree(tree, 3).await;
        println!("{label}: {} unspent boxes on mainnet", boxes.len());
        assert!(
            !boxes.is_empty(),
            "{label}: no live box uses the tree pinned in this crate"
        );
        assert!(boxes.iter().all(|b| b.ergo_tree == tree));
    }
}

/// Print the denominations the pool actually has, so the UI work that follows
/// offers only rings a user can really join.
#[tokio::test]
#[ignore]
async fn zerojoin_live_rings() {
    let halfs = unspent_by_tree(HALF_MIX_ERGO_TREE_HEX, 200).await;
    for r in zerojoin::discover_rings(&halfs) {
        println!(
            "{:>15} nanoERG  token={:?} x{:?}  waiting={}  max level={}",
            r.value, r.token_id, r.token_amount, r.waiting, r.max_mix_level
        );
    }
    let _ = Eip12Asset::new("x", 1);
}
