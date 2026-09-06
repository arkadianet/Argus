//! Token issuance (EIP-4).
//!
//! A new token's id is the id of the transaction's first input, and the
//! whole supply is minted into one output of that transaction. That
//! output carries the token's name, description and decimals in R4–R6
//! as UTF-8 byte collections, and for an NFT its kind, content hash and
//! link in R7–R9. Everything else in the inputs goes back to the wallet
//! as change, with the app fee and the miner fee on top.

use std::collections::HashMap;

use crate::dev_fee::{append_dev_fee_output, resolved_config};
use crate::eip12::{Eip12Asset, Eip12InputBox, Eip12Output, Eip12UnsignedTx};
use citadel_core::constants::{MIN_BOX_VALUE_NANO as MIN_BOX_VALUE, TX_FEE_NANO as TX_FEE};

/// What kind of NFT, as EIP-4 spells it in R7.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NftKind {
    Picture,
    Audio,
    Video,
}

impl NftKind {
    fn r7(self) -> [u8; 2] {
        match self {
            NftKind::Picture => [0x01, 0x01],
            NftKind::Audio => [0x01, 0x02],
            NftKind::Video => [0x01, 0x03],
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "picture" => Some(Self::Picture),
            "audio" => Some(Self::Audio),
            "video" => Some(Self::Video),
            _ => None,
        }
    }
}

/// The NFT registers: kind, SHA-256 of the content, and where it lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NftDetails {
    pub kind: NftKind,
    pub content_hash: Vec<u8>,
    pub url: String,
}

/// A token to issue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MintSpec {
    pub name: String,
    pub description: String,
    pub decimals: u8,
    pub amount: u64,
    pub nft: Option<NftDetails>,
}

#[derive(Debug)]
pub struct MintSummary {
    pub token_id: String,
    pub amount: u64,
    pub box_value: i64,
    pub miner_fee: i64,
    pub citadel_fee_nano: i64,
    pub change_erg: i64,
}

#[derive(Debug)]
pub struct MintBuildResult {
    pub unsigned_tx: Eip12UnsignedTx,
    pub summary: MintSummary,
}

#[derive(Debug, thiserror::Error)]
pub enum MintError {
    #[error("No inputs")]
    NoInputs,
    #[error("Token name is required")]
    EmptyName,
    #[error("Amount must be greater than zero")]
    ZeroAmount,
    #[error("Amount is beyond what a box can hold")]
    AmountTooLarge,
    #[error("An NFT is a single unit with no decimals")]
    NftShape,
    #[error("Content hash must be 32 bytes")]
    BadHash,
    #[error("Insufficient ERG: have {have}, need {need}")]
    InsufficientErg { have: i64, need: i64 },
    #[error("Citadel fee config error: {0}")]
    DevFee(String),
}

/// A `Coll[Byte]` constant: type code `0e`, the length as an unsigned
/// VLQ, then the bytes.
fn coll_byte(bytes: &[u8]) -> Result<String, MintError> {
    let mut out = vec![0x0eu8];
    let mut n = bytes.len() as u64;
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            break;
        }
        out.push(b | 0x80);
    }
    out.extend_from_slice(bytes);
    Ok(hex::encode(out))
}

/// The EIP-4 registers for `spec`.
pub fn issuance_registers(spec: &MintSpec) -> Result<HashMap<String, String>, MintError> {
    let mut regs = HashMap::new();
    regs.insert("R4".into(), coll_byte(spec.name.as_bytes())?);
    regs.insert("R5".into(), coll_byte(spec.description.as_bytes())?);
    regs.insert("R6".into(), coll_byte(spec.decimals.to_string().as_bytes())?);
    if let Some(nft) = &spec.nft {
        if nft.content_hash.len() != 32 {
            return Err(MintError::BadHash);
        }
        regs.insert("R7".into(), coll_byte(&nft.r7())?);
        regs.insert("R8".into(), coll_byte(&nft.content_hash)?);
        regs.insert("R9".into(), coll_byte(nft.url.as_bytes())?);
    }
    Ok(regs)
}

impl NftDetails {
    fn r7(&self) -> [u8; 2] {
        self.kind.r7()
    }
}

/// Build the issuance: the token box to `user_ergo_tree` first (its
/// token id is `user_inputs[0].box_id`), then change with every input
/// token, the app fee, the miner fee.
pub fn build_mint_tx(
    user_inputs: &[Eip12InputBox],
    spec: &MintSpec,
    user_ergo_tree: &str,
    current_height: i32,
) -> Result<MintBuildResult, MintError> {
    let first = user_inputs.first().ok_or(MintError::NoInputs)?;
    if spec.name.trim().is_empty() {
        return Err(MintError::EmptyName);
    }
    if spec.amount == 0 {
        return Err(MintError::ZeroAmount);
    }
    // A box asset amount is a signed 64-bit number; anything larger would
    // wrap to a negative supply rather than be refused.
    if spec.amount > i64::MAX as u64 {
        return Err(MintError::AmountTooLarge);
    }
    if spec.nft.is_some() && (spec.amount != 1 || spec.decimals != 0) {
        return Err(MintError::NftShape);
    }
    let registers = issuance_registers(spec)?;
    let fee_cfg = resolved_config();
    let citadel_fee = fee_cfg.budget();
    let box_value = MIN_BOX_VALUE;

    let total_erg: i64 = user_inputs
        .iter()
        .map(|b| b.value.parse::<i64>().unwrap_or(0))
        .try_fold(0i64, i64::checked_add)
        .ok_or(MintError::InsufficientErg { have: i64::MAX, need: 0 })?;
    let mut token_totals: Vec<(String, u64)> = Vec::new();
    for input in user_inputs {
        for asset in &input.assets {
            let amount = asset.amount.parse::<u64>().unwrap_or(0);
            match token_totals.iter_mut().find(|(id, _)| *id == asset.token_id) {
                Some((_, n)) => *n = n.saturating_add(amount),
                None => token_totals.push((asset.token_id.clone(), amount)),
            }
        }
    }
    // The change box always exists: it carries the inputs' tokens and the
    // leftover ERG, and must itself be at least a box.
    let need = box_value + TX_FEE + citadel_fee + MIN_BOX_VALUE;
    if total_erg < need {
        return Err(MintError::InsufficientErg { have: total_erg, need });
    }
    let change_erg = total_erg - box_value - TX_FEE - citadel_fee;

    let token_id = first.box_id.clone();
    let mut outputs = vec![
        Eip12Output {
            value: box_value.to_string(),
            ergo_tree: user_ergo_tree.to_string(),
            assets: vec![Eip12Asset::new(token_id.clone(), spec.amount as i64)],
            creation_height: current_height,
            additional_registers: registers,
        },
        Eip12Output {
            value: change_erg.to_string(),
            ergo_tree: user_ergo_tree.to_string(),
            assets: token_totals
                .into_iter()
                .filter(|(_, n)| *n > 0)
                .map(|(id, n)| Eip12Asset::new(id, n as i64))
                .collect(),
            creation_height: current_height,
            additional_registers: HashMap::new(),
        },
    ];
    append_dev_fee_output(&mut outputs, &fee_cfg, current_height)
        .map_err(|e| MintError::DevFee(e.to_string()))?;
    outputs.push(Eip12Output::fee(TX_FEE, current_height));

    Ok(MintBuildResult {
        unsigned_tx: Eip12UnsignedTx {
            inputs: user_inputs.to_vec(),
            data_inputs: Vec::new(),
            outputs,
        },
        summary: MintSummary {
            token_id,
            amount: spec.amount,
            box_value,
            miner_fee: TX_FEE,
            citadel_fee_nano: citadel_fee,
            change_erg,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(value: i64, assets: Vec<(&str, u64)>) -> Eip12InputBox {
        Eip12InputBox {
            box_id: "ab".repeat(32),
            transaction_id: "cd".repeat(32),
            index: 0,
            value: value.to_string(),
            ergo_tree: "0008cd02".into(),
            assets: assets
                .into_iter()
                .map(|(id, n)| Eip12Asset::new(id.to_string(), n as i64))
                .collect(),
            creation_height: 1,
            additional_registers: HashMap::new(),
            extension: HashMap::new(),
        }
    }

    #[test]
    fn a_fungible_token_is_minted_into_the_first_output_with_eip4_registers() {
        let spec = MintSpec {
            name: "Argus Test".into(),
            description: "a test".into(),
            decimals: 2,
            amount: 1_000_000,
            nft: None,
        };
        let r = build_mint_tx(&[input(1_000_000_000, vec![("tt", 5)])], &spec, "0008cd02", 100).unwrap();
        assert_eq!(r.summary.token_id, "ab".repeat(32));
        let out = &r.unsigned_tx.outputs[0];
        assert_eq!(out.assets[0].token_id, "ab".repeat(32));
        assert_eq!(out.assets[0].amount, "1000000");
        // "Argus Test" as a Coll[Byte]: 0e, length 10, bytes.
        assert_eq!(out.additional_registers["R4"], format!("0e0a{}", hex::encode("Argus Test")));
        assert_eq!(out.additional_registers["R6"], format!("0e01{}", hex::encode("2")));
        assert!(!out.additional_registers.contains_key("R7"));
        // Change keeps the inputs' tokens and the ERG less the fees.
        let change = &r.unsigned_tx.outputs[1];
        assert_eq!(change.assets[0].token_id, "tt");
        assert_eq!(change.value, r.summary.change_erg.to_string());
        assert_eq!(
            r.summary.change_erg,
            1_000_000_000 - MIN_BOX_VALUE - TX_FEE - r.summary.citadel_fee_nano
        );
    }

    #[test]
    fn an_nft_carries_kind_hash_and_link_and_must_be_one_unit() {
        let nft = NftDetails {
            kind: NftKind::Picture,
            content_hash: vec![7u8; 32],
            url: "ipfs://x".into(),
        };
        let spec = MintSpec {
            name: "Art".into(),
            description: String::new(),
            decimals: 0,
            amount: 1,
            nft: Some(nft.clone()),
        };
        let r = build_mint_tx(&[input(100_000_000, vec![])], &spec, "0008cd02", 100).unwrap();
        let regs = &r.unsigned_tx.outputs[0].additional_registers;
        assert_eq!(regs["R7"], "0e020101");
        assert_eq!(regs["R8"], format!("0e20{}", "07".repeat(32)));
        assert_eq!(regs["R9"], format!("0e08{}", hex::encode("ipfs://x")));
        let two = MintSpec { amount: 2, ..spec.clone() };
        assert!(matches!(build_mint_tx(&[input(100_000_000, vec![])], &two, "0008cd02", 100), Err(MintError::NftShape)));
        let bad_hash = MintSpec {
            nft: Some(NftDetails { content_hash: vec![1, 2], ..nft }),
            ..spec
        };
        assert!(matches!(build_mint_tx(&[input(100_000_000, vec![])], &bad_hash, "0008cd02", 100), Err(MintError::BadHash)));
    }

    #[test]
    fn a_long_description_gets_a_two_byte_length() {
        let long = "d".repeat(200);
        let spec = MintSpec { name: "n".into(), description: long.clone(), decimals: 0, amount: 1, nft: None };
        let regs = issuance_registers(&spec).unwrap();
        // 200 = 0xc8 → VLQ c8 01.
        assert_eq!(regs["R5"], format!("0ec801{}", hex::encode(&long)));
    }

    #[test]
    fn refuses_an_empty_name_zero_supply_or_too_little_erg() {
        let ok = MintSpec { name: "x".into(), description: String::new(), decimals: 0, amount: 1, nft: None };
        assert!(matches!(build_mint_tx(&[], &ok, "00", 1), Err(MintError::NoInputs)));
        assert!(matches!(build_mint_tx(&[input(1_000_000_000, vec![])], &MintSpec { name: " ".into(), ..ok.clone() }, "00", 1), Err(MintError::EmptyName)));
        assert!(matches!(build_mint_tx(&[input(1_000_000_000, vec![])], &MintSpec { amount: 0, ..ok.clone() }, "00", 1), Err(MintError::ZeroAmount)));
        assert!(matches!(build_mint_tx(&[input(2_000_000, vec![])], &ok, "00", 1), Err(MintError::InsufficientErg { .. })));
        let huge = MintSpec { amount: i64::MAX as u64 + 1, ..ok.clone() };
        assert!(
            matches!(build_mint_tx(&[input(1_000_000_000, vec![])], &huge, "00", 1), Err(MintError::AmountTooLarge)),
            "a supply past i64::MAX would wrap negative"
        );
        let most = MintSpec { amount: i64::MAX as u64, ..ok.clone() };
        assert_eq!(
            build_mint_tx(&[input(1_000_000_000, vec![])], &most, "00", 1).unwrap().unsigned_tx.outputs[0].assets[0].amount,
            i64::MAX.to_string()
        );
        assert!(NftKind::parse("audio") == Some(NftKind::Audio) && NftKind::parse("gif").is_none());
    }
}
