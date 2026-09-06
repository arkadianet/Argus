//! The lock transaction: the asset into a box at the bridge's lock
//! address, with the transfer's details in R4.

use std::collections::HashMap;

use ergo_tx::{Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};

use crate::LOCK_MIN_BOX_VALUE;

/// The contracts' minimum box value and transaction fee, nanoERG.
pub const MIN_BOX_VALUE: i64 = 1_000_000;

#[derive(Debug, thiserror::Error)]
pub enum LockError {
    #[error("no inputs")]
    NoInputs,
    #[error("amount must be positive")]
    ZeroAmount,
    #[error("an ERG transfer must lock at least {0} nanoERG")]
    ErgBelowMin(i64),
    #[error("inputs hold {have} of the token but the transfer needs {need}")]
    InsufficientTokens { have: u64, need: u64 },
    #[error("inputs hold {have} nanoERG but the transfer needs {need}")]
    InsufficientErg { have: i64, need: i64 },
    #[error("target address is empty")]
    NoAddress,
    #[error("serialization error: {0}")]
    Serialization(String),
}

/// One transfer out of Ergo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockSpec {
    /// The Ergo token to lock, or none for ERG.
    pub token_id: Option<String>,
    /// Units of the asset (nanoERG for ERG).
    pub amount: i64,
    pub to_chain: String,
    pub to_address: String,
    /// The sender's address: the bridge returns a failed transfer here.
    pub from_address: String,
    pub bridge_fee: i64,
    pub network_fee: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct LockSummary {
    pub lock_value: i64,
    pub miner_fee: i64,
    pub app_fee_nano: i64,
    pub change_erg: i64,
}

#[derive(Debug)]
pub struct LockBuildResult {
    pub unsigned_tx: Eip12UnsignedTx,
    pub summary: LockSummary,
}

fn vlq(mut n: u64, out: &mut Vec<u8>) {
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            break;
        }
        out.push(b | 0x80);
    }
}

/// A `Coll[Coll[Byte]]` constant: `1a`, the count, then each item's
/// length and bytes.
pub fn coll_coll_byte_hex(items: &[&[u8]]) -> String {
    let mut out = vec![0x1au8];
    vlq(items.len() as u64, &mut out);
    for it in items {
        vlq(it.len() as u64, &mut out);
        out.extend_from_slice(it);
    }
    hex::encode(out)
}

/// R4 of the lock box: target chain, target address, network fee,
/// bridge fee, sender, each as its UTF-8 text.
pub fn lock_registers(spec: &LockSpec) -> HashMap<String, String> {
    let network_fee = spec.network_fee.to_string();
    let bridge_fee = spec.bridge_fee.to_string();
    let r4 = coll_coll_byte_hex(&[
        spec.to_chain.as_bytes(),
        spec.to_address.as_bytes(),
        network_fee.as_bytes(),
        bridge_fee.as_bytes(),
        spec.from_address.as_bytes(),
    ]);
    HashMap::from([("R4".to_string(), r4)])
}

/// The height the transaction is created at (EIP-39): never below any
/// input's own creation height.
pub fn creation_height(network_height: i32, inputs: &[Eip12InputBox]) -> i32 {
    inputs
        .iter()
        .map(|b| b.creation_height)
        .fold(network_height, i32::max)
}

/// Build the lock: the lock box first, then change with every other
/// token and the leftover ERG, the app fee when configured, the miner
/// fee.
pub fn build_lock_tx(
    inputs: &[Eip12InputBox],
    spec: &LockSpec,
    lock_tree: &str,
    change_tree: &str,
    app_fee: Option<(&str, i64)>,
    miner_fee: i64,
    network_height: i32,
) -> Result<LockBuildResult, LockError> {
    if inputs.is_empty() {
        return Err(LockError::NoInputs);
    }
    if spec.amount <= 0 {
        return Err(LockError::ZeroAmount);
    }
    if spec.to_address.trim().is_empty() {
        return Err(LockError::NoAddress);
    }
    let parse = |s: &str| -> Result<i64, LockError> {
        s.parse().map_err(|_| LockError::Serialization(format!("bad amount {s:?}")))
    };
    let lock_value = match &spec.token_id {
        None => {
            if spec.amount < LOCK_MIN_BOX_VALUE {
                return Err(LockError::ErgBelowMin(LOCK_MIN_BOX_VALUE));
            }
            spec.amount
        }
        Some(_) => LOCK_MIN_BOX_VALUE,
    };
    let mut total: i64 = 0;
    let mut tokens: Vec<(String, i64)> = Vec::new();
    for b in inputs {
        total = total
            .checked_add(parse(&b.value)?)
            .ok_or_else(|| LockError::Serialization("input value overflows".into()))?;
        for a in &b.assets {
            let n = parse(&a.amount)?;
            match tokens.iter_mut().find(|(id, _)| id.eq_ignore_ascii_case(&a.token_id)) {
                Some((_, have)) => *have += n,
                None => tokens.push((a.token_id.to_ascii_lowercase(), n)),
            }
        }
    }
    let mut lock_assets = Vec::new();
    if let Some(id) = &spec.token_id {
        let have = tokens
            .iter()
            .find(|(t, _)| t.eq_ignore_ascii_case(id))
            .map(|(_, n)| *n)
            .unwrap_or(0);
        if have < spec.amount {
            return Err(LockError::InsufficientTokens { have: have as u64, need: spec.amount as u64 });
        }
        for (t, n) in tokens.iter_mut() {
            if t.eq_ignore_ascii_case(id) {
                *n -= spec.amount;
            }
        }
        lock_assets.push(Eip12Asset::new(id.to_ascii_lowercase(), spec.amount));
    }
    let app_fee_nano = app_fee.map(|(_, n)| n).unwrap_or(0);
    let change_tokens: Vec<Eip12Asset> = tokens
        .into_iter()
        .filter(|(_, n)| *n > 0)
        .map(|(id, n)| Eip12Asset::new(id, n))
        .collect();
    let spend = lock_value + miner_fee + app_fee_nano;
    let change_erg = total - spend;
    // The change box must exist when tokens ride in it, and be a box.
    let need = spend + if change_tokens.is_empty() { 0 } else { MIN_BOX_VALUE };
    if total < need || (change_erg > 0 && change_erg < MIN_BOX_VALUE) {
        return Err(LockError::InsufficientErg { have: total, need: need.max(spend + MIN_BOX_VALUE) });
    }
    let height = creation_height(network_height, inputs);
    let mut outputs = vec![Eip12Output {
        value: lock_value.to_string(),
        ergo_tree: lock_tree.to_string(),
        assets: lock_assets,
        creation_height: height,
        additional_registers: lock_registers(spec),
    }];
    if change_erg > 0 {
        outputs.push(Eip12Output {
            value: change_erg.to_string(),
            ergo_tree: change_tree.to_string(),
            assets: change_tokens,
            creation_height: height,
            additional_registers: HashMap::new(),
        });
    }
    if let Some((tree, n)) = app_fee {
        if n > 0 {
            outputs.push(Eip12Output::simple(n, tree, height));
        }
    }
    outputs.push(Eip12Output::fee(miner_fee, height));
    Ok(LockBuildResult {
        unsigned_tx: Eip12UnsignedTx {
            inputs: inputs.to_vec(),
            data_inputs: Vec::new(),
            outputs,
        },
        summary: LockSummary {
            lock_value,
            miner_fee,
            app_fee_nano,
            change_erg,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIGUSD: &str = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";

    fn input(value: i64, assets: Vec<(&str, i64)>, height: i32) -> Eip12InputBox {
        Eip12InputBox {
            box_id: "11".repeat(32),
            transaction_id: "22".repeat(32),
            index: 0,
            value: value.to_string(),
            ergo_tree: "0008cd02".into(),
            assets: assets.into_iter().map(|(t, n)| Eip12Asset::new(t.to_string(), n)).collect(),
            creation_height: height,
            additional_registers: HashMap::new(),
            extension: HashMap::new(),
        }
    }

    fn spec(token: Option<&str>, amount: i64) -> LockSpec {
        LockSpec {
            token_id: token.map(str::to_string),
            amount,
            to_chain: "cardano".into(),
            to_address: "addr1qxy".into(),
            from_address: "9fRusAar".into(),
            bridge_fee: 700,
            network_fee: 300,
        }
    }

    #[test]
    fn r4_holds_the_five_strings_as_a_byte_collection() {
        let regs = lock_registers(&spec(None, 1));
        // 1a 05, then "cardano" (7), "addr1qxy" (8), "300" (3), "700" (3), "9fRusAar" (8).
        assert_eq!(
            regs["R4"],
            format!(
                "1a0507{}08{}03{}03{}08{}",
                hex::encode("cardano"),
                hex::encode("addr1qxy"),
                hex::encode("300"),
                hex::encode("700"),
                hex::encode("9fRusAar")
            )
        );
    }

    #[test]
    fn a_token_lock_carries_the_token_on_the_minimum_erg_and_returns_the_rest() {
        let r = build_lock_tx(
            &[input(50_000_000, vec![(SIGUSD, 5_000), ("ee", 3)], 90)],
            &spec(Some(SIGUSD), 1_000),
            "lock",
            "0008cd02",
            Some(("fee", 1_100_000)),
            1_000_000,
            100,
        )
        .unwrap();
        let lock = &r.unsigned_tx.outputs[0];
        assert_eq!(lock.value, "2000000");
        assert_eq!(lock.ergo_tree, "lock");
        assert_eq!(lock.assets.len(), 1);
        assert_eq!(lock.assets[0].amount, "1000");
        assert!(lock.additional_registers.contains_key("R4"));
        let change = &r.unsigned_tx.outputs[1];
        assert_eq!(change.value, (50_000_000 - 2_000_000 - 1_000_000 - 1_100_000).to_string());
        assert_eq!(change.assets.iter().find(|a| a.token_id == SIGUSD).unwrap().amount, "4000");
        assert_eq!(change.assets.iter().find(|a| a.token_id == "ee").unwrap().amount, "3");
        assert_eq!(r.unsigned_tx.outputs[2].value, "1100000");
        assert_eq!(r.unsigned_tx.outputs.len(), 4);
        assert_eq!(lock.creation_height, 100);
    }

    #[test]
    fn an_erg_lock_puts_the_amount_in_the_box_and_keeps_the_height_rule() {
        // An input made at a height above the node's: the transaction is
        // dated at the input's height, never below it.
        let r = build_lock_tx(&[input(10_000_000_000, vec![], 150)], &spec(None, 5_000_000_000), "lock", "0008cd02", None, 1_000_000, 100).unwrap();
        assert_eq!(r.unsigned_tx.outputs[0].value, "5000000000");
        assert!(r.unsigned_tx.outputs[0].assets.is_empty());
        assert_eq!(r.unsigned_tx.outputs[0].creation_height, 150);
        assert_eq!(r.summary.change_erg, 10_000_000_000 - 5_000_000_000 - 1_000_000);
        assert!(matches!(build_lock_tx(&[input(10_000_000, vec![], 1)], &spec(None, 1_000_000), "l", "c", None, 1_000_000, 1), Err(LockError::ErgBelowMin(_))));
        assert!(matches!(build_lock_tx(&[input(10_000_000, vec![(SIGUSD, 5)], 1)], &spec(Some(SIGUSD), 6), "l", "c", None, 1_000_000, 1), Err(LockError::InsufficientTokens { have: 5, need: 6 })));
        assert!(matches!(build_lock_tx(&[input(2_500_000, vec![], 1)], &spec(None, 2_000_000), "l", "c", None, 1_000_000, 1), Err(LockError::InsufficientErg { .. })));
        assert!(matches!(build_lock_tx(&[input(10_000_000, vec![], 1)], &LockSpec { to_address: " ".into(), ..spec(None, 2_000_000) }, "l", "c", None, 1_000_000, 1), Err(LockError::NoAddress)));
    }
}
