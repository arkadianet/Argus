//! Dexy protocol integration for Argus mobile.
//!
//! Wraps the vendored Citadel `dexy` protocol crate. Read-only market state and
//! previews never touch the wallet handle; the build functions reuse the
//! existing prepare → confirm → sign & broadcast flow.

use citadel_core::constants::{MIN_BOX_VALUE_NANO, TX_FEE_NANO};
use citadel_core::{Network, NodeConfig, TokenId};
use dexy::calculator::{
    calculate_lp_deposit, calculate_lp_redeem, calculate_lp_swap_output,
    calculate_lp_swap_price_impact, cost_to_mint_dexy,
};
use dexy::constants::{
    DexyIds, DexyVariant, LP_REDEEM_FEE_PCT, LP_SWAP_FEE_DENOM, LP_SWAP_FEE_NUM,
};
use dexy::fetch::{fetch_dexy_state, parse_lp_box};
use dexy::rates::DexyRates;

use crate::error::ArgusError;

/// Resolve a node URL, preferring the explicit one, then the configured set.
fn resolve_node_url(node_url: Option<String>) -> String {
    if let Some(u) = node_url {
        let clean = u.trim().trim_end_matches('/');
        if !clean.is_empty() {
            return clean.to_string();
        }
    }
    wallet_net::client::node_urls(None)
        .into_iter()
        .next()
        .unwrap_or_default()
}

/// Build a Citadel node client for the dexy protocol fetchers.
pub(crate) async fn dexy_client(
    node_url: Option<String>,
) -> Result<ergo_node_client::NodeClient, String> {
    let url = resolve_node_url(node_url);
    if url.is_empty() {
        return Err(ArgusError::NodeUnreachable("no reachable node configured".into())
            .to_json_string());
    }
    ergo_node_client::NodeClient::new(NodeConfig {
        url,
        api_key: String::new(),
    })
    .await
    .map_err(|e| ArgusError::NodeUnreachable(e.to_string()).to_json_string())
}

fn parse_variant(variant: &str) -> Result<DexyVariant, String> {
    variant.parse::<DexyVariant>().map_err(|_| {
        ArgusError::Generic(format!("Invalid Dexy variant: {variant}. Use 'gold' or 'usd'"))
            .to_json_string()
    })
}

pub(crate) fn ids_for(variant: DexyVariant) -> Result<DexyIds, String> {
    DexyIds::for_variant(variant, Network::Mainnet).ok_or_else(|| {
        ArgusError::Generic(format!(
            "Dexy {} is not available on this network",
            variant.token_name()
        ))
        .to_json_string()
    })
}

fn proto_err<T: std::fmt::Display>(e: T) -> String {
    ArgusError::NodeError(e.to_string()).to_json_string()
}

fn ser_err<T: std::fmt::Display>(e: T) -> String {
    ArgusError::SerializationError(e.to_string()).to_json_string()
}

/// Clamp slippage to a valid percentage. Non-finite, NaN, or out-of-range
/// values fall back to the 0.5% default.
fn clamp_slippage(value: Option<f64>) -> f64 {
    match value {
        Some(p) if p.is_finite() && (0.0..=100.0).contains(&p) => p,
        _ => 0.5,
    }
}

/// Live protocol state + derived mint rates for a variant.
pub(crate) async fn state(variant: &str, node_url: Option<String>) -> Result<String, String> {
    let variant = parse_variant(variant)?;
    let ids = ids_for(variant)?;
    let client = dexy_client(node_url).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let state = fetch_dexy_state(&client, &caps, &ids).await.map_err(proto_err)?;
    let rates = DexyRates::from_state(&state);
    serde_json::to_string(&serde_json::json!({ "state": state, "rates": rates })).map_err(ser_err)
}

/// Mint cost preview at the live oracle rate. Mirrors Citadel's DTO.
pub(crate) async fn preview_mint(
    variant: &str,
    amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    let dexy_variant = parse_variant(variant)?;
    let ids = ids_for(dexy_variant)?;
    let client = dexy_client(node_url).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let state = fetch_dexy_state(&client, &caps, &ids).await.map_err(proto_err)?;

    if amount <= 0 {
        return Ok(preview_mint_json(
            dexy_variant,
            amount,
            0,
            0,
            false,
            Some("Amount must be positive".to_string()),
        ));
    }
    if !state.can_mint {
        return Ok(preview_mint_json(
            dexy_variant,
            amount,
            0,
            0,
            false,
            Some("Minting is currently unavailable".to_string()),
        ));
    }
    if amount > state.dexy_in_bank {
        return Ok(preview_mint_json(
            dexy_variant,
            amount,
            0,
            0,
            false,
            Some(format!("Amount exceeds available: {}", state.dexy_in_bank)),
        ));
    }

    let calc = cost_to_mint_dexy(amount, state.oracle_rate_nano, dexy_variant.decimals());
    let tx_fee = TX_FEE_NANO;
    let total = calc.erg_amount + tx_fee + MIN_BOX_VALUE_NANO;
    Ok(preview_mint_json(
        dexy_variant,
        amount,
        calc.erg_amount,
        total,
        true,
        None,
    ))
}

fn preview_mint_json(
    variant: DexyVariant,
    amount: i64,
    erg_cost_nano: i64,
    total_cost_nano: i64,
    can_execute: bool,
    error: Option<String>,
) -> String {
    serde_json::json!({
        "erg_cost_nano": erg_cost_nano.to_string(),
        "tx_fee_nano": TX_FEE_NANO.to_string(),
        "total_cost_nano": total_cost_nano.to_string(),
        "token_amount": amount.to_string(),
        "token_name": variant.token_name(),
        "can_execute": can_execute,
        "error": error,
    })
    .to_string()
}

/// Swap quote using live LP reserves.
pub(crate) async fn preview_swap(
    variant: &str,
    direction: &str,
    amount: i64,
    slippage_pct: Option<f64>,
    node_url: Option<String>,
) -> Result<String, String> {
    let dexy_variant = parse_variant(variant)?;
    if amount <= 0 {
        return Err(
            ArgusError::Generic("Amount must be positive".to_string()).to_json_string()
        );
    }
    let ids = ids_for(dexy_variant)?;
    let client = dexy_client(node_url).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;
    let state = fetch_dexy_state(&client, &caps, &ids).await.map_err(proto_err)?;

    let (output_amount, reserves_sold, reserves_bought) = match direction {
        "erg_to_dexy" => (
            calculate_lp_swap_output(
                amount,
                state.lp_erg_reserves,
                state.lp_dexy_reserves,
                LP_SWAP_FEE_NUM,
                LP_SWAP_FEE_DENOM,
            ),
            state.lp_erg_reserves,
            state.lp_dexy_reserves,
        ),
        "dexy_to_erg" => (
            calculate_lp_swap_output(
                amount,
                state.lp_dexy_reserves,
                state.lp_erg_reserves,
                LP_SWAP_FEE_NUM,
                LP_SWAP_FEE_DENOM,
            ),
            state.lp_dexy_reserves,
            state.lp_erg_reserves,
        ),
        _ => {
            return Err(ArgusError::Generic(format!(
                "Invalid direction '{direction}'. Use 'erg_to_dexy' or 'dexy_to_erg'"
            ))
            .to_json_string())
        }
    };

    let slippage_pct = clamp_slippage(slippage_pct);
    let min_output = (output_amount as f64 * (1.0 - slippage_pct / 100.0)) as i64;
    let price_impact = calculate_lp_swap_price_impact(
        amount,
        reserves_sold,
        reserves_bought,
        LP_SWAP_FEE_NUM,
        LP_SWAP_FEE_DENOM,
    );

    let output_token_name = match direction {
        "erg_to_dexy" => dexy_variant.token_name().to_string(),
        _ => "ERG".to_string(),
    };

    serde_json::to_string(&serde_json::json!({
        "input_amount": amount,
        "output_amount": output_amount,
        "min_output": min_output,
        "price_impact_pct": price_impact,
        "fee_pct": LP_SWAP_FEE_NUM as f64 / LP_SWAP_FEE_DENOM as f64 * 100.0,
        "miner_fee_nano": TX_FEE_NANO,
        "output_token_name": output_token_name,
        "lp_erg_reserves": state.lp_erg_reserves,
        "lp_dexy_reserves": state.lp_dexy_reserves,
        "can_execute": output_amount > 0,
        "error": if output_amount <= 0 { Some("No liquidity in the LP pool".to_string()) } else { None },
    }))
    .map_err(ser_err)
}

/// LP deposit / redeem preview. `action` is `"deposit"` or `"redeem"`.
pub(crate) async fn preview_lp(
    variant: &str,
    action: &str,
    erg_amount: i64,
    dexy_amount: i64,
    lp_amount: i64,
    node_url: Option<String>,
) -> Result<String, String> {
    let dexy_variant = parse_variant(variant)?;
    let ids = ids_for(dexy_variant)?;
    let client = dexy_client(node_url).await?;
    let caps = client
        .require_capabilities()
        .await
        .map_err(|e| ArgusError::NodeError(e).to_json_string())?;

    match action {
        "deposit" if erg_amount <= 0 || dexy_amount <= 0 => {
            return Err(ArgusError::Generic(
                "The LP pool requires both ERG and Dexy amounts".to_string(),
            )
            .to_json_string());
        }
        "redeem" if lp_amount <= 0 => {
            return Err(ArgusError::Generic("LP token amount must be positive".to_string())
                .to_json_string());
        }
        "deposit" | "redeem" => {}
        _ => {
            return Err(ArgusError::Generic(format!("Unknown LP action '{action}'"))
                .to_json_string());
        }
    }

    let lp_box = client
        .get_box_by_token_id(&caps, &TokenId::new(&ids.lp_token_id))
        .await
        .map_err(|e| ArgusError::NodeError(e.to_string()).to_json_string())?;
    let lp_data = parse_lp_box(&lp_box, &ids).map_err(proto_err)?;

    if action == "deposit" {
        let calc = calculate_lp_deposit(
            erg_amount,
            dexy_amount,
            lp_data.erg_reserves,
            lp_data.dexy_reserves,
            lp_data.lp_token_reserves,
            dexy_variant.initial_lp(),
        );
        return serde_json::to_string(&serde_json::json!({
            "action": "deposit",
            "consumed_erg": calc.consumed_erg,
            "consumed_dexy": calc.consumed_dexy,
            "requested_erg": erg_amount,
            "requested_dexy": dexy_amount,
            "lp_tokens": calc.lp_tokens_out,
            "can_execute": calc.lp_tokens_out > 0,
            "error": if calc.lp_tokens_out <= 0 { Some("Deposit too small: would receive 0 LP tokens".to_string()) } else { None },
            "miner_fee_nano": TX_FEE_NANO,
        }))
        .map_err(ser_err);
    }

    // redeem — needs the pooled/live state for the depeg-protection gate.
    let state = fetch_dexy_state(&client, &caps, &ids).await.map_err(proto_err)?;
    if !state.can_redeem_lp {
        return serde_json::to_string(&serde_json::json!({
            "action": "redeem",
            "lp_amount": lp_amount,
            "erg_out": 0,
            "dexy_out": 0,
            "redemption_fee_pct": LP_REDEEM_FEE_PCT,
            "can_execute": false,
            "error": "LP redeem blocked: LP rate below 98% of oracle rate (depeg protection)",
            "miner_fee_nano": TX_FEE_NANO,
        }))
        .map_err(ser_err);
    }

    let calc = calculate_lp_redeem(
        lp_amount,
        lp_data.erg_reserves,
        lp_data.dexy_reserves,
        lp_data.lp_token_reserves,
        dexy_variant.initial_lp(),
    );
    serde_json::to_string(&serde_json::json!({
        "action": "redeem",
        "lp_amount": lp_amount,
        "erg_out": calc.erg_out,
        "dexy_out": calc.dexy_out,
        "redemption_fee_pct": LP_REDEEM_FEE_PCT,
        "can_execute": calc.erg_out > 0 && calc.dexy_out > 0,
        "error": if calc.erg_out <= 0 || calc.dexy_out <= 0 { Some("Redeem too small: would receive 0 ERG or Dexy".to_string()) } else { None },
        "miner_fee_nano": TX_FEE_NANO,
    }))
    .map_err(ser_err)
}