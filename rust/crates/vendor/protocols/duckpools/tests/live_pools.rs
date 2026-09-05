//! Read every pool from mainnet. Ignored: needs the network.

#[tokio::test]
#[ignore = "needs the network"]
async fn duckpools_live_pools_parse() {
    let client = reqwest::Client::new();
    for pool in duckpools::POOLS {
        let url = format!(
            "https://api.ergoplatform.com/api/v1/boxes/unspent/byErgoTree/{}?limit=5",
            pool.ergo_tree
        );
        let text = client
            .get(&url)
            .send()
            .await
            .expect("explorer")
            .text()
            .await
            .unwrap();
        let states =
            duckpools::parse_pool_boxes(&text).unwrap_or_else(|e| panic!("{}: {e}", pool.key));
        let s = states
            .iter()
            .find(|s| s.pool == pool.key)
            .unwrap_or_else(|| panic!("{}: no pool box live", pool.key));
        eprintln!(
            "{:>7}: pooled {} borrowed {} utilisation {}bps price {:.4}",
            pool.ticker,
            s.pooled,
            s.borrowed,
            s.utilisation_bps(),
            s.lend_token_price()
        );
    }
}

/// Quote a 1 ERG lend and a withdraw of what it would mint, against the
/// live ERG pool, and read the live rate. Ignored: needs the network.
#[tokio::test]
#[ignore = "needs the network"]
async fn duckpools_live_quotes_and_rates() {
    let client = reqwest::Client::new();
    let pool = &duckpools::POOLS[0];
    let text = client
        .get(format!("https://api.ergoplatform.com/api/v1/boxes/unspent/byErgoTree/{}?limit=5", pool.ergo_tree))
        .send().await.unwrap().text().await.unwrap();
    let state = duckpools::parse_pool_boxes(&text).unwrap().into_iter().find(|s| s.pool == "erg").unwrap();
    let lend = duckpools::LendQuote::new(pool, &state, 1_000_000_000, 100, 2_000_000).unwrap();
    let proxy = lend.proxy_box(pool, "0008cd0247997e4390471ab3fe271ad4ad1ad485570c50326ff671a57722ee88e1fa4582").unwrap();
    eprintln!("lend 1 ERG: fee {} to pool {} tokens {} (min {}) proxy value {}", lend.service_fee, lend.to_pool, lend.lend_tokens_expected, lend.min_lend_tokens, proxy.value);
    assert!(lend.lend_tokens_expected > 0);
    let back = duckpools::WithdrawQuote::new(pool, &state, lend.lend_tokens_expected, 100, 2_000_000).unwrap();
    eprintln!("withdraw those tokens: entitled {} fee {} out {}", back.entitled, back.service_fee, back.out);
    assert!(back.out > 900_000_000 && back.out < 1_000_000_000);

    let params = client
        .get(format!("https://api.ergoplatform.com/api/v1/boxes/unspent/byTokenId/{}?limit=5", pool.interest_param_nft))
        .send().await.unwrap().text().await.unwrap();
    let v: serde_json::Value = serde_json::from_str(&params).unwrap();
    let p = v["items"].as_array().unwrap().iter().find_map(|b| duckpools::InterestParams::parse(pool, b).ok()).expect("live parameter box");
    let r = p.rates(&state);
    eprintln!("live ERG rates: borrow {}bps lend {}bps", r.borrow_apr_bps, r.lend_apr_bps);
    assert!(r.borrow_apr_bps >= 107);
}
