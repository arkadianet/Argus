//! The SigmaFi scripts, verbatim from `sigmafi-ui` (`src/offchain/plugins.ts`).
//!
//! ERG loans have fixed scripts. Token loans are templates: the token id
//! is a constant of the bond script, and the order script carries both
//! the token id and the blake2b-256 hash of that bond script (so the
//! order can insist the fill creates the right bond).
//!
//! Only "on close" orders are built here: the term starts when the order
//! is filled. The "fixed height" variant SigmaFi once offered is no longer
//! created by its interface and has no live boxes; its orders are still
//! recognised so they show up, but not filled.

use crate::ERG;

pub const ERG_BOND: &str = "100204000402d805d601b2a5730000d602e4c6a70808d603db6308a7d604c1a7d605e4c6a705089592a3e4c6a70704d19683040193c27201d0720293db63087201720393c17201720493e4c67201040ec5a7d801d606b2a5730100ea02d19683060193c27201d0720293c17201e4c6a7060593e4c67201040ec5a793c27206d0720593db63087206720393c1720672047205";

/// Segments around the token id.
pub const TOKEN_BOND: [&str; 2] = [
    "10060400040004020580897a0e20",
    "0402d805d601b2a5730000d602e4c6a70808d603db6308a7d604c1a7d605e4c6a705089592a3e4c6a70704d19683040193c27201d0720293db63087201720393c17201720493e4c67201040ec5a7d803d606db63087201d607b27206730100d608b2a5730200ea02d19683090193c27201d0720293c172017303938c7207017304938c720702e4c6a7060593b17206730593e4c67201040ec5a793c27208d0720593db63087208720393c1720872047205",
];

pub const ERG_ORDER_ON_CLOSE: &str = "1012040005e80705c09a0c08cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a0205a0060601000e20eccbd70bb2ed259a3f6888c4b68bbd963ff61e2d71cdfda3c7234231e1e4b76604020400043c04100400040401010402040601010101d80bd601b2a5730000d602e4c6a70408d603e4c6a70704d604e4c6a70505d605e30008d606e67205d6077301d6087302d6097303d60a957206d801d60a7e72040683024406860272099d9c7e720706720a7e7208068602e472059d9c7e730406720a7e72080683014406860272099d9c7e7207067e7204067e720806d60b730595937306cbc27201d804d60c999aa37203e4c672010704d60db2a5730700d60eb2720a730800d60f8c720e02d1ed96830b0193e4c67201040ec5a793e4c672010508720293e4c672010605e4c6a70605e6c67201080893db63087201db6308a793c17201c1a7927203730990720c730a92720c730b93c2720dd0720293c1720d7204ed9591720f720bd801d610b2a5730c009683020193c27210d08c720e01937ec1721006720f730d957206d802d610b2720a730e00d6118c72100295917211720bd801d612b2a5730f009683020193c27212d08c721001937ec17212067211731073117202";

pub const ERG_ORDER_FIXED_HEIGHT: &str = "100f040005e80705c09a0c08cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a0205a0060601000e20eccbd70bb2ed259a3f6888c4b68bbd963ff61e2d71cdfda3c7234231e1e4b76604020400040401010402040601010101d80ad601b2a5730000d602e4c6a70408d603e4c6a70505d604e30008d605e67204d6067301d6077302d6087303d609957205d801d6097e72030683024406860272089d9c7e72060672097e7207068602e472049d9c7e73040672097e72070683014406860272089d9c7e7206067e7203067e720706d60a730595937306cbc27201d803d60bb2a5730700d60cb27209730800d60d8c720c02d1ed9683090193e4c67201040ec5a793e4c672010508720293e4c672010605e4c6a70605e6c67201080893db63087201db6308a793c17201c1a793e4c672010704e4c6a7070493c2720bd0720293c1720b7203ed9591720d720ad801d60eb2a57309009683020193c2720ed08c720c01937ec1720e06720d730a957206d802d60eb27209730b00d60f8c720e029591720f720ad801d610b2a5730c009683020193c27210d08c720e01937ec1721006720f730d730e7202";

/// Segments: `[0]` token id `[1]` bond script hash `[2]`.
pub const TOKEN_ORDER_ON_CLOSE: [&str; 3] = [
    "101c04000e20",
    "05e80705c09a0c08cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a0205a0060601000e20",
    "040204000400043c041004000580897a0402040404000580897a040201010402040604000580897a040201010101d80cd601b2a5730000d602e4c6a70408d603e4c6a70704d6047301d605e4c6a70505d606e30008d607e67206d6087302d6097303d60a7304d60b957207d801d60b7e720506830244068602720a9d9c7e720806720b7e7209068602e472069d9c7e730506720b7e720906830144068602720a9d9c7e7208067e7205067e720906d60c730695937307cbc27201d806d60d999aa37203e4c672010704d60eb2a5730800d60fdb6308720ed610b2720f730900d611b2720b730a00d6128c721102d1ed96830e0193e4c67201040ec5a793e4c672010508720293e4c672010605e4c6a70605e6c67201080893db63087201db6308a793c17201c1a7927203730b90720d730c92720d730d93c2720ed0720293c1720e730e938c7210017204938c721002720593b1720f730fed95917212720cd803d613b2a5731000d614db63087213d615b272147311009683050193c27213d08c72110193c172137312938c7215017204937e8c72150206721293b1721473137314957207d802d613b2720b731500d6148c72130295917214720cd803d615b2a5731600d616db63087215d617b272167317009683050193c27215d08c72130193c172157318938c7217017204937e8c72170206721493b172167319731a731b7202",
];

pub const TOKEN_ORDER_FIXED_HEIGHT: [&str; 3] = [
    "101904000e20",
    "05e80705c09a0c08cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a0205a0060601000e20",
    "0402040004000580897a0402040404000580897a040201010402040604000580897a040201010101d80bd601b2a5730000d602e4c6a70408d6037301d604e4c6a70505d605e30008d606e67205d6077302d6087303d6097304d60a957206d801d60a7e72040683024406860272099d9c7e720706720a7e7208068602e472059d9c7e730506720a7e72080683014406860272099d9c7e7207067e7204067e720806d60b730695937307cbc27201d805d60cb2a5730800d60ddb6308720cd60eb2720d730900d60fb2720a730a00d6108c720f02d1ed96830c0193e4c67201040ec5a793e4c672010508720293e4c672010605e4c6a70605e6c67201080893db63087201db6308a793c17201c1a793e4c672010704e4c6a7070493c2720cd0720293c1720c730b938c720e017203938c720e02720493b1720d730ced95917210720bd803d611b2a5730d00d612db63087211d613b27212730e009683050193c27211d08c720f0193c17211730f938c7213017203937e8c72130206721093b1721273107311957206d802d611b2720a731200d6128c72110295917212720bd803d613b2a5731300d614db63087213d615b272147314009683050193c27213d08c72110193c172137315938c7215017203937e8c72150206721293b172147316731773187202",
];

/// P2PK tree of SigmaFi's developer, paid the contract fee on every fill.
pub const DEV_FEE_TREE: &str =
    "0008cd03a11d3028b9bc57b6ac724485e99960b89c278db6bab5d2b961b01aee29405a02";

/// The bond script for loans in `asset` (`"ERG"` or a token id).
pub fn bond_contract(asset: &str) -> String {
    if asset == ERG {
        return ERG_BOND.to_string();
    }
    format!("{}{}{}", TOKEN_BOND[0], asset.to_ascii_lowercase(), TOKEN_BOND[1])
}

/// The "on close" order script for loans in `asset`.
pub fn order_contract(asset: &str) -> String {
    if asset == ERG {
        return ERG_ORDER_ON_CLOSE.to_string();
    }
    let bond = bond_contract(asset);
    let hash = ergo_chain_types::blake2b256_hash(&hex::decode(&bond).expect("bond script hex"));
    format!(
        "{}{}{}{}{}",
        TOKEN_ORDER_ON_CLOSE[0],
        asset.to_ascii_lowercase(),
        TOKEN_ORDER_ON_CLOSE[1],
        hex::encode(hash.0),
        TOKEN_ORDER_ON_CLOSE[2]
    )
}

/// The loan asset of an order box's script, or `None` when the script is
/// not a SigmaFi order (either variant). Token scripts are checked end to
/// end, so a look-alike prefix with a foreign body is not an order.
pub fn loan_asset_of_order(tree: &str) -> Option<String> {
    let tree = tree.to_ascii_lowercase();
    if tree == ERG_ORDER_ON_CLOSE || tree == ERG_ORDER_FIXED_HEIGHT {
        return Some(ERG.to_string());
    }
    for template in [&TOKEN_ORDER_ON_CLOSE, &TOKEN_ORDER_FIXED_HEIGHT] {
        let Some(rest) = tree.strip_prefix(template[0]) else { continue };
        if rest.len() < 64 {
            continue;
        }
        let (token, rest) = rest.split_at(64);
        let Some(rest) = rest.strip_prefix(template[1]) else { continue };
        if rest.len() < 64 {
            continue;
        }
        let (hash, rest) = rest.split_at(64);
        if rest != template[2] || !is_token_id(token) {
            continue;
        }
        let expected = ergo_chain_types::blake2b256_hash(
            &hex::decode(bond_contract(token)).expect("bond script hex"),
        );
        if hash == hex::encode(expected.0) {
            return Some(token.to_string());
        }
    }
    None
}

/// Whether an order script is the "on close" variant this crate fills.
pub fn is_on_close_order(tree: &str) -> bool {
    let tree = tree.to_ascii_lowercase();
    tree == ERG_ORDER_ON_CLOSE || tree.starts_with(TOKEN_ORDER_ON_CLOSE[0])
}

/// The loan asset of a bond box's script, or `None` when it is not one.
pub fn loan_asset_of_bond(tree: &str) -> Option<String> {
    let tree = tree.to_ascii_lowercase();
    if tree == ERG_BOND {
        return Some(ERG.to_string());
    }
    let rest = tree.strip_prefix(TOKEN_BOND[0])?;
    if rest.len() < 64 {
        return None;
    }
    let (token, rest) = rest.split_at(64);
    (rest == TOKEN_BOND[1] && is_token_id(token)).then(|| token.to_string())
}

fn is_token_id(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIGUSD: &str = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";

    #[test]
    fn erg_order_embeds_the_hash_of_the_erg_bond_script() {
        let hash = ergo_chain_types::blake2b256_hash(&hex::decode(ERG_BOND).unwrap());
        assert!(ERG_ORDER_ON_CLOSE.contains(&hex::encode(hash.0)));
        assert!(ERG_ORDER_FIXED_HEIGHT.contains(&hex::encode(hash.0)));
    }

    #[test]
    fn token_scripts_round_trip_their_asset() {
        assert_eq!(loan_asset_of_order(&order_contract(SIGUSD)).as_deref(), Some(SIGUSD));
        assert_eq!(loan_asset_of_bond(&bond_contract(SIGUSD)).as_deref(), Some(SIGUSD));
        assert_eq!(loan_asset_of_order(ERG_ORDER_ON_CLOSE).as_deref(), Some(ERG));
        assert_eq!(loan_asset_of_order(ERG_ORDER_FIXED_HEIGHT).as_deref(), Some(ERG));
        assert_eq!(loan_asset_of_bond(ERG_BOND).as_deref(), Some(ERG));
        assert!(is_on_close_order(&order_contract(SIGUSD)));
        assert!(!is_on_close_order(ERG_ORDER_FIXED_HEIGHT));
    }

    #[test]
    fn foreign_scripts_are_not_orders_or_bonds() {
        assert_eq!(loan_asset_of_order("0008cd03a11d"), None);
        assert_eq!(loan_asset_of_bond(&format!("{}{}", TOKEN_BOND[0], SIGUSD)), None);
        // Right prefix and token, wrong bond hash.
        let mut forged = order_contract(SIGUSD);
        let at = TOKEN_ORDER_ON_CLOSE[0].len() + 64 + TOKEN_ORDER_ON_CLOSE[1].len();
        forged.replace_range(at..at + 2, "00");
        assert_eq!(loan_asset_of_order(&forged), None);
    }

    #[test]
    fn live_scripts_match_the_ones_sigmafi_deployed() {
        // The fixtures are live explorer boxes fetched from the addresses
        // these scripts produce; each must parse back to its asset.
        for (json, asset, order) in [
            (include_str!("../test/fixtures/orders_erg.json"), ERG, true),
            (include_str!("../test/fixtures/orders_sigusd.json"), SIGUSD, true),
            (include_str!("../test/fixtures/bonds_erg.json"), ERG, false),
            (include_str!("../test/fixtures/bonds_sigusd.json"), SIGUSD, false),
        ] {
            let boxes: Vec<serde_json::Value> = serde_json::from_str(json).unwrap();
            assert!(!boxes.is_empty());
            for b in boxes {
                let tree = b["ergoTree"].as_str().unwrap();
                let got = if order { loan_asset_of_order(tree) } else { loan_asset_of_bond(tree) };
                assert_eq!(got.as_deref(), Some(asset));
            }
        }
    }
}
