//! Pins the node interface on recorded node responses. Reduction and signing
//! read the state context, so every field of it is checked: header order and
//! content (each parsed header must re-serialize to bytes hashing to the id
//! the node reported), the pre-header, and the parameters. These expectations
//! were first confirmed against ergo-node-interface, which this code replaces.
//!
//! Fixtures: `/blocks/lastHeaders/10` and `/info` from two mainnet nodes at
//! height 1888754 (byte-identical), and `/blocks/chainSlice` for block
//! version 1 headers 100000..=100009.

use std::thread::JoinHandle;

use citadel_core::NodeConfig;
use ergo_lib::chain::ergo_state_context::ErgoStateContext;
use ergo_lib::chain::parameters::Parameters;
use ergo_lib::ergo_chain_types::blake2b256_hash;
use sigma_ser::ScorexSerializable;

use crate::node_interface::NodeInterface;
use crate::test_server::{serve, Recorded};
use crate::{parse_parameters, ErgoNodeClient};

const HEADERS: &str = include_str!("../tests/fixtures/last_headers_1888754.json");
const HEADERS_V1: &str = include_str!("../tests/fixtures/chain_slice_v1_100000.json");
const INFO: &str = include_str!("../tests/fixtures/info_1888754.json");

/// A node answering by path prefix (first match), 404 `{}` otherwise.
fn node(
    expected: usize,
    routes: Vec<(&'static str, u16, String)>,
) -> (String, JoinHandle<Vec<Recorded>>) {
    serve(expected, move |req| {
        routes
            .iter()
            .find(|(prefix, _, _)| req.target.starts_with(prefix))
            .map(|(_, status, body)| (*status, body.clone()))
            .unwrap_or((404, "{}".into()))
    })
}

fn port_of(url: &str) -> String {
    url.rsplit(':').next().unwrap().to_string()
}

fn closed_port() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.local_addr().unwrap().port().to_string()
}

fn headers_json(text: &str, take: usize) -> String {
    let all: Vec<serde_json::Value> = serde_json::from_str(text).unwrap();
    serde_json::to_string(&all.into_iter().take(take).collect::<Vec<_>>()).unwrap()
}

/// `ctx` must hold exactly the recorded headers, newest first, with the
/// newest header as the pre-header.
fn assert_context(ctx: &ErgoStateContext, fixture: &str, tip_height: u32) {
    let recorded: Vec<serde_json::Value> = serde_json::from_str(fixture).unwrap();
    assert_eq!(recorded.len(), 10);
    for (i, header) in ctx.headers.iter().enumerate() {
        let node_json = &recorded[9 - i];
        assert_eq!(header.height, tip_height - i as u32);
        assert_eq!(String::from(header.id.0), node_json["id"].as_str().unwrap());
        assert_eq!(
            blake2b256_hash(&header.scorex_serialize_bytes().unwrap()),
            header.id.0,
            "header {} must re-serialize to its id",
            header.height
        );
        assert_eq!(
            serde_json::to_value(header).unwrap()["parentId"],
            node_json["parentId"]
        );
    }
    let tip = &ctx.headers[0];
    let tip_json = &recorded[9];
    let pre = &ctx.pre_header;
    assert_eq!(pre.height, tip_height);
    assert_eq!(pre.height, tip.height);
    assert_eq!(
        u64::from(pre.version),
        tip_json["version"].as_u64().unwrap()
    );
    assert_eq!(pre.timestamp, tip_json["timestamp"].as_u64().unwrap());
    assert_eq!(u64::from(pre.n_bits), tip_json["nBits"].as_u64().unwrap());
    assert_eq!(
        String::from(pre.parent_id.0),
        tip_json["parentId"].as_str().unwrap()
    );
    assert_eq!(pre.miner_pk, tip.autolykos_solution.miner_pk);
    assert_eq!(pre.votes, tip.votes);
}

#[tokio::test]
async fn state_context_from_recorded_mainnet_headers() {
    for (fixture, tip, version) in [(HEADERS, 1_888_754, 4), (HEADERS_V1, 100_009, 1)] {
        let (url, server) = node(1, vec![("/blocks/lastHeaders/10", 200, fixture.into())]);
        let n = NodeInterface::new_without_probe("", "127.0.0.1", &port_of(&url)).unwrap();
        let ctx = n.get_state_context().await.unwrap();
        assert_context(&ctx, fixture, tip);
        assert_eq!(ctx.pre_header.version, version);
        assert_eq!(ctx.parameters, Parameters::default());
        assert_eq!(server.join().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn client_state_context_uses_node_parameters() {
    let info: serde_json::Value = serde_json::from_str(INFO).unwrap();
    let expected = parse_parameters(&info["parameters"]).unwrap();
    assert_eq!(expected.block_version(), 4);
    for (info_status, parameters) in [(200, expected), (500, Parameters::default())] {
        let (url, server) = node(
            3,
            vec![
                ("/blockchain/indexedHeight", 200, "{}".into()),
                ("/blocks/lastHeaders/10", 200, HEADERS.into()),
                ("/info", info_status, INFO.into()),
            ],
        );
        let client = ErgoNodeClient::new(NodeConfig {
            url,
            api_key: String::new(),
        })
        .await
        .unwrap();
        let ctx = client.get_state_context().await.unwrap();
        assert_context(&ctx, HEADERS, 1_888_754);
        assert_eq!(ctx.parameters, parameters);
        let targets: Vec<String> = server
            .join()
            .unwrap()
            .into_iter()
            .map(|r| r.target)
            .collect();
        assert_eq!(
            targets,
            [
                "/blockchain/indexedHeight",
                "/blocks/lastHeaders/10",
                "/info"
            ]
        );
    }
}

#[tokio::test]
async fn state_context_errors() {
    let mut eleven: Vec<serde_json::Value> = serde_json::from_str(HEADERS_V1).unwrap();
    eleven.push(serde_json::from_str::<Vec<serde_json::Value>>(HEADERS).unwrap()[0].clone());
    let eleven = serde_json::to_string(&eleven).unwrap();
    let mut garbage: Vec<serde_json::Value> = serde_json::from_str(HEADERS).unwrap();
    garbage.insert(3, serde_json::json!({"id": "not a header"}));
    let garbage = serde_json::to_string(&garbage).unwrap();
    let unreachable = "The configured node is unreachable. Please ensure your config is \
                       correctly filled out and the node is running.";

    // (status, body, NodeInterface result, ErgoNodeClient result)
    let cases: Vec<(u16, String, Result<u32, String>, Result<u32, String>)> = vec![
        (200, headers_json(HEADERS, 9), Err("Expected 10 block headers, got 9".into()), Err("Expected 10 block headers, got 9".into())),
        // More than ten: the interface refuses, the client keeps the newest ten.
        (200, eleven, Err("Failed to convert headers to array".into()), Ok(1_888_745)),
        // Elements that are not headers are skipped.
        (200, garbage, Ok(1_888_754), Ok(1_888_754)),
        (200, "[]".into(), Err("Expected 10 block headers, got 0".into()), Err("Expected 10 block headers, got 0".into())),
        // The status is not checked; an error object holds no headers.
        (503, r#"{"error":503,"reason":"Service Unavailable"}"#.into(), Err("Expected 10 block headers, got 0".into()), Err("Expected 10 block headers, got 0".into())),
        (502, "<html>bad gateway</html>".into(),
            Err("Failed reading response from node: <html>bad gateway</html>".into()),
            Err("Failed to get headers: Failed reading response from node: <html>bad gateway</html>".into())),
    ];
    for (status, body, interface, client) in cases {
        let (url, server) = node(1, vec![("/blocks/lastHeaders/10", status, body.clone())]);
        let n = NodeInterface::new_without_probe("", "127.0.0.1", &port_of(&url)).unwrap();
        let got = n
            .get_state_context()
            .await
            .map(|c| c.pre_header.height)
            .map_err(|e| e.to_string());
        assert_eq!(got, interface, "interface, body {body:.60}");
        server.join().unwrap();

        // /info is only read once the headers are good.
        let (url, server) = node(
            if client.is_ok() { 3 } else { 2 },
            vec![
                ("/blockchain/indexedHeight", 200, "{}".into()),
                ("/blocks/lastHeaders/10", status, body.clone()),
                ("/info", 200, INFO.into()),
            ],
        );
        let c = ErgoNodeClient::new(NodeConfig {
            url,
            api_key: String::new(),
        })
        .await
        .unwrap();
        let got = c.get_state_context().await.map(|c| c.pre_header.height);
        assert_eq!(got, client, "client, body {body:.60}");
        server.join().unwrap();
    }

    let n = NodeInterface::new_without_probe("", "127.0.0.1", &closed_port()).unwrap();
    assert_eq!(
        n.get_state_context().await.unwrap_err().to_string(),
        unreachable
    );
}

#[tokio::test]
async fn requests_carry_the_node_headers() {
    let (url, server) = node(
        3,
        vec![
            ("/blockchain/indexedHeight", 200, "{}".into()),
            ("/info", 200, INFO.into()),
            ("/transactions", 200, "\"id\"".into()),
        ],
    );
    let n = NodeInterface::from_url_str("secret", &url).await.unwrap();
    assert_eq!(n.current_block_height().await.unwrap(), 1_888_754);
    let post = n
        .send_post_req("/transactions", "{\"a\":1}".into())
        .await
        .unwrap();
    assert_eq!(post.text().await.unwrap(), "\"id\"");
    let requests = server.join().unwrap();
    let probe = &requests[0];
    assert_eq!(
        (probe.method.as_str(), probe.target.as_str()),
        ("GET", "/blockchain/indexedHeight")
    );
    assert_eq!(probe.header("accept"), Some("application/json"));
    assert_eq!(probe.header("api_key"), Some("secret"));
    assert_eq!(probe.header("content-type"), None);
    for (request, method, target, body) in [
        (&requests[1], "GET", "/info", ""),
        (&requests[2], "POST", "/transactions", "{\"a\":1}"),
    ] {
        assert_eq!(
            (request.method.as_str(), request.target.as_str()),
            (method, target)
        );
        assert_eq!(request.header("accept"), Some("application/json"));
        assert_eq!(request.header("api_key"), Some("secret"));
        assert_eq!(request.header("content-type"), Some("application/json"));
        assert_eq!(request.body, body);
    }

    // A key that is not a valid header value: the probe never leaves the
    // client and other requests send "None".
    let (url, server) = node(1, vec![("/info", 200, INFO.into())]);
    let n = NodeInterface::from_url_str("bad\nkey", &url).await.unwrap();
    assert_eq!(n.has_extra_index(), None);
    n.current_block_height().await.unwrap();
    let requests = server.join().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].header("api_key"), Some("None"));

    // An absolute endpoint replaces any path in the node URL (Url::join).
    let (url, server) = node(2, vec![("/info", 200, INFO.into())]);
    let n = NodeInterface::from_url_str("", &format!("{url}/some/base/"))
        .await
        .unwrap();
    n.current_block_height().await.unwrap();
    let targets: Vec<String> = server
        .join()
        .unwrap()
        .into_iter()
        .map(|r| r.target)
        .collect();
    assert_eq!(targets, ["/blockchain/indexedHeight", "/info"]);
}

#[tokio::test]
async fn height_and_info_handling() {
    for (status, body, height, info) in [
        (200, INFO, Ok(1_888_754), true),
        (
            200,
            r#"{"fullHeight":null}"#,
            Err("The node is still syncing."),
            false,
        ),
        (200, "{}", Err("The node is still syncing."), false),
        // A height that is not a JSON number does not parse.
        (
            200,
            r#"{"fullHeight":"5"}"#,
            Err(r#"Failed reading response from node: {"fullHeight":"5"}"#),
            true,
        ),
        // The status is not checked.
        (500, r#"{"error":500,"fullHeight":7}"#, Ok(7), true),
        (
            503,
            "<html>down</html>",
            Err("Failed reading response from node: <html>down</html>"),
            false,
        ),
    ] {
        let (url, server) = node(2, vec![("/info", status, body.into())]);
        let n = NodeInterface::new_without_probe("", "127.0.0.1", &port_of(&url)).unwrap();
        let got = n.current_block_height().await.map_err(|e| e.to_string());
        assert_eq!(
            got,
            height.map_err(str::to_string),
            "height, body {body:.40}"
        );
        assert_eq!(n.node_info().await.is_ok(), info, "info, body {body:.40}");
        server.join().unwrap();
    }
    let n = NodeInterface::new_without_probe("", "127.0.0.1", &closed_port()).unwrap();
    assert!(matches!(
        n.current_block_height().await,
        Err(crate::node_interface::NodeError::NodeUnreachable)
    ));
    assert_eq!(
        NodeInterface::from_url_str("", "not a url")
            .await
            .unwrap_err()
            .to_string(),
        "Failed to parse URL: relative URL without a base"
    );
}

#[tokio::test]
async fn extra_index_probe_and_guard() {
    for (status, expected) in [(200, Some(true)), (404, Some(false)), (500, None)] {
        let (url, server) = node(1, vec![("/blockchain/indexedHeight", status, "{}".into())]);
        let n = NodeInterface::from_url_str("", &url).await.unwrap();
        assert_eq!(n.has_extra_index(), expected);
        server.join().unwrap();
    }
    let n = NodeInterface::from_url_str("", &format!("http://127.0.0.1:{}", closed_port()))
        .await
        .unwrap();
    assert_eq!(n.has_extra_index(), None);

    // Known-disabled: guarded calls fail without reaching the node.
    let (url, server) = node(1, vec![("/blockchain/indexedHeight", 404, "{}".into())]);
    let n = NodeInterface::from_url_str("", &url).await.unwrap();
    let token = ergo_lib::ergotree_ir::chain::token::TokenId::from(
        ergo_lib::ergo_chain_types::Digest32::from([7u8; 32]),
    );
    let refused = "This operation requires a node with extraIndex enabled. Configure the \
                   node with `extraIndex = true` or use a different endpoint.";
    assert_eq!(
        n.get_indexed_height().await.unwrap_err().to_string(),
        refused
    );
    assert_eq!(
        n.unspent_boxes_by_token_id(&token, 0, 1)
            .await
            .unwrap_err()
            .to_string(),
        refused
    );
    assert_eq!(
        n.blockchain_transaction_from_id("tx")
            .await
            .unwrap_err()
            .to_string(),
        refused
    );
    assert_eq!(server.join().unwrap().len(), 1);

    // Refresh keeps the value on an inconclusive probe; clones share it.
    let next = std::sync::atomic::AtomicUsize::new(0);
    let (url, server) = serve(3, move |_| {
        [
            (404, "{}".to_string()),
            (503, "{}".into()),
            (200, "{}".into()),
        ][next.fetch_add(1, std::sync::atomic::Ordering::SeqCst)]
        .clone()
    });
    let n = NodeInterface::from_url_str("", &url).await.unwrap();
    let clone = n.clone();
    assert_eq!(n.has_extra_index(), Some(false));
    n.refresh_capabilities().await;
    assert_eq!(clone.has_extra_index(), Some(false));
    clone.refresh_capabilities().await;
    assert_eq!(n.has_extra_index(), Some(true));
    assert_eq!(server.join().unwrap().len(), 3);

    let (url, server) = node(
        1,
        vec![(
            "/blockchain/indexedHeight",
            200,
            r#"{"indexedHeight":10,"fullHeight":12}"#.into(),
        )],
    );
    let n = NodeInterface::new_without_probe("", "127.0.0.1", &port_of(&url)).unwrap();
    let h = n.get_indexed_height().await.unwrap();
    assert_eq!((h.indexed_height, h.full_height), (10, 12));
    server.join().unwrap();
}
