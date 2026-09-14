//! EIP-19 JSON and QR transport. No keys, network access or signing authority.
//! Limits are Argus resource policy, not additions to the wire protocol.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const MAX_PAGES: usize = 512;
pub const MAX_INNER_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_ENVELOPE_BYTES: usize = 4096;

#[derive(Debug, thiserror::Error)]
pub enum ColdError {
    #[error("Cold signing resource limit exceeded")]
    Limit,
    #[error("Invalid cold signing data: {0}")]
    Invalid(String),
    #[error("Conflicting QR pages; discard this scan and restart")]
    Conflict,
    #[error("QR scan is incomplete")]
    Incomplete,
    #[error("Returned transaction does not match the prepared transaction")]
    Mismatch,
    #[error("Invalid signature on input {0}")]
    InvalidProof(usize),
}

pub(crate) fn invalid(e: impl std::fmt::Display) -> ColdError {
    ColdError::Invalid(e.to_string())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Request,
    Response,
}
impl Direction {
    fn key(self) -> &'static str {
        match self {
            Self::Request => "CSR",
            Self::Response => "CSTX",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum Density {
    Normal,
    Low,
}
impl Density {
    pub fn byte_limit(self) -> usize {
        match self {
            Self::Normal => 2000,
            Self::Low => 400,
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RequestJson {
    reduced_tx: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    sender: Option<String>,
    inputs: Vec<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResponseJson {
    signed_tx: String,
}

/// Decoded transport bytes, still untrusted. Use `cold_signing` for binary validation.
#[derive(Debug, PartialEq, Eq)]
pub struct RequestBytes {
    pub reduced_tx: Vec<u8>,
    pub sender: Option<String>,
    pub inputs: Vec<Vec<u8>>,
}
impl RequestBytes {
    pub fn encode(&self) -> Result<String, ColdError> {
        let total = self.inputs.iter().try_fold(self.reduced_tx.len(), |n, b| {
            n.checked_add(b.len()).ok_or(ColdError::Limit)
        })?;
        if total > MAX_INNER_BYTES
            || self.inputs.len() > u16::MAX as usize
            || self
                .sender
                .as_ref()
                .is_some_and(|s| s.len() > MAX_INNER_BYTES)
        {
            return Err(ColdError::Limit);
        }
        let json = serde_json::to_string(&RequestJson {
            reduced_tx: STANDARD.encode(&self.reduced_tx),
            sender: self.sender.clone(),
            inputs: self.inputs.iter().map(|b| STANDARD.encode(b)).collect(),
        })
        .map_err(invalid)?;
        check_inner(&json)?;
        Ok(json)
    }
    pub fn decode(json: &str) -> Result<Self, ColdError> {
        check_inner(json)?;
        let raw: RequestJson = serde_json::from_str(json).map_err(invalid)?;
        if raw.inputs.len() > u16::MAX as usize {
            return Err(ColdError::Limit);
        }
        Ok(Self {
            reduced_tx: STANDARD.decode(raw.reduced_tx).map_err(invalid)?,
            sender: raw.sender,
            inputs: raw
                .inputs
                .iter()
                .map(|b| STANDARD.decode(b).map_err(invalid))
                .collect::<Result<_, _>>()?,
        })
    }
}
pub fn encode_response(bytes: &[u8]) -> Result<String, ColdError> {
    if bytes.len() > MAX_INNER_BYTES {
        return Err(ColdError::Limit);
    }
    let json = serde_json::to_string(&ResponseJson {
        signed_tx: STANDARD.encode(bytes),
    })
    .map_err(invalid)?;
    check_inner(&json)?;
    Ok(json)
}
pub fn decode_response(json: &str) -> Result<Vec<u8>, ColdError> {
    check_inner(json)?;
    let raw: ResponseJson = serde_json::from_str(json).map_err(invalid)?;
    STANDARD.decode(raw.signed_tx).map_err(invalid)
}
fn check_inner(json: &str) -> Result<(), ColdError> {
    if json.is_empty() || json.len() > MAX_INNER_BYTES {
        Err(ColdError::Limit)
    } else {
        Ok(())
    }
}
fn envelope(direction: Direction, data: &str, n: usize, p: usize) -> String {
    let mut obj = serde_json::Map::new();
    obj.insert(direction.key().into(), data.into());
    if n > 1 {
        obj.insert("n".into(), n.into());
        obj.insert("p".into(), p.into());
    }
    serde_json::Value::Object(obj).to_string()
}

/// Slice before escaping, preserving UTF-8 boundaries; cap actual encoded QR bytes.
pub fn pages(
    inner: &str,
    direction: Direction,
    density: Density,
) -> Result<Vec<String>, ColdError> {
    check_inner(inner)?;
    let limit = density.byte_limit();
    if envelope(direction, inner, 1, 1).len() <= limit {
        return Ok(vec![envelope(direction, inner, 1, 1)]);
    }
    let mut remaining = inner;
    let mut slices = Vec::new();
    while !remaining.is_empty() {
        if slices.len() == MAX_PAGES {
            return Err(ColdError::Limit);
        }
        let mut end = remaining.len().min(limit - 30 - direction.key().len());
        while !remaining.is_char_boundary(end) {
            end -= 1;
        }
        while envelope(direction, &remaining[..end], MAX_PAGES, MAX_PAGES).len() > limit {
            end -= 1;
            while !remaining.is_char_boundary(end) {
                end -= 1;
            }
        }
        slices.push(&remaining[..end]);
        remaining = &remaining[end..];
    }
    Ok(slices
        .iter()
        .enumerate()
        .map(|(i, s)| envelope(direction, s, slices.len(), i + 1))
        .collect())
}

#[derive(Deserialize)]
struct Page {
    #[serde(rename = "CSR")]
    request: Option<String>,
    #[serde(rename = "CSTX")]
    response: Option<String>,
    #[serde(default = "one")]
    n: usize,
    #[serde(default = "one")]
    p: usize,
}
fn one() -> usize {
    1
}

/// Retain this collector when scanning pauses. Conflicts latch until explicit reset.
/// EIP-19 has no session ID: same-count, disjoint mixed pages cannot be detected here.
#[derive(Debug)]
pub struct Collector {
    direction: Direction,
    total: Option<usize>,
    parts: BTreeMap<usize, String>,
    bytes: usize,
    conflicted: bool,
}
impl Collector {
    pub fn new(direction: Direction) -> Self {
        Self {
            direction,
            total: None,
            parts: BTreeMap::new(),
            bytes: 0,
            conflicted: false,
        }
    }
    pub fn reset(&mut self) {
        *self = Self::new(self.direction);
    }
    pub fn received(&self) -> usize {
        self.parts.len()
    }
    pub fn total(&self) -> Option<usize> {
        self.total
    }
    pub fn missing(&self) -> Vec<usize> {
        (1..=self.total.unwrap_or(0))
            .filter(|p| !self.parts.contains_key(p))
            .collect()
    }
    pub fn add(&mut self, envelope: &str) -> Result<(), ColdError> {
        if self.conflicted {
            return Err(ColdError::Conflict);
        }
        if envelope.len() > MAX_ENVELOPE_BYTES {
            return Err(ColdError::Limit);
        }
        let page: Page = serde_json::from_str(envelope).map_err(invalid)?;
        if page.n == 0 || page.n > MAX_PAGES || page.p == 0 || page.p > page.n {
            return Err(invalid("page index/count outside limits"));
        }
        let data = match (self.direction, page.request, page.response) {
            (Direction::Request, Some(s), None) | (Direction::Response, None, Some(s)) => s,
            _ => {
                self.conflicted = true;
                return Err(ColdError::Conflict);
            }
        };
        if self.total.is_some_and(|n| n != page.n)
            || self.parts.get(&page.p).is_some_and(|s| s != &data)
        {
            self.conflicted = true;
            return Err(ColdError::Conflict);
        }
        if self.parts.contains_key(&page.p) {
            return Ok(());
        }
        if self.bytes + data.len() > MAX_INNER_BYTES {
            return Err(ColdError::Limit);
        }
        self.bytes += data.len();
        self.total = Some(page.n);
        self.parts.insert(page.p, data);
        Ok(())
    }
    pub fn finish(&self) -> Result<String, ColdError> {
        if self.conflicted {
            return Err(ColdError::Conflict);
        }
        if self.total != Some(self.parts.len()) {
            return Err(ColdError::Incomplete);
        }
        Ok(self.parts.values().cloned().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn appkit_envelope_and_base64() {
        let request = RequestBytes {
            reduced_tx: vec![251, 255],
            sender: Some("ADDRESS".into()),
            inputs: vec![b"INPUT1".to_vec()],
        };
        let json = request.encode().unwrap();
        assert_eq!(
            json,
            r#"{"reducedTx":"+/8=","sender":"ADDRESS","inputs":["SU5QVVQx"]}"#
        );
        assert_eq!(RequestBytes::decode(&json).unwrap(), request);
        let mut collector = Collector::new(Direction::Request);
        collector
            .add(&pages(&json, Direction::Request, Density::Normal).unwrap()[0])
            .unwrap();
        assert_eq!(collector.finish().unwrap(), json);
        assert_eq!(
            decode_response(r#"{"signedTx":"+/8\u003d"}"#).unwrap(),
            vec![251, 255]
        );
        assert!(decode_response(r#"{"signedTx":"-_8="}"#).is_err());
        assert!(RequestBytes::decode(r#"{"reducedTx":"AA=="}"#).is_err());
        assert!(
            RequestBytes::decode(r#"{"reducedTx":"AA==","reducedTx":"AA==","inputs":[]}"#).is_err()
        );
    }
    #[test]
    fn out_of_order_duplicate_and_interruption() {
        let json = include_str!("../tests/fixtures/eip19/appkit-request-2.json").trim();
        let chunks = pages(json, Direction::Request, Density::Low).unwrap();
        assert_eq!(chunks.len(), 4); // pinned Appkit multi-page case
        let mut c = Collector::new(Direction::Request);
        c.add(&chunks[3]).unwrap();
        c.add(&chunks[0]).unwrap();
        c.add(&chunks[3]).unwrap();
        assert_eq!(c.received(), 2);
        assert_eq!(c.missing(), vec![2, 3]);
        assert!(matches!(c.finish(), Err(ColdError::Incomplete)));
        c.add(&chunks[2]).unwrap();
        c.add(&chunks[1]).unwrap();
        assert_eq!(c.finish().unwrap(), json);
    }
    #[test]
    fn conflicts_require_reset() {
        for conflict in [
            r#"{"CSR":"b","n":2,"p":1}"#,
            r#"{"CSR":"a","n":3,"p":2}"#,
            r#"{"CSTX":"a","n":2,"p":2}"#,
        ] {
            let mut c = Collector::new(Direction::Request);
            c.add(r#"{"CSR":"a","n":2,"p":1}"#).unwrap();
            assert!(matches!(c.add(conflict), Err(ColdError::Conflict)));
            assert!(c.finish().is_err());
            assert!(c.add(r#"{"CSR":"b","n":2,"p":2}"#).is_err());
            c.reset();
            c.add(r#"{"CSR":"ok"}"#).unwrap();
            assert_eq!(c.finish().unwrap(), "ok");
        }
    }
    #[test]
    fn malformed_bounds_and_escape_expansion() {
        for bad in [
            r#"{"CSR":"x","n":0}"#,
            r#"{"CSR":"x","p":0}"#,
            r#"{"CSR":"x","n":513}"#,
            r#"{"CSR":"x","p":2}"#,
            r#"{"CSR":"x","p":1.0}"#,
            r#"{"CSR":"x","n":-1}"#,
            r#"{"CSR":"x","p":null}"#,
            r#"{"CSR":"x","CSR":"y"}"#,
            r#"{"CSR":"x","CSTX":"y"}"#,
        ] {
            assert!(
                Collector::new(Direction::Request).add(bad).is_err(),
                "{bad}"
            );
        }
        assert!(Collector::new(Direction::Request)
            .add(&"x".repeat(MAX_ENVELOPE_BYTES + 1))
            .is_err());
        assert!(pages(
            &"x".repeat(MAX_INNER_BYTES + 1),
            Direction::Request,
            Density::Normal
        )
        .is_err());
        assert!(pages(
            &"x".repeat(MAX_INNER_BYTES),
            Direction::Request,
            Density::Low
        )
        .is_err());
        let inner = "\"\\\n🦀".repeat(900);
        for direction in [Direction::Request, Direction::Response] {
            for density in [Density::Normal, Density::Low] {
                let mut c = Collector::new(direction);
                for p in pages(&inner, direction, density).unwrap().iter().rev() {
                    assert!(p.len() <= density.byte_limit());
                    c.add(p).unwrap();
                }
                assert_eq!(c.finish().unwrap(), inner);
            }
        }
    }
}
