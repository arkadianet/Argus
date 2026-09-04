//! The four ErgoMixer contracts, as they exist on mainnet.
//!
//! These are **not** compiled here. Every tree below was lifted verbatim from
//! a mainnet transaction and the whole set is re-verified by
//! [`verify_contract_wiring`] and by the tests at the bottom of this file:
//! each contract embeds the blake2b256 hash of the next one as a compiled-in
//! constant, so the four hashes form a closed chain that cannot be satisfied
//! by an accidental or hostile substitution.
//!
//! ```text
//!   token emission ──embeds──▶ blake2b256(half mix)
//!   half  mix      ──embeds──▶ blake2b256(full mix)
//!   full  mix      ──embeds──▶ blake2b256(fee emission)
//!   token emission ──embeds──▶ blake2b256(mixer income P2PK)
//!   fee / token emission ─────▶ mixerOwner public key
//!   half / full / fee / token ▶ the mixing token id
//! ```
//!
//! Source transactions (mainnet):
//! - remix-as-Bob `2828df5af82ba172a06476d9265cb672faf95be83e488a68fdf1bdab3a6ae32f`
//!   — inputs `[half mix, full mix, fee emission]`, outputs `[full, full, fee copy, miner fee]`.
//! - Alice entry `b8d6a127ea0152ad2d16ec7d6ab46910a74f2e92001b9c10ce8c6f34ad41b206`
//!   — inputs `[funding, token emission]`, outputs `[half mix, income, token emission copy, miner fee]`.
//!
//! The scripts they compile from are in ErgoMixer's
//! `mixer/app/mixinterface/TokenErgoMix.scala`; the ErgoScript sources are
//! reproduced in the design doc, not here, because the deployed bytes are the
//! only thing interoperability depends on.

use ergo_chain_types::blake2b256_hash;

use crate::error::ZeroJoinError;

/// The mixing token. One or two units are burned per mixing transaction; a
/// box's remaining balance is its "mix level", the number of rounds it can
/// still pay for.
pub const MIXING_TOKEN_ID: &str =
    "1a6a8c16e4b1cc9d73d03183565cfb8e79dd84198cb66beeed7d3463e0da2b98";

/// Half-mix box script: Alice's `proveDlog(gX)` refund, or Bob's spend into
/// two full-mix boxes proving one of the two `(c1, c2)` orderings honest.
pub const HALF_MIX_ERGO_TREE_HEX: &str = "100d0e201a6a8c16e4b1cc9d73d03183565cfb8e79dd84198cb66beeed7d3463e0da2b9804000e20c9ffb7bf74cd7a0fc2b76baf54b4c6192b0a1689e6b0ea6b5d988447c353a3ee0400040004020504040205000402040204000100d806d601e4c6a70407d6027300d603b2a5730100d604c672030407d6057302d606db6a01ddeb02ea02cd7201d1afa5d9010763afdb63087207d901094d0e948c720901720295e67204d808d607db63087203d608b27207730300d609db6308a7d60ab27209730400d60bd9010b63eded93cbc2720b720593e4c6720b070ecbc2a793c1720bc1a7d60cb2a5730500d60de4c672030507d60ee47204ea02d1edededededededeced938c7208018c720a01919c8c72080273068c720a0293cbc2b2a47307007205edededda720b017203da720b01720c937207db6308720cd801d60f86027202730893b27209730901720fb27207730a01720f93e4c672030607720193e4c6720c0607720193e4c6720c0407720d93e4c6720c0507e4720493c5a7c5b2a4730b0094e47204720deb02ce72067201720e720dce72067201720d720ed1730c";

/// Full-mix box script: spendable with `proveDlog(c2)` (its Bob) or
/// `proveDHTuple(g, c1, gX, c2)` (its Alice), and only into a next round or a
/// transaction that burns every mixing token it holds.
pub const FULL_MIX_ERGO_TREE_HEX: &str = "10060e2002d1541415c323527f19ef5b103eb33c220ea8b66fcb711806b0037d115d63f204000402040004040e201a6a8c16e4b1cc9d73d03183565cfb8e79dd84198cb66beeed7d3463e0da2b98d803d601e4c6a70507d602d901026393cbc27202e4c6a7070ed6037300ea02eb02cd7201cedb6a01dde4c6a70407e4c6a706077201d1ececedda720201b2a573010093cbc2b2a47302007203edda720201b2a473030093cbc2b2a47304007203afa5d9010463afdb63087204d901064d0e948c7206017305";

/// Fee emission box script: pays the miner fee of every mixing transaction so
/// that no spender has to add a linkable fee input of their own.
pub const FEE_EMISSION_ERGO_TREE_HEX: &str = "10160e201a6a8c16e4b1cc9d73d03183565cfb8e79dd84198cb66beeed7d3463e0da2b9805000500040008cd03b038b0783c899be6b5b98bcf55df573c87cb2e01c16604c174e5a7e6105e848e04040406040204000400040604080402040004000402040405000500050205040100d808d601b1a4d602c2a7d603c6a70405d6047300d605860272047301d6067302d607d9010763d806d609c27207d60a9372097202d60bd805d60bc17207d60cc1a7d60de47203d60e99720c720dd60f92720b720e720fd60ced720a720bd60dd802d60dc672070405d60e93720d7203720ed60eed720c720d720ed608d9010863d806d60adb63087208d60bb2720a7303017205d60c8c720b01d60d93720c7204d60ed801d60e8c720b02720ed60f95720d720e7206720feb02730495ed937201730593b1a57306d802d6097207d60a7208d1edda720901b2a57307008fda720a01b2a5730800da720a01b2a473090095ed937201730a93b1a5730bd803d609da720801b2a4730c00d60ada720801b2a4730d00d60b999a720a72099ada720801b2a5730e00da720801b2a5730f00d1edda720701b2a5731000eded917209731191720a7312ec93720b731393720b7314d17315";

/// Token emission box script: sells mixing tokens in fixed batches, paying the
/// operator's income address. This is the box Argus must spend to *enter* a
/// mix; it is the operator's, and mixing stops if it is not refilled.
pub const TOKEN_EMISSION_ERGO_TREE_HEX: &str = "101c0e20199a5a0838f19ddd5a25abee8d90783c6c1796bbca31f47f9153e7e76816e3fb04000e205f4acea2d24afd2de28d3ca2cef4eeb044456b60a861b102f6a864afba833beb040804000400040004000500040004000402040404020404040a0400040004000400050004000400040204060404040608cd03b038b0783c899be6b5b98bcf55df573c87cb2e01c16604c174e5a7e6105e848ed809d601b1a5d6027300d603c2a7d604c6a7040c4005d605c6a70504d606b2db6308a7730100d6078c720601d6087302d6098c720602eb02d1ecededed9372017303dad9010a6393cbc2720a720201b2a5730400dad9010a3c6363d802d60c8c720a01d60d8c720a02ededededed93c2720c720393c6720c040c4005720493c6720c05047205938cb2db6308720c73050001720793cbc2720d7208aee47204d9010e4005ededed928cb2db6308720c730600029972097e8c720e010592c1720cc1a792c1720d9a8c720e029dc1b2a57307007ee4720505d803d610860272077308d611b2db6308720d7309017210d612b2db6308b2a5730a00730b017210ed938c7211018c721201928c7211029d8c7212027ee4720505018602b2a5730c00b2a5730d0093b1a4730eededed937201730fdad9010a6393cbc2720a720201b2a4731000dad9010a3c6363d802d60c8c720a01d60d8c720a02ededededed93c2720c720393c6720c040c4005720493c6720c05047205938cb2db6308720c73110001720793cbc2720d7208aee47204d9010e4005ededed928cb2db6308720c731200029972097e8c720e010592c1720cc1a792c1720d9a8c720e029dc1b2a57313007ee4720505d803d610860272077314d611b2db6308720d7315017210d612b2db6308b2a57316007317017210ed938c7211018c721201928c7211029d8c7212027ee4720505018602b2a5731800b2a573190093b1a4731a731b";

/// P2PK tree of ErgoMixer's income address `9f4bRuh6yjhz4wWuz75ihSJwXHrtGXsZiQWUaHSDRf3Da16dMuf`.
/// The token emission contract pins `blake2b256` of exactly these bytes, so an
/// entry transaction must pay this script or it will not validate.
pub const MIXER_INCOME_ERGO_TREE_HEX: &str =
    "0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582";

/// ErgoMixer's operator address (`mixerIncome` in `TokenErgoMix.scala`).
pub const MIXER_INCOME_ADDRESS: &str = "9f4bRuh6yjhz4wWuz75ihSJwXHrtGXsZiQWUaHSDRf3Da16dMuf";

/// The operator key that can unilaterally spend the fee and token emission
/// boxes — and nothing else. It has no rights over any half- or full-mix box.
pub const MIXER_OWNER_PK_HEX: &str =
    "03b038b0783c899be6b5b98bcf55df573c87cb2e01c16604c174e5a7e6105e848e";

/// `blake2b256(HALF_MIX_ERGO_TREE_HEX)`. Sits in R7 of every full-mix box and
/// as a constant in the token emission contract.
pub const HALF_MIX_SCRIPT_HASH_HEX: &str =
    "199a5a0838f19ddd5a25abee8d90783c6c1796bbca31f47f9153e7e76816e3fb";

/// `blake2b256(FULL_MIX_ERGO_TREE_HEX)`; a constant of the half-mix contract.
pub const FULL_MIX_SCRIPT_HASH_HEX: &str =
    "c9ffb7bf74cd7a0fc2b76baf54b4c6192b0a1689e6b0ea6b5d988447c353a3ee";

/// `blake2b256(FEE_EMISSION_ERGO_TREE_HEX)`; a constant of the full-mix contract.
pub const FEE_EMISSION_SCRIPT_HASH_HEX: &str =
    "02d1541415c323527f19ef5b103eb33c220ea8b66fcb711806b0037d115d63f2";

/// `blake2b256(MIXER_INCOME_ERGO_TREE_HEX)`; a constant of the token emission contract.
pub const MIXER_INCOME_SCRIPT_HASH_HEX: &str =
    "5f4acea2d24afd2de28d3ca2cef4eeb044456b60a861b102f6a864afba833beb";

/// `blake2b256(TOKEN_EMISSION_ERGO_TREE_HEX)`. Nothing on chain references it;
/// it is here so callers can identify the box by hash the way the others are.
pub const TOKEN_EMISSION_SCRIPT_HASH_HEX: &str =
    "213d9f5cd1cbd3802930e3b37b3c69a4bba4fbc2fe7e7e788378f35dff02cbfa";

/// blake2b256 of an ErgoTree given as hex, as hex.
pub fn script_hash_hex(ergo_tree_hex: &str) -> Result<String, ZeroJoinError> {
    let bytes = hex::decode(ergo_tree_hex)
        .map_err(|_| ZeroJoinError::Serialization("ErgoTree is not hex".into()))?;
    Ok(hex::encode(blake2b256_hash(&bytes).0))
}

/// Mainnet P2S address for an ErgoTree hex.
pub fn address_for_tree(ergo_tree_hex: &str) -> Result<String, ZeroJoinError> {
    use ergo_lib::ergotree_ir::chain::address::{Address, AddressEncoder, NetworkPrefix};
    use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
    use ergo_lib::ergotree_ir::serialization::SigmaSerializable;

    let bytes = hex::decode(ergo_tree_hex)
        .map_err(|_| ZeroJoinError::Serialization("ErgoTree is not hex".into()))?;
    let tree = ErgoTree::sigma_parse_bytes(&bytes)
        .map_err(|e| ZeroJoinError::Serialization(e.to_string()))?;
    Ok(AddressEncoder::new(NetworkPrefix::Mainnet).address_to_str(
        &Address::recreate_from_ergo_tree(&tree)
            .map_err(|e| ZeroJoinError::Serialization(e.to_string()))?,
    ))
}

/// True when `hex` is exactly the deployed half-mix script.
pub fn is_half_mix_tree(ergo_tree_hex: &str) -> bool {
    ergo_tree_hex.eq_ignore_ascii_case(HALF_MIX_ERGO_TREE_HEX)
}

/// True when `hex` is exactly the deployed full-mix script.
pub fn is_full_mix_tree(ergo_tree_hex: &str) -> bool {
    ergo_tree_hex.eq_ignore_ascii_case(FULL_MIX_ERGO_TREE_HEX)
}

/// True when `hex` is exactly the deployed fee emission script.
pub fn is_fee_emission_tree(ergo_tree_hex: &str) -> bool {
    ergo_tree_hex.eq_ignore_ascii_case(FEE_EMISSION_ERGO_TREE_HEX)
}

/// True when `hex` is exactly the deployed token emission script.
pub fn is_token_emission_tree(ergo_tree_hex: &str) -> bool {
    ergo_tree_hex.eq_ignore_ascii_case(TOKEN_EMISSION_ERGO_TREE_HEX)
}

/// Re-derive every pinned hash and check that each contract really does embed
/// the next one's hash and the shared identities.
///
/// Cheap, and worth calling before building any mixing transaction: it turns
/// "the constants in this file drifted" into an error instead of a
/// transaction that strands funds in a box nobody can spend.
pub fn verify_contract_wiring() -> Result<(), ZeroJoinError> {
    let checks = [
        (
            "half-mix script hash",
            script_hash_hex(HALF_MIX_ERGO_TREE_HEX)?,
            HALF_MIX_SCRIPT_HASH_HEX,
        ),
        (
            "full-mix script hash",
            script_hash_hex(FULL_MIX_ERGO_TREE_HEX)?,
            FULL_MIX_SCRIPT_HASH_HEX,
        ),
        (
            "fee emission script hash",
            script_hash_hex(FEE_EMISSION_ERGO_TREE_HEX)?,
            FEE_EMISSION_SCRIPT_HASH_HEX,
        ),
        (
            "token emission script hash",
            script_hash_hex(TOKEN_EMISSION_ERGO_TREE_HEX)?,
            TOKEN_EMISSION_SCRIPT_HASH_HEX,
        ),
        (
            "mixer income script hash",
            script_hash_hex(MIXER_INCOME_ERGO_TREE_HEX)?,
            MIXER_INCOME_SCRIPT_HASH_HEX,
        ),
    ];
    for (what, got, want) in checks {
        if got != want {
            return Err(ZeroJoinError::ContractMismatch {
                what: what.to_string(),
                expected: want.to_string(),
                found: got,
            });
        }
    }

    // Each contract must literally contain the constants it is compiled with.
    let embeds: [(&str, &str, &str); 8] = [
        ("half mix", HALF_MIX_ERGO_TREE_HEX, MIXING_TOKEN_ID),
        ("half mix", HALF_MIX_ERGO_TREE_HEX, FULL_MIX_SCRIPT_HASH_HEX),
        ("full mix", FULL_MIX_ERGO_TREE_HEX, MIXING_TOKEN_ID),
        (
            "full mix",
            FULL_MIX_ERGO_TREE_HEX,
            FEE_EMISSION_SCRIPT_HASH_HEX,
        ),
        ("fee emission", FEE_EMISSION_ERGO_TREE_HEX, MIXING_TOKEN_ID),
        (
            "fee emission",
            FEE_EMISSION_ERGO_TREE_HEX,
            MIXER_OWNER_PK_HEX,
        ),
        (
            "token emission",
            TOKEN_EMISSION_ERGO_TREE_HEX,
            HALF_MIX_SCRIPT_HASH_HEX,
        ),
        (
            "token emission",
            TOKEN_EMISSION_ERGO_TREE_HEX,
            MIXER_INCOME_SCRIPT_HASH_HEX,
        ),
    ];
    for (what, tree, needle) in embeds {
        if !tree.contains(needle) {
            return Err(ZeroJoinError::ContractMismatch {
                what: format!("{what} contract constant"),
                expected: needle.to_string(),
                found: "absent".to_string(),
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_four_contracts_form_a_closed_hash_chain() {
        verify_contract_wiring().expect("wiring holds");
    }

    #[test]
    fn every_tree_parses_and_has_an_address() {
        for tree in [
            HALF_MIX_ERGO_TREE_HEX,
            FULL_MIX_ERGO_TREE_HEX,
            FEE_EMISSION_ERGO_TREE_HEX,
            TOKEN_EMISSION_ERGO_TREE_HEX,
            MIXER_INCOME_ERGO_TREE_HEX,
        ] {
            let addr = address_for_tree(tree).expect("tree parses");
            assert!(addr.starts_with('9') || addr.len() > 40, "{addr}");
        }
    }

    #[test]
    fn the_income_tree_is_the_operators_published_address() {
        assert_eq!(
            address_for_tree(MIXER_INCOME_ERGO_TREE_HEX).unwrap(),
            MIXER_INCOME_ADDRESS
        );
        // ErgoMixer's `mixerOwner`; the key guarding both emission boxes.
        assert!(FEE_EMISSION_ERGO_TREE_HEX.contains(MIXER_OWNER_PK_HEX));
        assert!(TOKEN_EMISSION_ERGO_TREE_HEX.contains(MIXER_OWNER_PK_HEX));
    }

    #[test]
    fn tree_predicates_do_not_confuse_the_contracts() {
        assert!(is_half_mix_tree(HALF_MIX_ERGO_TREE_HEX));
        assert!(!is_half_mix_tree(FULL_MIX_ERGO_TREE_HEX));
        assert!(is_full_mix_tree(FULL_MIX_ERGO_TREE_HEX));
        assert!(!is_full_mix_tree(HALF_MIX_ERGO_TREE_HEX));
        assert!(is_fee_emission_tree(FEE_EMISSION_ERGO_TREE_HEX));
        assert!(!is_fee_emission_tree(TOKEN_EMISSION_ERGO_TREE_HEX));
        assert!(is_token_emission_tree(TOKEN_EMISSION_ERGO_TREE_HEX));
        assert!(!is_token_emission_tree(FEE_EMISSION_ERGO_TREE_HEX));
    }
}
