#![allow(unused_must_use)]
//! The port against the fork it replaces: every scenario runs both against
//! the same canned responses and must produce the same result and send the
//! same requests. Lives only while ergo-node-interface is still a dependency;
//! node_interface_tests.rs keeps the expectations confirmed here.

use std::fmt::{Debug, Display};
use std::sync::atomic::{AtomicUsize, Ordering};

use ergo_lib::chain::ergo_box::box_builder::ErgoBoxCandidateBuilder;
use ergo_lib::chain::transaction::TxId;
use ergo_lib::ergo_chain_types::Digest32;
use ergo_lib::ergotree_ir::chain::address::{AddressEncoder, NetworkPrefix};
use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_lib::ergotree_ir::chain::token::TokenId;
use ergo_node_interface::NodeInterface as Fork;

use crate::node_interface::NodeInterface as Port;
use crate::test_server::{serve, Recorded};

const HEADERS: &str = include_str!("../tests/fixtures/last_headers_1888754.json");
const HEADERS_V1: &str = include_str!("../tests/fixtures/chain_slice_v1_100000.json");
const INFO: &str = include_str!("../tests/fixtures/info_1888754.json");

fn show<T: Debug, E: Display>(r: Result<T, E>) -> Result<String, String> {
    r.map(|v| format!("{v:?}")).map_err(|e| e.to_string())
}

/// Compared by value: `Parameters` is a HashMap, so its Debug order varies.
fn ctx_view<E: Display>(
    r: Result<ergo_lib::chain::ergo_state_context::ErgoStateContext, E>,
) -> Result<ergo_lib::chain::ergo_state_context::ErgoStateContext, String> {
    r.map_err(|e| e.to_string())
}

/// Answer the k-th request with `responses[k]`.
fn serve_seq(responses: Vec<(u16, String)>) -> (String, std::thread::JoinHandle<Vec<Recorded>>) {
    let next = AtomicUsize::new(0);
    let n = responses.len();
    serve(n, move |_| {
        let k = next.fetch_add(1, Ordering::SeqCst);
        responses[k.min(n - 1)].clone()
    })
}

/// Requests minus Host, which carries each server's own port.
fn comparable(mut requests: Vec<Recorded>) -> Vec<Recorded> {
    for r in &mut requests {
        r.headers.retain(|(name, _)| name != "host");
        r.headers.sort();
    }
    requests
}

fn port_of(url: &str) -> String {
    url.rsplit(':').next().unwrap().to_string()
}

fn headers_json(text: &str, take: usize) -> String {
    let all: Vec<serde_json::Value> = serde_json::from_str(text).unwrap();
    serde_json::to_string(&all.into_iter().take(take).collect::<Vec<_>>()).unwrap()
}

fn box_json(spent: bool) -> serde_json::Value {
    let tree = AddressEncoder::new(NetworkPrefix::Mainnet)
        .parse_address_from_str("9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ")
        .unwrap()
        .script()
        .unwrap();
    let candidate = ErgoBoxCandidateBuilder::new(BoxValue::SAFE_USER_MIN, tree, 1_000)
        .build()
        .unwrap();
    let ergo_box = ErgoBox::from_box_candidate(&candidate, TxId::zero(), 0).unwrap();
    let mut json = serde_json::to_value(&ergo_box).unwrap();
    if spent {
        json["spentTransactionId"] = serde_json::json!("ab".repeat(32));
    }
    json
}

/// Run `$call` on a fork client and a port client built without a probe,
/// each against its own server answering `$responses` in order, and require
/// identical results and requests. Evaluates to the port's result.
macro_rules! parity {
    ($responses:expr, |$node:ident| $call:expr) => {
        parity!($responses, |$node| $call, show)
    };
    ($responses:expr, |$node:ident| $call:expr, $view:ident) => {{
        let responses: Vec<(u16, String)> = $responses;
        let (url, server) = serve_seq(responses.clone());
        let fork_result = {
            let $node = Fork::new_without_probe("", "127.0.0.1", &port_of(&url)).unwrap();
            $view($call.await)
        };
        let fork_requests = comparable(server.join().unwrap());
        let (url, server) = serve_seq(responses);
        let port_result = {
            let $node = Port::new_without_probe("", "127.0.0.1", &port_of(&url)).unwrap();
            $view($call.await)
        };
        let port_requests = comparable(server.join().unwrap());
        assert_eq!(fork_result, port_result);
        assert_eq!(fork_requests, port_requests);
        port_result
    }};
}

fn ok(body: &str) -> (u16, String) {
    (200, body.to_string())
}

#[tokio::test]
async fn state_context_and_headers_match_the_fork() {
    for fixture in [HEADERS, HEADERS_V1] {
        let r = parity!(vec![ok(fixture)], |n| n.get_state_context(), ctx_view);
        assert!(r.is_ok(), "{r:?}");
        let r = parity!(vec![ok(fixture)], |n| n.get_last_block_headers(10));
        assert!(r.is_ok(), "{r:?}");
    }
    // Too few, too many, garbage elements, error objects, non-JSON.
    let nine = headers_json(HEADERS, 9);
    assert_eq!(
        parity!(vec![ok(&nine)], |n| n.get_state_context(), ctx_view),
        Err("Expected 10 block headers, got 9".into())
    );
    let mut eleven: Vec<serde_json::Value> = serde_json::from_str(HEADERS_V1).unwrap();
    eleven.extend(
        serde_json::from_str::<Vec<serde_json::Value>>(HEADERS)
            .unwrap()
            .into_iter()
            .take(1),
    );
    let eleven = serde_json::to_string(&eleven).unwrap();
    assert_eq!(
        parity!(vec![ok(&eleven)], |n| n.get_state_context(), ctx_view),
        Err("Failed to convert headers to array".into())
    );
    let mut with_garbage: Vec<serde_json::Value> = serde_json::from_str(HEADERS).unwrap();
    with_garbage.insert(3, serde_json::json!({"id": "nope"}));
    let with_garbage = serde_json::to_string(&with_garbage).unwrap();
    assert!(parity!(vec![ok(&with_garbage)], |n| n.get_state_context(), ctx_view).is_ok());
    assert!(parity!(vec![ok(&with_garbage)], |n| n.get_last_block_headers(10)).is_ok());
    for (status, body) in [
        (200, "[]"),
        (503, r#"{"error":503,"reason":"Service Unavailable"}"#),
        (200, r#""text""#),
        (502, "<html>bad gateway</html>"),
        (200, ""),
    ] {
        parity!(
            vec![(status, body.to_string())],
            |n| n.get_state_context(),
            ctx_view
        );
        parity!(vec![(status, body.to_string())], |n| n
            .get_last_block_headers(10));
    }
}

#[tokio::test]
async fn info_endpoints_match_the_fork() {
    for (status, body) in [
        (200, INFO),
        (200, r#"{"fullHeight":null}"#),
        (200, r#"{"fullHeight":"5"}"#),
        (200, r#"{"fullHeight":-1}"#),
        (200, "{}"),
        (500, r#"{"error":500,"reason":"x","fullHeight":7}"#),
        (503, "<html>down</html>"),
    ] {
        parity!(vec![(status, body.to_string())], |n| n
            .current_block_height());
        parity!(vec![(status, body.to_string())], |n| n.node_info());
    }
}

#[tokio::test]
async fn box_and_block_endpoints_match_the_fork() {
    let good = box_json(false).to_string();
    assert!(parity!(vec![ok(&good)], |n| n.box_from_id_with_pool("abc")).is_ok());
    parity!(vec![ok(r#"{"boxId":"x"}"#)], |n| n
        .box_from_id_with_pool("abc"));
    parity!(vec![(404, "not found".into())], |n| n
        .box_from_id_with_pool("abc"));

    parity!(vec![ok(r#"["aa","bb"]"#)], |n| n.block_ids_at_height(5));
    parity!(vec![ok(r#"{"x":1}"#)], |n| n.block_ids_at_height(5));
    for body in [r#"{"a":[1,2]}"#, "nope"] {
        parity!(vec![ok(body)], |n| n.get_block("id1"));
        parity!(vec![ok(body)], |n| n.get_block_header("id1"));
        parity!(vec![ok(body)], |n| n.get_block_transactions("id1"));
        parity!(vec![ok(body)], |n| n.unconfirmed_transaction_by_id("tx1"));
        parity!(vec![ok(body)], |n| n
            .blockchain_transaction_from_id(&"tx1".to_string()));
    }
    parity!(vec![ok(r#"[{"id":"t1"},{"id":"t2"}]"#)], |n| n
        .mempool_transactions());
    parity!(vec![ok(r#"{"items":[]}"#)], |n| n.mempool_transactions());

    parity!(vec![ok(r#"{"indexedHeight":10,"fullHeight":12}"#)], |n| n
        .get_indexed_height());
    parity!(vec![ok(r#"{"indexedHeight":10}"#)], |n| n
        .get_indexed_height());

    let token = TokenId::from(Digest32::from([7u8; 32]));
    let mixed = serde_json::json!([box_json(false), box_json(true), {"garbage": true}]).to_string();
    let r = parity!(vec![ok(&mixed)], |n| n
        .unspent_boxes_by_token_id(&token, 0, 5));
    assert_eq!(r.unwrap().matches("box_id").count(), 1);
    parity!(vec![ok("{}")], |n| n
        .unspent_boxes_by_token_id(&token, 3, 9));
}

#[tokio::test]
async fn raw_requests_match_the_fork() {
    let mut seen = Vec::new();
    for build_fork in [true, false] {
        let (url, server) = serve_seq(vec![(418, "teapot".into()), ok("\"txid\"")]);
        let p = port_of(&url);
        let (get, post) = if build_fork {
            let n = Fork::new_without_probe("k", "127.0.0.1", &p).unwrap();
            let get = n.send_get_req("/x?y=1").await.unwrap();
            let get = (get.status().as_u16(), get.text().await.unwrap());
            let post = n
                .send_post_req("/transactions", "{\"a\":1}".into())
                .await
                .unwrap();
            (get, (post.status().as_u16(), post.text().await.unwrap()))
        } else {
            let n = Port::new_without_probe("k", "127.0.0.1", &p).unwrap();
            let get = n.send_get_req("/x?y=1").await.unwrap();
            let get = (get.status().as_u16(), get.text().await.unwrap());
            let post = n
                .send_post_req("/transactions", "{\"a\":1}".into())
                .await
                .unwrap();
            (get, (post.status().as_u16(), post.text().await.unwrap()))
        };
        seen.push((get, post, comparable(server.join().unwrap())));
    }
    assert_eq!(seen[0], seen[1]);
    assert_eq!(seen[1].0, (418, "teapot".to_string()));
    let requests = &seen[1].2;
    assert_eq!(
        (requests[0].method.as_str(), requests[0].target.as_str()),
        ("GET", "/x?y=1")
    );
    assert_eq!(
        (requests[1].method.as_str(), requests[1].body.as_str()),
        ("POST", "{\"a\":1}")
    );
}

/// Unreachable nodes, invalid URLs, api keys and capability probing.
#[tokio::test]
async fn construction_and_probing_match_the_fork() {
    let closed = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port().to_string()
    };
    let fork = Fork::new_without_probe("", "127.0.0.1", &closed).unwrap();
    let port = Port::new_without_probe("", "127.0.0.1", &closed).unwrap();
    assert_eq!(
        show(fork.current_block_height().await),
        show(port.current_block_height().await)
    );
    assert_eq!(
        show(fork.get_state_context().await),
        show(port.get_state_context().await)
    );
    assert_eq!(
        show(Fork::from_url_str("", "not a url").await).unwrap_err(),
        show(Port::from_url_str("", "not a url").await).unwrap_err()
    );
    let fork = Fork::from_url_str("", &format!("http://127.0.0.1:{closed}"))
        .await
        .unwrap();
    let port = Port::from_url_str("", &format!("http://127.0.0.1:{closed}"))
        .await
        .unwrap();
    assert_eq!(
        (fork.has_extra_index(), port.has_extra_index()),
        (None, None)
    );

    for (status, expected) in [(200, Some(true)), (404, Some(false)), (500, None)] {
        let mut seen = Vec::new();
        for build_fork in [true, false] {
            let (url, server) = serve_seq(vec![(status, "{}".into()), (200, INFO.into())]);
            let (cap, height) = if build_fork {
                let n = Fork::from_url_str("key-1", &url).await.unwrap();
                (n.has_extra_index(), show(n.current_block_height().await))
            } else {
                let n = Port::from_url_str("key-1", &url).await.unwrap();
                (n.has_extra_index(), show(n.current_block_height().await))
            };
            assert_eq!(cap, expected);
            seen.push((cap, height, comparable(server.join().unwrap())));
        }
        assert_eq!(seen[0], seen[1]);
    }

    // Guarded extraIndex calls fail without a request once 404 was probed.
    let token = TokenId::from(Digest32::from([7u8; 32]));
    let mut results = Vec::new();
    for build_fork in [true, false] {
        let (url, server) = serve_seq(vec![(404, "{}".into())]);
        let r = if build_fork {
            let n = Fork::from_url_str("", &url).await.unwrap();
            vec![
                show(n.get_indexed_height().await),
                show(n.unspent_boxes_by_token_id(&token, 0, 1).await),
                show(n.blockchain_transaction_from_id(&"tx".to_string()).await),
            ]
        } else {
            let n = Port::from_url_str("", &url).await.unwrap();
            vec![
                show(n.get_indexed_height().await),
                show(n.unspent_boxes_by_token_id(&token, 0, 1).await),
                show(n.blockchain_transaction_from_id("tx").await),
            ]
        };
        results.push((r, comparable(server.join().unwrap())));
    }
    assert_eq!(results[0], results[1]);
    assert_eq!(results[1].1.len(), 1, "only the probe reaches the node");

    // Refresh keeps the old value on an inconclusive probe; clones share it.
    let mut refreshes = Vec::new();
    for build_fork in [true, false] {
        let (url, server) = serve_seq(vec![
            (404, "{}".into()),
            (503, "{}".into()),
            (200, "{}".into()),
        ]);
        let r = if build_fork {
            let n = Fork::from_url_str("", &url).await.unwrap();
            let clone = n.clone();
            let a = n.has_extra_index();
            n.refresh_capabilities().await;
            let b = clone.has_extra_index();
            clone.refresh_capabilities().await;
            (a, b, n.has_extra_index())
        } else {
            let n = Port::from_url_str("", &url).await.unwrap();
            let clone = n.clone();
            let a = n.has_extra_index();
            n.refresh_capabilities().await;
            let b = clone.has_extra_index();
            clone.refresh_capabilities().await;
            (a, b, n.has_extra_index())
        };
        refreshes.push((r, comparable(server.join().unwrap())));
    }
    assert_eq!(refreshes[0], refreshes[1]);
    assert_eq!(refreshes[1].0, (Some(false), Some(false), Some(true)));

    // An api key that is not a valid header value: "None" on requests, and a
    // probe that never leaves the client.
    let mut keys = Vec::new();
    for build_fork in [true, false] {
        let (url, server) = serve_seq(vec![(200, INFO.into())]);
        let r = if build_fork {
            let n = Fork::from_url_str("bad\nkey", &url).await.unwrap();
            (n.has_extra_index(), show(n.current_block_height().await))
        } else {
            let n = Port::from_url_str("bad\nkey", &url).await.unwrap();
            (n.has_extra_index(), show(n.current_block_height().await))
        };
        keys.push((r, comparable(server.join().unwrap())));
    }
    assert_eq!(keys[0], keys[1]);
    assert_eq!(keys[1].1[0].header("api_key"), Some("None"));

    // An absolute endpoint replaces any path in the node URL (Url::join).
    let mut joined = Vec::new();
    for build_fork in [true, false] {
        let (url, server) = serve_seq(vec![(404, "{}".into()), (200, INFO.into())]);
        let base = format!("{url}/some/base/");
        let r = if build_fork {
            show(
                Fork::from_url_str("", &base)
                    .await
                    .unwrap()
                    .current_block_height()
                    .await,
            )
        } else {
            show(
                Port::from_url_str("", &base)
                    .await
                    .unwrap()
                    .current_block_height()
                    .await,
            )
        };
        joined.push((r, comparable(server.join().unwrap())));
    }
    assert_eq!(joined[0], joined[1]);
    let targets: Vec<&str> = joined[1].1.iter().map(|r| r.target.as_str()).collect();
    assert_eq!(targets, ["/blockchain/indexedHeight", "/info"]);
}

/// Both against the public mainnet nodes over TLS. Ignored: needs the network.
#[tokio::test]
#[ignore = "needs the network"]
async fn live_nodes_match_the_fork() {
    for url in crate::NODE_CANDIDATES {
        let fork = Fork::from_url_str("", url).await.unwrap();
        let port = Port::from_url_str("", url).await.unwrap();
        assert_eq!(fork.has_extra_index(), port.has_extra_index(), "{url}");
        // A block may land between the two reads; retry until both agree.
        let mut agreed = false;
        for _ in 0..5 {
            let a = ctx_view(fork.get_state_context().await);
            let b = ctx_view(port.get_state_context().await);
            if a == b {
                let ctx = b.unwrap();
                eprintln!("{url}: tip {} matches", ctx.pre_header.height);
                agreed = true;
                break;
            }
        }
        assert!(agreed, "{url}: state contexts differ");
        let h = (
            fork.get_indexed_height().await.is_ok(),
            port.get_indexed_height().await.is_ok(),
        );
        assert_eq!(h.0, h.1, "{url}");
    }
}
