//! Which protocol a box belongs to, for the activity list.
//!
//! The tags name what the wallet already knows how to use: the contract
//! trees and NFTs of the protocol crates it builds transactions for. A box
//! is matched by its protocol NFT first (the SigmaUSD bank, the Dexy boxes,
//! which every crate locates that way), then by its exact script, then by
//! script template (Spectrum orders, SigmaFi token orders, stealth and
//! Babel scripts). Anything else is untagged.
//!
//! Tags are `protocol:role` strings the app reads (`activity_classifier.dart`
//! keeps the same list): `spectrum:pool`, `spectrum:swap_order`,
//! `spectrum:deposit_order`, `spectrum:redeem_order`, `sigmausd:bank`,
//! `dexy:bank`, `dexy:mint`, `dexy:buyback`, `dexy:lp`, `dexy:lp_swap`,
//! `dexy:lp_mint`, `dexy:lp_redeem`, `duckpools:pool`,
//! `duckpools:collateral`, `duckpools:{lend,withdraw,borrow,repay,partial_repay}`,
//! `sigmafi:order`, `sigmafi:bond`, `mixer:half`, `mixer:full`,
//! `mixer:emission`, `rosen:lock`, `stake:<pool>`, `stake:proxy`,
//! `stealth`, `babel`, `oracle`, and `argus_fee`.

use std::collections::HashMap;
use std::sync::LazyLock;

use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;

use crate::api::{ARGUS_FEE_ADDRESS, ARGUS_FEE_NANO};

/// Protocol NFTs (and the tag of the box carrying one).
static NFT_TAGS: LazyLock<HashMap<&'static str, &'static str>> = LazyLock::new(|| {
    let mut m = HashMap::new();
    m.insert(sigmausd::mainnet::BANK_NFT_ID, "sigmausd:bank");
    m.insert(sigmausd::mainnet::ORACLE_POOL_NFT_ID, "oracle");
    macro_rules! dexy {
        ($v:ident) => {{
            use dexy::$v as d;
            m.insert(d::BANK_NFT_ID, "dexy:bank");
            m.insert(d::FREE_MINT_NFT_ID, "dexy:mint");
            m.insert(d::ARBITRAGE_MINT_NFT_ID, "dexy:mint");
            m.insert(d::BUYBACK_NFT_ID, "dexy:buyback");
            m.insert(d::LP_NFT_ID, "dexy:lp");
            m.insert(d::LP_SWAP_NFT_ID, "dexy:lp_swap");
            m.insert(d::LP_MINT_NFT_ID, "dexy:lp_mint");
            m.insert(d::LP_REDEEM_NFT_ID, "dexy:lp_redeem");
            m.insert(d::ORACLE_POOL_NFT_ID, "oracle");
        }};
    }
    dexy!(gold_mainnet);
    dexy!(usd_mainnet);
    m
});

fn tree_of(address: &str) -> Option<String> {
    wallet_net::address_to_ergo_tree(address).ok()
}

/// Whole scripts, lowercase hex.
static TREE_TAGS: LazyLock<HashMap<String, String>> = LazyLock::new(|| {
    let mut m: HashMap<String, String> = HashMap::new();
    let mut put = |tree: Option<String>, tag: &str| {
        if let Some(t) = tree {
            m.insert(t.to_ascii_lowercase(), tag.to_string());
        }
    };
    put(
        Some(wallet_amm::contract::N2T_POOL_TREE.into()),
        "spectrum:pool",
    );
    put(
        Some(wallet_amm::contract::T2T_POOL_TREE.into()),
        "spectrum:pool",
    );
    for pool in duckpools::POOLS {
        put(Some(pool.ergo_tree.into()), "duckpools:pool");
        if !pool.collateral_address.is_empty() {
            put(tree_of(pool.collateral_address), "duckpools:collateral");
        }
    }
    for (tree, _, kind) in duckpools::proxy_trees() {
        let role = match kind {
            duckpools::OrderKind::Lend => "duckpools:lend",
            duckpools::OrderKind::Withdraw => "duckpools:withdraw",
            duckpools::OrderKind::Borrow => "duckpools:borrow",
            duckpools::OrderKind::Repay => "duckpools:repay",
            duckpools::OrderKind::PartialRepay => "duckpools:partial_repay",
        };
        put(Some(tree), role);
    }
    put(
        Some(zerojoin::contracts::HALF_MIX_ERGO_TREE_HEX.into()),
        "mixer:half",
    );
    put(
        Some(zerojoin::contracts::FULL_MIX_ERGO_TREE_HEX.into()),
        "mixer:full",
    );
    put(
        Some(zerojoin::contracts::FEE_EMISSION_ERGO_TREE_HEX.into()),
        "mixer:emission",
    );
    put(
        Some(zerojoin::contracts::TOKEN_EMISSION_ERGO_TREE_HEX.into()),
        "mixer:emission",
    );
    put(tree_of(rosen::LOCK_ADDRESS), "rosen:lock");
    use stake_recovery::contracts::{EGIO, ERGOPAD, PAIDEIA};
    for pool in [&ERGOPAD, &PAIDEIA, &EGIO] {
        let tag = format!("stake:{}", pool.name.to_ascii_lowercase());
        put(tree_of(pool.stake_address), &tag);
        put(tree_of(pool.state_address), &tag);
    }
    put(
        tree_of(stake_recovery::contracts::PAIDEIA_PROXY_ADDRESS),
        "stake:proxy",
    );
    put(
        tree_of(stake_recovery::contracts::PAIDEIA_INCENTIVE_ADDRESS),
        "stake:paideia",
    );
    m
});

fn template_of(hex_tree: &str) -> Option<Vec<u8>> {
    let bytes = hex::decode(hex_tree).ok()?;
    ErgoTree::sigma_parse_bytes(&bytes)
        .ok()?
        .template_bytes()
        .ok()
}

static DEPOSIT_TEMPLATE: LazyLock<Option<Vec<u8>>> =
    LazyLock::new(|| template_of(amm::constants::lp_templates::N2T_DEPOSIT_TEMPLATE));
static REDEEM_TEMPLATE: LazyLock<Option<Vec<u8>>> =
    LazyLock::new(|| template_of(amm::constants::lp_templates::N2T_REDEEM_TEMPLATE));

/// The protocol tag of one box (node JSON), or None for an ordinary box.
pub fn tag_box(b: &serde_json::Value) -> Option<String> {
    let tree = b["ergoTree"]
        .as_str()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let assets = b["assets"].as_array();

    if b["value"].as_i64() == Some(ARGUS_FEE_NANO)
        && assets.is_none_or(|a| a.is_empty())
        && wallet_net::activity::box_address(b).as_deref() == Some(ARGUS_FEE_ADDRESS)
    {
        return Some(wallet_net::activity::ARGUS_FEE_TAG.to_string());
    }
    if let Some(assets) = assets {
        for a in assets {
            if let Some(tag) = a["tokenId"].as_str().and_then(|id| NFT_TAGS.get(id)) {
                return Some((*tag).to_string());
            }
        }
    }
    if tree.is_empty() {
        return None;
    }
    if let Some(tag) = TREE_TAGS.get(&tree) {
        return Some(tag.clone());
    }
    if sigmafi::loan_asset_of_order(&tree).is_some() {
        return Some("sigmafi:order".into());
    }
    if sigmafi::loan_asset_of_bond(&tree).is_some() {
        return Some("sigmafi:bond".into());
    }
    if stealth::is_stealth_tree(&tree) {
        return Some("stealth".into());
    }
    if ergo_tx::babel_token_of(&tree).is_some() {
        return Some("babel".into());
    }
    // Templates only for scripts with segregated constants (a leading
    // header byte with bit 4 set), which every Spectrum order has; a P2PK
    // never pays for the parse.
    if tree.starts_with("19") || tree.starts_with("18") {
        let tmpl = template_of(&tree)?;
        if tmpl == *amm::constants::swap_template_bytes::N2T_SWAP_SELL
            || tmpl == *amm::constants::swap_template_bytes::N2T_SWAP_BUY
        {
            return Some("spectrum:swap_order".into());
        }
        if DEPOSIT_TEMPLATE.as_ref() == Some(&tmpl) {
            return Some("spectrum:deposit_order".into());
        }
        if REDEEM_TEMPLATE.as_ref() == Some(&tmpl) {
            return Some("spectrum:redeem_order".into());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn known_scripts_and_nfts_are_tagged() {
        let pool =
            json!({"ergoTree": wallet_amm::contract::N2T_POOL_TREE, "value": 1, "assets": []});
        assert_eq!(tag_box(&pool).as_deref(), Some("spectrum:pool"));
        let bank = json!({"ergoTree": "00", "value": 1, "assets": [
            {"tokenId": sigmausd::mainnet::SIGUSD_TOKEN_ID, "amount": 5},
            {"tokenId": sigmausd::mainnet::BANK_NFT_ID, "amount": 1}]});
        assert_eq!(tag_box(&bank).as_deref(), Some("sigmausd:bank"));
        let half = json!({"ergoTree": zerojoin::contracts::HALF_MIX_ERGO_TREE_HEX, "value": 1});
        assert_eq!(tag_box(&half).as_deref(), Some("mixer:half"));
        let lock = json!({"ergoTree": wallet_net::address_to_ergo_tree(rosen::LOCK_ADDRESS).unwrap(), "value": 1});
        assert_eq!(tag_box(&lock).as_deref(), Some("rosen:lock"));
        let duck = json!({"ergoTree": duckpools::POOLS[0].ergo_tree, "value": 1});
        assert_eq!(tag_box(&duck).as_deref(), Some("duckpools:pool"));
        let lp = json!({"ergoTree": "00", "value": 1, "assets": [{"tokenId": dexy::gold_mainnet::LP_NFT_ID, "amount": 1}]});
        assert_eq!(tag_box(&lp).as_deref(), Some("dexy:lp"));
        let fee = json!({"address": ARGUS_FEE_ADDRESS, "ergoTree": "00", "value": ARGUS_FEE_NANO, "assets": []});
        assert_eq!(tag_box(&fee).as_deref(), Some("argus_fee"));
        // The same address paid anything else is an ordinary payment.
        let paid = json!({"address": ARGUS_FEE_ADDRESS, "ergoTree": "00", "value": 5_000_000, "assets": []});
        assert_eq!(tag_box(&paid), None);
        let p2pk = json!({"ergoTree": "0008cd03e0e953d67d623597b372ee", "value": 1});
        assert_eq!(tag_box(&p2pk), None);
        let sell =
            json!({"ergoTree": amm::constants::swap_templates::N2T_SWAP_SELL_TEMPLATE, "value": 1});
        assert_eq!(tag_box(&sell).as_deref(), Some("spectrum:swap_order"));
        let deposit =
            json!({"ergoTree": amm::constants::lp_templates::N2T_DEPOSIT_TEMPLATE, "value": 1});
        assert_eq!(tag_box(&deposit).as_deref(), Some("spectrum:deposit_order"));
    }
}
