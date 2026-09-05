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
