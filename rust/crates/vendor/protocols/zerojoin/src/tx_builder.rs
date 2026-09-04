//! Transaction builders for the five ZeroJoin moves.
//!
//! Each returns an [`Eip12UnsignedTx`] in the same shape as the other
//! protocol crates, plus the prover inputs the signer must add on top of the
//! wallet's own dlog keys (see `WalletHandle::sign_reduced_with_secrets`).
//!
//! ## Why the input and output order is not negotiable
//!
//! Every ErgoMixer contract reads its transaction positionally —
//! `INPUTS(0)`, `OUTPUTS(2)`, `INPUTS.size == 3` — so these builders emit
//! exactly the layouts the deployed scripts accept:
//!
//! | move | inputs | outputs |
//! |---|---|---|
//! | Alice entry | funding, token emission | half mix, income, token emission copy, fee |
//! | Bob entry | half mix, funding, token emission | full, full, income, token emission copy, fee |
//! | remix as Alice | full mix, fee emission | half mix, fee emission copy, fee |
//! | remix as Bob | half mix, full mix, fee emission | full, full, fee emission copy, fee |
//! | withdraw | full mix, fee emission | destination, fee emission copy, fee |
//!
//! Note what is missing: a change output. The token emission contract pins
//! `OUTPUTS.size` for both entry shapes, so the entry builders put every
//! leftover nanoERG into the operator's income box rather than returning it —
//! which is also what ErgoMixer does.

use std::collections::HashMap;

use ergo_tx::{Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};
use ergotree_interpreter::sigma_protocol::private_input::{DhTupleProverInput, DlogProverInput};

use crate::boxes::{FeeEmissionBox, FullMixBox, HalfMixBox, TokenEmissionBox};
use crate::contracts::{MIXER_INCOME_ERGO_TREE_HEX, MIXING_TOKEN_ID};
use crate::error::ZeroJoinError;
use crate::round::{
    enter_as_bob_tokens, full_mix_outputs, half_mix_output, next_full_mix, next_half_mix,
    PairOrder,
};
use crate::secret::MixSecret;

/// A secret the signer must supply beyond the wallet's own payment keys.
///
/// Deliberately not `Debug`, `Clone` or `Serialize`: a mix secret must never
/// reach a log line or a database row.
pub enum MixProverInput {
    /// `proveDlog(c2)` — a full-mix box spent by the party that was Bob.
    Dlog(DlogProverInput),
    /// `proveDHTuple(...)` — a half-mix box spent by Bob, or a full-mix box
    /// spent by the party that was Alice.
    DhTuple(DhTupleProverInput),
}

impl MixProverInput {
    /// Convert to the `SecretKey` `sign_reduced_with_secrets` expects.
    pub fn into_secret_key(self) -> ergo_lib::wallet::secret_key::SecretKey {
        use ergo_lib::wallet::secret_key::SecretKey;
        match self {
            MixProverInput::Dlog(d) => SecretKey::DlogSecretKey(d),
            MixProverInput::DhTuple(d) => SecretKey::DhtSecretKey(d),
        }
    }
}

/// Prints only which kind of proof is needed, never the scalar behind it.
impl core::fmt::Debug for MixProverInput {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            MixProverInput::Dlog(_) => f.write_str("MixProverInput::Dlog(*****)"),
            MixProverInput::DhTuple(_) => f.write_str("MixProverInput::DhTuple(*****)"),
        }
    }
}

/// A built mixing transaction and everything the caller needs to sign, track
/// and display it.
#[derive(Debug)]
pub struct MixTx {
    pub unsigned_tx: Eip12UnsignedTx,
    /// Extra prover inputs, one per mixing input that is not a plain wallet box.
    pub prover_inputs: Vec<MixProverInput>,
    pub summary: MixTxSummary,
}

/// What a mixing transaction does, in terms a UI can show.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct MixTxSummary {
    /// `alice_entry`, `bob_entry`, `remix_alice`, `remix_bob` or `withdraw`.
    pub action: String,
    /// The ring's denomination in nanoERG.
    pub denomination: i64,
    /// Mixing tokens on each mix output afterwards.
    pub mix_level_after: i64,
    /// Mixing tokens destroyed by this transaction.
    pub tokens_burned: i64,
    pub miner_fee_nano: i64,
    /// nanoERG paid to ErgoMixer's income address. Zero for a remix or a
    /// withdrawal: only entering a mix costs the operator fee.
    pub operator_fee_nano: i64,
}

fn miner_fee_output(fee: i64, height: i32) -> Eip12Output {
    Eip12Output::fee(fee, height)
}

fn value_of(b: &Eip12InputBox) -> Result<i64, ZeroJoinError> {
    b.value
        .parse::<i64>()
        .map_err(|_| ZeroJoinError::Serialization(format!("box value {:?}", b.value)))
}

fn token_amount(b: &Eip12InputBox, token_id: &str) -> i64 {
    b.assets
        .iter()
        .filter(|a| a.token_id.eq_ignore_ascii_case(token_id))
        .filter_map(|a| a.amount.parse::<i64>().ok())
        .sum()
}

/// The fee emission box copied forward, minus the fee it just paid.
///
/// `isCopy` in the fee contract requires the same script, the same R4 and a
/// value no lower than `SELF.value - maxFee`.
fn fee_emission_copy(fee_box: &FeeEmissionBox, fee: i64, height: i32) -> Result<Eip12Output, ZeroJoinError> {
    if fee > fee_box.max_fee {
        return Err(ZeroJoinError::FeeTooLarge {
            requested: fee,
            max_fee: fee_box.max_fee,
        });
    }
    if fee_box.value - fee <= 0 {
        return Err(ZeroJoinError::InsufficientFunds {
            needed: fee,
            available: fee_box.value,
        });
    }
    Ok(Eip12Output {
        value: (fee_box.value - fee).to_string(),
        ergo_tree: fee_box.input.ergo_tree.clone(),
        assets: fee_box.input.assets.clone(),
        creation_height: height,
        additional_registers: fee_box.input.additional_registers.clone(),
    })
}

/// The token emission box copied forward, minus the batch it just sold.
fn token_emission_copy(
    token_box: &TokenEmissionBox,
    sold: i64,
    height: i32,
) -> Result<Eip12Output, ZeroJoinError> {
    if sold > token_box.tokens_available {
        return Err(ZeroJoinError::TokenAccounting(format!(
            "token emission box holds {} mixing tokens, {sold} requested",
            token_box.tokens_available
        )));
    }
    Ok(Eip12Output {
        value: token_box.value.to_string(),
        ergo_tree: token_box.input.ergo_tree.clone(),
        assets: vec![Eip12Asset::new(
            MIXING_TOKEN_ID,
            token_box.tokens_available - sold,
        )],
        creation_height: height,
        additional_registers: token_box.input.additional_registers.clone(),
    })
}

/// What entering a mix costs the operator's income address.
///
/// The token emission contract demands
/// `income.value >= batchPrice + poolAmount / rate`, and for a token ring
/// also `income.tokens(0) >= mixed / rate` of the ring's token. Both come
/// straight out of the funding inputs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OperatorFee {
    pub batch_price: i64,
    pub proportional: i64,
}

impl OperatorFee {
    pub fn total(&self) -> i64 {
        self.batch_price + self.proportional
    }
}

/// Compute the operator fee for entering a ring of `denomination` at `level`.
pub fn operator_fee(
    token_box: &TokenEmissionBox,
    denomination: i64,
    level: i32,
) -> Result<OperatorFee, ZeroJoinError> {
    if token_box.rate <= 0 {
        return Err(ZeroJoinError::Invalid(
            "token emission box has a non-positive rate".into(),
        ));
    }
    Ok(OperatorFee {
        batch_price: token_box.batch_price(level)?,
        proportional: denomination / token_box.rate as i64,
    })
}

fn income_output(
    value: i64,
    ring_token_commission: Option<(String, i64)>,
    height: i32,
) -> Eip12Output {
    Eip12Output {
        value: value.to_string(),
        ergo_tree: MIXER_INCOME_ERGO_TREE_HEX.to_string(),
        assets: ring_token_commission
            .into_iter()
            .filter(|(_, a)| *a > 0)
            .map(|(id, a)| Eip12Asset::new(id, a))
            .collect(),
        creation_height: height,
        additional_registers: HashMap::new(),
    }
}

// ---------------------------------------------------------------------------
// Entering a mix
// ---------------------------------------------------------------------------

/// Enter a mix as Alice: buy a batch of mixing tokens and post a half-mix box.
///
/// `funding` must be a single wallet box — the token emission contract fixes
/// `INPUTS.size == 2`, so the caller has to consolidate first if it holds
/// enough ERG only across several boxes.
pub struct AliceEntry<'a> {
    pub funding: &'a Eip12InputBox,
    pub token_box: &'a TokenEmissionBox,
    pub x: &'a MixSecret,
    /// nanoERG per mix box: must be a denomination the pool already has.
    pub denomination: i64,
    /// Mixing tokens to buy; must be one of the emission box's batch levels.
    pub level: i32,
    /// `(token id, amount per box)` for a token ring; `None` for an ERG mix.
    pub ring_token: Option<(String, i64)>,
    pub miner_fee: i64,
    pub height: i32,
}

pub fn build_alice_entry(req: &AliceEntry<'_>) -> Result<MixTx, ZeroJoinError> {
    let fee = operator_fee(req.token_box, req.denomination, req.level)?;
    let funding_value = value_of(req.funding)?;

    // The income box takes everything the mix box and the emission copy do
    // not: there is no change output in this shape.
    let income_value = funding_value - req.miner_fee - req.denomination;
    if income_value < fee.total() {
        return Err(ZeroJoinError::InsufficientFunds {
            needed: req.denomination + req.miner_fee + fee.total(),
            available: funding_value,
        });
    }

    let ring_commission = match &req.ring_token {
        Some((id, per_box)) => {
            let held = token_amount(req.funding, id);
            let commission = held - per_box;
            if commission < per_box / req.token_box.rate as i64 {
                return Err(ZeroJoinError::TokenAccounting(format!(
                    "ring token commission {commission} is below the required {}",
                    per_box / req.token_box.rate as i64
                )));
            }
            Some((id.clone(), commission))
        }
        None => None,
    };

    let half = half_mix_output(
        req.denomination,
        req.x,
        req.level as i64,
        &req.ring_token,
        req.height,
    )?;

    let unsigned_tx = Eip12UnsignedTx {
        inputs: vec![req.funding.clone(), req.token_box.input.clone()],
        data_inputs: vec![],
        outputs: vec![
            half,
            income_output(income_value, ring_commission, req.height),
            token_emission_copy(req.token_box, req.level as i64, req.height)?,
            miner_fee_output(req.miner_fee, req.height),
        ],
    };

    Ok(MixTx {
        unsigned_tx,
        // The funding box is a plain wallet box; the emission box is spent
        // under its own `aliceBuying` branch. Neither needs a mix secret.
        prover_inputs: vec![],
        summary: MixTxSummary {
            action: "alice_entry".into(),
            denomination: req.denomination,
            mix_level_after: req.level as i64,
            tokens_burned: 0,
            miner_fee_nano: req.miner_fee,
            operator_fee_nano: income_value,
        },
    })
}

/// Enter a mix as Bob: buy a batch and immediately consume a waiting half-mix
/// box, producing the round's two full-mix boxes.
pub struct BobEntry<'a> {
    pub half: &'a HalfMixBox,
    pub funding: &'a Eip12InputBox,
    pub token_box: &'a TokenEmissionBox,
    pub y: &'a MixSecret,
    pub level: i32,
    pub order: PairOrder,
    pub miner_fee: i64,
    pub height: i32,
}

pub fn build_bob_entry(req: &BobEntry<'_>) -> Result<MixTx, ZeroJoinError> {
    let split = enter_as_bob_tokens(req.half.mix_level, req.level as i64)?;
    let fee = operator_fee(req.token_box, req.half.value, req.level)?;
    let funding_value = value_of(req.funding)?;

    // Bob's own money funds the second full-mix box; the half-mix box funds
    // the first, so the transaction moves `denomination` of new ERG in.
    let income_value = funding_value - req.miner_fee - req.half.value;
    if income_value < fee.total() {
        return Err(ZeroJoinError::InsufficientFunds {
            needed: req.half.value + req.miner_fee + fee.total(),
            available: funding_value,
        });
    }

    let ring_commission = match &req.half.mixing_token {
        Some((id, per_box)) => {
            let held = token_amount(req.funding, id);
            let commission = held - per_box;
            if commission < per_box / req.token_box.rate as i64 {
                return Err(ZeroJoinError::TokenAccounting(format!(
                    "ring token commission {commission} is below the required {}",
                    per_box / req.token_box.rate as i64
                )));
            }
            Some((id.clone(), commission))
        }
        None => None,
    };

    let outputs = full_mix_outputs(
        req.half.value,
        &req.half.g_x,
        req.y,
        req.order,
        split,
        &req.half.mixing_token,
        req.height,
    )?;

    let unsigned_tx = Eip12UnsignedTx {
        inputs: vec![
            req.half.input.clone(),
            req.funding.clone(),
            req.token_box.input.clone(),
        ],
        data_inputs: vec![],
        outputs: vec![
            outputs[0].clone(),
            outputs[1].clone(),
            income_output(income_value, ring_commission, req.height),
            token_emission_copy(req.token_box, req.level as i64, req.height)?,
            miner_fee_output(req.miner_fee, req.height),
        ],
    };

    Ok(MixTx {
        unsigned_tx,
        // INPUTS(0), the half-mix box, needs `proveDHTuple(g, gX, gY, gXY)`.
        prover_inputs: vec![MixProverInput::DhTuple(req.y.spend_half_mix_as_bob(req.half))],
        summary: MixTxSummary {
            action: "bob_entry".into(),
            denomination: req.half.value,
            mix_level_after: split.per_output,
            tokens_burned: split.burned,
            miner_fee_nano: req.miner_fee,
            operator_fee_nano: income_value,
        },
    })
}

// ---------------------------------------------------------------------------
// Remixing
// ---------------------------------------------------------------------------

/// Which proof our own full-mix box needs, given who we were last round.
fn full_mix_proof(
    full: &FullMixBox,
    secret: &MixSecret,
) -> Result<MixProverInput, ZeroJoinError> {
    match secret.role_for(full) {
        Some(crate::secret::Role::Bob) => {
            Ok(MixProverInput::Dlog(secret.spend_full_mix_as_bob(full)?))
        }
        Some(crate::secret::Role::Alice) => Ok(MixProverInput::DhTuple(
            secret.spend_full_mix_as_alice(full)?,
        )),
        None => Err(ZeroJoinError::Invalid(format!(
            "full-mix box {} does not belong to this round's secret",
            full.input.box_id
        ))),
    }
}

/// Remix as Alice: turn our full-mix box into the next round's half-mix box,
/// with the miner fee paid by the operator's fee emission box.
pub struct RemixAsAlice<'a> {
    pub full: &'a FullMixBox,
    /// The secret of the round that created `full`.
    pub current: &'a MixSecret,
    /// The secret of the round we are entering.
    pub next_x: &'a MixSecret,
    pub fee_box: &'a FeeEmissionBox,
    pub miner_fee: i64,
    pub height: i32,
}

pub fn build_remix_as_alice(req: &RemixAsAlice<'_>) -> Result<MixTx, ZeroJoinError> {
    let round = next_half_mix(req.full, req.next_x, req.height)?;
    let proof = full_mix_proof(req.full, req.current)?;

    let unsigned_tx = Eip12UnsignedTx {
        inputs: vec![req.full.input.clone(), req.fee_box.input.clone()],
        data_inputs: vec![],
        outputs: vec![
            round.half_mix,
            fee_emission_copy(req.fee_box, req.miner_fee, req.height)?,
            miner_fee_output(req.miner_fee, req.height),
        ],
    };

    Ok(MixTx {
        unsigned_tx,
        prover_inputs: vec![proof],
        summary: MixTxSummary {
            action: "remix_alice".into(),
            denomination: req.full.value,
            mix_level_after: round.tokens.per_output,
            tokens_burned: round.tokens.burned,
            miner_fee_nano: req.miner_fee,
            operator_fee_nano: 0,
        },
    })
}

/// Remix as Bob: spend a stranger's half-mix box together with our own
/// full-mix box of the same denomination.
pub struct RemixAsBob<'a> {
    pub half: &'a HalfMixBox,
    pub full: &'a FullMixBox,
    /// The secret of the round that created `full`.
    pub current: &'a MixSecret,
    /// The secret of the round we are entering.
    pub next_y: &'a MixSecret,
    pub fee_box: &'a FeeEmissionBox,
    pub order: PairOrder,
    pub miner_fee: i64,
    pub height: i32,
}

pub fn build_remix_as_bob(req: &RemixAsBob<'_>) -> Result<MixTx, ZeroJoinError> {
    let round = next_full_mix(req.full, req.half, req.next_y, req.order, req.height)?;
    let own_proof = full_mix_proof(req.full, req.current)?;

    let unsigned_tx = Eip12UnsignedTx {
        inputs: vec![
            req.half.input.clone(),
            req.full.input.clone(),
            req.fee_box.input.clone(),
        ],
        data_inputs: vec![],
        outputs: vec![
            round.outputs[0].clone(),
            round.outputs[1].clone(),
            fee_emission_copy(req.fee_box, req.miner_fee, req.height)?,
            miner_fee_output(req.miner_fee, req.height),
        ],
    };

    Ok(MixTx {
        unsigned_tx,
        prover_inputs: vec![
            // INPUTS(0): the half-mix box, proved with the next round's secret.
            MixProverInput::DhTuple(req.next_y.spend_half_mix_as_bob(req.half)),
            // INPUTS(1): our own full-mix box, proved with this round's.
            own_proof,
        ],
        summary: MixTxSummary {
            action: "remix_bob".into(),
            denomination: req.full.value,
            mix_level_after: round.tokens.per_output,
            tokens_burned: round.tokens.burned,
            miner_fee_nano: req.miner_fee,
            operator_fee_nano: 0,
        },
    })
}

// ---------------------------------------------------------------------------
// Leaving
// ---------------------------------------------------------------------------

/// Withdraw a full-mix box to an ordinary address.
///
/// Every remaining mixing token is burned — that is the full-mix contract's
/// `destroyToken` branch, and it is what lets the box leave the pool. The
/// destination should be a fresh address, or a stealth address, or the mix
/// buys nothing.
pub struct Withdraw<'a> {
    pub full: &'a FullMixBox,
    pub current: &'a MixSecret,
    pub fee_box: &'a FeeEmissionBox,
    /// ErgoTree of where the money goes.
    pub destination_ergo_tree: &'a str,
    pub miner_fee: i64,
    pub height: i32,
}

pub fn build_withdraw(req: &Withdraw<'_>) -> Result<MixTx, ZeroJoinError> {
    let proof = full_mix_proof(req.full, req.current)?;

    // The mixing token is destroyed; a ring token, if any, travels with the
    // money.
    let assets: Vec<Eip12Asset> = req
        .full
        .mixing_token
        .iter()
        .map(|(id, a)| Eip12Asset::new(id.clone(), *a))
        .collect();

    let destination = Eip12Output {
        value: req.full.value.to_string(),
        ergo_tree: req.destination_ergo_tree.to_string(),
        assets,
        creation_height: req.height,
        additional_registers: HashMap::new(),
    };

    let unsigned_tx = Eip12UnsignedTx {
        inputs: vec![req.full.input.clone(), req.fee_box.input.clone()],
        data_inputs: vec![],
        outputs: vec![
            destination,
            fee_emission_copy(req.fee_box, req.miner_fee, req.height)?,
            miner_fee_output(req.miner_fee, req.height),
        ],
    };

    Ok(MixTx {
        unsigned_tx,
        prover_inputs: vec![proof],
        summary: MixTxSummary {
            action: "withdraw".into(),
            denomination: req.full.value,
            mix_level_after: 0,
            tokens_burned: req.full.mix_level,
            miner_fee_nano: req.miner_fee,
            operator_fee_nano: 0,
        },
    })
}

/// Reclaim a half-mix box that never found a counterpart.
///
/// Spent with `proveDlog(gX)`, which the half-mix contract allows as long as
/// no output keeps a mixing token — so the tokens are burned and the ERG
/// comes home. Unlike a withdrawal this pays its own miner fee, because the
/// operator's fee box only funds transactions that are actually mixes.
pub struct ReclaimHalfMix<'a> {
    pub half: &'a HalfMixBox,
    pub x: &'a MixSecret,
    pub destination_ergo_tree: &'a str,
    pub miner_fee: i64,
    pub height: i32,
}

pub fn build_reclaim_half_mix(req: &ReclaimHalfMix<'_>) -> Result<MixTx, ZeroJoinError> {
    if req.half.g_x != *req.x.public_key() {
        return Err(ZeroJoinError::Invalid(format!(
            "half-mix box {} was not created by this secret",
            req.half.input.box_id
        )));
    }
    if req.miner_fee >= req.half.value {
        return Err(ZeroJoinError::InsufficientFunds {
            needed: req.miner_fee,
            available: req.half.value,
        });
    }
    let assets: Vec<Eip12Asset> = req
        .half
        .mixing_token
        .iter()
        .map(|(id, a)| Eip12Asset::new(id.clone(), *a))
        .collect();

    let unsigned_tx = Eip12UnsignedTx {
        inputs: vec![req.half.input.clone()],
        data_inputs: vec![],
        outputs: vec![
            Eip12Output {
                value: (req.half.value - req.miner_fee).to_string(),
                ergo_tree: req.destination_ergo_tree.to_string(),
                assets,
                creation_height: req.height,
                additional_registers: HashMap::new(),
            },
            miner_fee_output(req.miner_fee, req.height),
        ],
    };

    Ok(MixTx {
        unsigned_tx,
        prover_inputs: vec![MixProverInput::Dlog(req.x.dlog_prover_input())],
        summary: MixTxSummary {
            action: "reclaim_half".into(),
            denomination: req.half.value,
            mix_level_after: 0,
            tokens_burned: req.half.mix_level,
            miner_fee_nano: req.miner_fee,
            operator_fee_nano: 0,
        },
    })
}

/// Sum of every mixing token on the inputs minus the outputs.
///
/// The fee emission contract checks this exactly, so the builders' tests
/// check it too.
pub fn mixing_tokens_burned(tx: &Eip12UnsignedTx) -> i64 {
    let sum = |amounts: Vec<&Eip12Asset>| -> i64 {
        amounts
            .into_iter()
            .filter(|a| a.token_id.eq_ignore_ascii_case(MIXING_TOKEN_ID))
            .filter_map(|a| a.amount.parse::<i64>().ok())
            .sum()
    };
    sum(tx.inputs.iter().flat_map(|b| b.assets.iter()).collect())
        - sum(tx.outputs.iter().flat_map(|b| b.assets.iter()).collect())
}

/// nanoERG on the inputs minus nanoERG on the outputs. Must be zero: a mixing
/// transaction that leaks ERG is a bug, not a donation.
pub fn erg_imbalance(tx: &Eip12UnsignedTx) -> i64 {
    let ins: i64 = tx
        .inputs
        .iter()
        .filter_map(|b| b.value.parse::<i64>().ok())
        .sum();
    let outs: i64 = tx
        .outputs
        .iter()
        .filter_map(|b| b.value.parse::<i64>().ok())
        .sum();
    ins - outs
}

#[cfg(test)]
mod tests;
