//! Ergopad full recovery. Ownership is established by the wallet boundary, not
//! by these equality checks. Layout and accounting are derived from real inputs.
use std::collections::BTreeMap;

use ergo_lib::{
    chain::{ergo_state_context::ErgoStateContext, transaction::reduced::reduce_tx},
    wallet::tx_context::TransactionContext,
};
use ergo_tx::{Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};
use ergotree_ir::{
    mir::constant::Constant,
    serialization::SigmaSerializable,
    sigma_protocol::sigma_boolean::{SigmaBoolean, SigmaProofOfKnowledgeTree},
};

use crate::{
    boxes::canonical_box,
    contracts::parse_tree,
    validation::{validate_full_unstake, validate_key_box, validate_unique_inputs},
    Pool, RecoveryError, StakeBox, StakeStateBox,
};

pub const APP_FEE: i64 = 1_100_000;
pub const MIN_VALUE: i64 = 1_000_000;
pub const APP_FEE_ADDRESS: &str = "9iArkadiaZAPVxbUp2XQ8SVA1zGA29rCPhbpVuUaaKW6fWspUZA";

/// Inputs must already be ordered state, stake, key, then optional funding.
/// `wallet_trees` must come from addresses authenticated by a wallet handle.
pub struct DirectRequest<'a> {
    pub inputs: &'a [Eip12InputBox],
    pub key: &'a [u8; 32],
    /// Wallet-controlled destination for the surviving key and wallet change.
    /// Payout must use INPUTS(2)'s authenticated wallet tree.
    pub recipient: &'a str,
    pub wallet_trees: &'a [String],
    pub height: i32,
    pub miner_fee: i64,
}

fn invalid(s: &str) -> RecoveryError {
    RecoveryError::Invalid(s.into())
}
fn number(s: &str) -> Result<i64, RecoveryError> {
    s.parse().map_err(|_| invalid("amount outside Long range"))
}
fn add(a: i64, b: i64) -> Result<i64, RecoveryError> {
    a.checked_add(b)
        .ok_or(RecoveryError::Overflow("transaction totals"))
}
fn assets<'a>(
    items: impl Iterator<Item = &'a Eip12Asset>,
) -> Result<BTreeMap<String, i64>, RecoveryError> {
    let mut out = BTreeMap::new();
    for asset in items {
        let n = number(&asset.amount)?;
        if n <= 0 {
            return Err(invalid("nonpositive token amount"));
        }
        let entry = out.entry(asset.token_id.to_lowercase()).or_insert(0);
        *entry = add(*entry, n)?;
    }
    Ok(out)
}

pub fn build(r: &DirectRequest<'_>) -> Result<Eip12UnsignedTx, RecoveryError> {
    let tx = assemble(r)?;
    validate(r, &tx)?;
    Ok(tx)
}

fn assemble(r: &DirectRequest<'_>) -> Result<Eip12UnsignedTx, RecoveryError> {
    if r.inputs.len() < 3 || r.height < 0 || r.miner_fee < MIN_VALUE {
        return Err(invalid("input count, height or miner fee"));
    }
    validate_unique_inputs(r.inputs)?;
    let state = StakeStateBox::parse(&r.inputs[0], Pool::Ergopad)?;
    let stake = StakeBox::parse(&r.inputs[1], Pool::Ergopad)?;
    if stake.key_id() != r.key {
        return Err(invalid("R5 differs from the key being redeemed"));
    }
    validate_key_box(&r.inputs[2], r.key)?;
    let after = validate_full_unstake(&state, &stake)?;
    if !r.wallet_trees.iter().any(|t| t == r.recipient) {
        return Err(invalid("recipient is not wallet controlled"));
    }
    let tree = parse_tree(
        &hex::decode(r.recipient).map_err(|e| RecoveryError::Serialization(e.to_string()))?,
    )?;
    // Ordinary P2PK only: no permissionless or unrecognised wallet scripts.
    if !matches!(
        tree.proposition()
            .map_err(|e| RecoveryError::Serialization(e.to_string()))?,
        ergotree_ir::mir::expr::Expr::Const(_)
    ) || !r.recipient.starts_with("0008cd")
        || r.recipient.len() != 72
    {
        return Err(invalid("recipient must be an ordinary wallet P2PK"));
    }
    for (i, input) in r.inputs.iter().enumerate() {
        if input.creation_height < 0
            || input.creation_height > r.height
            || !input.extension.is_empty()
        {
            return Err(invalid("input height or unexpected context extension"));
        }
        if i >= 2 {
            if !r.wallet_trees.contains(&input.ergo_tree)
                || !input.ergo_tree.starts_with("0008cd")
                || input.ergo_tree.len() != 72
            {
                return Err(invalid("funding input is not wallet controlled"));
            }
            for a in &input.assets {
                for pool in [Pool::Ergopad, Pool::Paideia, Pool::Egio] {
                    let c = pool.contracts();
                    if [c.state_nft, c.stake_token]
                        .iter()
                        .any(|id| a.token_id.eq_ignore_ascii_case(id))
                    {
                        return Err(invalid("unexpected protocol asset on wallet input"));
                    }
                }
                if i > 2 && a.token_id.eq_ignore_ascii_case(&hex::encode(r.key)) {
                    return Err(invalid("ambiguous key inputs"));
                }
            }
        }
    }
    let c = Pool::Ergopad.contracts();
    let mut state_out = Eip12Output::change(
        number(&r.inputs[0].value)?,
        r.inputs[0].ergo_tree.clone(),
        vec![
            Eip12Asset::new(c.state_nft, 1),
            Eip12Asset::new(c.stake_token, after.returned_stake_tokens),
        ],
        r.height,
    );
    state_out.additional_registers.insert(
        "R4".into(),
        hex::encode(
            Constant::from(vec![
                after.remaining_staked,
                state.checkpoint(),
                after.remaining_stakers,
                state.last_checkpoint_ms(),
                state.cycle_duration_ms(),
            ])
            .sigma_serialize_bytes()
            .map_err(|e| RecoveryError::Serialization(e.to_string()))?,
        ),
    );
    let payout = Eip12Output::change(
        MIN_VALUE,
        &r.inputs[2].ergo_tree,
        vec![Eip12Asset::new(c.reward_token, after.payout)],
        r.height,
    );
    let total = r
        .inputs
        .iter()
        .try_fold(0, |n, b| add(n, number(&b.value)?))?;
    let spent = add(
        add(number(&state_out.value)?, MIN_VALUE)?,
        add(APP_FEE, r.miner_fee)?,
    )?;
    let change = total
        .checked_sub(spent)
        .ok_or(RecoveryError::Overflow("ERG change"))?;
    if change < MIN_VALUE {
        return Err(invalid(
            "insufficient ERG for fees and key return; add wallet funding",
        ));
    }
    let change_assets = assets(r.inputs[2..].iter().flat_map(|b| &b.assets))?
        .into_iter()
        .map(|(id, n)| Eip12Asset::new(id, n))
        .collect();
    let fee_tree = ergo_tx::address_to_ergo_tree(APP_FEE_ADDRESS)
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    let tx = Eip12UnsignedTx {
        inputs: r.inputs.to_vec(),
        data_inputs: vec![],
        outputs: vec![
            state_out,
            payout,
            Eip12Output::change(change, r.recipient, change_assets, r.height),
            Eip12Output::simple(APP_FEE, fee_tree, r.height),
            Eip12Output::fee(r.miner_fee, r.height),
        ],
    };
    Ok(tx)
}

/// Reject layout edits as wallet policy even where scripts would accept them.
pub fn validate(r: &DirectRequest<'_>, tx: &Eip12UnsignedTx) -> Result<(), RecoveryError> {
    let expected = assemble(r)?;
    if serde_json::to_value(tx).map_err(|e| RecoveryError::Serialization(e.to_string()))?
        != serde_json::to_value(expected)
            .map_err(|e| RecoveryError::Serialization(e.to_string()))?
    {
        return Err(invalid("transaction differs from pinned Direct layout"));
    }
    let inputs = assets(tx.inputs.iter().flat_map(|b| &b.assets))?;
    let outputs = assets(tx.outputs.iter().flat_map(|b| &b.assets))?;
    if inputs != outputs {
        return Err(invalid("token creation or burn"));
    }
    let incoming = tx
        .inputs
        .iter()
        .try_fold(0, |n, b| add(n, number(&b.value)?))?;
    let outgoing = tx
        .outputs
        .iter()
        .try_fold(0, |n, b| add(n, number(&b.value)?))?;
    if incoming != outgoing
        || tx
            .outputs
            .iter()
            .any(|b| number(&b.value).map_or(true, |n| n < MIN_VALUE))
    {
        return Err(invalid("ERG conservation or minimum value"));
    }
    // Candidate construction also enforces the size-dependent minimum value.
    ergo_tx::chain::to_unsigned_transaction(tx).map_err(RecoveryError::Serialization)?;
    Ok(())
}

/// Reduction is a required preflight, not just a serialization check.
pub fn reduce(tx: &Eip12UnsignedTx, context: &ErgoStateContext) -> Result<(), RecoveryError> {
    let unsigned =
        ergo_tx::chain::to_unsigned_transaction(tx).map_err(RecoveryError::Serialization)?;
    let boxes = tx
        .inputs
        .iter()
        .map(canonical_box)
        .collect::<Result<Vec<_>, _>>()?;
    let ctx = TransactionContext::new(unsigned, boxes, vec![])
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    let reduced =
        reduce_tx(ctx, context).map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    for (i, input) in reduced.reduced_inputs().iter().enumerate() {
        if i < 2 {
            if input.sigma_prop != SigmaBoolean::TrivialProp(true) {
                return Err(invalid("protocol input did not reduce to true"));
            }
        } else if let SigmaBoolean::ProofOfKnowledge(SigmaProofOfKnowledgeTree::ProveDlog(key)) =
            &input.sigma_prop
        {
            if hex::encode(
                key.h
                    .sigma_serialize_bytes()
                    .map_err(|e| RecoveryError::Serialization(e.to_string()))?,
            ) != tx.inputs[i].ergo_tree[6..]
            {
                return Err(invalid("wallet signature key changed"));
            }
        } else {
            return Err(invalid("wallet input lost its signature requirement"));
        }
    }
    Ok(())
}
