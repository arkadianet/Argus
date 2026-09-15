//! Explicit, single-provider EIP-4 inspection. Never called by balance sync.
use ergo_lib::ergotree_ir::{
    mir::constant::{Constant, TryExtractInto},
    serialization::SigmaSerializable,
};
use serde_json::{json, Value};
use std::time::Duration;

const MAX_RESPONSE: usize = 64 * 1024;

async fn read(client: &reqwest::Client, url: reqwest::Url) -> Result<Value, String> {
    let mut response = client.get(url).send().await.map_err(|e| e.to_string())?;
    if response.status().is_redirection() {
        return Err("Redirect blocked".into());
    }
    if !response.status().is_success() {
        return Err(format!("Metadata provider returned {}", response.status()));
    }
    if response
        .content_length()
        .is_some_and(|n| n > MAX_RESPONSE as u64)
    {
        return Err("Metadata response too large".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        if bytes.len() + chunk.len() > MAX_RESPONSE {
            return Err("Metadata response too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

/// `provider` is the explorer API explicitly named in the user's action.
/// No node/explorer failover, redirects, cookies, credentials or media fetches.
pub async fn load(id: &str, provider: &str) -> Result<Value, String> {
    load_from(id, provider, false).await
}

pub async fn load_from(id: &str, provider: &str, node: bool) -> Result<Value, String> {
    if id.len() != 64 || !id.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("Invalid token ID".into());
    }
    let base = reqwest::Url::parse(provider).map_err(|e| e.to_string())?;
    if base.scheme() != "https"
        || base.host_str().is_none()
        || !base.username().is_empty()
        || base.password().is_some()
        || base.query().is_some()
        || base.fragment().is_some()
    {
        return Err(
            "Metadata provider must be an HTTPS URL without credentials, query or fragment".into(),
        );
    }
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| e.to_string())?;
    let root = provider.trim_end_matches('/');
    let token_path = if node {
        "blockchain/token/byId"
    } else {
        "api/v1/tokens"
    };
    let box_path = if node {
        "blockchain/box/byId"
    } else {
        "api/v1/boxes"
    };
    let index = read(
        &client,
        reqwest::Url::parse(&format!("{root}/{token_path}/{id}")).map_err(|e| e.to_string())?,
    )
    .await?;
    if index["id"].as_str() != Some(id) {
        return Err("Metadata conflict: token ID".into());
    }
    let box_id = index["boxId"]
        .as_str()
        .filter(|v| v.len() == 64 && v.bytes().all(|c| c.is_ascii_hexdigit()));
    let bx = if let Some(bid) = box_id {
        read(
            &client,
            reqwest::Url::parse(&format!("{root}/{box_path}/{bid}")).map_err(|e| e.to_string())?,
        )
        .await
        .ok()
    } else {
        None
    };
    Ok(describe(id, provider, &index, bx.as_ref()))
}

// Admit only the flat byte collection type before invoking Sigma's recursive
// parser. Unsupported structured attachment/audio data cannot trigger nesting.
fn bytes(v: &Value) -> Result<Vec<u8>, ()> {
    let encoded = v
        .as_str()
        .or_else(|| v.get("serializedValue").and_then(Value::as_str))
        .ok_or(())?;
    if encoded.len() > 8192 || encoded.len() % 2 != 0 {
        return Err(());
    }
    let raw = base16::decode(encoded.as_bytes()).map_err(|_| ())?;
    if raw.first() != Some(&0x0e) {
        return Err(());
    }
    let c = Constant::sigma_parse_bytes(&raw).map_err(|_| ())?;
    // Reject trailing bytes and noncanonical encodings too.
    if c.sigma_serialize_bytes().map_err(|_| ())? != raw {
        return Err(());
    }
    c.try_extract_into::<Vec<u8>>().map_err(|_| ())
}

fn audio_links(v: &Value) -> Result<(String, String), ()> {
    let encoded = v
        .as_str()
        .or_else(|| v["serializedValue"].as_str())
        .ok_or(())?;
    if encoded.len() > 8192 {
        return Err(());
    }
    let raw = base16::decode(encoded.as_bytes()).map_err(|_| ())?;
    // Exactly a pair of byte collections, no recursive type admission.
    if !raw.starts_with(&[0x3c, 0x0e, 0x0e]) {
        return Err(());
    }
    let c = Constant::sigma_parse_bytes(&raw).map_err(|_| ())?;
    if c.sigma_serialize_bytes().map_err(|_| ())? != raw {
        return Err(());
    }
    let (audio, cover) = c.try_extract_into::<(Vec<u8>, Vec<u8>)>().map_err(|_| ())?;
    if audio.len() > 2048 || cover.len() > 2048 {
        return Err(());
    }
    Ok((
        String::from_utf8(audio).map_err(|_| ())?,
        String::from_utf8(cover).map_err(|_| ())?,
    ))
}

pub fn describe(id: &str, source: &str, index: &Value, bx: Option<&Value>) -> Value {
    let mut out = json!({"id": id, "source": source, "parserVersion": 1,
        "fetchedAt": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs(),
        "issuanceTransactionId": bx.map(|b| b["transactionId"].clone()),
        "metadataState": "partial", "supplyEvidence": "unknown", "decimalsEvidence": "unknown",
        "declaredAssetKind": "none", "mediaState": "unknown", "boxId": index["boxId"],
        "name": index["name"], "description": index["description"]});
    if let Some(n) = index["emissionAmount"]
        .as_u64()
        .filter(|n| *n > 0 && *n <= i64::MAX as u64)
    {
        out["emissionAmount"] = json!(n);
        out["supplyEvidence"] = json!("originalEmission");
    }
    if let Some(d) = index["decimals"].as_u64().filter(|d| *d <= 255) {
        out["decimals"] = json!(d);
        out["decimalsEvidence"] = json!("valid");
    }
    let Some(bx) = bx else {
        return out;
    };
    if bx["boxId"] != index["boxId"]
        || !bx["assets"].as_array().is_some_and(|a| {
            a.iter().any(|t| {
                t["tokenId"].as_str() == Some(id) && t["amount"].as_u64().is_some_and(|n| n > 0)
            })
        })
    {
        out["metadataState"] = json!("conflict");
        return out;
    }
    let Some(regs) = bx["additionalRegisters"].as_object() else {
        return out;
    };
    let total: usize = regs
        .values()
        .map(|v| {
            v.as_str()
                .or_else(|| v["serializedValue"].as_str())
                .map_or(8193, str::len)
        })
        .sum();
    if total > 8192 {
        out["metadataState"] = json!("invalid");
        return out;
    }
    out["rawRegisters"] = json!(serde_json::to_string(regs).unwrap_or_default());
    out["metadataState"] = json!("complete");
    for (reg, field) in [("R4", "name"), ("R5", "description"), ("R6", "decimals")] {
        let Some(v) = regs.get(reg) else {
            // Missing evidence must not erase malformed or contradictory evidence.
            if out["metadataState"] == "complete" {
                out["metadataState"] = json!("partial");
            }
            continue;
        };
        let text = bytes(v).and_then(|b| String::from_utf8(b).map_err(|_| ()));
        match text {
            Ok(text) if reg != "R6" => {
                if index[field].as_str().is_some_and(|s| s != text) {
                    out["metadataState"] = json!("conflict");
                }
                out[field] = json!(text);
            }
            Ok(text)
                if !text.is_empty()
                    && text.bytes().all(|c| c.is_ascii_digit())
                    && text.parse::<u8>().is_ok() =>
            {
                let d = text.parse::<u8>().unwrap();
                if index[field].as_u64().is_some_and(|n| n != d as u64) {
                    out["metadataState"] = json!("conflict");
                }
                out[field] = json!(d);
                out["decimalsEvidence"] = json!("valid");
            }
            _ => {
                out["metadataState"] = json!("invalid");
                if reg == "R6" {
                    out["decimalsEvidence"] = json!("invalid");
                }
            }
        }
    }
    if let Some(v) = regs.get("R7") {
        match bytes(v) {
            Ok(b) => {
                out["declarationBytes"] = json!(base16::encode_lower(&b));
                out["declaredAssetKind"] = json!(match b.as_slice() {
                    [1, 1] => "picture",
                    [1, 2] => "audio",
                    [1, 3] => "video",
                    [1, 4] => "collection",
                    [1, 15] => "attachments",
                    [1, ..] => "unsupported",
                    _ => "none",
                });
            }
            Err(_) => out["metadataState"] = json!("invalid"),
        }
    }
    if let Some(v) = regs.get("R8") {
        if let Ok(hash) = bytes(v) {
            if hash.len() == 32 {
                out["issuanceHash"] = json!(base16::encode_lower(&hash));
            }
        }
    }
    out["mediaState"] = json!("absent");
    if let Some(v) = regs.get("R9") {
        if out["declaredAssetKind"] == "audio" {
            if let Ok((audio, cover)) = audio_links(v) {
                out["iconUrl"] = json!(audio);
                out["audioCoverUri"] = json!(cover);
                out["mediaState"] = json!("unsupported");
                return out;
            }
        }
        match bytes(v).and_then(|b| String::from_utf8(b).map_err(|_| ())) {
            Ok(uri) if uri.len() <= 2048 => {
                out["iconUrl"] = json!(uri);
                out["mediaState"] = json!(if out["declaredAssetKind"] == "picture" {
                    "notLoaded"
                } else {
                    "unsupported"
                });
            }
            _ => out["mediaState"] = json!("unsupported"),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Value, Value) {
        (
            json!({"id":"token", "boxId":"issuance", "emissionAmount":21000000000u64,"decimals":0}),
            json!({"boxId":"issuance","assets":[{"tokenId":"token","amount":1}],"additionalRegisters":{"R4":"0e0141","R5":{"serializedValue":"0e00"},"R6":"0e0130","R7":"0e020101"}}),
        )
    }
    #[test]
    fn burned_supply_is_not_current_box_amount() {
        let (i, b) = fixture();
        let d = describe("token", "provider", &i, Some(&b));
        assert_eq!(d["emissionAmount"], 21000000000u64);
        assert_eq!(d["metadataState"], "complete");
    }
    #[test]
    fn rejects_trailing_truncated_wrong_and_nested_constants() {
        for v in ["0e013000", "0e0230", "0400", "0c0c0c0c0c0c0c0c", "0e80"] {
            assert!(bytes(&json!(v)).is_err(), "{v}");
        }
    }
    #[test]
    fn detects_conflict_and_bad_decimals() {
        let (i, mut b) = fixture();
        b["boxId"] = json!("issuer");
        assert_eq!(
            describe("token", "p", &i, Some(&b))["metadataState"],
            "conflict"
        );
        b["boxId"] = i["boxId"].clone();
        b["additionalRegisters"]["R6"] = json!("0e0178");
        assert_eq!(
            describe("token", "p", &i, Some(&b))["decimalsEvidence"],
            "invalid"
        );
    }
    #[test]
    fn missing_registers_do_not_weaken_invalid_or_conflicting_metadata() {
        for (bad, missing) in [("R4", "R5"), ("R5", "R4")] {
            for state in ["invalid", "conflict"] {
                let (mut i, mut b) = fixture();
                let field = if bad == "R4" { "name" } else { "description" };
                if state == "invalid" {
                    b["additionalRegisters"][bad] = json!("0400");
                } else {
                    i[field] = json!("contradicts register");
                }
                b["additionalRegisters"].as_object_mut().unwrap().remove(missing);
                assert_eq!(
                    describe("token", "p", &i, Some(&b))["metadataState"],
                    state,
                    "{state} {bad}, missing {missing}"
                );
            }
        }
        let (i, mut b) = fixture();
        b["additionalRegisters"].as_object_mut().unwrap().remove("R5");
        assert_eq!(describe("token", "p", &i, Some(&b))["metadataState"], "partial");
    }
    #[test]
    fn preserves_hostile_text_as_inert_inspectable_data() {
        let (i, mut b) = fixture();
        let text = "evil\u{202e}\u{0001}";
        b["additionalRegisters"]["R4"] = json!(base16::encode_lower(
            &Constant::from(text.as_bytes().to_vec())
                .sigma_serialize_bytes()
                .unwrap()
        ));
        assert_eq!(describe("token", "p", &i, Some(&b))["name"], text);
    }
    async fn response_fixture(response: String) -> Result<Value, String> {
        use std::io::{Read, Write};
        let server = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = server.local_addr().unwrap();
        let worker = std::thread::spawn(move || {
            let (mut socket, _) = server.accept().unwrap();
            let mut request = [0; 4096];
            let n = socket.read(&mut request).unwrap();
            let headers = String::from_utf8_lossy(&request[..n]).to_lowercase();
            for forbidden in ["authorization:", "cookie:", "referer:", "x-api-key:"] {
                assert!(!headers.contains(forbidden));
            }
            let _ = socket.write_all(response.as_bytes());
        });
        let client = reqwest::Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(2)).build().unwrap();
        let answer = read(&client, reqwest::Url::parse(&format!("http://{addr}/fixture")).unwrap()).await;
        worker.join().unwrap();
        answer
    }
    #[tokio::test]
    async fn metadata_redirect_is_not_followed() {
        let e = response_fixture("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/private\r\nContent-Length: 0\r\n\r\n".into()).await.unwrap_err();
        assert_eq!(e, "Redirect blocked");
    }
    #[tokio::test]
    async fn metadata_stream_cap_does_not_trust_content_length() {
        let body = "x".repeat(MAX_RESPONSE + 1);
        let response = format!("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{body}\r\n0\r\n\r\n",body.len());
        assert_eq!(response_fixture(response).await.unwrap_err(), "Metadata response too large");
    }
    #[test]
    fn audio_tuple_is_typed_bounded_and_never_an_image() {
        let (i, mut b) = fixture();
        b["additionalRegisters"]["R7"] = json!("0e020102");
        let c: Constant = (
            b"https://audio.example/a".to_vec(),
            b"https://cover.example/c".to_vec(),
        ).into();
        b["additionalRegisters"]["R9"] =
            json!(base16::encode_lower(&c.sigma_serialize_bytes().unwrap()));
        let d = describe("token", "p", &i, Some(&b));
        assert_eq!(d["audioCoverUri"], "https://cover.example/c");
        assert_eq!(d["mediaState"], "unsupported");
    }
    #[test]
    fn absent_media_unknown_subtype_and_register_limit() {
        let (i, mut b) = fixture();
        b["additionalRegisters"]["R7"] = json!("0e020177");
        let d = describe("token", "p", &i, Some(&b));
        assert_eq!(d["declaredAssetKind"], "unsupported");
        assert_eq!(d["mediaState"], "absent");
        b["additionalRegisters"]["R5"] = json!("00".repeat(4097));
        assert_eq!(
            describe("token", "p", &i, Some(&b))["metadataState"],
            "invalid"
        );
    }
}
