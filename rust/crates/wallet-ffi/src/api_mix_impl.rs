//! Mixing over the FFI: a persisted state and a chain snapshot in, one
//! built move out.
//!
//! The Dart side owns persistence and fetching. It hands over the mix's
//! `MixState` JSON and a `ChainView` JSON, and gets back either a prepared
//! transaction (entries, which the user confirms) or a broadcast result
//! with the state to persist (every later move). Secrets never cross the
//! boundary: each is derived from the unlocked handle for one call.

use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_lib::wallet::secret_key::SecretKey;
use ergo_tx::Eip12InputBox;
use wallet_core::WalletHandle;
use zerojoin::boxes::HalfMixBox;
use zerojoin::tx_builder::operator_fee;
use zerojoin::{
    build_alice_entry, build_bob_entry, build_reclaim_half_mix, build_remix_as_alice,
    build_remix_as_bob, build_withdraw, discover_rings, plan, AliceEntry, Applied, BobEntry,
    ChainView, MixPhase, MixState, MixTx, PairOrder, Plan, ReclaimHalfMix, RemixAsAlice,
    RemixAsBob, Withdraw,
};

use crate::error::ArgusError;

fn err(e: impl std::fmt::Display) -> String {
    ArgusError::TxBuildFailed(e.to_string()).to_json_string()
}

fn ser_err(e: impl std::fmt::Display) -> String {
    ArgusError::SerializationError(e.to_string()).to_json_string()
}

/// A mixing input in a cached preparation whose proof needs a mix secret.
/// Only a Bob entry has one: the half-mix box it spends.
#[derive(Debug, Clone)]
pub struct MixProofRecipe {
    pub mix_id: u32,
    pub round: u32,
    pub half_box_id: String,
}

/// Derive the DH-tuple secret for each recipe, from the boxes the
/// preparation kept.
pub fn secrets_for(
    handle: &WalletHandle,
    recipes: &[MixProofRecipe],
    boxes: &[ErgoBox],
) -> Result<Vec<SecretKey>, String> {
    recipes
        .iter()
        .map(|r| {
            let b = boxes
                .iter()
                .find(|b| b.box_id().to_string() == r.half_box_id)
                .ok_or_else(|| {
                    ArgusError::SigningFailed(format!(
                        "half-mix box {} is not among the prepared inputs",
                        r.half_box_id
                    ))
                    .to_json_string()
                })?;
            let input = Eip12InputBox::from_ergo_box(b, String::new(), 0);
            let half = HalfMixBox::parse(&input)
                .map_err(|e| ArgusError::SigningFailed(e.to_string()).to_json_string())?;
            let secret = handle
                .mix_secret(r.mix_id, r.round)
                .map_err(|e| ArgusError::SigningFailed(e.to_string()).to_json_string())?;
            Ok(SecretKey::DhtSecretKey(secret.spend_half_mix_as_bob(&half)))
        })
        .collect()
}

pub fn parse_state(json: &str) -> Result<MixState, String> {
    serde_json::from_str(json).map_err(|e| ser_err(format!("mix state: {e}")))
}

pub fn parse_view(json: &str) -> Result<ChainView, String> {
    ChainView::parse(json).map_err(ser_err)
}

pub fn state_json(state: &MixState) -> Result<String, String> {
    serde_json::to_string(state).map_err(ser_err)
}

/// An EIP-12 box as the `ErgoBox` the reducer needs, checked to hash back
/// to the same id so a mangled field cannot slip through.
pub fn to_ergo_box(b: &Eip12InputBox) -> Result<ErgoBox, String> {
    let value: i64 = b
        .value
        .parse()
        .map_err(|_| ser_err(format!("box {} value", b.box_id)))?;
    let assets = b
        .assets
        .iter()
        .map(|a| {
            let amount: u64 = a
                .amount
                .parse()
                .map_err(|_| ser_err(format!("box {} token amount", b.box_id)))?;
            Ok(serde_json::json!({ "tokenId": a.token_id, "amount": amount }))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let node = serde_json::json!({
        "boxId": b.box_id,
        "transactionId": b.transaction_id,
        "index": b.index,
        "value": value,
        "ergoTree": b.ergo_tree,
        "creationHeight": b.creation_height,
        "assets": assets,
        "additionalRegisters": b.additional_registers,
    });
    let parsed: ErgoBox =
        serde_json::from_value(node).map_err(|e| ser_err(format!("box {}: {e}", b.box_id)))?;
    if parsed.box_id().to_string() != b.box_id {
        return Err(err(format!(
            "box {} did not round-trip to the same id",
            b.box_id
        )));
    }
    Ok(parsed)
}

/// What the pool offers right now: rings with waiting counts, the token
/// levels for sale, and whether the operator's boxes are there.
pub fn rings_json(view: &ChainView) -> serde_json::Value {
    let inputs: Vec<Eip12InputBox> = view.half.iter().map(|h| h.input.clone()).collect();
    let rings = discover_rings(&inputs);
    let token = view.token_box();
    let levels: Vec<serde_json::Value> = token
        .map(|t| {
            t.levels()
                .into_iter()
                .filter_map(|l| {
                    t.batch_price(l)
                        .ok()
                        .map(|p| serde_json::json!({ "level": l, "price_nano_erg": p }))
                })
                .collect()
        })
        .unwrap_or_default();
    serde_json::json!({
        "rings": rings,
        "token_levels": levels,
        "token_rate": token.map(|t| t.rate),
        "tokens_available": token.map(|t| t.tokens_available),
        "fee_box_available": view.fee_box().is_some(),
        "fee_box_max_fee": view.fee_box().map(|f| f.max_fee),
        "token_box_available": token.is_some(),
        "height": view.height,
        "unreadable_boxes": view.unreadable,
    })
}

/// What a funding box must hold to enter `denomination` at `level`.
pub fn funding_requirement(
    view: &ChainView,
    denomination: i64,
    level: i32,
    miner_fee: i64,
) -> Result<serde_json::Value, String> {
    let token = view
        .token_box()
        .ok_or_else(|| err("no token emission box: the mixer operator has none for sale"))?;
    let fee = operator_fee(token, denomination, level).map_err(err)?;
    let needed = denomination
        .checked_add(fee.total())
        .and_then(|v| v.checked_add(miner_fee))
        .ok_or_else(|| err("funding amount overflows"))?;
    Ok(serde_json::json!({
        "denomination": denomination,
        "level": level,
        "operator_fee_nano": fee.total(),
        "miner_fee_nano": miner_fee,
        "needed_nano_erg": needed,
    }))
}

/// Where a round's secret comes from: the unlocked handle in the
/// foreground, a stored mix key in the background.
pub type SecretFor<'a> = dyn Fn(u32) -> Result<zerojoin::MixSecret, String> + 'a;

/// A provider backed by the unlocked wallet.
pub fn handle_secrets<'a>(
    handle: &'a WalletHandle,
    mix_id: u32,
) -> impl Fn(u32) -> Result<zerojoin::MixSecret, String> + 'a {
    move |round| handle.mix_secret(mix_id, round).map_err(err)
}

/// A provider backed by an exported mix key.
pub fn key_secrets<'a>(
    key: &'a zerojoin::MixKey,
) -> impl Fn(u32) -> Result<zerojoin::MixSecret, String> + 'a {
    move |round| key.round_secret(round).map_err(err)
}

/// Parse a hex mix key exported by `mix_export_key`.
pub fn parse_key(hex_key: &str, mix_id: u32) -> Result<zerojoin::MixKey, String> {
    // The decoded secret is wiped when this scope ends; the caller's hex
    // string is theirs to clear.
    let bytes = zeroize::Zeroizing::new(
        hex::decode(hex_key.trim()).map_err(|e| ser_err(format!("mix key: {e}")))?,
    );
    zerojoin::MixKey::from_bytes(&bytes, mix_id).map_err(ser_err)
}

/// One built move, with everything the caller needs to reduce and sign it.
pub struct BuiltMove {
    pub tx: MixTx,
    pub applied: Applied,
    /// Every input box, in the transaction's input order.
    pub inputs: Vec<Eip12InputBox>,
    /// Proofs to re-derive when signing happens later (entries only).
    pub recipes: Vec<MixProofRecipe>,
}

fn pair_order() -> PairOrder {
    // Which output is Bob's must not follow from anything public.
    PairOrder::from_bit(rand::random::<bool>())
}

/// Ids of the transaction's outputs, known before signing because an Ergo
/// transaction id covers no proofs.
fn outputs_of(tx: &MixTx) -> Result<Vec<Eip12InputBox>, String> {
    ergo_tx::chain::derive_output_boxes(&tx.unsigned_tx)
        .map(|(_, outs)| outs)
        .map_err(err)
}

/// Among the two full-mix outputs, the one this secret spends as Bob.
fn own_full_output(tx: &MixTx, secret: &zerojoin::MixSecret) -> Result<String, String> {
    outputs_of(tx)?
        .iter()
        .take(2)
        .filter_map(|o| zerojoin::FullMixBox::parse(o).ok())
        .find(|f| secret.owns_as_bob(f))
        .map(|f| f.input.box_id)
        .ok_or_else(|| err("neither full-mix output belongs to this secret"))
}

fn inputs_in_order(tx: &MixTx, pool: &[&Eip12InputBox]) -> Result<Vec<Eip12InputBox>, String> {
    tx.unsigned_tx
        .inputs
        .iter()
        .map(|i| {
            pool.iter()
                .find(|b| b.box_id == i.box_id)
                .map(|b| (*b).clone())
                .ok_or_else(|| err(format!("input {} is not in the snapshot", i.box_id)))
        })
        .collect()
}

/// Build the entry transaction for a pending mix from `funding`.
pub fn build_entry(
    secret_for: &SecretFor<'_>,
    state: &MixState,
    view: &ChainView,
    funding: &Eip12InputBox,
    own_half_ids: &[String],
    miner_fee: i64,
    height: i32,
) -> Result<BuiltMove, String> {
    if state.phase != MixPhase::Pending {
        return Err(err("this mix has already entered the pool"));
    }
    let token_box = view
        .token_box()
        .ok_or_else(|| err("no token emission box: the mixer operator has none for sale"))?;
    let secret = secret_for(state.round)?;
    match plan(state, view, own_half_ids) {
        Plan::EnterAsAlice => {
            let tx = build_alice_entry(&AliceEntry {
                funding,
                token_box,
                x: &secret,
                denomination: state.ring.value,
                level: state.level,
                ring_token: state.ring.ring_token(),
                miner_fee,
                height,
            })
            .map_err(err)?;
            let half_box_id = outputs_of(&tx)?
                .first()
                .map(|o| o.box_id.clone())
                .ok_or_else(|| err("entry has no outputs"))?;
            let inputs = inputs_in_order(&tx, &[funding, &token_box.input])?;
            Ok(BuiltMove {
                tx,
                applied: Applied::EnteredAsAlice { half_box_id },
                inputs,
                recipes: Vec::new(),
            })
        }
        Plan::EnterAsBob { half_box_id } => {
            let half = view
                .half_by_id(&half_box_id)
                .ok_or_else(|| err("the half-mix box to join is not in the snapshot"))?;
            let tx = build_bob_entry(&BobEntry {
                half,
                funding,
                token_box,
                y: &secret,
                level: state.level,
                order: pair_order(),
                miner_fee,
                height,
            })
            .map_err(err)?;
            let full_box_id = own_full_output(&tx, &secret)?;
            let inputs = inputs_in_order(&tx, &[&half.input, funding, &token_box.input])?;
            Ok(BuiltMove {
                tx,
                applied: Applied::EnteredAsBob { full_box_id },
                inputs,
                recipes: vec![MixProofRecipe {
                    mix_id: state.mix_id,
                    round: state.round,
                    half_box_id,
                }],
            })
        }
        Plan::Wait { reason } => Err(err(format!("cannot enter yet: {reason:?}"))),
        other => Err(err(format!("not an entry: {other:?}"))),
    }
}

/// Build the next move for a mix already in the pool, or `None` when the
/// plan is to wait.
pub fn build_move(
    secret_for: &SecretFor<'_>,
    state: &MixState,
    view: &ChainView,
    own_half_ids: &[String],
    miner_fee: i64,
    height: i32,
) -> Result<Option<BuiltMove>, String> {
    let next = plan(state, view, own_half_ids);
    let MixPhase::FullOwned { box_id, .. } = &state.phase else {
        return match next {
            Plan::Wait { .. } => Ok(None),
            Plan::EnterAsAlice | Plan::EnterAsBob { .. } => {
                Err(err("a pending mix enters through mix_prepare_entry"))
            }
            other => Err(err(format!("unexpected plan {other:?} for this phase"))),
        };
    };
    let full = view
        .full_by_id(box_id)
        .ok_or_else(|| err("our full-mix box is not in the snapshot"))?;
    let fee_box = view
        .fee_box()
        .ok_or_else(|| err("no fee emission box to pay the miner from"))?;
    let current = secret_for(state.round)?;
    match next {
        Plan::Wait { .. } => Ok(None),
        Plan::RemixAsBob { half_box_id } => {
            let half = view
                .half_by_id(&half_box_id)
                .ok_or_else(|| err("the half-mix box to join is not in the snapshot"))?;
            let next_y = secret_for(state.round + 1)?;
            let tx = build_remix_as_bob(&RemixAsBob {
                half,
                full,
                current: &current,
                next_y: &next_y,
                fee_box,
                order: pair_order(),
                miner_fee,
                height,
            })
            .map_err(err)?;
            let full_box_id = own_full_output(&tx, &next_y)?;
            let inputs = inputs_in_order(&tx, &[&half.input, &full.input, &fee_box.input])?;
            Ok(Some(BuiltMove {
                tx,
                applied: Applied::RemixedAsBob { full_box_id },
                inputs,
                recipes: Vec::new(),
            }))
        }
        Plan::RemixAsAlice => {
            let next_x = secret_for(state.round + 1)?;
            let tx = build_remix_as_alice(&RemixAsAlice {
                full,
                current: &current,
                next_x: &next_x,
                fee_box,
                miner_fee,
                height,
            })
            .map_err(err)?;
            let half_box_id = outputs_of(&tx)?
                .first()
                .map(|o| o.box_id.clone())
                .ok_or_else(|| err("remix has no outputs"))?;
            let inputs = inputs_in_order(&tx, &[&full.input, &fee_box.input])?;
            Ok(Some(BuiltMove {
                tx,
                applied: Applied::RemixedAsAlice { half_box_id },
                inputs,
                recipes: Vec::new(),
            }))
        }
        Plan::Withdraw { .. } => withdraw(
            state,
            full,
            fee_box,
            &current,
            &state.destination_ergo_tree,
            miner_fee,
            height,
        )
        .map(Some),
        other => Err(err(format!("unexpected plan {other:?} for an owned box"))),
    }
}

fn withdraw(
    _state: &MixState,
    full: &zerojoin::FullMixBox,
    fee_box: &zerojoin::FeeEmissionBox,
    current: &zerojoin::MixSecret,
    destination_ergo_tree: &str,
    miner_fee: i64,
    height: i32,
) -> Result<BuiltMove, String> {
    if destination_ergo_tree.is_empty() {
        return Err(err(
            "this mix has no destination yet; choose where it should go",
        ));
    }
    let tx = build_withdraw(&Withdraw {
        full,
        current,
        fee_box,
        destination_ergo_tree,
        miner_fee,
        height,
    })
    .map_err(err)?;
    let inputs = inputs_in_order(&tx, &[&full.input, &fee_box.input])?;
    Ok(BuiltMove {
        tx,
        applied: Applied::Withdrawn,
        inputs,
        recipes: Vec::new(),
    })
}

/// Take the money out now, whatever the round count: withdraw a full-mix
/// box, or reclaim a half-mix box nobody joined.
pub fn build_leave(
    secret_for: &SecretFor<'_>,
    state: &MixState,
    view: &ChainView,
    destination_ergo_tree: &str,
    miner_fee: i64,
    height: i32,
) -> Result<BuiltMove, String> {
    let current = secret_for(state.round)?;
    match &state.phase {
        MixPhase::FullOwned { box_id, .. } => {
            let full = view
                .full_by_id(box_id)
                .ok_or_else(|| err("our full-mix box is not in the snapshot"))?;
            let fee_box = view
                .fee_box()
                .ok_or_else(|| err("no fee emission box to pay the miner from"))?;
            withdraw(
                state,
                full,
                fee_box,
                &current,
                destination_ergo_tree,
                miner_fee,
                height,
            )
        }
        MixPhase::HalfPosted { box_id } => {
            if destination_ergo_tree.is_empty() {
                return Err(err("choose where the money should go"));
            }
            let half = view
                .half_by_id(box_id)
                .ok_or_else(|| err("our half-mix box is not in the snapshot"))?;
            let tx = build_reclaim_half_mix(&ReclaimHalfMix {
                half,
                x: &current,
                destination_ergo_tree,
                miner_fee,
                height,
            })
            .map_err(err)?;
            let inputs = inputs_in_order(&tx, &[&half.input])?;
            Ok(BuiltMove {
                tx,
                applied: Applied::Reclaimed,
                inputs,
                recipes: Vec::new(),
            })
        }
        MixPhase::Pending => Err(err(
            "this mix has not entered the pool; nothing to take out",
        )),
        _ => Err(err("this mix is already finished")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wallet_core::seed::MnemonicPhrase;
    use wallet_core::WalletHandle;
    use zerojoin::{MixPhase, Plan, RingSpec};

    const APPKIT: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";
    const HALF: &str =
        include_str!("../../vendor/protocols/zerojoin/test/fixtures/half_mix_boxes.json");
    const FEE: &str =
        include_str!("../../vendor/protocols/zerojoin/test/fixtures/fee_emission_boxes.json");
    const TOKEN: &str =
        include_str!("../../vendor/protocols/zerojoin/test/fixtures/token_emission_boxes.json");
    const MINER_FEE: i64 = 1_500_000;
    const HEIGHT: i32 = 1_500_000;
    const DEST: &str = "0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582";

    fn handle() -> WalletHandle {
        WalletHandle::create(MnemonicPhrase::parse(APPKIT).unwrap(), "").unwrap()
    }

    fn view(half: &str, full: Vec<Eip12InputBox>) -> ChainView {
        let json = serde_json::json!({
            "half_boxes": serde_json::from_str::<serde_json::Value>(half).unwrap(),
            "full_boxes": full,
            "fee_boxes": serde_json::from_str::<serde_json::Value>(FEE).unwrap(),
            "token_boxes": serde_json::from_str::<serde_json::Value>(TOKEN).unwrap(),
            "height": HEIGHT,
        });
        ChainView::parse(&json.to_string()).unwrap()
    }

    fn funding(value: i64) -> Eip12InputBox {
        Eip12InputBox {
            box_id: "11".repeat(32),
            transaction_id: "22".repeat(32),
            index: 0,
            value: value.to_string(),
            ergo_tree: DEST.into(),
            assets: vec![],
            creation_height: 1_000_000,
            additional_registers: Default::default(),
            extension: Default::default(),
        }
    }

    /// Enter as Bob against a real fixture half box, then own the box the
    /// entry created, remix out of it, and withdraw: the ids the builders
    /// derive before signing must be the ids the next step finds.
    #[test]
    fn ids_thread_from_entry_through_remix_to_withdrawal() {
        let h = handle();
        let v = view(HALF, vec![]);
        // Pick the ERG ring the fixture's first half box is in.
        let target = v
            .half
            .iter()
            .find(|b| b.mixing_token.is_none())
            .expect("an ERG half box");
        let ring = RingSpec::erg(target.value);
        let level = v.token_box().unwrap().levels()[0];
        let need = funding_requirement(&v, ring.value, level, MINER_FEE).unwrap();
        let fund = funding(need["needed_nano_erg"].as_i64().unwrap());
        let state = MixState::new(0, ring.clone(), level, 2, DEST.into(), 1);

        let entry = build_entry(
            &handle_secrets(&h, 0),
            &state,
            &v,
            &fund,
            &[],
            MINER_FEE,
            HEIGHT,
        )
        .expect("Bob entry");
        let Applied::EnteredAsBob { full_box_id } = &entry.applied else {
            panic!(
                "a waiting half box means a Bob entry, got {:?}",
                entry.applied
            );
        };
        assert_eq!(
            entry.recipes.len(),
            1,
            "the half box needs a DH-tuple proof at signing"
        );
        assert_eq!(
            entry
                .inputs
                .iter()
                .map(|b| b.box_id.as_str())
                .collect::<Vec<_>>(),
            entry
                .tx
                .unsigned_tx
                .inputs
                .iter()
                .map(|i| i.box_id.as_str())
                .collect::<Vec<_>>(),
            "boxes are handed to the reducer in input order"
        );
        // The recipe derives the same secret the builder used.
        let ergo = entry
            .inputs
            .iter()
            .map(to_ergo_box)
            .collect::<Result<Vec<_>, _>>();
        assert!(
            ergo.is_err(),
            "the fake funding box cannot round-trip; real ones do"
        );
        let half_ergo = to_ergo_box(&entry.inputs[0]).expect("fixture half box round-trips");
        assert_eq!(
            secrets_for(&h, &entry.recipes, &[half_ergo]).unwrap().len(),
            1
        );

        let state = state.after(entry.applied.clone(), "tx1", 2);
        assert_eq!(state.rounds_done, 1);

        // Our full box is among the entry's outputs; feed it back as the chain.
        let outs = outputs_of(&entry.tx).unwrap();
        let ours = outs
            .iter()
            .find(|o| o.box_id == *full_box_id)
            .unwrap()
            .clone();
        let alone = view("[]", vec![ours.clone()]);
        assert_eq!(plan(&state, &alone, &[]), Plan::RemixAsAlice);
        let remix = build_move(
            &handle_secrets(&h, 0),
            &state,
            &alone,
            &[],
            MINER_FEE,
            HEIGHT,
        )
        .unwrap()
        .expect("a move, not a wait");
        let Applied::RemixedAsAlice { half_box_id } = &remix.applied else {
            panic!("expected a remix as Alice, got {:?}", remix.applied);
        };
        assert_eq!(remix.inputs[0].box_id, ours.box_id);
        let state = state.after(remix.applied.clone(), "tx2", 3);
        assert_eq!((state.round, state.rounds_done), (1, 1));

        // Someone joins our half box (simulate with a stranger's Bob entry
        // shape is not needed: observe only needs a full box carrying gX).
        let half_out = outputs_of(&remix.tx)
            .unwrap()
            .into_iter()
            .find(|o| o.box_id == *half_box_id)
            .unwrap();
        assert!(zerojoin::HalfMixBox::parse(&half_out).is_ok());
        let waiting = view(&serde_json::json!([half_out]).to_string(), vec![]);
        assert_eq!(
            plan(&state, &waiting, &[]),
            Plan::Wait {
                reason: zerojoin::WaitReason::CounterpartNeeded
            }
        );
        assert!(build_move(
            &handle_secrets(&h, 0),
            &state,
            &waiting,
            &[],
            MINER_FEE,
            HEIGHT
        )
        .unwrap()
        .is_none());

        // Leaving early reclaims the half box to the destination.
        let leave = build_leave(
            &handle_secrets(&h, 0),
            &state,
            &waiting,
            DEST,
            MINER_FEE,
            HEIGHT,
        )
        .unwrap();
        assert_eq!(leave.applied, Applied::Reclaimed);
        assert!(leave.tx.summary.action.contains("reclaim"));

        // And a mix that has done its rounds withdraws from its full box.
        let done = MixState {
            rounds_target: 1,
            ..state.clone()
        };
        let done = MixState {
            round: 0,
            phase: MixPhase::FullOwned {
                box_id: ours.box_id.clone(),
                role: zerojoin::Role::Bob,
            },
            ..done
        };
        let out = build_move(
            &handle_secrets(&h, 0),
            &done,
            &alone,
            &[],
            MINER_FEE,
            HEIGHT,
        )
        .unwrap()
        .unwrap();
        assert_eq!(out.applied, Applied::Withdrawn);
        assert_eq!(out.tx.unsigned_tx.outputs[0].ergo_tree, DEST);
    }

    #[test]
    fn a_stored_mix_key_builds_the_same_moves_as_the_unlocked_wallet() {
        let h = handle();
        let exported = hex::encode(&h.mix_key(0).unwrap().to_bytes().unwrap()[..]);
        let key = parse_key(&exported, 0).unwrap();
        let v = view("[]", vec![]);
        let level = v.token_box().unwrap().levels()[0];
        let need = funding_requirement(&v, 1_000_000_000, level, MINER_FEE).unwrap();
        let fund = funding(need["needed_nano_erg"].as_i64().unwrap());
        let state = MixState::new(0, RingSpec::erg(1_000_000_000), level, 2, DEST.into(), 1);
        let a = build_entry(
            &handle_secrets(&h, 0),
            &state,
            &v,
            &fund,
            &[],
            MINER_FEE,
            HEIGHT,
        )
        .unwrap();
        let b = build_entry(
            &key_secrets(&key),
            &state,
            &v,
            &fund,
            &[],
            MINER_FEE,
            HEIGHT,
        )
        .unwrap();
        assert_eq!(a.applied, b.applied, "same gX, same half box id");
        assert!(parse_key("zz", 0).is_err());
    }

    #[test]
    fn entering_as_alice_when_nobody_waits_and_refusing_a_second_entry() {
        let h = handle();
        let v = view("[]", vec![]);
        let level = v.token_box().unwrap().levels()[0];
        let need = funding_requirement(&v, 1_000_000_000, level, MINER_FEE).unwrap();
        let fund = funding(need["needed_nano_erg"].as_i64().unwrap());
        let state = MixState::new(0, RingSpec::erg(1_000_000_000), level, 2, DEST.into(), 1);
        let entry = build_entry(
            &handle_secrets(&h, 0),
            &state,
            &v,
            &fund,
            &[],
            MINER_FEE,
            HEIGHT,
        )
        .unwrap();
        assert!(matches!(entry.applied, Applied::EnteredAsAlice { .. }));
        assert!(
            entry.recipes.is_empty(),
            "Alice signs with a wallet key only"
        );
        let entered = state.after(entry.applied, "tx", 2);
        assert!(build_entry(
            &handle_secrets(&h, 0),
            &entered,
            &v,
            &fund,
            &[],
            MINER_FEE,
            HEIGHT
        )
        .is_err());
        assert!(
            build_move(&handle_secrets(&h, 0), &entered, &v, &[], MINER_FEE, HEIGHT)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn node_shaped_box_round_trips_to_an_ergo_box() {
        // A real mainnet box: the reducer needs exactly this conversion.
        let json = r#"[{"boxId":"7e38e4bf4c1ba7a2f7e0bd2c4ad0d5a9a3e6b2e4b0b9b6a5c1d2e3f4a5b6c7d8","value":1000000000,"ergoTree":"0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582","assets":[],"creationHeight":1000000,"additionalRegisters":{},"transactionId":"0000000000000000000000000000000000000000000000000000000000000000","index":0}]"#;
        let boxes = zerojoin::parse_explorer_boxes(json).unwrap();
        // The id above is made up, so the round trip must catch it.
        assert!(to_ergo_box(&boxes[0]).is_err());
    }
}
