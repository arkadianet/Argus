//! SigmaUSD (AgeUSD) protocol integration for Argus mobile.
//!
//! Wraps the vendored Citadel `sigmausd` protocol crate. Read-only state and
//! previews never touch the wallet handle; the build function reuses the
//! existing prepare → confirm → sign & broadcast flow.

use citadel_core::constants::{MIN_BOX_VALUE_NANO, TX_FEE_NANO};
use sigmausd::calculator::{
    cost_to_mint_sigrsv, cost_to_mint_sigusd, erg_from_redeem_sigrsv, erg_from_redeem_sigusd,
};
use sigmausd::constants::NftIds;
use sigmausd::fetch::fetch_sigmausd_state;
use sigmausd::tx_builder::{
    validate_mint_sigusd, validate_mint_sigrsv, validate_redeem_sigusd, validate_redeem_sigrsv,
    SigmaUsdAction,
};

use crate::api_dexy_impl::dexy_client;
use crate::error::ArgusError;

fn proto_err<T: std::fmt::Display>(e: T) -> String {
    ArgusError::NodeError(e.to_string()).to_json_string()
}

fn ser_err<T: std::fmt::Display>(e: T) -> String {
    ArgusError::SerializationError(e.to_string()).to_json_string()
}

/// Protocol constants for the current network (mainnet only).
pub(crate) fn nft_ids() -> Result<NftIds, String> {
    NftIds::for_network(citadel_core::Network::Mainnet).ok_or_else(|| {
        ArgusError::Generic("SigmaUSD is not available on this network".to_string())
            .to_json_string()
    })
}

fn parse_action(action: &str) -> Result<SigmaUsdAction, String> {
    action.parse::<SigmaUsdAction>().map_err(|_| {
        ArgusError::Generic(format!(
            "Invalid SigmaUSD action '{action}'. Use 'mint_sigusd', 'redeem_sigusd', \
             'mint_sigrsv', or 'redeem_sigrsv'"
        ))
        .to_json_string()
    })
}

fn token_name(action: SigmaUsdAction) -> &'static str {
    match action {
        SigmaUsdAction::MintSigUsd | SigmaUsdAction::RedeemSigUsd => "SigUSD",
        SigmaUsdAction::MintSigRsv | SigmaUsdAction::RedeemSigRsv => "SigRSV",
    }
}

/// Live protocol state: bank reserves, oracle rate, reserve ratio, prices,
/// liabilities/equity, and per-action availability with limits.
pub(crate) async fn state(node_url: Option<String>) -> Result<String, String> {
    let ids = nft_ids()?;
    let client = dexy_client(node_url).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let state = fetch_sigmausd_state(&client, &caps, &ids)
        .await
        .map_err(proto_err)?;
    serde_json::to_string(&state).map_err(ser_err)
}

fn preview_json(
    action: SigmaUsdAction,
    amount: i64,
    erg_cost_nano: i64,
    erg_out_nano: i64,
    protocol_fee_nano: i64,
    total_cost_nano: i64,
    can_execute: bool,
    error: Option<String>,
) -> String {
    serde_json::json!({
        "action": action.as_str(),
        "token_amount": amount.to_string(),
        "token_name": token_name(action),
        "erg_cost_nano": erg_cost_nano.to_string(),
        "erg_out_nano": erg_out_nano.to_string(),
        "protocol_fee_nano": protocol_fee_nano.to_string(),
        "tx_fee_nano": TX_FEE_NANO.to_string(),
        "total_cost_nano": total_cost_nano.to_string(),
        "can_execute": can_execute,
        "error": error,
    })
    .to_string()
}

/// Cost/proceeds preview for one of the four bank actions at the live oracle
/// rate. Mirrors the availability rules the transaction builder enforces.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn preview(
    action: &str,
    amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    let parsed = parse_action(action)?;
    if amount <= 0 {
        return Ok(preview_json(
            parsed,
            amount,
            0,
            0,
            0,
            0,
            false,
            Some("Amount must be positive".to_string()),
        ));
    }
    let ids = nft_ids()?;
    let client = dexy_client(node_url).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let state = fetch_sigmausd_state(&client, &caps, &ids)
        .await
        .map_err(proto_err)?;

    // Availability + limit checks mirror tx_builder::validate_*.
    type Validation = Result<(), citadel_core::ProtocolError>;
    let check: Validation = match parsed {
        SigmaUsdAction::MintSigUsd => validate_mint_sigusd(amount, &state),
        SigmaUsdAction::RedeemSigUsd => validate_redeem_sigusd(amount, &state),
        SigmaUsdAction::MintSigRsv => validate_mint_sigrsv(amount, &state),
        SigmaUsdAction::RedeemSigRsv => validate_redeem_sigrsv(amount, &state),
    };
    if let Err(e) = check {
        return Ok(preview_json(
            parsed,
            amount,
            0,
            0,
            0,
            0,
            false,
            Some(e.to_string()),
        ));
    }

    match parsed {
        SigmaUsdAction::MintSigUsd => {
            let calc = cost_to_mint_sigusd(amount, state.oracle_erg_per_usd_nano);
            let total = calc.net_amount + TX_FEE_NANO + MIN_BOX_VALUE_NANO;
            Ok(preview_json(
                parsed,
                amount,
                calc.net_amount,
                0,
                calc.fee,
                total,
                true,
                None,
            ))
        }
        SigmaUsdAction::RedeemSigUsd => {
            let calc = erg_from_redeem_sigusd(amount, state.oracle_erg_per_usd_nano);
            Ok(preview_json(
                parsed,
                amount,
                0,
                calc.net_amount,
                calc.fee,
                TX_FEE_NANO,
                true,
                None,
            ))
        }
        SigmaUsdAction::MintSigRsv => {
            let calc = cost_to_mint_sigrsv(amount, state.sigrsv_price_nano);
            let total = calc.net_amount + TX_FEE_NANO + MIN_BOX_VALUE_NANO;
            Ok(preview_json(
                parsed,
                amount,
                calc.net_amount,
                0,
                calc.fee,
                total,
                true,
                None,
            ))
        }
        SigmaUsdAction::RedeemSigRsv => {
            let calc = erg_from_redeem_sigrsv(amount, state.sigrsv_price_nano);
            Ok(preview_json(
                parsed,
                amount,
                0,
                calc.net_amount,
                calc.fee,
                TX_FEE_NANO,
                true,
                None,
            ))
        }
    }
}
