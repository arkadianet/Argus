//! The per-mix state machine.
//!
//! A mix is one box's worth of money moving through rounds until it has
//! done as many as the user asked for, then leaving for a destination fixed
//! at the start. Everything here is a pure function of a persisted
//! [`MixState`] and a [`ChainView`] snapshot: no network, no clock, no
//! secrets beyond the one public key a step needs. The wallet layer feeds
//! it snapshots, applies the [`Plan`] it returns, and records the result
//! with [`MixState::after`].
//!
//! Secrets are never in the state. Round `r` of mix `m` is re-derived from
//! the seed at `m/44'/429'/0'/4'/m/r` whenever a proof or a public key is
//! needed, and [`recover`] rebuilds the state of every live mix from the
//! seed and the chain alone.

use serde::{Deserialize, Serialize};

use crate::boxes::{
    parse_explorer_boxes, FeeEmissionBox, FullMixBox, HalfMixBox, TokenEmissionBox,
};
use crate::contracts::{
    is_fee_emission_tree, is_full_mix_tree, is_half_mix_tree, is_token_emission_tree,
};
use crate::error::ZeroJoinError;
use crate::round::{enter_as_bob_tokens, remix_as_alice_tokens, remix_as_bob_tokens};
use crate::secret::{MixSecret, Role};

/// The denomination a mix moves in: nanoERG per box, plus the token and
/// amount for a token ring.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RingSpec {
    pub value: i64,
    pub token_id: Option<String>,
    pub token_amount: Option<i64>,
}

impl RingSpec {
    pub fn erg(value: i64) -> Self {
        RingSpec {
            value,
            token_id: None,
            token_amount: None,
        }
    }

    /// `(token id, amount per box)` in the shape the builders take.
    pub fn ring_token(&self) -> Option<(String, i64)> {
        match (&self.token_id, self.token_amount) {
            (Some(id), Some(amount)) => Some((id.clone(), amount)),
            _ => None,
        }
    }

    pub fn matches_half(&self, half: &HalfMixBox) -> bool {
        half.value == self.value && half.mixing_token == self.ring_token()
    }

    pub fn matches_full(&self, full: &FullMixBox) -> bool {
        full.value == self.value && full.mixing_token == self.ring_token()
    }

    fn of_half(half: &HalfMixBox) -> Self {
        RingSpec {
            value: half.value,
            token_id: half.mixing_token.as_ref().map(|(id, _)| id.clone()),
            token_amount: half.mixing_token.as_ref().map(|(_, a)| *a),
        }
    }

    fn of_full(full: &FullMixBox) -> Self {
        RingSpec {
            value: full.value,
            token_id: full.mixing_token.as_ref().map(|(id, _)| id.clone()),
            token_amount: full.mixing_token.as_ref().map(|(_, a)| *a),
        }
    }
}

/// Where the mix's money is right now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MixPhase {
    /// Created in the wallet; the entry transaction has not been broadcast.
    Pending,
    /// We are Alice: our half-mix box is waiting for a Bob.
    HalfPosted { box_id: String },
    /// A full-mix box of ours, spendable into the next round or out.
    FullOwned { box_id: String, role: Role },
    /// Left the pool for the destination.
    Withdrawn { tx_id: String },
    /// A half-mix box nobody joined, taken back to the destination.
    Reclaimed { tx_id: String },
}

impl MixPhase {
    /// The mix's box on chain, when it has one.
    pub fn box_id(&self) -> Option<&str> {
        match self {
            MixPhase::HalfPosted { box_id } | MixPhase::FullOwned { box_id, .. } => Some(box_id),
            _ => None,
        }
    }

    /// True once the money has left the pool, one way or the other.
    pub fn is_finished(&self) -> bool {
        matches!(
            self,
            MixPhase::Withdrawn { .. } | MixPhase::Reclaimed { .. }
        )
    }
}

/// One thing that happened to a mix, for the screen's history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MixEvent {
    pub at: i64,
    pub action: String,
    pub round: u32,
    pub tx_id: Option<String>,
}

/// Where the mix stood before its latest broadcast move, kept until the
/// move's box is seen on chain. A move whose transaction never confirms
/// (the counterpart reclaimed first, the node dropped it, the fee box
/// copy was taken) leaves the old box ours and unspent; after
/// [`LOST_MOVE_GRACE_SECS`] with the new box unseen and the old one still
/// unspent, [`observe`] rolls the state back here so the next plan
/// rebuilds the move.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviousStep {
    pub phase: MixPhase,
    pub round: u32,
    pub rounds_done: u32,
    /// When the move was broadcast.
    pub at: i64,
}

/// How long a broadcast move may stay unseen before it counts as lost:
/// long enough for a mempool transaction to confirm or be dropped.
/// Rolling back sooner would double-spend our own box while the move is
/// still in the mempool.
pub const LOST_MOVE_GRACE_SECS: i64 = 30 * 60;

/// Everything the wallet persists about one mix. No secrets: see the
/// module documentation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MixState {
    /// Index on the seed's mix branch; unique per wallet, never reused.
    pub mix_id: u32,
    pub ring: RingSpec,
    /// Mixing tokens bought at entry.
    pub level: i32,
    pub rounds_target: u32,
    pub rounds_done: u32,
    /// Secret index of the box in `phase`. Every box the mix creates after
    /// the entry increments it.
    pub round: u32,
    pub phase: MixPhase,
    /// ErgoTree the money goes to when the mix ends. Empty after a
    /// recovery, until the user picks one.
    pub destination_ergo_tree: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub events: Vec<MixEvent>,
    /// The step before the latest broadcast move, until its box is seen.
    #[serde(default)]
    pub previous: Option<PreviousStep>,
}

impl MixState {
    pub fn new(
        mix_id: u32,
        ring: RingSpec,
        level: i32,
        rounds_target: u32,
        destination_ergo_tree: String,
        now: i64,
    ) -> Self {
        MixState {
            mix_id,
            ring,
            level,
            rounds_target: rounds_target.max(1),
            rounds_done: 0,
            round: 0,
            phase: MixPhase::Pending,
            destination_ergo_tree,
            created_at: now,
            updated_at: now,
            events: Vec::new(),
            previous: None,
        }
    }

    /// nanoERG locked in the pool for this mix, for the "in mix" pocket.
    pub fn locked_value(&self) -> i64 {
        match self.phase {
            MixPhase::HalfPosted { .. } | MixPhase::FullOwned { .. } => self.ring.value,
            _ => 0,
        }
    }

    /// Record a transaction of ours and move to the phase it creates.
    pub fn after(mut self, applied: Applied, tx_id: &str, now: i64) -> Self {
        let action = applied.name();
        let before = PreviousStep {
            phase: self.phase.clone(),
            round: self.round,
            rounds_done: self.rounds_done,
            at: now,
        };
        // A move out of the pool has no box to wait for, and an entry has
        // no box to fall back to; a move within the pool keeps the box it
        // spent until the new one is seen.
        self.previous = match applied {
            Applied::Withdrawn | Applied::Reclaimed => None,
            _ if before.phase.box_id().is_none() => None,
            _ => Some(before),
        };
        match applied {
            Applied::EnteredAsAlice { half_box_id } => {
                self.phase = MixPhase::HalfPosted {
                    box_id: half_box_id,
                };
            }
            Applied::EnteredAsBob { full_box_id } => {
                self.phase = MixPhase::FullOwned {
                    box_id: full_box_id,
                    role: Role::Bob,
                };
                self.rounds_done += 1;
            }
            Applied::RemixedAsBob { full_box_id } => {
                self.round += 1;
                self.phase = MixPhase::FullOwned {
                    box_id: full_box_id,
                    role: Role::Bob,
                };
                self.rounds_done += 1;
            }
            Applied::RemixedAsAlice { half_box_id } => {
                self.round += 1;
                self.phase = MixPhase::HalfPosted {
                    box_id: half_box_id,
                };
            }
            Applied::Withdrawn => {
                self.phase = MixPhase::Withdrawn {
                    tx_id: tx_id.to_string(),
                };
            }
            Applied::Reclaimed => {
                self.phase = MixPhase::Reclaimed {
                    tx_id: tx_id.to_string(),
                };
            }
        }
        self.updated_at = now;
        self.events.push(MixEvent {
            at: now,
            action: action.to_string(),
            round: self.round,
            tx_id: Some(tx_id.to_string()),
        });
        self
    }

    /// Undo the latest move: back to the box it spent, which is still ours.
    fn rolled_back(mut self, now: i64) -> Self {
        let Some(prev) = self.previous.take() else {
            return self;
        };
        self.phase = prev.phase;
        self.round = prev.round;
        self.rounds_done = prev.rounds_done;
        self.updated_at = now;
        self.events.push(MixEvent {
            at: now,
            action: "rolled_back".to_string(),
            round: self.round,
            tx_id: None,
        });
        self
    }

    /// Someone spent our half-mix box as Bob: the full-mix box holding our
    /// `gX` is now ours as Alice, and a round is done.
    pub fn joined_as_alice(mut self, full_box_id: String, now: i64) -> Self {
        self.phase = MixPhase::FullOwned {
            box_id: full_box_id,
            role: Role::Alice,
        };
        self.previous = None;
        self.rounds_done += 1;
        self.updated_at = now;
        self.events.push(MixEvent {
            at: now,
            action: "joined".to_string(),
            round: self.round,
            tx_id: None,
        });
        self
    }
}

/// A transaction of ours that was broadcast.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Applied {
    EnteredAsAlice { half_box_id: String },
    EnteredAsBob { full_box_id: String },
    RemixedAsBob { full_box_id: String },
    RemixedAsAlice { half_box_id: String },
    Withdrawn,
    Reclaimed,
}

impl Applied {
    fn name(&self) -> &'static str {
        match self {
            Applied::EnteredAsAlice { .. } => "entered_as_alice",
            Applied::EnteredAsBob { .. } => "entered_as_bob",
            Applied::RemixedAsBob { .. } => "remixed_as_bob",
            Applied::RemixedAsAlice { .. } => "remixed_as_alice",
            Applied::Withdrawn => "withdrawn",
            Applied::Reclaimed => "reclaimed",
        }
    }
}

/// A snapshot of the parts of the chain a step needs.
///
/// `half` is every unspent half-mix box the caller fetched (at least the
/// mix's ring). `full` holds the full-mix boxes the caller could find for
/// this wallet: its own by id, and the outputs of whatever spent its half
/// box. `fee` and `token` are the operator's emission boxes.
#[derive(Debug, Default)]
pub struct ChainView {
    pub half: Vec<HalfMixBox>,
    pub full: Vec<FullMixBox>,
    pub fee: Vec<FeeEmissionBox>,
    pub token: Vec<TokenEmissionBox>,
    pub height: i32,
    /// Boxes under a mixing script the parser could not read. Counted so a
    /// caller can tell "nothing there" from "could not read it".
    pub unreadable: usize,
}

impl ChainView {
    /// Parse `{"half_boxes": [...], "full_boxes": [...], "fee_boxes": [...],
    /// "token_boxes": [...], "height": n}`, each list in explorer or node
    /// box shape. A box under the wrong script for its list is ignored, as
    /// is one the parser rejects: a stranger's malformed box must not stop
    /// everyone else's mix.
    pub fn parse(json: &str) -> Result<Self, ZeroJoinError> {
        let v: serde_json::Value = serde_json::from_str(json)
            .map_err(|e| ZeroJoinError::Serialization(format!("chain view: {e}")))?;
        let height = v
            .get("height")
            .and_then(|h| h.as_i64())
            .and_then(|h| i32::try_from(h).ok())
            .filter(|h| *h > 0)
            .ok_or_else(|| ZeroJoinError::Serialization("chain view is missing height".into()))?;
        let list = |key: &str| -> Result<Vec<ergo_tx::Eip12InputBox>, ZeroJoinError> {
            match v.get(key) {
                None | Some(serde_json::Value::Null) => Ok(Vec::new()),
                Some(items) => parse_explorer_boxes(&items.to_string())
                    .map_err(|e| ZeroJoinError::Serialization(format!("{key}: {e}"))),
            }
        };
        let mut view = ChainView {
            height,
            ..Default::default()
        };
        let mut seen = std::collections::BTreeSet::new();
        for b in list("half_boxes")? {
            if !is_half_mix_tree(&b.ergo_tree) || !seen.insert(b.box_id.clone()) {
                continue;
            }
            match HalfMixBox::parse(&b) {
                Ok(h) => view.half.push(h),
                Err(_) => view.unreadable += 1,
            }
        }
        for b in list("full_boxes")? {
            if !is_full_mix_tree(&b.ergo_tree) || !seen.insert(b.box_id.clone()) {
                continue;
            }
            match FullMixBox::parse(&b) {
                Ok(f) => view.full.push(f),
                Err(_) => view.unreadable += 1,
            }
        }
        for b in list("fee_boxes")? {
            if !is_fee_emission_tree(&b.ergo_tree) || !seen.insert(b.box_id.clone()) {
                continue;
            }
            match FeeEmissionBox::parse(&b) {
                Ok(f) => view.fee.push(f),
                Err(_) => view.unreadable += 1,
            }
        }
        for b in list("token_boxes")? {
            if !is_token_emission_tree(&b.ergo_tree) || !seen.insert(b.box_id.clone()) {
                continue;
            }
            match TokenEmissionBox::parse(&b) {
                Ok(t) => view.token.push(t),
                Err(_) => view.unreadable += 1,
            }
        }
        Ok(view)
    }

    /// The fee emission box to pay `fee` from: among those whose `maxFee`
    /// allows it and that hold more than it, the one with the most ERG
    /// left, as the fullest is least likely to be contended. A box with a
    /// tiny `maxFee` (anyone may post one under the script) never stalls
    /// a remix this way.
    pub fn fee_box_for(&self, fee: i64) -> Option<&FeeEmissionBox> {
        self.fee
            .iter()
            .filter(|f| f.max_fee >= fee && f.value > fee)
            .max_by_key(|f| f.value)
    }

    /// A fee emission box that can pay the minimum miner fee.
    pub fn fee_box(&self) -> Option<&FeeEmissionBox> {
        self.fee_box_for(crate::tx_builder::MIN_MINER_FEE_NANO)
    }

    /// The token emission box with the most mixing tokens for sale.
    pub fn token_box(&self) -> Option<&TokenEmissionBox> {
        self.token.iter().max_by_key(|t| t.tokens_available)
    }

    /// The token emission box to buy `level` tokens from: the cheapest
    /// batch at that level among boxes with enough tokens, the fullest
    /// on a tie. Anyone may post a box under the emission script with
    /// absurd prices; it is simply never the cheapest.
    pub fn token_box_for(&self, level: i32) -> Option<&TokenEmissionBox> {
        // A level is a count of tokens bought: R4 is attacker-controlled,
        // and a zero or negative "batch" would sell nothing at any price.
        if level < 1 {
            return None;
        }
        self.token
            .iter()
            .filter(|t| t.tokens_available >= level as i64)
            .filter_map(|t| t.batch_price(level).ok().map(|p| (p, t)))
            // A negative "price" is a hostile register, not a bargain: it
            // must not win over an honest box at the same level.
            .filter(|(p, _)| *p >= 0)
            .min_by_key(|(p, t)| (*p, -t.tokens_available))
            .map(|(_, t)| t)
    }

    /// Every level for sale with its lowest price across the boxes.
    pub fn token_levels(&self) -> Vec<(i32, i64)> {
        let mut best: std::collections::BTreeMap<i32, i64> = Default::default();
        for t in &self.token {
            for (l, p) in &t.batches {
                if *l >= 1 && *p >= 0 && t.tokens_available >= *l as i64 {
                    best.entry(*l).and_modify(|b| *b = (*b).min(*p)).or_insert(*p);
                }
            }
        }
        let mut out: Vec<(i32, i64)> = best.into_iter().collect();
        out.sort_by_key(|(l, p)| (*p, *l));
        out
    }

    pub fn half_by_id(&self, id: &str) -> Option<&HalfMixBox> {
        self.half.iter().find(|h| h.input.box_id == id)
    }

    pub fn full_by_id(&self, id: &str) -> Option<&FullMixBox> {
        self.full.iter().find(|f| f.input.box_id == id)
    }

    /// A stranger's half-mix box in `ring` we could join as Bob, or none.
    ///
    /// `own_half_ids` are half boxes this wallet posted; joining one's own
    /// box completes a round that hides nothing. Prefers the box with the
    /// most rounds left in it. `accept` says whether the token accounting
    /// works for a given half-mix level.
    fn counterpart<'a>(
        &'a self,
        ring: &RingSpec,
        own_half_ids: &[String],
        accept: impl Fn(&HalfMixBox) -> bool,
    ) -> Option<&'a HalfMixBox> {
        self.half
            .iter()
            .filter(|h| ring.matches_half(h))
            .filter(|h| !own_half_ids.contains(&h.input.box_id))
            .filter(|h| accept(h))
            .max_by_key(|h| (h.mix_level, h.input.box_id.clone()))
    }
}

/// Why a mix is not moving right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaitReason {
    /// Our half-mix box is on chain and nobody has joined it yet.
    CounterpartNeeded,
    /// No token emission box is available to buy mixing tokens from.
    NoTokenBox,
    /// No fee emission box is available to pay a remix's miner fee.
    NoFeeBox,
    /// The box the state points at is neither unspent nor accounted for in
    /// the snapshot. Usually a stale or partial fetch; never act on it.
    BoxNotSeen,
    /// The mix is over.
    Finished,
}

/// Why a withdrawal is the next move.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WithdrawReason {
    RoundsDone,
    /// The box has no mixing tokens left to pay for another round.
    TokensExhausted,
}

/// The next move for a mix, given a snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Plan {
    Wait { reason: WaitReason },
    EnterAsAlice,
    EnterAsBob { half_box_id: String },
    RemixAsBob { half_box_id: String },
    RemixAsAlice,
    Withdraw { reason: WithdrawReason },
}

/// Fold what the chain shows into the state: a half-mix box of ours that
/// was spent by a Bob becomes a full-mix box of ours. `secret` is the
/// secret of `state.round`. Returns the state unchanged when nothing new
/// is visible.
///
/// Ownership is proved, not inferred from `gX`: both boxes of a round
/// carry our `gX` (and anyone can mint a box that does, since `gX` is
/// public in our half box), so only the box whose `c2 == c1^x` is ours.
pub fn observe(mut state: MixState, view: &ChainView, secret: &MixSecret, now: i64) -> MixState {
    // A broadcast move: confirmed (its box seen), lost (the box it spent
    // still unspent after the grace), or not known yet.
    let seen = |id: &str| view.half_by_id(id).is_some() || view.full_by_id(id).is_some();
    if let (Some(prev), Some(current)) = (&state.previous, state.phase.box_id()) {
        if seen(current) {
            state.previous = None;
        } else if now - prev.at >= LOST_MOVE_GRACE_SECS && prev.phase.box_id().is_some_and(seen) {
            return state.rolled_back(now);
        }
    }
    let MixPhase::HalfPosted { box_id } = &state.phase else {
        return state;
    };
    if view.half_by_id(box_id).is_some() {
        return state;
    }
    let joined = view
        .full
        .iter()
        .find(|f| secret.owns_as_alice(f) && state.ring.matches_full(f));
    match joined {
        Some(full) => {
            let id = full.input.box_id.clone();
            state.joined_as_alice(id, now)
        }
        None => state,
    }
}

/// Decide the next move. Pure: builds nothing, changes nothing.
pub fn plan(state: &MixState, view: &ChainView, own_half_ids: &[String]) -> Plan {
    match &state.phase {
        MixPhase::Pending => {
            if view.token_box().is_none() {
                return Plan::Wait {
                    reason: WaitReason::NoTokenBox,
                };
            }
            let bought = state.level as i64;
            match view.counterpart(&state.ring, own_half_ids, |h| {
                enter_as_bob_tokens(h.mix_level, bought).is_ok()
            }) {
                Some(h) => Plan::EnterAsBob {
                    half_box_id: h.input.box_id.clone(),
                },
                None => Plan::EnterAsAlice,
            }
        }
        MixPhase::HalfPosted { box_id } => Plan::Wait {
            reason: if view.half_by_id(box_id).is_some() {
                WaitReason::CounterpartNeeded
            } else {
                WaitReason::BoxNotSeen
            },
        },
        MixPhase::FullOwned { box_id, .. } => {
            let Some(full) = view.full_by_id(box_id) else {
                return Plan::Wait {
                    reason: WaitReason::BoxNotSeen,
                };
            };
            if view.fee_box().is_none() {
                return Plan::Wait {
                    reason: WaitReason::NoFeeBox,
                };
            }
            if state.rounds_done >= state.rounds_target {
                return Plan::Withdraw {
                    reason: WithdrawReason::RoundsDone,
                };
            }
            if let Some(h) = view.counterpart(&state.ring, own_half_ids, |h| {
                remix_as_bob_tokens(full.mix_level, h.mix_level).is_ok()
            }) {
                return Plan::RemixAsBob {
                    half_box_id: h.input.box_id.clone(),
                };
            }
            if remix_as_alice_tokens(full.mix_level).is_ok() {
                Plan::RemixAsAlice
            } else {
                Plan::Withdraw {
                    reason: WithdrawReason::TokensExhausted,
                }
            }
        }
        MixPhase::Withdrawn { .. } | MixPhase::Reclaimed { .. } => Plan::Wait {
            reason: WaitReason::Finished,
        },
    }
}

/// How many mixes with no box on chain end a recovery scan.
pub const RECOVERY_MIX_GAP: u32 = 5;
/// Rounds tried per mix during recovery. A mix past this many rounds is
/// beyond anything the wallet offers.
pub const RECOVERY_MAX_ROUNDS: u32 = 64;

/// Rebuild the state of every mix that still has a box in `view`, from the
/// seed alone. `secret_for(mix, round)` derives; `view.full` must hold
/// every unspent full-mix box and `view.half` every unspent half-mix box.
///
/// A recovered mix has no destination and a target equal to the rounds it
/// has done, so it presents as ready to withdraw until the user says
/// otherwise. `rounds_done` is an estimate: the round index counts boxes
/// the mix created, and a full box adds the round its creation completed.
pub fn recover(
    view: &ChainView,
    secret_for: impl Fn(u32, u32) -> Option<MixSecret>,
    now: i64,
) -> Vec<MixState> {
    let mut found = Vec::new();
    let mut empty_run = 0;
    let mut mix_id = 0u32;
    while empty_run < RECOVERY_MIX_GAP {
        let mut best: Option<MixState> = None;
        for round in 0..RECOVERY_MAX_ROUNDS {
            let Some(secret) = secret_for(mix_id, round) else {
                break;
            };
            let pk = secret.public_key();
            if let Some(h) = view.half.iter().find(|h| h.g_x == *pk) {
                best = Some(MixState {
                    mix_id,
                    ring: RingSpec::of_half(h),
                    level: h.mix_level as i32,
                    rounds_target: round,
                    rounds_done: round,
                    round,
                    phase: MixPhase::HalfPosted {
                        box_id: h.input.box_id.clone(),
                    },
                    destination_ergo_tree: String::new(),
                    created_at: now,
                    updated_at: now,
                    events: vec![MixEvent {
                        at: now,
                        action: "recovered".into(),
                        round,
                        tx_id: None,
                    }],
                    previous: None,
                });
                continue;
            }
            if let Some((f, role)) = view
                .full
                .iter()
                .find_map(|f| secret.role_for(f).map(|r| (f, r)))
            {
                best = Some(MixState {
                    mix_id,
                    ring: RingSpec::of_full(f),
                    level: f.mix_level as i32,
                    rounds_target: round + 1,
                    rounds_done: round + 1,
                    round,
                    phase: MixPhase::FullOwned {
                        box_id: f.input.box_id.clone(),
                        role,
                    },
                    destination_ergo_tree: String::new(),
                    created_at: now,
                    updated_at: now,
                    events: vec![MixEvent {
                        at: now,
                        action: "recovered".into(),
                        round,
                        tx_id: None,
                    }],
                    previous: None,
                });
            }
        }
        match best {
            Some(s) => {
                found.push(s);
                empty_run = 0;
            }
            None => empty_run += 1,
        }
        mix_id += 1;
    }
    found
}

/// The next unused mix index for a wallet with these mixes.
pub fn next_mix_id(states: &[MixState]) -> u32 {
    states.iter().map(|s| s.mix_id + 1).max().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::round::PairOrder;
    use crate::testing::{
        fixture_fee_box, fixture_token_box, synthetic_half_mix, synthetic_round, test_secret,
    };

    const RING: i64 = 1_000_000_000;
    const NOW: i64 = 1_757_000_000;

    fn half(tag: u8, secret: &MixSecret, level: i64) -> HalfMixBox {
        let mut h = synthetic_half_mix(*secret.public_key(), RING, level);
        h.input.box_id = hex::encode([tag; 32]);
        h
    }

    fn view_with(half: Vec<HalfMixBox>, full: Vec<FullMixBox>) -> ChainView {
        ChainView {
            half,
            full,
            fee: vec![fixture_fee_box()],
            token: vec![fixture_token_box()],
            height: 1_500_000,
            unreadable: 0,
        }
    }

    fn pending(level: i32, rounds: u32) -> MixState {
        MixState::new(
            0,
            RingSpec::erg(RING),
            level,
            rounds,
            "0008cd00".into(),
            NOW,
        )
    }

    #[test]
    fn a_new_mix_enters_as_bob_when_a_stranger_is_waiting() {
        let stranger = test_secret(90, 0);
        let view = view_with(vec![half(1, &stranger, 20)], vec![]);
        assert_eq!(
            plan(&pending(20, 3), &view, &[]),
            Plan::EnterAsBob {
                half_box_id: hex::encode([1u8; 32])
            }
        );
    }

    #[test]
    fn a_new_mix_enters_as_alice_when_the_ring_is_empty_or_only_holds_our_boxes() {
        let stranger = test_secret(90, 0);
        assert_eq!(
            plan(&pending(20, 3), &view_with(vec![], vec![]), &[]),
            Plan::EnterAsAlice
        );
        let ours = hex::encode([1u8; 32]);
        let view = view_with(vec![half(1, &stranger, 20)], vec![]);
        assert_eq!(
            plan(&pending(20, 3), &view, &[ours]),
            Plan::EnterAsAlice,
            "never Bob our own half box"
        );
        // A different denomination is a different ring.
        let mut other = half(2, &stranger, 20);
        other.value = RING * 10;
        assert_eq!(
            plan(&pending(20, 3), &view_with(vec![other], vec![]), &[]),
            Plan::EnterAsAlice
        );
    }

    #[test]
    fn a_new_mix_waits_when_there_is_no_token_box_to_buy_from() {
        let mut view = view_with(vec![], vec![]);
        view.token.clear();
        assert_eq!(
            plan(&pending(20, 3), &view, &[]),
            Plan::Wait {
                reason: WaitReason::NoTokenBox
            }
        );
    }

    #[test]
    fn a_posted_half_box_waits_until_someone_joins_it() {
        let x = test_secret(0, 0);
        let state = pending(20, 3).after(
            Applied::EnteredAsAlice {
                half_box_id: hex::encode([7u8; 32]),
            },
            "tx1",
            NOW,
        );
        assert_eq!(
            state.phase,
            MixPhase::HalfPosted {
                box_id: hex::encode([7u8; 32])
            }
        );
        assert_eq!(state.locked_value(), RING);

        let view = view_with(vec![half(7, &x, 20)], vec![]);
        let same = observe(state.clone(), &view, &x, NOW + 1);
        assert_eq!(same, state, "still unspent: nothing to fold in");
        assert_eq!(
            plan(&same, &view, &[]),
            Plan::Wait {
                reason: WaitReason::CounterpartNeeded
            }
        );

        // Gone from the unspent set, and no full box carries our gX yet:
        // never guess, wait for a better snapshot.
        let empty = view_with(vec![], vec![]);
        let still = observe(state.clone(), &empty, &x, NOW + 2);
        assert_eq!(still, state);
        assert_eq!(
            plan(&still, &empty, &[]),
            Plan::Wait {
                reason: WaitReason::BoxNotSeen
            }
        );

        // A Bob spent it: the full box holding our gX is ours as Alice.
        let bob = test_secret(91, 0);
        let [_, alices] = synthetic_round(x.public_key(), &bob, PairOrder::BobFirst, RING, 19);
        let joined_view = view_with(vec![], vec![alices.clone()]);
        let joined = observe(state.clone(), &joined_view, &x, NOW + 3);
        assert_eq!(
            joined.phase,
            MixPhase::FullOwned {
                box_id: alices.input.box_id.clone(),
                role: Role::Alice
            }
        );
        assert_eq!(joined.rounds_done, 1);
        assert_eq!(joined.round, 0, "the same secret spends the full box");
        assert_eq!(joined.events.last().unwrap().action, "joined");

        // Bob's box of the same round carries our gX too, and so would a
        // box anyone minted with it: neither is ours, and neither may
        // capture the record.
        let [bobs, alices] = synthetic_round(x.public_key(), &bob, PairOrder::BobFirst, RING, 19);
        assert_eq!(bobs.g_x, *x.public_key());
        let forged = view_with(vec![], vec![bobs.clone()]);
        assert_eq!(observe(state.clone(), &forged, &x, NOW + 4), state);
        let both = view_with(vec![], vec![bobs, alices.clone()]);
        assert_eq!(
            observe(state, &both, &x, NOW + 5).phase,
            MixPhase::FullOwned {
                box_id: alices.input.box_id,
                role: Role::Alice
            }
        );
    }

    #[test]
    fn a_move_whose_box_never_appears_is_rolled_back_after_the_grace() {
        let x = test_secret(0, 0);
        let bob = test_secret(91, 0);
        let [_, ours] = synthetic_round(x.public_key(), &bob, PairOrder::BobFirst, RING, 19);
        let full_id = ours.input.box_id.clone();
        let owned = pending(20, 3)
            .after(Applied::EnteredAsAlice { half_box_id: hex::encode([7u8; 32]) }, "tx1", NOW)
            .joined_as_alice(full_id.clone(), NOW + 1);
        assert_eq!(owned.previous, None);

        // A remix as Alice is broadcast: the new half box is not seen yet.
        let remixed = owned.clone().after(
            Applied::RemixedAsAlice { half_box_id: hex::encode([8u8; 32]) },
            "tx2",
            NOW + 10,
        );
        assert_eq!(remixed.round, 1);
        assert_eq!(remixed.previous.as_ref().map(|p| p.round), Some(0));
        let x1 = test_secret(0, 1);
        let old_still_there = view_with(vec![], vec![ours.clone()]);

        // Within the grace: still in the mempool for all we know.
        let soon = observe(remixed.clone(), &old_still_there, &x1, NOW + 10 + LOST_MOVE_GRACE_SECS - 1);
        assert_eq!(soon, remixed);

        // After the grace, the old box unspent: the move was lost.
        let back = observe(remixed.clone(), &old_still_there, &x1, NOW + 10 + LOST_MOVE_GRACE_SECS);
        assert_eq!(back.phase, owned.phase);
        assert_eq!(back.round, 0);
        assert_eq!(back.rounds_done, owned.rounds_done);
        assert_eq!(back.previous, None);
        assert_eq!(back.events.last().unwrap().action, "rolled_back");
        assert!(matches!(plan(&back, &old_still_there, &[]), Plan::RemixAsAlice | Plan::Wait { .. }));

        // After the grace but the old box spent (our move went through and
        // the snapshot is just late): wait, never roll back.
        let old_gone = view_with(vec![], vec![]);
        let late = observe(remixed.clone(), &old_gone, &x1, NOW + 10 + LOST_MOVE_GRACE_SECS);
        assert_eq!(late, remixed);

        // The new box seen: the fallback is dropped.
        let new_half = half(8, &x1, 19);
        let new_seen = view_with(vec![new_half], vec![ours]);
        let confirmed = observe(remixed, &new_seen, &x1, NOW + 20);
        assert_eq!(confirmed.previous, None);
        assert_eq!(confirmed.round, 1);
    }

    #[test]
    fn states_without_a_previous_step_still_load() {
        let v: serde_json::Value = serde_json::to_value(pending(20, 3)).unwrap();
        let mut m = v.as_object().unwrap().clone();
        m.remove("previous");
        let s: MixState = serde_json::from_value(serde_json::Value::Object(m)).unwrap();
        assert_eq!(s.previous, None);
    }

    #[test]
    fn the_cheapest_token_box_with_enough_tokens_is_offered() {
        let mut dear = fixture_token_box();
        dear.batches = vec![(20, 1_000_000_000_000), (40, 2_000_000_000_000)];
        dear.tokens_available = 1_000_000;
        let mut fair = fixture_token_box();
        fair.batches = vec![(20, 30_000_000), (40, 50_000_000)];
        fair.tokens_available = 30;
        let mut empty = fixture_token_box();
        empty.batches = vec![(20, 1)];
        empty.tokens_available = 5;
        let view = ChainView {
            token: vec![dear.clone(), fair.clone(), empty],
            ..view_with(vec![], vec![])
        };
        assert_eq!(view.token_box_for(20).map(|t| t.tokens_available), Some(30), "cheapest with enough");
        assert_eq!(view.token_box_for(40).map(|t| t.tokens_available), Some(1_000_000), "only the dear box has 40");
        assert!(view.token_box_for(60).is_none(), "no box sells a batch of 60");
        assert_eq!(view.token_levels(), vec![(20, 30_000_000), (40, 2_000_000_000_000)]);
        assert_eq!(view.token_box().map(|t| t.tokens_available), Some(1_000_000), "existence still counts any box");

        // Junk batches from a hostile box never reach the list or the pick.
        let mut junk = fixture_token_box();
        junk.batches = vec![(0, 1), (-5, 1), (20, 40_000_000)];
        junk.tokens_available = 100;
        let view = ChainView { token: vec![junk], ..view_with(vec![], vec![]) };
        assert_eq!(view.token_levels(), vec![(20, 40_000_000)]);
        assert!(view.token_box_for(0).is_none());
        assert!(view.token_box_for(-5).is_none());
        assert!(view.token_box_for(20).is_some());
        let mut negative = fixture_token_box();
        negative.batches = vec![(20, -7)];
        negative.tokens_available = 100;
        let view = ChainView { token: vec![negative], ..view_with(vec![], vec![]) };
        assert!(view.token_levels().is_empty());
        assert!(view.token_box_for(20).is_none(), "a negative price is not for sale");

        // Two boxes at one level: the negative price loses to the honest one.
        let mut hostile = fixture_token_box();
        hostile.batches = vec![(20, -1)];
        hostile.tokens_available = 1_000_000;
        let mut honest = fixture_token_box();
        honest.batches = vec![(20, 40_000_000)];
        honest.tokens_available = 50;
        let view = ChainView { token: vec![hostile, honest], ..view_with(vec![], vec![]) };
        assert_eq!(view.token_box_for(20).map(|t| t.tokens_available), Some(50));
    }

    #[test]
    fn the_fee_box_must_allow_and_hold_the_fee() {
        let mut small = fixture_fee_box();
        small.max_fee = 1000;
        small.value = 5_000_000_000;
        let mut drained = fixture_fee_box();
        drained.max_fee = 10_000_000;
        drained.value = 1_000_000;
        let mut fine = fixture_fee_box();
        fine.max_fee = 10_000_000;
        fine.value = 3_000_000_000;
        let view = ChainView {
            fee: vec![small.clone(), drained, fine.clone()],
            ..view_with(vec![], vec![])
        };
        assert_eq!(view.fee_box_for(1_100_000).map(|f| f.value), Some(fine.value));
        assert_eq!(view.fee_box().map(|f| f.value), Some(fine.value));
        assert!(view.fee_box_for(20_000_000).is_none());
        let only_small = ChainView {
            fee: vec![small],
            ..view_with(vec![], vec![])
        };
        assert!(only_small.fee_box().is_none(), "a tiny maxFee cannot pay a remix");
    }

    #[test]
    fn an_owned_full_box_remixes_as_bob_first_then_as_alice_then_withdraws() {
        let x = test_secret(0, 0);
        let bob = test_secret(91, 0);
        let [_, ours] = synthetic_round(x.public_key(), &bob, PairOrder::BobFirst, RING, 19);
        let state = pending(20, 3)
            .after(
                Applied::EnteredAsAlice {
                    half_box_id: "h".into(),
                },
                "tx1",
                NOW,
            )
            .joined_as_alice(ours.input.box_id.clone(), NOW);

        // A stranger waits: join them.
        let stranger = test_secret(92, 0);
        let view = view_with(vec![half(3, &stranger, 10)], vec![ours.clone()]);
        assert_eq!(
            plan(&state, &view, &[]),
            Plan::RemixAsBob {
                half_box_id: hex::encode([3u8; 32])
            }
        );

        // Nobody waits: post a half box.
        let alone = view_with(vec![], vec![ours.clone()]);
        assert_eq!(plan(&state, &alone, &[]), Plan::RemixAsAlice);

        // No fee box: nothing can be built.
        let mut no_fee = view_with(vec![], vec![ours.clone()]);
        no_fee.fee.clear();
        assert_eq!(
            plan(&state, &no_fee, &[]),
            Plan::Wait {
                reason: WaitReason::NoFeeBox
            }
        );

        // Box not in the snapshot: wait, do not build against a stale id.
        assert_eq!(
            plan(&state, &view_with(vec![], vec![]), &[]),
            Plan::Wait {
                reason: WaitReason::BoxNotSeen
            }
        );

        // Two more rounds as Bob reach the target, then it withdraws.
        let done = state
            .after(
                Applied::RemixedAsBob {
                    full_box_id: "f2".into(),
                },
                "tx2",
                NOW,
            )
            .after(
                Applied::RemixedAsBob {
                    full_box_id: ours.input.box_id.clone(),
                },
                "tx3",
                NOW,
            );
        assert_eq!((done.rounds_done, done.round), (3, 2));
        assert_eq!(
            plan(&done, &alone, &[]),
            Plan::Withdraw {
                reason: WithdrawReason::RoundsDone
            }
        );
        let out = done.after(Applied::Withdrawn, "tx4", NOW);
        assert!(out.phase.is_finished());
        assert_eq!(out.locked_value(), 0);
        assert_eq!(
            plan(&out, &alone, &[]),
            Plan::Wait {
                reason: WaitReason::Finished
            }
        );
    }

    #[test]
    fn a_box_with_no_tokens_left_withdraws_instead_of_remixing() {
        let x = test_secret(0, 0);
        let bob = test_secret(91, 0);
        // Level 1: remixing as Alice would need to burn its only token and
        // keep some, which the contract does not allow.
        let [_, ours] = synthetic_round(x.public_key(), &bob, PairOrder::BobFirst, RING, 1);
        let state = pending(2, 5)
            .after(
                Applied::EnteredAsAlice {
                    half_box_id: "h".into(),
                },
                "tx1",
                NOW,
            )
            .joined_as_alice(ours.input.box_id.clone(), NOW);
        assert_eq!(
            plan(&state, &view_with(vec![], vec![ours]), &[]),
            Plan::Withdraw {
                reason: WithdrawReason::TokensExhausted
            }
        );
    }

    #[test]
    fn recovery_rebuilds_live_mixes_from_the_seed_and_stops_at_the_gap() {
        // Mix 0 is waiting as Alice at round 2; mix 3 owns a full box as Bob
        // at round 1; mixes 1, 2 and everything after 3 have nothing.
        let alice_x = test_secret(0, 2);
        let bob_y = test_secret(3, 1);
        let stranger = test_secret(95, 0);
        let [bobs, _] =
            synthetic_round(stranger.public_key(), &bob_y, PairOrder::BobFirst, RING, 9);
        let view = view_with(vec![half(4, &alice_x, 12)], vec![bobs.clone()]);

        let derived = std::cell::RefCell::new(Vec::new());
        let states = recover(
            &view,
            |m, r| {
                derived.borrow_mut().push(m);
                Some(test_secret(m, r))
            },
            NOW,
        );
        assert_eq!(states.len(), 2);
        let a = &states[0];
        assert_eq!((a.mix_id, a.round), (0, 2));
        assert_eq!(
            a.phase,
            MixPhase::HalfPosted {
                box_id: hex::encode([4u8; 32])
            }
        );
        assert_eq!(a.ring, RingSpec::erg(RING));
        assert_eq!(a.level, 12);
        assert!(a.destination_ergo_tree.is_empty(), "the user picks one");
        let b = &states[1];
        assert_eq!((b.mix_id, b.round), (3, 1));
        assert_eq!(
            b.phase,
            MixPhase::FullOwned {
                box_id: bobs.input.box_id.clone(),
                role: Role::Bob
            }
        );
        assert_eq!(
            b.rounds_done, b.rounds_target,
            "presents as ready to withdraw"
        );

        let last_mix_tried = *derived.borrow().iter().max().unwrap();
        assert_eq!(
            last_mix_tried,
            3 + RECOVERY_MIX_GAP,
            "five empty mixes after the last hit"
        );
        assert_eq!(next_mix_id(&states), 4);
    }

    #[test]
    fn state_round_trips_through_json_without_a_secret_in_sight() {
        let s = pending(20, 3).after(
            Applied::EnteredAsBob {
                full_box_id: "abc".into(),
            },
            "tx",
            NOW,
        );
        let json = serde_json::to_string(&s).unwrap();
        assert!(json.contains("\"kind\":\"full_owned\""));
        assert!(json.contains("\"role\":\"bob\""));
        let back: MixState = serde_json::from_str(&json).unwrap();
        assert_eq!(back, s);
    }

    #[test]
    fn chain_view_parses_fixture_shaped_lists_and_skips_what_it_cannot_read() {
        use crate::testing::{
            FEE_EMISSION_FIXTURE, FULL_MIX_FIXTURE, HALF_MIX_FIXTURE, TOKEN_EMISSION_FIXTURE,
        };
        let json = format!(
            r#"{{"half_boxes":{HALF_MIX_FIXTURE},"full_boxes":{FULL_MIX_FIXTURE},"fee_boxes":{FEE_EMISSION_FIXTURE},"token_boxes":{TOKEN_EMISSION_FIXTURE},"height":1500000}}"#
        );
        let view = ChainView::parse(&json).expect("parses");
        assert!(!view.half.is_empty() && !view.full.is_empty());
        assert!(view.fee_box().is_some() && view.token_box().is_some());
        assert_eq!(view.unreadable, 0);

        // A half box listed under full_boxes is ignored, not misread.
        let swapped = format!(
            r#"{{"half_boxes":[],"full_boxes":{HALF_MIX_FIXTURE},"fee_boxes":[],"token_boxes":[],"height":1}}"#
        );
        let v = ChainView::parse(&swapped).unwrap();
        assert!(v.full.is_empty() && v.half.is_empty());

        assert!(
            ChainView::parse(r#"{"half_boxes":[]}"#).is_err(),
            "height is required"
        );
    }
}
