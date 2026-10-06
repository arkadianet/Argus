//! Turning a quoted arbitrage cycle into its chain of transactions, and the swap back
//! to ERG for a token a broken chain left behind. Pure: the caller fetches
//! pools and wallet boxes, nothing here touches the network.
//!
//! Each leg is an ordinary direct swap from the vendored builder (the same
//! one the Swap screen uses, Argus fee included) spending exactly one pool
//! box. Leg n+1 must spend the box leg n paid out: every input carrying the
//! token it sells comes from that leg, so if leg n never lands leg n+1 is
//! invalid too, instead of quietly selling tokens the wallet already held.
//! Transaction ids hash the unsigned transaction, so every leg's output ids
//! are known before anything is signed and the whole chain can be shown
//! and signed up front.
//!
//! Every built chain is checked before it is returned: each leg pays out
//! exactly what `wallet-amm` quoted, conserves ERG and every token, never
//! pays the inherited Citadel fee, and the wallet's ERG across all legs
//! moves by exactly the quoted net profit.

use std::collections::{HashMap, HashSet};

use amm::state::{AmmPool, SwapInput};
use ergo_lib::ergotree_ir::chain::ergo_box::{ErgoBox, NonMandatoryRegisterId};
use ergo_lib::ergotree_ir::mir::constant::Literal;
use ergo_tx::{Eip12InputBox, Eip12UnsignedTx};
use wallet_amm::{Opportunity, Pool, PoolError};

/// A pool box as `wallet-amm` sees it. Unlike the vendored parser, a box
/// without an `Int` fee numerator in R4 is refused: the contract reads it
/// with `.get`, so such a box can never be traded.
pub(crate) fn pool_from_box(b: &ErgoBox) -> Result<Pool, PoolError> {
    let fee = match b
        .additional_registers
        .get_constant(NonMandatoryRegisterId::R4)
    {
        Ok(Some(c)) => match c.v {
            Literal::Int(v) => Some(v as i64),
            _ => None,
        },
        _ => None,
    };
    Pool::from_box(b.box_id().to_string(), u64::from(b.value), &tokens(b), fee)
}

/// A pool as read moments ago: `wallet-amm`'s view for quoting, the
/// vendored view for the builder, and the box itself for signing.
#[derive(Clone)]
pub(crate) struct FreshPool {
    pub pool: Pool,
    pub amm: AmmPool,
    pub ergo_box: ErgoBox,
}

#[derive(Clone)]
pub(crate) struct BuiltLeg {
    pub unsigned: Eip12UnsignedTx,
    /// Inputs in input order: the pool box, then the wallet's boxes.
    pub inputs: Vec<ErgoBox>,
    /// Every output, with the id it will have once broadcast.
    pub outputs: Vec<ErgoBox>,
    pub tx_id: String,
    pub miner_fee: u64,
    pub app_fee: u64,
    /// This leg's change to the wallet's ERG.
    pub wallet_delta_nano: i64,
}

impl BuiltLeg {
    /// Outputs paid back to the wallet.
    pub fn wallet_outputs<'a>(
        &'a self,
        change_tree: &'a str,
    ) -> impl Iterator<Item = &'a ErgoBox> + 'a {
        self.outputs
            .iter()
            .filter(move |b| tree_hex(b) == change_tree)
    }
}

pub(crate) struct BuiltChain {
    pub legs: Vec<BuiltLeg>,
    pub wallet_delta_nano: i64,
}

pub(crate) fn eip12(b: &ErgoBox) -> Eip12InputBox {
    Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index)
}

pub(crate) fn id_of(b: &ErgoBox) -> String {
    b.box_id().to_string()
}

fn value(b: &ErgoBox) -> u64 {
    u64::from(b.value)
}

fn tree_hex(b: &ErgoBox) -> String {
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
    b.ergo_tree
        .sigma_serialize_bytes()
        .map(hex::encode)
        .unwrap_or_default()
}

fn tokens(b: &ErgoBox) -> Vec<(String, u64)> {
    b.tokens
        .as_ref()
        .map(|t| {
            t.iter()
                .map(|t| (hex::encode(t.token_id.as_ref()), u64::from(t.amount)))
                .collect()
        })
        .unwrap_or_default()
}

pub(crate) fn holds(b: &ErgoBox, token_id: &str) -> bool {
    tokens(b).iter().any(|(id, _)| id == token_id)
}

fn erg_only(b: &ErgoBox) -> bool {
    b.tokens.is_none()
}

fn build_err(msg: impl Into<String>) -> String {
    crate::error::ArgusError::TxBuildFailed(msg.into()).to_json_string()
}

/// A transaction's outputs as the boxes they become, with their real ids.
pub(crate) fn derive_outputs(tx: &Eip12UnsignedTx) -> Result<(String, Vec<ErgoBox>), String> {
    let unsigned = ergo_tx::chain::to_unsigned_transaction(tx).map_err(build_err)?;
    let tx_id = unsigned.id();
    let outputs = unsigned
        .output_candidates
        .iter()
        .enumerate()
        .map(|(i, c)| ErgoBox::from_box_candidate(c, tx_id, i as u16))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| build_err(format!("deriving outputs: {e}")))?;
    Ok((tx_id.to_string(), outputs))
}

/// Inputs and outputs carry the same ERG and the same amount of every token.
pub(crate) fn check_conserved(inputs: &[ErgoBox], outputs: &[ErgoBox]) -> Result<(), String> {
    let erg = |bs: &[ErgoBox]| bs.iter().map(|b| value(b) as u128).sum::<u128>();
    if erg(inputs) != erg(outputs) {
        return Err(build_err(format!(
            "leg moves {} nanoERG in and {} out",
            erg(inputs),
            erg(outputs)
        )));
    }
    let count = |bs: &[ErgoBox]| {
        let mut m: HashMap<String, u128> = HashMap::new();
        for (id, n) in bs.iter().flat_map(tokens) {
            *m.entry(id).or_default() += n as u128;
        }
        m
    };
    if count(inputs) != count(outputs) {
        return Err(build_err("leg does not conserve its tokens"));
    }
    Ok(())
}

/// The wallet boxes leg one may spend: ERG-only boxes, largest first, until
/// they cover the whole chain's capital, so later legs never run short of
/// fee money. Token boxes are only drawn on when ERG-only boxes cannot.
fn fund_first_leg(wallet: &[ErgoBox], capital: u64) -> Result<Vec<ErgoBox>, String> {
    let mut order: Vec<&ErgoBox> = wallet.iter().collect();
    order.sort_by(|a, b| erg_only(b).cmp(&erg_only(a)).then(value(b).cmp(&value(a))));
    let mut chosen = Vec::new();
    let mut total: u64 = 0;
    for b in order {
        if total >= capital {
            break;
        }
        total = total.saturating_add(value(b));
        chosen.push(b.clone());
    }
    if total < capital {
        // "needs … can use …" is the shape the mempool rules read to say
        // when funds still confirming would have covered the shortfall.
        return Err(build_err(format!(
            "NOT_ENOUGH_ERG: this trade needs {capital} nanoERG and the wallet can use {total}"
        )));
    }
    Ok(chosen)
}

/// The chain of transactions for `opp`, quoted against `pools` (one per
/// leg, in order). Refused when the wallet's ERG would move by less than
/// `min_profit_nano`.
pub(crate) fn build_chain(
    pools: &[FreshPool],
    opp: &Opportunity,
    wallet: &[ErgoBox],
    change_tree: &str,
    height: i32,
    min_profit_nano: i64,
) -> Result<BuiltChain, String> {
    if pools.len() != opp.legs.len() || opp.legs.len() < 2 {
        return Err(build_err(
            "a chain needs one fresh pool per leg and at least two legs",
        ));
    }
    let funding = fund_first_leg(wallet, opp.capital_nano)?;
    let mut spare: Vec<ErgoBox> = wallet
        .iter()
        .filter(|b| erg_only(b) && !funding.iter().any(|f| f.box_id() == b.box_id()))
        .cloned()
        .collect();
    let mut leftover: Vec<ErgoBox> = funding.clone();
    let mut carry: Vec<ErgoBox> = Vec::new();
    let mut legs: Vec<BuiltLeg> = Vec::with_capacity(opp.legs.len());

    for (i, (quoted, fresh)) in opp.legs.iter().zip(pools).enumerate() {
        if fresh.pool.pool_id != quoted.pool_id || id_of(&fresh.ergo_box) != quoted.box_id {
            return Err(build_err(format!(
                "leg {} was quoted on a different pool box",
                i + 1
            )));
        }
        let (input, candidates) = match &quoted.from_token_id {
            None if i == 0 => (
                SwapInput::Erg {
                    amount: quoted.amount_in,
                },
                funding.clone(),
            ),
            Some(token) if i > 0 => {
                // The token comes only from the previous leg; fees may also
                // come from untouched ERG-only boxes.
                let mut c = carry.clone();
                c.extend(
                    leftover
                        .iter()
                        .chain(&spare)
                        .filter(|b| erg_only(b))
                        .cloned(),
                );
                (
                    SwapInput::Token {
                        token_id: token.clone(),
                        amount: quoted.amount_in,
                    },
                    c,
                )
            }
            _ => {
                return Err(build_err(
                    "a chain starts with ERG and then sells what it bought",
                ))
            }
        };
        let eip12_candidates: Vec<Eip12InputBox> = candidates.iter().map(eip12).collect();
        let built = amm::direct_swap::build_direct_swap_eip12(
            &eip12(&fresh.ergo_box),
            &fresh.amm,
            &input,
            1,
            &eip12_candidates,
            change_tree,
            height,
            None,
            None,
        )
        .map_err(|e| build_err(format!("leg {}: {e}", i + 1)))?;
        if built.summary.output_amount != quoted.amount_out {
            return Err(build_err(format!(
                "leg {} would pay {} where {} was quoted",
                i + 1,
                built.summary.output_amount,
                quoted.amount_out
            )));
        }

        let by_id: HashMap<String, &ErgoBox> = candidates.iter().map(|b| (id_of(b), b)).collect();
        let mut inputs = vec![fresh.ergo_box.clone()];
        for input in built.unsigned_tx.inputs.iter().skip(1) {
            let b = by_id
                .get(&input.box_id)
                .ok_or_else(|| build_err(format!("leg {} spends an unknown box", i + 1)))?;
            inputs.push((*b).clone());
        }
        if i > 0 {
            let carried: HashSet<String> = carry.iter().map(id_of).collect();
            if !inputs.iter().skip(1).any(|b| carried.contains(&id_of(b))) {
                return Err(build_err(format!(
                    "leg {} does not spend what leg {i} paid out",
                    i + 1
                )));
            }
        }

        let (tx_id, outputs) = derive_outputs(&built.unsigned_tx)?;
        check_conserved(&inputs, &outputs)?;
        let trees: Vec<String> = built
            .unsigned_tx
            .outputs
            .iter()
            .map(|o| o.ergo_tree.clone())
            .collect();
        if crate::api_amm_impl::pays_citadel_dev_fee(&trees) {
            return Err(build_err("DEV_FEE_LEAK: a leg pays the Citadel dev fee"));
        }

        let spent: HashSet<String> = inputs.iter().skip(1).map(id_of).collect();
        let back: u64 = outputs
            .iter()
            .filter(|b| tree_hex(b) == change_tree)
            .map(value)
            .sum();
        let out: u64 = inputs.iter().skip(1).map(value).sum();
        leftover.retain(|b| !spent.contains(&id_of(b)));
        spare.retain(|b| !spent.contains(&id_of(b)));
        let leg = BuiltLeg {
            unsigned: built.unsigned_tx,
            inputs,
            tx_id,
            miner_fee: built.summary.miner_fee,
            app_fee: built.summary.citadel_fee_nano,
            wallet_delta_nano: back as i64 - out as i64,
            outputs,
        };
        carry = leg.wallet_outputs(change_tree).cloned().collect();
        legs.push(leg);
    }

    let wallet_delta_nano: i64 = legs.iter().map(|l| l.wallet_delta_nano).sum();
    if wallet_delta_nano != opp.net_profit_nano {
        return Err(build_err(format!(
            "the chain moves the wallet by {wallet_delta_nano} nanoERG, {} was quoted",
            opp.net_profit_nano
        )));
    }
    if wallet_delta_nano < min_profit_nano {
        return Err(crate::error::ArgusError::Generic(format!(
            "NOT_PROFITABLE: expected net profit {wallet_delta_nano} nanoERG is below your minimum {min_profit_nano}"
        ))
        .to_json_string());
    }
    Ok(BuiltChain {
        legs,
        wallet_delta_nano,
    })
}

/// What a stranded token's sale back to ERG spends and pays.
pub(crate) struct BuiltExit {
    pub unsigned: Eip12UnsignedTx,
    pub inputs: Vec<ErgoBox>,
    pub erg_out: u64,
    pub miner_fee: u64,
    pub app_fee: u64,
    pub change_erg: i64,
}

/// Sell `amount` of `token_id`, held in `stranded`, into `pool` for ERG.
/// Fees come from `fee_boxes`; only `stranded` may supply the token, so
/// the sale spends exactly what the broken chain left behind.
pub(crate) fn build_exit(
    pool: &FreshPool,
    stranded: &ErgoBox,
    token_id: &str,
    amount: u64,
    fee_boxes: &[ErgoBox],
    change_tree: &str,
    height: i32,
) -> Result<BuiltExit, String> {
    let mut candidates = vec![stranded.clone()];
    candidates.extend(
        fee_boxes
            .iter()
            .filter(|b| !holds(b, token_id) && b.box_id() != stranded.box_id())
            .cloned(),
    );
    let eip12_candidates: Vec<Eip12InputBox> = candidates.iter().map(eip12).collect();
    let input = SwapInput::Token {
        token_id: token_id.to_string(),
        amount,
    };
    let built = amm::direct_swap::build_direct_swap_eip12(
        &eip12(&pool.ergo_box),
        &pool.amm,
        &input,
        1,
        &eip12_candidates,
        change_tree,
        height,
        None,
        None,
    )
    .map_err(|e| build_err(e.to_string()))?;
    let by_id: HashMap<String, &ErgoBox> = candidates.iter().map(|b| (id_of(b), b)).collect();
    let mut inputs = vec![pool.ergo_box.clone()];
    for input in built.unsigned_tx.inputs.iter().skip(1) {
        let b = by_id
            .get(&input.box_id)
            .ok_or_else(|| build_err("the sale spends an unknown box"))?;
        inputs.push((*b).clone());
    }
    if !inputs.iter().any(|b| b.box_id() == stranded.box_id()) {
        return Err(build_err("the sale does not spend the stranded box"));
    }
    let (_, outputs) = derive_outputs(&built.unsigned_tx)?;
    check_conserved(&inputs, &outputs)?;
    let trees: Vec<String> = built
        .unsigned_tx
        .outputs
        .iter()
        .map(|o| o.ergo_tree.clone())
        .collect();
    if crate::api_amm_impl::pays_citadel_dev_fee(&trees) {
        return Err(build_err("DEV_FEE_LEAK: the sale pays the Citadel dev fee"));
    }
    let change_erg = outputs
        .iter()
        .filter(|b| tree_hex(b) == change_tree)
        .map(|b| value(b) as i64)
        .max()
        .unwrap_or(0);
    Ok(BuiltExit {
        erg_out: built.summary.output_amount,
        miner_fee: built.summary.miner_fee,
        app_fee: built.summary.citadel_fee_nano,
        change_erg,
        unsigned: built.unsigned_tx,
        inputs,
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::str::FromStr;

    use ergo_lib::ergo_chain_types::Digest32;
    use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
    use ergo_lib::ergotree_ir::chain::ergo_box::{
        BoxId, BoxTokens, NonMandatoryRegisterId, NonMandatoryRegisters,
    };
    use ergo_lib::ergotree_ir::chain::token::{Token, TokenAmount, TokenId};
    use ergo_lib::ergotree_ir::chain::tx_id::TxId;
    use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
    use ergo_lib::ergotree_ir::mir::constant::Constant;
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
    use ergo_tx::DevFeeConfig;
    use wallet_amm::contract::{LP_EMISSION, N2T_POOL_TREE};
    use wallet_amm::{
        price_book, requote, scan, ArbOptions, Asset, Costs, PricingOptions, RouteStep,
    };

    use crate::api::{ARGUS_FEE_ADDRESS, ARGUS_FEE_NANO};

    pub(crate) const USER_TREE: &str =
        "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    const ERG: u64 = 1_000_000_000;

    fn hex32(byte: u8) -> String {
        hex::encode([byte; 32])
    }

    fn tree(hex_str: &str) -> ErgoTree {
        ErgoTree::sigma_parse_bytes(&hex::decode(hex_str).unwrap()).unwrap()
    }

    fn token(byte: u8, amount: u64) -> Token {
        Token {
            token_id: TokenId::from(BoxId::from_str(&hex32(byte)).unwrap()),
            amount: TokenAmount::try_from(amount).unwrap(),
        }
    }

    fn ergo_box(
        value: u64,
        tree_hex: &str,
        tokens: Vec<Token>,
        r4: Option<i32>,
        tx_byte: u8,
        index: u16,
    ) -> ErgoBox {
        let regs = match r4 {
            Some(f) => {
                NonMandatoryRegisters::new([(NonMandatoryRegisterId::R4, Constant::from(f))])
                    .unwrap()
            }
            None => NonMandatoryRegisters::empty(),
        };
        ErgoBox::new(
            BoxValue::try_from(value).unwrap(),
            tree(tree_hex),
            if tokens.is_empty() {
                None
            } else {
                Some(BoxTokens::from_vec(tokens).unwrap())
            },
            regs,
            1_000_000,
            TxId(Digest32::try_from(hex32(tx_byte)).unwrap()),
            index,
        )
        .unwrap()
    }

    /// An N2T pool box for token `tok`, with `lp_out` LP units circulating.
    fn pool_box(nft: u8, erg: u64, tok: u8, amount: u64) -> FreshPool {
        let b = ergo_box(
            erg,
            N2T_POOL_TREE,
            vec![
                token(nft, 1),
                token(nft + 1, LP_EMISSION - 10_000),
                token(tok, amount),
            ],
            Some(997),
            nft,
            0,
        );
        FreshPool {
            pool: super::pool_from_box(&b).unwrap(),
            amm: crate::api_amm_impl::parse_pool_box(&b).unwrap(),
            ergo_box: b,
        }
    }

    fn wallet(values: &[u64]) -> Vec<ErgoBox> {
        values
            .iter()
            .enumerate()
            .map(|(i, v)| ergo_box(*v, USER_TREE, vec![], None, 0xa0, i as u16))
            .collect()
    }

    fn costs() -> Costs {
        Costs {
            miner_fee_nano: 1_100_000,
            app_fee_nano: ARGUS_FEE_NANO as u64,
            box_min_nano: 1_000_000,
        }
    }

    pub(crate) fn argus_fee() -> DevFeeConfig {
        DevFeeConfig::custom(
            wallet_net::client::address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap(),
            ARGUS_FEE_NANO,
        )
    }

    /// Two pools pricing token 0x33 at 100 and 120 nanoERG per unit.
    pub(crate) fn skewed() -> Vec<FreshPool> {
        vec![
            pool_box(0x10, 1_000 * ERG, 0x33, 10_000_000_000),
            pool_box(0x20, 1_200 * ERG, 0x33, 10_000_000_000),
        ]
    }

    pub(crate) fn best_opportunity(pools: &[FreshPool], available: u64) -> Opportunity {
        let ps: Vec<Pool> = pools.iter().map(|p| p.pool.clone()).collect();
        let book = price_book(
            &ps,
            &PricingOptions {
                min_depth_nano: 50 * ERG,
                trusted: HashSet::new(),
            },
        );
        let s = scan(
            &ps,
            &book,
            &ArbOptions {
                max_legs: 3,
                min_depth_nano: 50 * ERG,
                costs: costs(),
                min_net_profit_nano: 0,
                available_nano: Some(available),
                trusted: HashSet::new(),
                include_untrusted: true,
                busy_boxes: HashSet::new(),
                max_results: 5,
            },
        );
        s.opportunities.into_iter().next().expect("an opportunity")
    }

    pub(crate) fn in_route_order(pools: &[FreshPool], opp: &Opportunity) -> Vec<FreshPool> {
        opp.legs
            .iter()
            .map(|l| {
                pools
                    .iter()
                    .find(|p| p.pool.pool_id == l.pool_id)
                    .unwrap()
                    .clone()
            })
            .collect()
    }

    /// Every leg conserves ERG and tokens, chains onto the previous leg,
    /// pays what was quoted, and the wallet ends exactly the quoted net
    /// profit richer: pool fees, miner fees, the Argus fee on every leg and
    /// the box minimum all accounted for.
    #[test]
    fn a_chain_conserves_value_and_lands_the_quoted_profit() {
        ergo_tx::with_test_dev_fee(argus_fee(), || {
            let pools = skewed();
            let opp = best_opportunity(&pools, 100 * ERG);
            let route = in_route_order(&pools, &opp);
            let funds = wallet(&[60 * ERG, 40 * ERG]);
            let chain = build_chain(&route, &opp, &funds, USER_TREE, 1_000_100, 0).unwrap();

            assert_eq!(chain.legs.len(), 2);
            assert_eq!(chain.wallet_delta_nano, opp.net_profit_nano);
            assert!(chain.wallet_delta_nano > 0);

            // Independent box accounting: replay every leg over the wallet.
            let mut held: Vec<ErgoBox> = funds.clone();
            for leg in &chain.legs {
                check_conserved(&leg.inputs, &leg.outputs).unwrap();
                let spent: HashSet<String> = leg.inputs.iter().skip(1).map(id_of).collect();
                assert!(
                    spent.iter().all(|id| held.iter().any(|b| &id_of(b) == id)),
                    "spends only what the wallet holds"
                );
                held.retain(|b| !spent.contains(&id_of(b)));
                held.extend(leg.wallet_outputs(USER_TREE).cloned());
                assert_eq!(leg.miner_fee, 1_100_000);
                assert_eq!(leg.app_fee, ARGUS_FEE_NANO as u64);
            }
            let before: u64 = funds.iter().map(value).sum();
            let after: u64 = held.iter().map(value).sum();
            assert_eq!(after as i64 - before as i64, opp.net_profit_nano);
            assert!(
                held.iter().all(|b| b.tokens.is_none()),
                "no token left behind"
            );

            // Leg 2 spends leg 1's payout by its precomputed id.
            let paid: HashSet<String> =
                chain.legs[0].wallet_outputs(USER_TREE).map(id_of).collect();
            assert!(chain.legs[1]
                .inputs
                .iter()
                .any(|b| paid.contains(&id_of(b))));
            assert_eq!(opp.legs[0].amount_out, opp.legs[1].amount_in);
            // The precomputed ids are the real ones.
            let (tx_id, outputs) = derive_outputs(&chain.legs[0].unsigned).unwrap();
            assert_eq!(tx_id, chain.legs[0].tx_id);
            assert_eq!(
                outputs.iter().map(id_of).collect::<Vec<_>>(),
                chain.legs[0].outputs.iter().map(id_of).collect::<Vec<_>>()
            );
            // Each leg pays the miner and the Argus fee address.
            let fee_tree = argus_fee().recipient_ergo_tree;
            for leg in &chain.legs {
                assert_eq!(
                    leg.unsigned
                        .outputs
                        .iter()
                        .filter(|o| o.ergo_tree == fee_tree)
                        .count(),
                    1
                );
            }
        });
    }

    #[test]
    fn a_chain_below_the_minimum_profit_is_refused() {
        ergo_tx::with_test_dev_fee(argus_fee(), || {
            let pools = skewed();
            let opp = best_opportunity(&pools, 100 * ERG);
            let route = in_route_order(&pools, &opp);
            let err = build_chain(
                &route,
                &opp,
                &wallet(&[100 * ERG]),
                USER_TREE,
                1_000_100,
                opp.net_profit_nano + 1,
            )
            .err()
            .expect("refused");
            assert!(err.contains("NOT_PROFITABLE"), "{err}");
            // At exactly the minimum it builds.
            assert!(build_chain(
                &route,
                &opp,
                &wallet(&[100 * ERG]),
                USER_TREE,
                1_000_100,
                opp.net_profit_nano
            )
            .is_ok());
        });
    }

    /// A pool that moved before signing re-quotes below the minimum and is
    /// refused before anything is built.
    #[test]
    fn a_moved_pool_is_refused_at_requote() {
        let pools = skewed();
        let opp = best_opportunity(&pools, 100 * ERG);
        let steps: Vec<RouteStep> = opp
            .legs
            .iter()
            .map(|l| RouteStep {
                pool_id: l.pool_id.clone(),
                from: Asset::from_token_id(l.from_token_id.as_deref()),
                to: Asset::from_token_id(l.to_token_id.as_deref()),
            })
            .collect();
        // Someone bought from the cheap pool first: its price caught up.
        let moved = vec![
            pool_box(0x10, 1_150 * ERG, 0x33, 8_700_000_000).pool,
            pools[1].pool.clone(),
        ];
        let err = requote(
            &moved,
            &steps,
            Some(opp.input_nano),
            u64::MAX,
            &costs(),
            1_000_000,
        )
        .unwrap_err();
        assert!(
            matches!(err, wallet_amm::RouteError::NotProfitable { .. }),
            "{err}"
        );
    }

    #[test]
    fn a_wallet_too_small_for_the_whole_chain_is_refused_up_front() {
        ergo_tx::with_test_dev_fee(argus_fee(), || {
            let pools = skewed();
            let opp = best_opportunity(&pools, 100 * ERG);
            let route = in_route_order(&pools, &opp);
            let err = build_chain(
                &route,
                &opp,
                &wallet(&[opp.capital_nano - 1]),
                USER_TREE,
                1_000_100,
                0,
            )
            .err()
            .expect("refused");
            assert!(err.contains("NOT_ENOUGH_ERG"), "{err}");
        });
    }

    /// The token the wallet already held is never sold by a later leg in
    /// place of what the first leg bought.
    #[test]
    fn later_legs_sell_only_what_the_chain_bought() {
        ergo_tx::with_test_dev_fee(argus_fee(), || {
            let pools = skewed();
            let opp = best_opportunity(&pools, 100 * ERG);
            let route = in_route_order(&pools, &opp);
            let mut funds = wallet(&[100 * ERG]);
            funds.push(ergo_box(
                5 * ERG,
                USER_TREE,
                vec![token(0x33, 10_000_000_000)],
                None,
                0xb0,
                0,
            ));
            let chain = build_chain(&route, &opp, &funds, USER_TREE, 1_000_100, 0).unwrap();
            let held_id = id_of(&funds[1]);
            assert!(chain
                .legs
                .iter()
                .all(|l| l.inputs.iter().all(|b| id_of(b) != held_id)));
        });
    }

    /// Leg 2's pool moved before it landed: the wallet holds leg 1's token
    /// in leg 1's payout box. The way back sells exactly that box's token
    /// into the best pool at its current state, conserving everything, and
    /// pays the ERG it was quoted.
    #[test]
    fn a_stranded_token_is_sold_back_from_the_box_leg_one_paid_out() {
        ergo_tx::with_test_dev_fee(argus_fee(), || {
            let pools = skewed();
            let opp = best_opportunity(&pools, 100 * ERG);
            let route = in_route_order(&pools, &opp);
            let funds = wallet(&[100 * ERG, 3 * ERG]);
            let chain = build_chain(&route, &opp, &funds, USER_TREE, 1_000_100, 0).unwrap();

            // Leg 1 landed, leg 2 did not.
            let statuses = [
                wallet_amm::LegStatus::Pending,
                wallet_amm::LegStatus::NotSubmitted,
            ];
            let wallet_amm::ChainState::Stranded { failed_leg } = wallet_amm::classify(&statuses)
            else {
                panic!("stranded expected")
            };
            let (token_id, amount) = wallet_amm::stranded_holding(&opp.legs, failed_leg).unwrap();
            assert_eq!(token_id, hex32(0x33));
            let stranded = chain.legs[0]
                .wallet_outputs(USER_TREE)
                .find(|b| holds(b, &token_id))
                .unwrap()
                .clone();

            // The pools as they are now: the cheap pool moved by our own
            // leg 1; the dear pool was taken by someone else.
            let after_leg1 = chain.legs[0].outputs[0].clone();
            let cheap_now = FreshPool {
                pool: super::pool_from_box(&after_leg1).unwrap(),
                amm: crate::api_amm_impl::parse_pool_box(&after_leg1).unwrap(),
                ergo_box: after_leg1,
            };
            let dear_now = pool_box(0x20, 1_020 * ERG, 0x33, 11_760_000_000);
            let exit = wallet_amm::best_exit(
                &[cheap_now.pool.clone(), dear_now.pool.clone()],
                &token_id,
                amount,
            )
            .unwrap();
            let exit_pool = if exit.pool_id == cheap_now.pool.pool_id {
                &cheap_now
            } else {
                &dear_now
            };

            let fee_boxes: Vec<ErgoBox> = funds
                .iter()
                .filter(|b| {
                    !chain.legs[0]
                        .inputs
                        .iter()
                        .any(|i| i.box_id() == b.box_id())
                })
                .cloned()
                .collect();
            let sale = build_exit(
                exit_pool, &stranded, &token_id, amount, &fee_boxes, USER_TREE, 1_000_101,
            )
            .unwrap();
            assert_eq!(sale.erg_out, exit.erg_out_nano);
            assert!(sale.inputs.iter().any(|b| b.box_id() == stranded.box_id()));
            let (_, outputs) = derive_outputs(&sale.unsigned).unwrap();
            check_conserved(&sale.inputs, &outputs).unwrap();
            // Every unit of the stranded token goes back to a pool.
            let to_wallet: u64 = outputs
                .iter()
                .filter(|b| tree_hex(b) == USER_TREE)
                .flat_map(tokens)
                .filter(|(id, _)| id == &token_id)
                .map(|(_, n)| n)
                .sum();
            assert_eq!(to_wallet, 0);
            assert_eq!(sale.app_fee, ARGUS_FEE_NANO as u64);
            // Recovering costs money: back with less ERG than went in.
            assert!((sale.erg_out as i64) < opp.input_nano as i64);
        });
    }

    /// The contract reads the fee with `R4.get`, so a box without it can
    /// never be traded; the vendored parser assumes 997 and would price it.
    #[test]
    fn a_pool_box_without_a_fee_register_is_not_a_pool() {
        let b = ergo_box(
            100 * ERG,
            N2T_POOL_TREE,
            vec![token(1, 1), token(2, 5), token(3, 9)],
            None,
            1,
            0,
        );
        assert_eq!(
            super::pool_from_box(&b),
            Err(wallet_amm::PoolError::MissingFee)
        );
        assert_eq!(
            crate::api_amm_impl::parse_pool_box(&b).unwrap().fee_num,
            997
        );
        let with_fee = ergo_box(
            100 * ERG,
            N2T_POOL_TREE,
            vec![token(1, 1), token(2, 5), token(3, 9)],
            Some(995),
            1,
            0,
        );
        assert_eq!(super::pool_from_box(&with_fee).unwrap().fee_num, 995);
    }

    #[test]
    fn a_route_must_start_with_erg() {
        ergo_tx::with_test_dev_fee(argus_fee(), || {
            let pools = skewed();
            let mut opp = best_opportunity(&pools, 100 * ERG);
            let route = in_route_order(&pools, &opp);
            opp.legs[0].from_token_id = Some(hex32(0x33));
            assert!(build_chain(&route, &opp, &wallet(&[100 * ERG]), USER_TREE, 1, 0).is_err());
        });
    }
}
