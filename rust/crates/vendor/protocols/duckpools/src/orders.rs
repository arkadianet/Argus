//! Lend and withdraw orders: the quote, the proxy box, the transaction that
//! posts it, the refund that takes it back, and what became of it.
//!
//! The proxy contracts (`proxyLend.md`, `proxyWithdraw.md`, and the token
//! pools' `deposit.md` / `withdraw.md`) accept two spends: a fill, where
//! `OUTPUTS(2)` pays the user at least `R5` with `R7 = SELF.id`, and a
//! refund after height `R6`, where `OUTPUTS(0)` pays the user everything
//! but one transaction fee with `R4 = SELF.id`. Neither needs a signature,
//! so a bot can fill and anyone can refund, but only ever to the user.

use std::collections::HashMap;

use ergo_tx::{Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};

use crate::encode;
use crate::fees::{service_fee, split_for_deposit};
use crate::state::{PoolState, PoolsError};
use crate::{Pool, MIN_BOX_VALUE, TX_FEE};

/// The box an order posts.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ProxyBox {
    pub ergo_tree: String,
    pub value: i64,
    pub assets: Vec<Eip12Asset>,
    pub registers: HashMap<String, String>,
}

impl ProxyBox {
    pub fn output(&self, height: i32) -> Eip12Output {
        Eip12Output {
            value: self.value.to_string(),
            ergo_tree: self.ergo_tree.clone(),
            assets: self.assets.clone(),
            creation_height: height,
            additional_registers: self.registers.clone(),
        }
    }
}

fn tree_of(address: &str) -> Result<String, PoolsError> {
    ergo_tx::address_to_ergo_tree(address).map_err(|e| PoolsError::Serialization(e.to_string()))
}

fn with_slippage(amount: i64, slippage_bps: i64) -> i64 {
    let bps = slippage_bps.clamp(0, 10_000) as i128;
    (amount as i128 * (10_000 - bps) / 10_000) as i64
}

/// What a lend order will do, before it is posted.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct LendQuote {
    pub pool: &'static str,
    /// Asset units the user puts in, service fee included.
    pub amount: i64,
    /// The protocol's cut of `amount`.
    pub service_fee: i64,
    /// What reaches the pool.
    pub to_pool: i64,
    /// Lend tokens the bot would mint for `to_pool` at today's price, less
    /// the one it keeps for rounding.
    pub lend_tokens_expected: i64,
    /// The least the order accepts (`R5`).
    pub min_lend_tokens: i64,
    /// nanoERG the proxy box carries: the deposit for the ERG pool, plus
    /// the bot's fee box and the fill's transaction fee.
    pub box_value: i64,
    /// Height after which the order can be refunded (`R6`).
    pub refund_height: i64,
}

impl LendQuote {
    pub fn new(
        pool: &'static Pool,
        state: &PoolState,
        amount: i64,
        slippage_bps: i64,
        refund_height: i64,
    ) -> Result<Self, PoolsError> {
        if amount <= 0 {
            return Err(PoolsError::Serialization("amount must be positive".into()));
        }
        let (to_pool, fee) = split_for_deposit(pool, amount);
        if to_pool <= 0 {
            return Err(PoolsError::Serialization(
                "amount is smaller than the minimum service fee".into(),
            ));
        }
        // The bot hands the user one token fewer than the pool's own
        // arithmetic mints, as a rounding guard.
        let expected = (state.tokens_for_deposit(to_pool) - 1).max(0);
        if expected <= 0 {
            return Err(PoolsError::Serialization(
                "amount too small to mint a lend token".into(),
            ));
        }
        let box_value = if pool.is_erg() {
            amount + 2 * MIN_BOX_VALUE + TX_FEE
        } else {
            2 * MIN_BOX_VALUE + TX_FEE
        };
        Ok(Self {
            pool: pool.key,
            amount,
            service_fee: fee,
            to_pool,
            lend_tokens_expected: expected,
            min_lend_tokens: with_slippage(expected, slippage_bps).max(1),
            box_value,
            refund_height,
        })
    }

    /// The proxy box, paying to `user_tree` when filled or refunded.
    pub fn proxy_box(&self, pool: &Pool, user_tree_hex: &str) -> Result<ProxyBox, PoolsError> {
        let user =
            hex::decode(user_tree_hex).map_err(|e| PoolsError::Serialization(e.to_string()))?;
        let mut registers = HashMap::new();
        registers.insert("R4".into(), encode::coll_byte(&user)?);
        registers.insert("R5".into(), encode::long(self.min_lend_tokens)?);
        registers.insert("R6".into(), encode::long(self.refund_height)?);
        let mut assets = Vec::new();
        if let Some(currency) = pool.currency_id {
            // A token pool's deposit proxy names the lend token in R7 and
            // carries the deposit as tokens.
            registers.insert(
                "R7".into(),
                encode::coll_byte(
                    &hex::decode(pool.lend_token)
                        .map_err(|e| PoolsError::Serialization(e.to_string()))?,
                )?,
            );
            assets.push(Eip12Asset {
                token_id: currency.to_string(),
                amount: self.amount.to_string(),
            });
        }
        Ok(ProxyBox {
            ergo_tree: tree_of(pool.lend_proxy_address)?,
            value: self.box_value,
            assets,
            registers,
        })
    }
}

/// What a withdraw order will do, before it is posted.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct WithdrawQuote {
    pub pool: &'static str,
    /// Lend tokens handed in.
    pub lend_tokens: i64,
    /// Asset units those tokens are worth in the pool today, as the bot
    /// computes it (the pool keeps one unit and, for ERG, the fill's fee).
    pub entitled: i64,
    pub service_fee: i64,
    /// What the user receives at today's price.
    pub out: i64,
    /// The least the order accepts (`R5`).
    pub min_out: i64,
    pub box_value: i64,
    pub refund_height: i64,
}

impl WithdrawQuote {
    pub fn new(
        pool: &'static Pool,
        state: &PoolState,
        lend_tokens: i64,
        slippage_bps: i64,
        refund_height: i64,
    ) -> Result<Self, PoolsError> {
        if lend_tokens <= 0 || lend_tokens > state.lend_circulating {
            return Err(PoolsError::Serialization(
                "lend token amount is out of range".into(),
            ));
        }
        let circ = state.lend_circulating as i128;
        let total = state.total_assets();
        let after = circ - lend_tokens as i128;
        // The bot keeps ceil(after × total / circ − borrowed) + 1 in the pool.
        let num = after * total;
        let kept_assets = (num + circ - 1) / circ - state.borrowed as i128 + 1;
        let mut entitled = state.pooled as i128 - kept_assets;
        if pool.is_erg() {
            entitled -= TX_FEE as i128;
        }
        if entitled <= 0 {
            return Err(PoolsError::Serialization(
                "too few lend tokens to withdraw anything".into(),
            ));
        }
        let entitled = entitled as i64;
        let fee = service_fee(pool, entitled);
        let out = entitled - fee;
        if out <= 0 {
            return Err(PoolsError::Serialization(
                "the service fee would consume the withdrawal".into(),
            ));
        }
        Ok(Self {
            pool: pool.key,
            lend_tokens,
            entitled,
            service_fee: fee,
            out,
            min_out: with_slippage(out, slippage_bps).max(1),
            box_value: 2 * MIN_BOX_VALUE + TX_FEE,
            refund_height,
        })
    }

    pub fn proxy_box(&self, pool: &Pool, user_tree_hex: &str) -> Result<ProxyBox, PoolsError> {
        let user =
            hex::decode(user_tree_hex).map_err(|e| PoolsError::Serialization(e.to_string()))?;
        let mut registers = HashMap::new();
        registers.insert("R4".into(), encode::coll_byte(&user)?);
        registers.insert("R5".into(), encode::long(self.min_out)?);
        registers.insert("R6".into(), encode::long(self.refund_height)?);
        Ok(ProxyBox {
            ergo_tree: tree_of(pool.withdraw_proxy_address)?,
            value: self.box_value,
            assets: vec![Eip12Asset {
                token_id: pool.lend_token.to_string(),
                amount: self.lend_tokens.to_string(),
            }],
            registers,
        })
    }
}

fn parse_amount(s: &str) -> Result<i64, PoolsError> {
    s.parse()
        .map_err(|_| PoolsError::Serialization(format!("bad amount {s:?}")))
}

/// The transaction that posts `proxy` from the wallet's `inputs`: the
/// proxy box, the app fee if any, change with every leftover token, and
/// the miner fee. Fails rather than build a change box below the minimum.
pub fn build_order_tx(
    proxy: &ProxyBox,
    inputs: &[Eip12InputBox],
    change_tree: &str,
    app_fee: Option<(&str, i64)>,
    miner_fee: i64,
    height: i32,
) -> Result<Eip12UnsignedTx, PoolsError> {
    if inputs.is_empty() {
        return Err(PoolsError::Serialization("no inputs".into()));
    }
    let mut total: i64 = 0;
    let mut tokens: HashMap<String, i64> = HashMap::new();
    for b in inputs {
        total = total
            .checked_add(parse_amount(&b.value)?)
            .ok_or_else(|| PoolsError::Serialization("input value overflows".into()))?;
        for a in &b.assets {
            *tokens.entry(a.token_id.clone()).or_default() += parse_amount(&a.amount)?;
        }
    }
    for a in &proxy.assets {
        let have = tokens.get(&a.token_id).copied().unwrap_or(0);
        let need = parse_amount(&a.amount)?;
        if have < need {
            return Err(PoolsError::Serialization(format!(
                "inputs hold {have} of {} but the order needs {need}",
                a.token_id
            )));
        }
        tokens.insert(a.token_id.clone(), have - need);
    }
    let app_fee_nano = app_fee.map(|(_, n)| n).unwrap_or(0);
    let spend = proxy.value + app_fee_nano + miner_fee;
    if total < spend {
        return Err(PoolsError::Serialization(format!(
            "inputs hold {total} nanoERG but the order needs {spend}"
        )));
    }
    let change = total - spend;
    let change_tokens: Vec<Eip12Asset> = tokens
        .into_iter()
        .filter(|(_, n)| *n > 0)
        .map(|(id, n)| Eip12Asset {
            token_id: id,
            amount: n.to_string(),
        })
        .collect();
    if (change > 0 && change < MIN_BOX_VALUE) || (change == 0 && !change_tokens.is_empty()) {
        return Err(PoolsError::Serialization(
            "change would be below the minimum box value; add an input or adjust the amount".into(),
        ));
    }
    let mut outputs = vec![proxy.output(height)];
    if let Some((tree, n)) = app_fee {
        if n > 0 {
            outputs.push(Eip12Output::simple(n, tree, height));
        }
    }
    if change > 0 {
        outputs.push(Eip12Output {
            value: change.to_string(),
            ergo_tree: change_tree.to_string(),
            assets: change_tokens,
            creation_height: height,
            additional_registers: HashMap::new(),
        });
    }
    outputs.push(Eip12Output::fee(miner_fee, height));
    Ok(Eip12UnsignedTx {
        inputs: inputs.to_vec(),
        data_inputs: Vec::new(),
        outputs,
    })
}

/// Take an unfilled order back after its refund height: everything in the
/// proxy box less one contract fee goes to the user, with `R4 = SELF.id`
/// as the contract demands. The fee is fixed by the contract.
pub fn build_refund_tx(
    proxy: &Eip12InputBox,
    user_tree: &str,
    height: i32,
) -> Result<Eip12UnsignedTx, PoolsError> {
    let value = parse_amount(&proxy.value)? - TX_FEE;
    if value < MIN_BOX_VALUE {
        return Err(PoolsError::Serialization(
            "proxy box too small to refund".into(),
        ));
    }
    let mut registers = HashMap::new();
    registers.insert("R4".into(), encode::box_id_register(&proxy.box_id)?);
    Ok(Eip12UnsignedTx {
        inputs: vec![proxy.clone()],
        data_inputs: Vec::new(),
        outputs: vec![
            Eip12Output {
                value: value.to_string(),
                ergo_tree: user_tree.to_string(),
                assets: proxy.assets.clone(),
                creation_height: height,
                additional_registers: registers,
            },
            Eip12Output::fee(TX_FEE, height),
        ],
    })
}

/// What a transaction that spent a proxy box did with it.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum OrderOutcome {
    /// A bot filled it: this output is the user's, with `R7 = proxy id`.
    Filled { value: i64, assets: Vec<Eip12Asset> },
    /// It was refunded: this output is the user's, with `R4 = proxy id`.
    Refunded { value: i64, assets: Vec<Eip12Asset> },
    /// The transaction spent the box some other way (it should not be
    /// able to) or is not about this box.
    Unknown,
}

/// Classify the transaction that spent `proxy_box_id` from its outputs
/// (explorer or node shape).
pub fn classify_spend(
    proxy_box_id: &str,
    tx: &serde_json::Value,
) -> Result<OrderOutcome, PoolsError> {
    let marker = encode::box_id_register(proxy_box_id)?;
    let outputs = tx
        .get("outputs")
        .and_then(|o| o.as_array())
        .ok_or_else(|| PoolsError::Serialization("transaction has no outputs".into()))?;
    let reg = |o: &serde_json::Value, name: &str| -> Option<String> {
        let r = o.get("additionalRegisters")?.get(name)?;
        r.as_str().map(str::to_string).or_else(|| {
            r.get("serializedValue")
                .and_then(|s| s.as_str())
                .map(str::to_string)
        })
    };
    let assets_of = |o: &serde_json::Value| -> Vec<Eip12Asset> {
        o.get("assets")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|t| {
                        Some(Eip12Asset {
                            token_id: t.get("tokenId")?.as_str()?.to_string(),
                            amount: t.get("amount").and_then(|x| {
                                x.as_i64()
                                    .map(|n| n.to_string())
                                    .or_else(|| x.as_str().map(str::to_string))
                            })?,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    };
    let value_of = |o: &serde_json::Value| -> i64 {
        o.get("value")
            .and_then(|x| {
                x.as_i64()
                    .or_else(|| x.as_str().and_then(|s| s.parse().ok()))
            })
            .unwrap_or(0)
    };
    // Explorer and node may differ in hex case; the marker follows the
    // caller's.
    let same = |r: Option<String>| r.map(|h| h.eq_ignore_ascii_case(&marker)).unwrap_or(false);
    for o in outputs {
        if same(reg(o, "R7")) {
            return Ok(OrderOutcome::Filled {
                value: value_of(o),
                assets: assets_of(o),
            });
        }
    }
    for o in outputs {
        if same(reg(o, "R4")) {
            return Ok(OrderOutcome::Refunded {
                value: value_of(o),
                assets: assets_of(o),
            });
        }
    }
    Ok(OrderOutcome::Unknown)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::POOLS;

    fn erg_state() -> PoolState {
        let v: serde_json::Value =
            serde_json::from_str(include_str!("../test/fixtures/pool_erg.json")).unwrap();
        PoolState::parse(&POOLS[0], &v).unwrap()
    }

    fn sigusd_state() -> PoolState {
        let v: serde_json::Value =
            serde_json::from_str(include_str!("../test/fixtures/pool_sigusd.json")).unwrap();
        PoolState::parse(&POOLS[1], &v).unwrap()
    }

    const USER: &str = "0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582";

    fn input(value: i64, assets: Vec<(&str, i64)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: "11".repeat(32),
            transaction_id: "22".repeat(32),
            index: 0,
            value: value.to_string(),
            ergo_tree: USER.into(),
            assets: assets
                .into_iter()
                .map(|(id, n)| Eip12Asset {
                    token_id: id.into(),
                    amount: n.to_string(),
                })
                .collect(),
            creation_height: 1,
            additional_registers: HashMap::new(),
            extension: HashMap::new(),
        }
    }

    #[test]
    fn a_lend_quote_matches_what_the_bot_would_do() {
        let pool = &POOLS[0];
        let s = erg_state();
        let q = LendQuote::new(pool, &s, 1_000_000_000, 100, 1_900_000).unwrap();
        assert_eq!(q.to_pool + q.service_fee, q.amount);
        assert!(
            q.service_fee >= 6_000_000 && q.service_fee <= 6_300_000,
            "{}",
            q.service_fee
        );
        assert_eq!(q.lend_tokens_expected, s.tokens_for_deposit(q.to_pool) - 1);
        assert_eq!(q.min_lend_tokens, q.lend_tokens_expected * 99 / 100);
        assert_eq!(q.box_value, 1_000_000_000 + 3_000_000);
        let p = q.proxy_box(pool, USER).unwrap();
        assert_eq!(p.registers["R4"], format!("0e24{USER}"));
        assert_eq!(p.registers["R6"], encode::long(1_900_000).unwrap());
        assert!(
            p.assets.is_empty(),
            "the ERG pool's deposit is the box value"
        );
        assert_eq!(p.ergo_tree, tree_of(pool.lend_proxy_address).unwrap());
        assert!(
            LendQuote::new(pool, &s, 1_000, 100, 1).is_err(),
            "below the minimum fee"
        );
    }

    #[test]
    fn a_token_pool_lend_carries_the_deposit_as_tokens_and_names_the_lend_token() {
        let pool = &POOLS[1];
        let s = sigusd_state();
        let q = LendQuote::new(pool, &s, 10_000, 50, 1_900_000).unwrap();
        assert_eq!(q.box_value, 3_000_000);
        let p = q.proxy_box(pool, USER).unwrap();
        assert_eq!(p.assets.len(), 1);
        assert_eq!(p.assets[0].token_id, pool.currency_id.unwrap());
        assert_eq!(p.assets[0].amount, "10000");
        assert_eq!(p.registers["R7"], format!("0e20{}", pool.lend_token));
    }

    #[test]
    fn a_withdraw_quote_returns_about_the_deposit_less_two_fees() {
        let pool = &POOLS[0];
        let s = erg_state();
        let deposit = 10_000_000_000;
        let lend = LendQuote::new(pool, &s, deposit, 0, 1).unwrap();
        // Pretend the deposit was filled: the pool grew and we hold the tokens.
        let grown = PoolState {
            pooled: s.pooled + lend.to_pool,
            lend_circulating: s.lend_circulating + lend.lend_tokens_expected + 1,
            ..s.clone()
        };
        let w = WithdrawQuote::new(pool, &grown, lend.lend_tokens_expected, 0, 1).unwrap();
        let round_trip_loss = deposit - w.out;
        assert!(round_trip_loss > 0);
        // Two service fees, one contract fee, and a few nanoERG of rounding.
        let two_fees = lend.service_fee + w.service_fee + TX_FEE;
        assert!(
            round_trip_loss >= two_fees && round_trip_loss < two_fees + 1_000,
            "{round_trip_loss} vs {two_fees}"
        );
        let p = w.proxy_box(pool, USER).unwrap();
        assert_eq!(p.assets[0].token_id, pool.lend_token);
        assert_eq!(p.registers["R5"], encode::long(w.min_out).unwrap());
        assert!(WithdrawQuote::new(pool, &s, 0, 0, 1).is_err());
        assert!(WithdrawQuote::new(pool, &s, s.lend_circulating + 1, 0, 1).is_err());
    }

    #[test]
    fn an_order_transaction_has_the_proxy_first_then_fee_change_and_miner() {
        let pool = &POOLS[0];
        let q = LendQuote::new(pool, &erg_state(), 1_000_000_000, 100, 1).unwrap();
        let p = q.proxy_box(pool, USER).unwrap();
        let tx = build_order_tx(
            &p,
            &[input(2_000_000_000, vec![("aa", 5)])],
            USER,
            Some(("bb", 1_100_000)),
            1_100_000,
            100,
        )
        .unwrap();
        assert_eq!(tx.outputs.len(), 4);
        assert_eq!(tx.outputs[0].ergo_tree, p.ergo_tree);
        assert_eq!(tx.outputs[1].ergo_tree, "bb");
        let change = &tx.outputs[2];
        assert_eq!(change.ergo_tree, USER);
        assert_eq!(
            change.value,
            (2_000_000_000 - p.value - 2_200_000).to_string()
        );
        assert_eq!(
            change.assets[0].amount, "5",
            "every leftover token rides on change"
        );
        // Not enough, or dust change: refused rather than built wrong.
        assert!(build_order_tx(
            &p,
            &[input(1_000_000_000, vec![])],
            USER,
            None,
            1_100_000,
            100
        )
        .is_err());
        assert!(build_order_tx(
            &p,
            &[input(p.value + 1_100_000 + 10, vec![])],
            USER,
            None,
            1_100_000,
            100
        )
        .is_err());
    }

    #[test]
    fn a_refund_pays_the_user_everything_but_the_contract_fee_and_marks_the_box() {
        let proxy = Eip12InputBox {
            box_id: "cd".repeat(32),
            value: "1003000000".into(),
            ergo_tree: "00".into(),
            assets: vec![Eip12Asset {
                token_id: "aa".into(),
                amount: "7".into(),
            }],
            ..input(0, vec![])
        };
        let tx = build_refund_tx(&proxy, USER, 5).unwrap();
        assert_eq!(tx.inputs.len(), 1);
        assert_eq!(tx.outputs[0].value, "1002000000");
        assert_eq!(tx.outputs[0].ergo_tree, USER);
        assert_eq!(
            tx.outputs[0].assets[0].amount, "7",
            "a withdraw order's lend tokens come back"
        );
        assert_eq!(
            tx.outputs[0].additional_registers["R4"],
            format!("0e20{}", "cd".repeat(32))
        );
        assert_eq!(
            tx.outputs[1].value,
            TX_FEE.to_string(),
            "the contract allows exactly one fee"
        );
    }

    #[test]
    fn a_spend_is_read_as_fill_refund_or_unknown() {
        let id = "ef".repeat(32);
        let marker = format!("0e20{id}");
        let filled = serde_json::json!({"outputs": [
            {"value": 1, "additionalRegisters": {}},
            {"value": 2, "additionalRegisters": {}},
            {"value": 1000000, "assets": [{"tokenId": "aa", "amount": 42}], "additionalRegisters": {"R7": {"serializedValue": marker}}},
        ]});
        // The explorer may answer in upper-case hex.
        let upper = serde_json::json!({"outputs": [
            {"value": 1000000, "additionalRegisters": {"R7": marker.to_uppercase()}},
        ]});
        assert!(matches!(classify_spend(&id, &upper).unwrap(), OrderOutcome::Filled { .. }), "case-insensitive marker");
        match classify_spend(&id, &filled).unwrap() {
            OrderOutcome::Filled { value, assets } => {
                assert_eq!(value, 1_000_000);
                assert_eq!(assets[0].amount, "42");
            }
            other => panic!("{other:?}"),
        }
        let refunded =
            serde_json::json!({"outputs": [{"value": 999, "additionalRegisters": {"R4": marker}}]});
        assert!(matches!(
            classify_spend(&id, &refunded).unwrap(),
            OrderOutcome::Refunded { value: 999, .. }
        ));
        let other =
            serde_json::json!({"outputs": [{"value": 1, "additionalRegisters": {"R4": "0e01aa"}}]});
        assert!(matches!(
            classify_spend(&id, &other).unwrap(),
            OrderOutcome::Unknown
        ));
    }
}
