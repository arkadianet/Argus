//! Orders found on chain rather than in the wallet's records: every proxy
//! box under a Duckpools proxy script whose user register names one of
//! the wallet's addresses. A reinstall or a second device has no record
//! of an order it posted; the box is still there, refundable after its
//! height, and this is how it is found again.

use serde::Serialize;

use crate::loans::OrderKind;
use crate::pools::{Pool, POOLS};
use crate::state::PoolsError;

/// A proxy box of the wallet's, as found on chain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FoundOrder {
    pub pool: &'static str,
    pub kind: &'static str,
    pub box_id: String,
    pub tx_id: String,
    /// The order's own size: ERG for an ERG-pool lend, the pool's token
    /// for a token-pool lend or a repayment, lend tokens for a withdraw,
    /// the loan asked for a borrow.
    pub amount: i64,
    pub value: i64,
    pub refund_height: i64,
}

#[allow(dead_code)]
fn err(m: impl Into<String>) -> PoolsError {
    PoolsError::Serialization(m.into())
}

/// Every distinct proxy script, hex, with the pool and kind it serves.
pub fn proxy_trees() -> Vec<(String, &'static Pool, OrderKind)> {
    let mut out: Vec<(String, &'static Pool, OrderKind)> = Vec::new();
    for pool in POOLS {
        let kinds = [
            (pool.lend_proxy_address, OrderKind::Lend),
            (pool.withdraw_proxy_address, OrderKind::Withdraw),
            (pool.borrow_proxy_address, OrderKind::Borrow),
            (pool.repay_proxy_address, OrderKind::Repay),
            (pool.partial_repay_proxy_address, OrderKind::PartialRepay),
        ];
        for (address, kind) in kinds {
            if address.is_empty() {
                continue;
            }
            if let Ok(tree) = ergo_tx::address_to_ergo_tree(address) {
                let tree = tree.to_ascii_lowercase();
                if !out.iter().any(|(t, _, _)| *t == tree) {
                    out.push((tree, pool, kind));
                }
            }
        }
    }
    out
}

fn kind_name(kind: OrderKind) -> &'static str {
    match kind {
        OrderKind::Lend => "lend",
        OrderKind::Withdraw => "withdraw",
        OrderKind::Borrow => "borrow",
        OrderKind::Repay => "repay",
        OrderKind::PartialRepay => "partial_repay",
    }
}

/// A VLQ from `bytes`: the value and the bytes it took. None when it
/// does not terminate, is longer than a u64 allows, or is not canonical
/// (a continuation byte followed by a zero byte encodes nothing).
fn vlq(bytes: &[u8]) -> Option<(u64, usize)> {
    let mut result: u64 = 0;
    let mut shift = 0u32;
    for (i, &b) in bytes.iter().enumerate() {
        if shift > 63 || (shift == 63 && (b & 0x7f) > 1) {
            return None;
        }
        result |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 {
            if i > 0 && b == 0 {
                return None;
            }
            return Some((result, i + 1));
        }
        shift += 7;
    }
    None
}

fn register_hex<'a>(v: &'a serde_json::Value, name: &str) -> Option<&'a str> {
    let raw = v.get("additionalRegisters")?.get(name)?;
    match raw {
        serde_json::Value::String(s) => Some(s.as_str()),
        serde_json::Value::Object(m) => m.get("serializedValue")?.as_str(),
        _ => None,
    }
}

/// A `Coll[Byte]` register (`0e` + VLQ length + bytes), as hex. The length
/// must account for exactly the rest of the value.
fn register_bytes(v: &serde_json::Value, name: &str) -> Option<String> {
    let bytes = hex::decode(register_hex(v, name)?).ok()?;
    if bytes.first() != Some(&0x0e) {
        return None;
    }
    let (len, used) = vlq(&bytes[1..])?;
    let start = 1 + used;
    let end = start.checked_add(usize::try_from(len).ok()?)?;
    (bytes.len() == end).then(|| hex::encode(&bytes[start..end]))
}

/// An `Int` (`04`) or `Long` (`05`) register: zigzag VLQ, nothing after it.
fn register_number(v: &serde_json::Value, name: &str) -> Option<i64> {
    let bytes = hex::decode(register_hex(v, name)?).ok()?;
    if !matches!(bytes.first(), Some(0x04) | Some(0x05)) {
        return None;
    }
    let (result, used) = vlq(&bytes[1..])?;
    if 1 + used != bytes.len() {
        return None;
    }
    Some(if result & 1 == 0 { (result >> 1) as i64 } else { -((result >> 1) as i64) - 1 })
}

/// The wallet's orders among `boxes` (node or explorer JSON of unspent
/// boxes under the proxy scripts). `wallet_trees` are the wallet's
/// address trees, hex.
pub fn discover_orders(boxes: &[serde_json::Value], wallet_trees: &[String]) -> Result<Vec<FoundOrder>, PoolsError> {
    let trees = proxy_trees();
    let mine: Vec<String> = wallet_trees.iter().map(|t| t.to_ascii_lowercase()).collect();
    let mut out = Vec::new();
    for b in boxes {
        let tree = b.get("ergoTree").and_then(|t| t.as_str()).unwrap_or_default().to_ascii_lowercase();
        let Some((_, pool, kind)) = trees.iter().find(|(t, _, _)| *t == tree) else {
            continue;
        };
        let user_reg = match kind {
            OrderKind::Lend | OrderKind::Withdraw | OrderKind::Borrow => "R4",
            OrderKind::Repay => "R5",
            OrderKind::PartialRepay => "R6",
        };
        let Some(user) = register_bytes(b, user_reg) else { continue };
        if !mine.contains(&user) {
            continue;
        }
        let refund_reg = match kind {
            OrderKind::PartialRepay => "R7",
            _ => "R6",
        };
        // A malformed box is skipped, not a reason to lose the others.
        let Some(refund_height) = register_number(b, refund_reg) else { continue };
        let Some(value) = b.get("value").and_then(|v| v.as_i64()) else { continue };
        let first_token = b
            .get("assets")
            .and_then(|a| a.as_array())
            .and_then(|a| a.first())
            .and_then(|a| a.get("amount"))
            .and_then(|n| n.as_i64())
            .unwrap_or(0);
        let amount = match kind {
            OrderKind::Borrow => register_number(b, "R5").unwrap_or(0),
            OrderKind::Lend if pool.is_erg() => value,
            OrderKind::Repay if pool.is_erg() => value,
            _ => first_token,
        };
        out.push(FoundOrder {
            pool: pool.key,
            kind: kind_name(*kind),
            box_id: b.get("boxId").and_then(|s| s.as_str()).unwrap_or_default().to_string(),
            tx_id: b.get("transactionId").and_then(|s| s.as_str()).unwrap_or_default().to_string(),
            amount,
            value,
            refund_height,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encode;

    const USER: &str = "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    const OTHER: &str = "0008cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a02";

    fn proxy(tree: &str, regs: &[(&str, String)], value: i64, tokens: &[(&str, i64)]) -> serde_json::Value {
        serde_json::json!({
            "boxId": "ab".repeat(32),
            "transactionId": "cd".repeat(32),
            "ergoTree": tree,
            "value": value,
            "assets": tokens.iter().map(|(id, n)| serde_json::json!({"tokenId": id, "amount": n})).collect::<Vec<_>>(),
            "additionalRegisters": regs.iter().map(|(k, v)| (k.to_string(), serde_json::json!({"serializedValue": v}))).collect::<serde_json::Map<_, _>>(),
        })
    }

    #[test]
    fn every_pool_contributes_distinct_proxy_scripts() {
        let trees = proxy_trees();
        assert!(trees.len() >= 10, "{}", trees.len());
        assert!(trees.iter().all(|(t, _, _)| t.starts_with("10")));
    }

    #[test]
    fn the_wallets_orders_are_found_by_their_user_register() {
        let trees = proxy_trees();
        let (borrow_tree, pool, _) = trees.iter().find(|(_, p, k)| p.key == "sigusd" && *k == OrderKind::Borrow).unwrap();
        let (lend_tree, _, _) = trees.iter().find(|(_, p, k)| p.key == "erg" && *k == OrderKind::Lend).unwrap();
        let (partial_tree, _, _) = trees.iter().find(|(_, p, k)| p.key == "sigusd" && *k == OrderKind::PartialRepay).unwrap();
        let user_bytes = hex::decode(USER).unwrap();
        let other_bytes = hex::decode(OTHER).unwrap();
        let boxes = vec![
            proxy(borrow_tree, &[("R4", encode::coll_byte(&user_bytes).unwrap()), ("R5", encode::long(100).unwrap()), ("R6", encode::int(1_900_000).unwrap())], 12_003_000_000, &[]),
            proxy(borrow_tree, &[("R4", encode::coll_byte(&other_bytes).unwrap()), ("R5", encode::long(5).unwrap()), ("R6", encode::int(1).unwrap())], 1, &[]),
            proxy(lend_tree, &[("R4", encode::coll_byte(&user_bytes).unwrap()), ("R5", encode::long(1).unwrap()), ("R6", encode::long(1_900_720).unwrap())], 5_000_000_000, &[]),
            proxy(partial_tree, &[("R4", encode::box_id_register(&"11".repeat(32)).unwrap()), ("R5", encode::long(1).unwrap()), ("R6", encode::coll_byte(&user_bytes).unwrap()), ("R7", encode::long(1_900_800).unwrap())], 3_000_000, &[("03faf2", 50)]),
            proxy("0008cd00", &[("R4", encode::coll_byte(&user_bytes).unwrap())], 1, &[]),
        ];
        let found = discover_orders(&boxes, &[USER.to_string()]).unwrap();
        assert_eq!(found.len(), 3);
        assert_eq!(found[0].pool, pool.key);
        assert_eq!((found[0].kind, found[0].amount, found[0].refund_height), ("borrow", 100, 1_900_000));
        assert_eq!((found[1].kind, found[1].amount, found[1].refund_height), ("lend", 5_000_000_000, 1_900_720));
        assert_eq!((found[2].kind, found[2].amount, found[2].refund_height), ("partial_repay", 50, 1_900_800));
        assert!(discover_orders(&boxes, &[OTHER.to_uppercase()]).unwrap().len() == 1, "case does not matter");
    }

    #[test]
    fn malformed_registers_are_rejected_not_misread() {
        let reg = |hex: &str| serde_json::json!({"additionalRegisters": {"R4": hex}});
        // Unterminated length, non-canonical length, length past the end, trailing bytes.
        assert_eq!(register_bytes(&reg("0e81"), "R4"), None);
        assert_eq!(register_bytes(&reg("0e8000"), "R4"), None);
        assert_eq!(register_bytes(&reg("0e05aabb"), "R4"), None);
        assert_eq!(register_bytes(&reg("0e01aabb"), "R4"), None);
        assert_eq!(register_bytes(&reg("0e02aabb"), "R4"), Some("aabb".into()));
        // A number needs at least one byte, must terminate, and must end the value.
        assert_eq!(register_number(&reg("04"), "R4"), None);
        assert_eq!(register_number(&reg("0480"), "R4"), None);
        assert_eq!(register_number(&reg("048000"), "R4"), None);
        assert_eq!(register_number(&reg("040201"), "R4"), None);
        assert_eq!(register_number(&reg("04ffffffffffffffffffff01"), "R4"), None, "eleven bytes overflow");
        assert_eq!(register_number(&reg("0402"), "R4"), Some(1));
        assert_eq!(register_number(&reg("0403"), "R4"), Some(-2));
        assert_eq!(register_number(&reg("05ac02"), "R4"), Some(150));
    }

    #[test]
    fn a_malformed_proxy_box_is_skipped_and_the_rest_kept() {
        let trees = proxy_trees();
        let (borrow_tree, _, _) = trees.iter().find(|(_, p, k)| p.key == "sigusd" && *k == OrderKind::Borrow).unwrap();
        let user_bytes = hex::decode(USER).unwrap();
        let mut bad = proxy(borrow_tree, &[("R4", encode::coll_byte(&user_bytes).unwrap()), ("R5", encode::long(7).unwrap()), ("R6", "0480".to_string())], 1, &[]);
        bad["boxId"] = serde_json::json!("ff".repeat(32));
        let no_value = {
            let mut b = proxy(borrow_tree, &[("R4", encode::coll_byte(&user_bytes).unwrap()), ("R6", encode::int(5).unwrap())], 1, &[]);
            b.as_object_mut().unwrap().remove("value");
            b
        };
        let good = proxy(borrow_tree, &[("R4", encode::coll_byte(&user_bytes).unwrap()), ("R5", encode::long(100).unwrap()), ("R6", encode::int(1_900_000).unwrap())], 1, &[]);
        let found = discover_orders(&[bad, no_value, good], &[USER.to_string()]).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].amount, 100);
    }
}
