//! Paideia creation and independent refund. No executor transaction is exposed.
//! Authenticated wallet trees must be supplied by the wallet-handle boundary.
use std::collections::BTreeMap;

use crate::{
    boxes::canonical_box,
    contracts::*,
    direct::{APP_FEE, APP_FEE_ADDRESS},
    validation::*,
    PaideiaProxyBox, RecoveryError, StakeBox, StakeStateBox,
};
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

fn invalid(s: &str) -> RecoveryError {
    RecoveryError::Invalid(s.into())
}
fn serial(e: impl std::fmt::Display) -> RecoveryError {
    RecoveryError::Serialization(e.to_string())
}
fn number(s: &str) -> Result<i64, RecoveryError> {
    s.parse().map_err(serial)
}
fn add(a: i64, b: i64) -> Result<i64, RecoveryError> {
    a.checked_add(b)
        .ok_or(RecoveryError::Overflow("proxy accounting"))
}
fn sub(a: i64, b: i64) -> Result<i64, RecoveryError> {
    a.checked_sub(b)
        .ok_or(RecoveryError::Overflow("proxy accounting"))
}
fn constant(c: Constant) -> Result<String, RecoveryError> {
    Ok(hex::encode(c.sigma_serialize_bytes().map_err(serial)?))
}
fn tree(address: &str) -> Result<String, RecoveryError> {
    ergo_tx::address_to_ergo_tree(address).map_err(serial)
}
fn tokens<'a>(
    items: impl Iterator<Item = &'a Eip12Asset>,
) -> Result<BTreeMap<String, i64>, RecoveryError> {
    let mut result = BTreeMap::new();
    for a in items {
        let n = number(&a.amount)?;
        if n <= 0 {
            return Err(invalid("nonpositive asset"));
        }
        let old = result.entry(a.token_id.to_lowercase()).or_insert(0);
        *old = add(*old, n)?;
    }
    Ok(result)
}
fn input_context(inputs: &[Eip12InputBox], height: i32) -> Result<(), RecoveryError> {
    validate_unique_inputs(inputs)?;
    if height < 0
        || inputs
            .iter()
            .any(|b| b.creation_height < 0 || b.creation_height > height || !b.extension.is_empty())
    {
        return Err(invalid("height or context extension"));
    }
    Ok(())
}
fn wallet_tree(recipient: &str, trees: &[String]) -> Result<(), RecoveryError> {
    if !trees.iter().any(|t| t == recipient)
        || !recipient.starts_with("0008cd")
        || recipient.len() != 72
    {
        return Err(invalid("recipient must be authenticated wallet P2PK"));
    }
    parse_tree(&hex::decode(recipient).map_err(serial)?)?;
    Ok(())
}
fn equal(expected: &Eip12UnsignedTx, tx: &Eip12UnsignedTx) -> Result<(), RecoveryError> {
    if serde_json::to_value(expected).map_err(serial)?
        != serde_json::to_value(tx).map_err(serial)?
    {
        return Err(invalid("transaction differs from re-derived proxy layout"));
    }
    Ok(())
}
// Exactly one intentional key burn is allowed only in the private eligibility
// witness. Creation and refund pass None, and cannot burn or create any token.
fn conserved(tx: &Eip12UnsignedTx, burn: Option<&[u8; 32]>) -> Result<(), RecoveryError> {
    let mut incoming = tokens(tx.inputs.iter().flat_map(|b| &b.assets))?;
    if let Some(key) = burn {
        if incoming.remove(&hex::encode(key)) != Some(1) {
            return Err(invalid("execution must burn exactly one key"));
        }
    }
    if incoming != tokens(tx.outputs.iter().flat_map(|b| &b.assets))? {
        return Err(invalid("unexpected token creation or burn"));
    }
    let sum_in = tx
        .inputs
        .iter()
        .try_fold(0, |n, b| add(n, number(&b.value)?))?;
    let sum_out = tx
        .outputs
        .iter()
        .try_fold(0, |n, b| add(n, number(&b.value)?))?;
    if sum_in != sum_out
        || tx
            .outputs
            .iter()
            .any(|b| number(&b.value).map_or(true, |n| n < MIN_BOX_VALUE))
    {
        return Err(invalid("ERG conservation or minimum value"));
    }
    ergo_tx::chain::to_unsigned_transaction(tx).map_err(serial)?;
    Ok(())
}

/// Refund needs exactly the proxy and height; R5 is authoritative. Ownership
/// and tracked-box identity are checked at the handle boundary, independently
/// of pool discovery. There is no Argus fee in this contract-pinned layout.
pub fn refund(proxy: &Eip12InputBox, height: i32) -> Result<Eip12UnsignedTx, RecoveryError> {
    let tx = assemble_refund(proxy, height)?;
    validate_refund(proxy, height, &tx)?;
    Ok(tx)
}
fn assemble_refund(proxy: &Eip12InputBox, height: i32) -> Result<Eip12UnsignedTx, RecoveryError> {
    input_context(std::slice::from_ref(proxy), height)?;
    let parsed = PaideiaProxyBox::parse(proxy)?;
    Ok(Eip12UnsignedTx {
        inputs: vec![proxy.clone()],
        data_inputs: vec![],
        outputs: vec![
            Eip12Output::change(
                sub(number(&proxy.value)?, REFUND_FEE)?,
                hex::encode(parsed.recipient().sigma_serialize_bytes().map_err(serial)?),
                proxy.assets.clone(),
                height,
            ),
            Eip12Output::fee(REFUND_FEE, height),
        ],
    })
}
pub fn validate_refund(
    proxy: &Eip12InputBox,
    height: i32,
    tx: &Eip12UnsignedTx,
) -> Result<(), RecoveryError> {
    equal(&assemble_refund(proxy, height)?, tx)?;
    conserved(tx, None)
}

pub struct CreationRequest<'a> {
    pub state: &'a Eip12InputBox,
    pub stake: &'a Eip12InputBox,
    /// Key box first, then wallet funding. All unrelated assets return in change.
    pub wallet_inputs: &'a [Eip12InputBox],
    pub wallet_trees: &'a [String],
    pub recipient: &'a str,
    pub height: i32,
    pub miner_fee: i64,
}

/// Derive funding from pinned branch costs and decoded stake value, not the
/// historical 0.113 ERG deposit. Reserve a minimum payout and refund output.
pub fn required_funding(stake: &Eip12InputBox) -> Result<i64, RecoveryError> {
    StakeBox::parse(stake, Pool::Paideia)?;
    let fixed = add(add(INCENTIVE_VALUE, EXECUTOR_VALUE)?, EXECUTION_FEE)?;
    Ok(
        sub(add(fixed, MIN_BOX_VALUE)?, number(&stake.value)?)?
            .max(add(REFUND_FEE, MIN_BOX_VALUE)?),
    )
}
fn assemble_creation(r: &CreationRequest<'_>) -> Result<Eip12UnsignedTx, RecoveryError> {
    if r.wallet_inputs.is_empty() || r.miner_fee < MIN_BOX_VALUE {
        return Err(invalid("missing key input or invalid fee"));
    }
    let mut all = vec![r.state.clone(), r.stake.clone()];
    all.extend_from_slice(r.wallet_inputs);
    input_context(&all, r.height)?;
    wallet_tree(r.recipient, r.wallet_trees)?;
    let state = StakeStateBox::parse(r.state, Pool::Paideia)?;
    let stake = StakeBox::parse(r.stake, Pool::Paideia)?;
    let after = validate_full_unstake(&state, &stake)?;
    validate_key_box(&r.wallet_inputs[0], stake.key_id())?;
    for b in r.wallet_inputs {
        wallet_tree(&b.ergo_tree, r.wallet_trees)?;
        for a in &b.assets {
            for p in [Pool::Ergopad, Pool::Paideia, Pool::Egio] {
                let c = p.contracts();
                if [c.state_nft, c.stake_token]
                    .iter()
                    .any(|id| a.token_id.eq_ignore_ascii_case(id))
                {
                    return Err(invalid("unexpected protocol asset on wallet input"));
                }
            }
        }
    }
    let mut change_assets = tokens(r.wallet_inputs.iter().flat_map(|b| &b.assets))?;
    let key = hex::encode(stake.key_id());
    if change_assets.remove(&key) != Some(1) {
        return Err(invalid("ambiguous key quantity"));
    }
    let value = required_funding(r.stake)?;
    let mut proxy = Eip12Output::change(
        value,
        tree(PAIDEIA_PROXY_ADDRESS)?,
        vec![Eip12Asset::new(key, 1)],
        r.height,
    );
    proxy
        .additional_registers
        .insert("R4".into(), constant(Constant::from(vec![after.payout]))?);
    proxy.additional_registers.insert(
        "R5".into(),
        constant(Constant::from(hex::decode(r.recipient).map_err(serial)?))?,
    );
    let total = r
        .wallet_inputs
        .iter()
        .try_fold(0, |n, b| add(n, number(&b.value)?))?;
    let change = sub(total, add(value, add(APP_FEE, r.miner_fee)?)?)?;
    Ok(Eip12UnsignedTx {
        inputs: r.wallet_inputs.to_vec(),
        data_inputs: vec![],
        outputs: vec![
            proxy,
            Eip12Output::change(
                change,
                r.recipient,
                change_assets
                    .into_iter()
                    .map(|(id, n)| Eip12Asset::new(id, n))
                    .collect(),
                r.height,
            ),
            Eip12Output::simple(APP_FEE, tree(APP_FEE_ADDRESS)?, r.height),
            Eip12Output::fee(r.miner_fee, r.height),
        ],
    })
}
pub fn validate_creation(
    r: &CreationRequest<'_>,
    tx: &Eip12UnsignedTx,
) -> Result<(), RecoveryError> {
    equal(&assemble_creation(r)?, tx)?;
    conserved(tx, None)
}
/// No creation leaves this builder without exact reduction of its wallet inputs,
/// its independent refund, and a private execution eligibility witness.
pub fn create(
    r: &CreationRequest<'_>,
    context: &ErgoStateContext,
) -> Result<Eip12UnsignedTx, RecoveryError> {
    let tx = assemble_creation(r)?;
    validate_creation(r, &tx)?;
    reduce(&tx, context, false)?;
    let (_, outputs) = ergo_tx::chain::derive_output_boxes(&tx).map_err(serial)?;
    let proxy = &outputs[0];
    let refund = refund(proxy, r.height)?;
    reduce(&refund, context, true)?;
    eligibility(r, proxy, context)?;
    Ok(tx)
}
/// This witness is discarded after reduction. It is never returned, cached,
/// signed or exposed through FFI; batch 5 owns the executor builder and flow.
fn eligibility(
    r: &CreationRequest<'_>,
    proxy: &Eip12InputBox,
    context: &ErgoStateContext,
) -> Result<(), RecoveryError> {
    verify_incentive_commitment()?;
    let state = StakeStateBox::parse(r.state, Pool::Paideia)?;
    let stake = StakeBox::parse(r.stake, Pool::Paideia)?;
    let parsed = PaideiaProxyBox::parse(proxy)?;
    let after = validate_proxy_unstake(&state, &stake, &parsed)?;
    let c = Pool::Paideia.contracts();
    let mut next = Eip12Output::change(
        number(&r.state.value)?,
        r.state.ergo_tree.clone(),
        vec![
            Eip12Asset::new(c.state_nft, 1),
            Eip12Asset::new(c.stake_token, after.returned_stake_tokens),
        ],
        r.height,
    );
    next.additional_registers.insert(
        "R4".into(),
        constant(Constant::from(vec![
            after.remaining_staked,
            state.checkpoint(),
            after.remaining_stakers,
            state.last_checkpoint_ms(),
            state.cycle_duration_ms(),
        ]))?,
    );
    let payout_value = sub(
        add(number(&r.stake.value)?, number(&proxy.value)?)?,
        add(add(INCENTIVE_VALUE, EXECUTOR_VALUE)?, EXECUTION_FEE)?,
    )?;
    let witness = Eip12UnsignedTx {
        inputs: vec![r.state.clone(), r.stake.clone(), proxy.clone()],
        data_inputs: vec![],
        outputs: vec![
            next,
            Eip12Output::change(
                payout_value,
                r.recipient,
                vec![Eip12Asset::new(c.reward_token, after.payout)],
                r.height,
            ),
            Eip12Output::simple(INCENTIVE_VALUE, tree(PAIDEIA_INCENTIVE_ADDRESS)?, r.height),
            Eip12Output::simple(EXECUTOR_VALUE, r.recipient, r.height),
            Eip12Output::fee(EXECUTION_FEE, r.height),
        ],
    };
    conserved(&witness, Some(stake.key_id()))?;
    reduce(&witness, context, true)
}

/// Inspect exact propositions, not merely successful interpreter evaluation.
pub fn reduce(
    tx: &Eip12UnsignedTx,
    context: &ErgoStateContext,
    permissionless: bool,
) -> Result<(), RecoveryError> {
    if tx
        .inputs
        .iter()
        .any(|b| u32::try_from(b.creation_height).map_or(true, |h| h > context.pre_header.height))
        || tx.outputs.iter().any(|b| {
            u32::try_from(b.creation_height).map_or(true, |h| h > context.pre_header.height)
        })
    {
        return Err(invalid("box height exceeds reduction context"));
    }
    let unsigned = ergo_tx::chain::to_unsigned_transaction(tx).map_err(serial)?;
    let boxes = tx
        .inputs
        .iter()
        .map(canonical_box)
        .collect::<Result<Vec<_>, _>>()?;
    let reduced = reduce_tx(
        TransactionContext::new(unsigned, boxes, vec![]).map_err(serial)?,
        context,
    )
    .map_err(serial)?;
    for (i, input) in reduced.reduced_inputs().iter().enumerate() {
        if permissionless {
            if input.sigma_prop != SigmaBoolean::TrivialProp(true) {
                return Err(invalid("protocol proposition is not true"));
            }
        } else if let SigmaBoolean::ProofOfKnowledge(SigmaProofOfKnowledgeTree::ProveDlog(key)) =
            &input.sigma_prop
        {
            let expected = format!(
                "0008cd{}",
                hex::encode(key.h.sigma_serialize_bytes().map_err(serial)?)
            );
            if expected != tx.inputs[i].ergo_tree {
                return Err(invalid("wallet signature key changed"));
            }
        } else {
            return Err(invalid("wallet signature requirement lost"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod accounting_tests {
    use super::*;

    #[test]
    fn only_execution_accounting_allows_exactly_one_key_burn() {
        let history: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/paideia-refund.json")).unwrap();
        let b: ergotree_ir::chain::ergo_box::ErgoBox =
            serde_json::from_value(history["inputs"][0].clone()).unwrap();
        let proxy = Eip12InputBox::from_ergo_box(&b, b.transaction_id.to_string(), b.index);
        let parsed = PaideiaProxyBox::parse(&proxy).unwrap();
        let mut tx = Eip12UnsignedTx {
            inputs: vec![proxy.clone()],
            data_inputs: vec![],
            outputs: vec![Eip12Output::simple(
                number(&proxy.value).unwrap(),
                hex::encode(parsed.recipient().sigma_serialize_bytes().unwrap()),
                proxy.creation_height,
            )],
        };
        assert!(conserved(&tx, None).is_err());
        conserved(&tx, Some(parsed.key_id())).unwrap();
        // Keeping the key is not a full execution; burning an unrelated token
        // or creating any token is not permitted by the explicit exception.
        tx.outputs[0].assets = proxy.assets.clone();
        assert!(conserved(&tx, Some(parsed.key_id())).is_err());
        tx.outputs[0].assets = vec![Eip12Asset::new("12".repeat(32), 1)];
        assert!(conserved(&tx, Some(parsed.key_id())).is_err());
        tx.outputs[0].assets.clear();
        tx.inputs[0]
            .assets
            .push(Eip12Asset::new("12".repeat(32), 1));
        assert!(conserved(&tx, Some(parsed.key_id())).is_err());
        tx.inputs[0].assets = vec![Eip12Asset::new(hex::encode(parsed.key_id()), 2)];
        assert!(conserved(&tx, Some(parsed.key_id())).is_err());
    }
}
