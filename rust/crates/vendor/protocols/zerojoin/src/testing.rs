//! Fixtures and synthetic boxes for the crate's own tests.
//!
//! The fixtures are real mainnet boxes, captured with the explorer's
//! `boxes/unspent/byTokenId/<mixing token>` endpoint and from the two
//! transactions cited in [`crate::contracts`]. They are the ground truth for
//! everything the parsers claim.

use ergo_chain_types::EcPoint;
use ergo_lib::wallet::ext_secret_key::ExtSecretKey;
use ergo_lib::wallet::mnemonic::Mnemonic;
use ergo_tx::{Eip12Asset, Eip12InputBox, Eip12Output};

use crate::boxes::{
    parse_explorer_boxes, FeeEmissionBox, FullMixBox, HalfMixBox, TokenEmissionBox,
};
use crate::contracts::{FULL_MIX_ERGO_TREE_HEX, HALF_MIX_ERGO_TREE_HEX, MIXING_TOKEN_ID};
use crate::round::{full_mix_outputs, half_mix_output, MixTokenSplit, PairOrder};
use crate::secret::MixSecret;

pub const HALF_MIX_FIXTURE: &str = include_str!("../test/fixtures/half_mix_boxes.json");
pub const FULL_MIX_FIXTURE: &str = include_str!("../test/fixtures/full_mix_boxes.json");
pub const FEE_EMISSION_FIXTURE: &str = include_str!("../test/fixtures/fee_emission_boxes.json");
pub const TOKEN_EMISSION_FIXTURE: &str = include_str!("../test/fixtures/token_emission_boxes.json");

/// Parse one of the fixture files into EIP-12 input boxes.
pub fn fixture_boxes(json: &str) -> Vec<Eip12InputBox> {
    parse_explorer_boxes(json).expect("fixture parses")
}

/// The first fee emission box in the fixtures.
pub fn fixture_fee_box() -> FeeEmissionBox {
    FeeEmissionBox::parse(&fixture_boxes(FEE_EMISSION_FIXTURE)[0]).expect("fee box parses")
}

/// The first token emission box in the fixtures.
pub fn fixture_token_box() -> TokenEmissionBox {
    TokenEmissionBox::parse(&fixture_boxes(TOKEN_EMISSION_FIXTURE)[0]).expect("token box parses")
}

const MNEMONIC: &str = "slow silly start wash bundle suffer bulb ancient height spin express remind today effort helmet";

/// A deterministic secret for `(mix_id, round)` from a fixed test mnemonic.
pub fn test_secret(mix_id: u32, round: u32) -> MixSecret {
    // The seed stretch is slow by design; recovery tests derive hundreds.
    static ROOT: std::sync::OnceLock<ExtSecretKey> = std::sync::OnceLock::new();
    let root =
        ROOT.get_or_init(|| ExtSecretKey::derive_master(Mnemonic::to_seed(MNEMONIC, "")).unwrap());
    MixSecret::derive(root, mix_id, round).unwrap()
}

fn fake_input(
    value: i64,
    ergo_tree: &str,
    assets: Vec<Eip12Asset>,
    registers: Vec<(&str, String)>,
    tag: u8,
) -> Eip12InputBox {
    Eip12InputBox {
        box_id: hex::encode([tag; 32]),
        transaction_id: hex::encode([tag.wrapping_add(1); 32]),
        index: 0,
        value: value.to_string(),
        ergo_tree: ergo_tree.to_string(),
        assets,
        creation_height: 1_000_000,
        additional_registers: registers
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect(),
        extension: Default::default(),
    }
}

/// A half-mix box with a chosen `gX`, denomination and mix level.
///
/// Takes the public `gX` rather than a secret, because most of the half-mix
/// boxes a wallet meets are strangers'.
pub fn synthetic_half_mix(g_x: EcPoint, value: i64, level: i64) -> HalfMixBox {
    let r4 = crate::boxes::group_element_register(&g_x).expect("point serializes");
    HalfMixBox::parse(&fake_input(
        value,
        HALF_MIX_ERGO_TREE_HEX,
        vec![Eip12Asset::new(MIXING_TOKEN_ID, level)],
        vec![("R4", r4)],
        0xa1,
    ))
    .expect("synthetic half-mix parses")
}

/// A half-mix box as our own Alice would post it, straight from the round model.
pub fn synthetic_own_half_mix(x: &MixSecret, value: i64, level: i64) -> HalfMixBox {
    let out = half_mix_output(value, x, level, &None, 1_000_000).expect("half-mix output");
    HalfMixBox::parse(&Eip12InputBox {
        box_id: hex::encode([0xa2; 32]),
        transaction_id: hex::encode([0xa3; 32]),
        index: 0,
        value: out.value.clone(),
        ergo_tree: out.ergo_tree.clone(),
        assets: out.assets.clone(),
        creation_height: out.creation_height,
        additional_registers: out.additional_registers.clone(),
        extension: Default::default(),
    })
    .expect("own half-mix parses")
}

/// The two full-mix boxes a round would produce, parsed back as boxes.
pub fn synthetic_full_mix(
    g_x: &EcPoint,
    y: &MixSecret,
    order: PairOrder,
    value: i64,
    level: i64,
) -> FullMixBox {
    let outs = full_mix_outputs(
        value,
        g_x,
        y,
        order,
        MixTokenSplit {
            per_output: level,
            burned: 1,
        },
        &None,
        1_000_000,
    )
    .expect("outputs build");
    full_mix_from_output(&outs[0])
}

/// Both boxes of a synthetic round, so a test can pick either side.
pub fn synthetic_round(
    g_x: &EcPoint,
    y: &MixSecret,
    order: PairOrder,
    value: i64,
    level: i64,
) -> [FullMixBox; 2] {
    let outs = full_mix_outputs(
        value,
        g_x,
        y,
        order,
        MixTokenSplit {
            per_output: level,
            burned: 1,
        },
        &None,
        1_000_000,
    )
    .expect("outputs build");
    [
        full_mix_from_output(&outs[0]),
        full_mix_from_output(&outs[1]),
    ]
}

/// Read an output back as a spendable box, the way the next round would see
/// it once the transaction is on chain.
pub fn full_mix_from_output(out: &Eip12Output) -> FullMixBox {
    let value: i64 = out.value.parse().expect("value");
    let input = Eip12InputBox {
        box_id: hex::encode([0xf1; 32]),
        transaction_id: hex::encode([0xf2; 32]),
        index: 0,
        value: out.value.clone(),
        ergo_tree: out.ergo_tree.clone(),
        assets: out.assets.clone(),
        creation_height: out.creation_height,
        additional_registers: out.additional_registers.clone(),
        extension: Default::default(),
    };
    debug_assert_eq!(input.ergo_tree, FULL_MIX_ERGO_TREE_HEX);
    let _ = value;
    FullMixBox::parse(&input).expect("full-mix output parses as a box")
}

/// A plain P2PK funding box for the entry builders.
pub fn funding_box(value: i64, assets: Vec<Eip12Asset>) -> Eip12InputBox {
    fake_input(
        value,
        "0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582",
        assets,
        vec![],
        0xb2,
    )
}
