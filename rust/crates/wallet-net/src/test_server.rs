//! A one-request-per-connection HTTP/1.1 server for tests: answers each
//! request from a routing function and records what it received.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recorded {
    pub method: String,
    pub target: String,
    /// Lowercased header names with their values, in arrival order.
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Recorded {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }
}

/// Serve until `expected` requests were answered or two seconds pass without
/// a connection. Returns the base URL (`http://127.0.0.1:port`) and a handle
/// yielding the recorded requests.
pub fn serve<F>(expected: usize, route: F) -> (String, JoinHandle<Vec<Recorded>>)
where
    F: Fn(&Recorded) -> (u16, String) + Send + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let handle = std::thread::spawn(move || {
        let mut seen = Vec::new();
        let mut idle_since = Instant::now();
        while seen.len() < expected && idle_since.elapsed() < Duration::from_secs(2) {
            let (mut stream, _) = match listener.accept() {
                Ok(conn) => conn,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                    continue;
                }
                Err(e) => panic!("accept: {e}"),
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let request = read_request(&mut stream);
            let (status, body) = route(&request);
            write!(
                stream,
                "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
            seen.push(request);
            idle_since = Instant::now();
        }
        seen
    });
    (url, handle)
}

fn read_request(stream: &mut std::net::TcpStream) -> Recorded {
    let mut raw = Vec::new();
    let mut buf = [0u8; 4096];
    let (head_end, length) = loop {
        let n = stream.read(&mut buf).unwrap();
        assert!(n > 0, "connection closed before the request ended");
        raw.extend_from_slice(&buf[..n]);
        if let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&raw[..end]).to_string();
            let length = head
                .lines()
                .find_map(|l| {
                    let (name, value) = l.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            break (end, length);
        }
    };
    while raw.len() < head_end + 4 + length {
        let n = stream.read(&mut buf).unwrap();
        assert!(n > 0, "connection closed before the body ended");
        raw.extend_from_slice(&buf[..n]);
    }
    let head = String::from_utf8_lossy(&raw[..head_end]).to_string();
    let mut lines = head.lines();
    let mut request_line = lines.next().unwrap().split(' ');
    let method = request_line.next().unwrap().to_string();
    let target = request_line.next().unwrap().to_string();
    let headers = lines
        .filter_map(|l| {
            let (name, value) = l.split_once(':')?;
            Some((name.trim().to_ascii_lowercase(), value.trim().to_string()))
        })
        .collect();
    let body = String::from_utf8_lossy(&raw[head_end + 4..head_end + 4 + length]).to_string();
    Recorded {
        method,
        target,
        headers,
        body,
    }
}
