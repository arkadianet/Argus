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
pub(crate) fn resolve_node_url(node_url: Option<String>) -> String {
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
            Some(format!(
                "Amount exceeds the bank's {} {}",
                fmt_units(state.dexy_in_bank, dexy_variant.decimals()),
                dexy_variant.token_name()
            )),
        ));
    }
    if state.free_mint_available > 0 && amount > state.free_mint_available {
        return Ok(preview_mint_json(
            dexy_variant,
            amount,
            0,
            0,
            false,
            Some(format!(
                "Only {} {} can be minted at the oracle rate right now; the allowance refills each period",
                fmt_units(state.free_mint_available, dexy_variant.decimals()),
                dexy_variant.token_name()
            )),
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

/// Base units as a decimal string, e.g. 749971 with 3 decimals → "749.971".
pub(crate) fn fmt_units(amount: i64, decimals: u8) -> String {
    if decimals == 0 {
        return amount.to_string();
    }
    let scale = 10_i64.pow(decimals as u32);
    let whole = amount / scale;
    let frac = (amount % scale).abs();
    let s = format!("{whole}.{frac:0width$}", width = decimals as usize);
    s.trim_end_matches('0').trim_end_matches('.').to_string()
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
/// Live reproduction of the LP deposit "reduced to false" report. Builds a
/// deposit against the mainnet DexyGold pool using a real holder's box as
/// the user input and reduces every input script. Network access; run with
/// `cargo test -p wallet-ffi lp_deposit_live -- --ignored --nocapture`.
#[cfg(test)]
mod lp_live_tests {
    use citadel_core::BoxId;
    use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
    use ergo_tx::dev_fee::{with_test_dev_fee, DevFeeConfig};

    async fn run(variant: dexy::constants::DexyVariant, holder_id: &str, deposit_erg: i64, deposit_dexy: i64, fee: bool) {
        let node = "https://ergo-node.eutxo.de".to_string();
        let client = super::dexy_client(Some(node.clone())).await.expect("client");
        let caps = client.require_capabilities().await.expect("caps");
        let ids = super::ids_for(variant).expect("ids");
        let ctx = dexy::fetch::fetch_lp_tx_context(&client, &caps, &ids, dexy::fetch::LpAction::Deposit)
            .await
            .expect("lp ctx");
        println!(
            "[{variant:?} fee={fee}] LP reserves erg={} dexy={} lp={}",
            ctx.lp_erg_reserves, ctx.lp_dexy_reserves, ctx.lp_token_reserves
        );
        {
            use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
            for (label, tree) in [("LP", &ctx.lp_box.ergo_tree), ("MINT", &ctx.action_box.ergo_tree)] {
                let n = tree.constants_len().unwrap_or(0);
                println!("  {label} tree constants: {n}");
                for i in 0..n {
                    if let Ok(c) = tree.get_constant(i) {
                        if let Some(c) = c {
                            let bytes = c.sigma_serialize_bytes().unwrap_or_default();
                            println!("    [{i}] {}", hex::encode(bytes));
                        }
                    }
                }
            }
            println!("  ids: lp_nft={} mint={} redeem={} swap={} lp_token={} dexy={}", ids.lp_nft, ids.lp_mint_nft, ids.lp_redeem_nft, ids.lp_swap_nft, ids.lp_token_id, ids.dexy_token);
        }
        let holder: ErgoBox = client.get_box_by_id(&BoxId::new(holder_id)).await.expect("holder box");
        let eip12 = ergo_tx::Eip12InputBox::from_ergo_box(&holder, holder.transaction_id.to_string(), holder.index);
        let user_tree = eip12.ergo_tree.clone();
        let height = client.current_height().await.expect("height") as i32;
        let request = dexy::tx_builder::LpDepositRequest {
            variant,
            deposit_erg,
            deposit_dexy,
            user_address: String::new(),
            user_ergo_tree: user_tree.clone(),
            user_inputs: vec![eip12],
            current_height: height,
            recipient_ergo_tree: Some(user_tree),
        };
        let build = || {
            dexy::tx_builder::build_lp_deposit_tx(&request, &ctx, &ids.dexy_token, &ids.lp_token_id, variant.initial_lp())
        };
        let built = if fee {
            let tree = wallet_net::client::address_to_ergo_tree(crate::api::ARGUS_FEE_ADDRESS).unwrap();
            with_test_dev_fee(DevFeeConfig::custom(tree, crate::api::ARGUS_FEE_NANO), build)
        } else {
            build()
        }
        .expect("build");
        println!("  summary: {:?} outputs={}", built.summary, built.unsigned_tx.outputs.len());
        let boxes = vec![ctx.lp_box.clone(), ctx.action_box.clone(), holder];
        match ergopay_core::reduce_transaction(&built.unsigned_tx, boxes, vec![], &client).await {
            Ok(bytes) => {
                use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
                let reduced = ergo_lib::chain::transaction::reduced::ReducedTransaction::sigma_parse_bytes(&bytes).expect("parse");
                for (i, input) in reduced.reduced_inputs().iter().enumerate() {
                    println!("  input {i}: {:?}", input.sigma_prop);
                }
            }
            Err(e) => println!("  REDUCTION FAILED: {e}"),
        }
    }

    /// Live reproduction of the LP deposit "reduced to false" report against
    /// the mainnet pools. Network access; run with
    /// `cargo test -p wallet-ffi lp_deposit_live -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn lp_deposit_live_reduces() {
        use dexy::constants::DexyVariant;
        let gold = "24169a4f3dbee4f04f2c21883848910bb0171eb2d1555848f7d86594125be6f3";
        let usd = "68baba4d2ca396acfe9cfdb0aa3ae6b2a7daf0afb3495d39009c5e2f27866125";
        run(DexyVariant::Gold, gold, 600_000_000, 1, false).await;
        run(DexyVariant::Gold, gold, 600_000_000, 1, true).await;
        run(DexyVariant::Usd, usd, 300_000_000, 2000, false).await;
        run(DexyVariant::Usd, usd, 300_000_000, 2000, true).await;
        run(DexyVariant::Usd, usd, 1_000_000_000, 7999, true).await;
    }
}

#[cfg(test)]
mod fmt_units_tests {
    #[test]
    fn formats_base_units_with_decimals() {
        assert_eq!(super::fmt_units(749971, 3), "749.971");
        assert_eq!(super::fmt_units(1000, 3), "1");
        assert_eq!(super::fmt_units(59, 0), "59");
        assert_eq!(super::fmt_units(5, 3), "0.005");
    }
}

#[cfg(test)]
mod dexy_state_live_tests {
    /// Prints live state, rates and a 1-token mint preview per variant.
    /// `cargo test -p wallet-ffi dexy_state_live -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn dexy_state_live_dump() {
        let node = Some("https://ergo-node.eutxo.de".to_string());
        for (variant, one_token) in [("gold", 1i64), ("usd", 1000i64)] {
            let raw = crate::api::dexy_state(variant.to_string(), node.clone()).await.expect("state");
            let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
            println!("[{variant}] oracle_rate_nano={} lp_rate_nano={} free_mint_available={} dexy_in_bank={} lp_erg={} lp_dexy={}",
                v["state"]["oracle_rate_nano"], v["state"]["lp_rate_nano"], v["state"]["free_mint_available"], v["state"]["dexy_in_bank"], v["state"]["lp_erg_reserves"], v["state"]["lp_dexy_reserves"]);
            println!("[{variant}] rates erg_per_token={} tokens_per_erg={} decimals={}", v["rates"]["erg_per_token"], v["rates"]["tokens_per_erg"], v["rates"]["token_decimals"]);
            let p = crate::api::dexy_preview_mint(variant.to_string(), one_token, node.clone()).await.expect("preview");
            println!("[{variant}] preview mint {one_token} base units: {p}");
        }
    }
}
