//! Diagnostic for rank 6: the pinned API cannot refresh fresh health semantics
//! while retaining transport. This test protects the reason for rejecting it.
use ergo_node_interface::NodeInterface;
use std::io::{Read, Write};

#[tokio::test]
async fn reused_capability_after_inconclusive_probe_differs_from_fresh_client() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        for status in [
            "404 Not Found",
            "503 Service Unavailable",
            "503 Service Unavailable",
        ] {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut req = Vec::new();
            let mut byte = [0];
            while !req.ends_with(b"\r\n\r\n") {
                assert_eq!(stream.read(&mut byte).unwrap(), 1);
                req.push(byte[0]);
            }
            assert!(String::from_utf8(req)
                .unwrap()
                .starts_with("GET /blockchain/indexedHeight "));
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
        }
    });
    let reused = NodeInterface::from_url_str("", &url).await.unwrap();
    assert_eq!(reused.has_extra_index(), Some(false));
    reused.refresh_capabilities().await;
    let fresh = NodeInterface::from_url_str("", &url).await.unwrap();
    assert_eq!(reused.has_extra_index(), Some(false));
    assert_eq!(fresh.has_extra_index(), None);
    server.join().unwrap();
}
