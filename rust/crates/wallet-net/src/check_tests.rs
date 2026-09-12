use super::*;
use std::io::{Read, Write};

// Exercise the real HTTP method, including response status and body parsing.
async fn request(status: u16, response: &str, submit: bool) -> bool {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port().to_string();
    let response = response.to_owned();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut request = Vec::new();
        let mut buf = [0; 4096];
        loop {
            let count = stream.read(&mut buf).unwrap();
            assert!(count > 0);
            request.extend_from_slice(&buf[..count]);
            if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                let header = String::from_utf8_lossy(&request[..end]);
                let length: usize = header
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length: ")
                            .map(|v| v.parse().unwrap())
                    })
                    .unwrap();
                if request.len() >= end + 4 + length {
                    break;
                }
            }
        }
        let path = if submit {
            "/transactions"
        } else {
            "/transactions/check"
        };
        assert!(request.starts_with(format!("POST {path} HTTP/1.1").as_bytes()));
        write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).unwrap();
    });
    let inner = NodeInterface::new_without_probe("", "127.0.0.1", &port).unwrap();
    let client = ErgoNodeClient {
        inner: Arc::new(inner),
        url: String::new(),
    };
    let tx = serde_json::json!({
        "id": "forged-id-must-not-be-used",
        "inputs": [{"boxId": "0000000000000000000000000000000000000000000000000000000000000000", "spendingProof": {"proofBytes": "", "extension": {}}}],
        "dataInputs": [],
        "outputs": [{"value": 1000000, "ergoTree": "0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", "creationHeight": 1, "assets": [], "additionalRegisters": {}}]
    });
    let result = if submit {
        let result = client.submit_transaction(&tx).await;
        if let Ok(id) = &result {
            assert_eq!(id.len(), 64);
            assert!(id.bytes().all(|b| b.is_ascii_hexdigit()));
        }
        result.is_ok()
    } else {
        client.check_transaction(&tx).await.is_ok()
    };
    server.join().unwrap();
    result
}

#[tokio::test]
async fn duplicate_preflight_passes() {
    assert!(check(400, r#"{"error":400,"reason":"duplicate"}"#).await);
}

#[tokio::test]
async fn scala_preflight_passes() {
    assert!(
        check(
            200,
            r#""acd2ddb65cd2eb744ad7cde9b0e070d4a1a5edd0b97a00e5cfa4d12b4dbe6734""#
        )
        .await
    );
}

#[tokio::test]
async fn invalid_preflight_fails_closed() {
    for body in [
        r#"{"error":400,"reason":"script_failed"}"#,
        r#"{"error":400,"reason":"unresolved_input"}"#,
        r#"{"error":400,"reason":"bad.request","detail":"duplicate input"}"#,
        r#"{"error":400,"reason":"duplicate input"}"#,
        r#"{"error":400,"reason":"duplicate","detail":"script failed"}"#,
        r#"{"error":500,"reason":"duplicate"}"#,
        r#"{"reason":"duplicate"}"#,
        "duplicate",
        "{",
    ] {
        assert!(!check(400, body).await, "must reject {body}");
    }
    assert!(!check(500, r#"{"error":400,"reason":"duplicate"}"#).await);
}

async fn check(status: u16, response: &str) -> bool {
    request(status, response, false).await
}

#[tokio::test]
async fn submit_success_duplicate_and_rejection() {
    assert!(
        request(
            200,
            r#""acd2ddb65cd2eb744ad7cde9b0e070d4a1a5edd0b97a00e5cfa4d12b4dbe6734""#,
            true
        )
        .await
    );
    assert!(request(400, r#"{"error":400,"reason":"duplicate"}"#, true).await);
    for body in [
        r#"{"error":400,"reason":"script_failed"}"#,
        r#"{"error":400,"reason":"unresolved_input"}"#,
        r#"{"error":400,"reason":"bad.request","detail":"duplicate input"}"#,
        r#"{"error":400,"reason":"duplicate","detail":"script failed"}"#,
    ] {
        assert!(!request(400, body, true).await);
    }
}

#[test]
fn duplicate_requires_parseable_transaction_and_derives_id() {
    let body = r#"{"error":400,"reason":"duplicate"}"#.to_string();
    assert!(transaction_response(400, body, &serde_json::json!({"id": "forged"})).is_err());
}
