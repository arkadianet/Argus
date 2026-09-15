//! In-memory EIP-19 sessions. Public preparation never uses a wallet handle.
use super::*;
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use wallet_core::{
    cold_signing::{PreparedColdTransaction, VerifiedColdTransaction},
    cold_transport::{encode_response, pages, Collector, Density, Direction},
    watch_xpub::WatchContext,
};

/// Public input ownership only; a single address has no invented derivation metadata.
struct WatchSource {
    addresses: Vec<String>,
    metadata: serde_json::Value,
}
impl WatchSource {
    fn account(key: &str, count: u32) -> Result<Self, String> {
        let watch = WatchContext::new(key, count)?;
        Ok(Self {
            addresses: watch.addresses.iter().map(|a| a.address.clone()).collect(),
            metadata: serde_json::to_value(watch).map_err(fail)?,
        })
    }
    fn address(address: String) -> Result<Self, String> {
        use ergo_lib::ergotree_ir::chain::address::{Address, AddressEncoder, NetworkPrefix};
        let parsed = AddressEncoder::new(NetworkPrefix::Mainnet)
            .parse_address_from_str(&address)
            .map_err(fail)?;
        if !matches!(parsed, Address::P2Pk(_)) {
            return Err("Cold send requires a mainnet P2PK watched address".into());
        }
        Ok(Self {
            metadata: serde_json::json!({"address": address, "change_address": address}),
            addresses: vec![address],
        })
    }
}

struct Session {
    created: Instant,
    collector: Collector,
    prepared: Option<Arc<PreparedColdTransaction>>,
    verified: Option<Arc<VerifiedColdTransaction>>,
    signed: Option<Vec<u8>>,
    handle: Option<u64>,
    node: Option<String>,
    request: Option<String>,
    watch: Option<WatchSource>,
    input_ownership: Vec<String>,
}
static SESSIONS: Lazy<Mutex<HashMap<String, Session>>> = Lazy::new(|| Mutex::new(HashMap::new()));
fn fail(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn insert(s: Session) -> Result<String, String> {
    let mut sessions = recover(SESSIONS.lock());
    sessions.retain(|_, s| s.created.elapsed() < Duration::from_secs(1800) || s.verified.is_some());
    if sessions.len() >= 8 {
        return Err("Too many cold sessions; discard an existing session".into());
    }
    let id = format!("{:032x}", rand::random::<u128>());
    sessions.insert(id.clone(), s);
    Ok(id)
}
fn session<'a>(
    sessions: &'a mut HashMap<String, Session>,
    id: &str,
) -> Result<&'a mut Session, String> {
    let s = sessions
        .get_mut(id)
        .ok_or("Cold session missing; start again")?;
    if s.created.elapsed() >= Duration::from_secs(1800) {
        return Err("Cold session expired; rebuild and sign again".into());
    }
    Ok(s)
}
pub(super) fn start() -> Result<String, String> {
    insert(Session {
        created: Instant::now(),
        collector: Collector::new(Direction::Request),
        prepared: None,
        verified: None,
        signed: None,
        handle: None,
        node: None,
        request: None,
        watch: None,
        input_ownership: Vec::new(),
    })
}
pub(super) fn discard(id: String) {
    recover(SESSIONS.lock()).remove(&id);
}
pub(super) fn reset(id: String) -> Result<(), String> {
    let mut sessions = recover(SESSIONS.lock());
    let s = session(&mut sessions, &id)?;
    s.collector.reset();
    s.verified = None;
    s.signed = None;
    s.handle = None;
    if s.watch.is_none() {
        s.prepared = None;
    }
    Ok(())
}
pub(super) fn add(id: String, page: String) -> Result<String, String> {
    let mut sessions = recover(SESSIONS.lock());
    let s = session(&mut sessions, &id)?;
    // Never keep approval after additional scanned data, even if it is a duplicate.
    s.verified = None;
    s.signed = None;
    s.handle = None;
    s.collector.add(&page).map_err(fail)?;
    Ok(serde_json::json!({ "received": s.collector.received(), "total": s.collector.total(), "missing": s.collector.missing() }).to_string())
}
pub(super) fn review(id: String, handle: u64) -> Result<String, String> {
    let mut sessions = recover(SESSIONS.lock());
    let s = session(&mut sessions, &id)?;
    if s.watch.is_some() {
        return Err("Expected an offline request session".into());
    }
    s.handle = None;
    s.prepared = None;
    let prepared = wallet_core::cold_request::parse_request(&s.collector.finish().map_err(fail)?)
        .map_err(fail)?;
    let review = with_handle(handle, "cold_review", |h| {
        prepared
            .review(|a| {
                h.owns_address(a)
                    .map_err(|e| wallet_core::cold_transport::ColdError::Invalid(e.to_string()))
            })
            .map_err(fail)
    })?;
    s.prepared = Some(Arc::new(prepared));
    s.handle = Some(handle);
    Ok(review_value(&review)?.to_string())
}
fn review_value(
    review: &wallet_core::cold_signing::ColdReview,
) -> Result<serde_json::Value, String> {
    let mut value = serde_json::to_value(review).map_err(fail)?;
    for output in value["outputs"]
        .as_array_mut()
        .ok_or("Missing review outputs")?
    {
        output["application_fee"] = serde_json::json!(
            output["address"].as_str() == Some(ARGUS_FEE_ADDRESS)
                && output["nano_erg"].as_str() == Some(ARGUS_FEE_NANO.to_string().as_str())
                && output["tokens"].as_array().is_some_and(Vec::is_empty)
        );
    }
    Ok(value)
}
pub(super) fn sign(id: String, handle: u64) -> Result<(), String> {
    let mut sessions = recover(SESSIONS.lock());
    let s = session(&mut sessions, &id)?;
    if s.watch.is_some() || s.handle != Some(handle) {
        return Err("Review this request with the selected unlocked wallet first".into());
    }
    let p = s.prepared.as_ref().ok_or("Review is required")?;
    let bytes = with_handle(handle, "cold_sign", |h| p.sign_reviewed(h).map_err(fail))?;
    s.signed = Some(bytes);
    Ok(())
}
pub(super) fn qr(id: String, low: bool) -> Result<Vec<String>, String> {
    let mut sessions = recover(SESSIONS.lock());
    let s = session(&mut sessions, &id)?;
    let (inner, direction) = if let Some(bytes) = &s.signed {
        (encode_response(bytes).map_err(fail)?, Direction::Response)
    } else {
        (
            s.request.clone().ok_or("No QR payload ready")?,
            Direction::Request,
        )
    };
    pages(
        &inner,
        direction,
        if low { Density::Low } else { Density::Normal },
    )
    .map_err(fail)
}
pub(super) fn verify(id: String) -> Result<String, String> {
    let mut sessions = recover(SESSIONS.lock());
    let s = session(&mut sessions, &id)?;
    s.verified = None;
    if s.watch.is_none() {
        return Err("Expected a hot preparation".into());
    }
    let verified = s
        .prepared
        .as_ref()
        .ok_or("Missing preparation")?
        .verify_response(&s.collector.finish().map_err(fail)?)
        .map_err(fail)?;
    if s.input_ownership.is_empty() {
        return Err("Missing prepared input ownership".into());
    }
    let tx_id = verified.id();
    s.verified = Some(Arc::new(verified));
    Ok(tx_id)
}
pub(super) async fn broadcast(id: String) -> Result<String, String> {
    let (verified, node) = {
        let mut sessions = recover(SESSIONS.lock());
        // Expiry blocks new approval, but a verified return survives for retries.
        let s = sessions.get_mut(&id).ok_or("Cold session missing")?;
        (
            s.verified
                .clone()
                .ok_or("Refusing broadcast: no verified response")?,
            s.node.clone(),
        )
    };
    let json = serde_json::from_str(&verified.node_json().map_err(fail)?).map_err(fail)?;
    let client = node_client(node).await?;
    // Includes live spendability and node policy. Existing client normalizes an
    // already-known result to this exact transaction ID. Keep bytes for retry.
    if let Err(error) = client.check_transaction(&json).await {
        if already_known(&client, &verified.id()).await {
            return Ok(verified.id());
        }
        return Err(error);
    }
    let returned = match client.submit_transaction(&json).await {
        Ok(id) => id,
        Err(error) => {
            if already_known(&client, &verified.id()).await {
                return Ok(verified.id());
            }
            return Err(error);
        }
    };
    if returned != verified.id() {
        return Err("Node returned a different transaction ID".into());
    }
    Ok(returned)
}
async fn already_known(client: &ErgoNodeClient, id: &str) -> bool {
    client
        .get_transaction_by_id(id)
        .await
        .is_ok_and(|tx| tx["id"].as_str() == Some(id))
}
pub(super) async fn prepare(
    key: String,
    count: u32,
    change_index: u32,
    recipient: String,
    amount: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node: String,
) -> Result<String, String> {
    let watch = WatchSource::account(&key, count)?;
    prepare_source(
        watch,
        change_index,
        recipient,
        amount,
        token_id,
        token_amount,
        node,
    )
    .await
}

pub(super) async fn prepare_address(
    address: String,
    recipient: String,
    amount: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node: String,
) -> Result<String, String> {
    prepare_source(
        WatchSource::address(address)?,
        0,
        recipient,
        amount,
        token_id,
        token_amount,
        node,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn prepare_source(
    watch: WatchSource,
    change_index: u32,
    recipient: String,
    amount: i64,
    token_id: Option<String>,
    token_amount: Option<u64>,
    node: String,
) -> Result<String, String> {
    watch
        .addresses
        .get(change_index as usize)
        .ok_or("Change index outside discovered account")?;
    if amount < MIN_BOX_VALUE_NANO {
        return Err(format!("Send at least {MIN_BOX_VALUE_NANO} nanoERG"));
    }
    let recipient_tree = address_to_ergo_tree(&recipient)?;
    // Mainnet P2PK is the explicit first policy, including destinations.
    use ergo_lib::ergotree_ir::chain::address::{Address, AddressEncoder, NetworkPrefix};
    let address = AddressEncoder::new(NetworkPrefix::Mainnet)
        .parse_address_from_str(&recipient)
        .map_err(fail)?;
    if !matches!(address, Address::P2Pk(_)) {
        return Err("Cold send requires a mainnet P2PK recipient".into());
    }
    let mut tokens = HashMap::new();
    match (token_id, token_amount) {
        (Some(id), Some(n)) if n > 0 && n <= i64::MAX as u64 => {
            let bytes = hex::decode(&id).map_err(fail)?;
            if bytes.len() != 32 {
                return Err("Invalid token ID".into());
            }
            tokens.insert(id.to_lowercase(), n);
        }
        (None, None) => (),
        _ => return Err("Supply both a token ID and a positive integer quantity".into()),
    }
    let client = node_client(Some(node.clone())).await?;
    let mut boxes = Vec::new();
    let mut seen = HashSet::new();
    for a in &watch.addresses {
        let (bs, ins) = client.get_effective_unspent(a).await?;
        if bs.len() != ins.len() {
            return Err("Incomplete node input data".into());
        }
        let expected = address_to_ergo_tree(a)?;
        for (b, input) in bs.into_iter().zip(ins) {
            if hex::encode(b.ergo_tree.sigma_serialize_bytes().map_err(fail)?) != expected {
                return Err("Node returned a foreign input".into());
            }
            if seen.insert(input.box_id.clone()) {
                boxes.push(b);
            }
        }
    }
    let height = client.current_height().await?;
    let context = client.get_state_context().await?;
    build_watch_session(
        watch,
        change_index,
        recipient_tree,
        amount,
        tokens,
        node,
        boxes,
        height,
        &context,
    )
}

#[allow(clippy::too_many_arguments)]
fn build_watch_session(
    watch: WatchSource,
    change_index: u32,
    recipient_tree: String,
    amount: i64,
    tokens: HashMap<String, u64>,
    node: String,
    boxes: Vec<ErgoBox>,
    height: u64,
    context: &ergo_lib::chain::ergo_state_context::ErgoStateContext,
) -> Result<String, String> {
    let change = watch
        .addresses
        .get(change_index as usize)
        .ok_or("Change index outside discovered account")?;
    let inputs = boxes
        .iter()
        .map(|b| ergo_tx::Eip12InputBox::from_ergo_box(b, b.transaction_id.to_string(), b.index))
        .collect::<Vec<_>>();
    let required = multi_send_required_erg(amount, TX_FEE_NANO, false)?;
    let selected = select_for_multi_send(&inputs, required, &tokens).map_err(fail)?;
    let built = ergo_tx::build_multi_send_tx_with_fee(
        &selected,
        &[ergo_tx::RecipientSpec {
            ergo_tree: recipient_tree,
            amount_nano_erg: amount,
            tokens: tokens.into_iter().collect(),
        }],
        &address_to_ergo_tree(change)?,
        TX_FEE_NANO,
        i32::try_from(height).map_err(fail)?,
    )
    .map_err(fail)?;
    let selected_boxes = built
        .unsigned_tx
        .inputs
        .iter()
        .map(|input| {
            boxes
                .iter()
                .find(|b| b.box_id().to_string() == input.box_id)
                .cloned()
                .ok_or("Missing selected input".to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    let reduced =
        reduce_transaction_with_context(&built.unsigned_tx, selected_boxes, Vec::new(), context)
            .map_err(fail)?;
    // Apply exactly the cold-device grammar now, so an unsupported payment cannot
    // be exported as an apparently signable request.
    let selected_boxes = built
        .unsigned_tx
        .inputs
        .iter()
        .map(|input| {
            boxes
                .iter()
                .find(|b| b.box_id().to_string() == input.box_id)
                .ok_or("Missing input".to_string())?
                .sigma_serialize_bytes()
                .map_err(fail)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let request = wallet_core::cold_transport::RequestBytes {
        reduced_tx: reduced,
        sender: Some(watch.addresses[0].clone()),
        inputs: selected_boxes,
    }
    .encode()
    .map_err(fail)?;
    let prepared = wallet_core::cold_request::parse_request(&request).map_err(fail)?;
    let review = prepared
        .review(|a| Ok(watch.addresses.iter().any(|entry| entry == a)))
        .map_err(fail)?;
    let input_ownership = built
        .unsigned_tx
        .inputs
        .iter()
        .map(|input| {
            let b = boxes
                .iter()
                .find(|b| b.box_id().to_string() == input.box_id)
                .ok_or("Missing input")?;
            let tree = hex::encode(b.ergo_tree.sigma_serialize_bytes().map_err(fail)?);
            watch
                .addresses
                .iter()
                .find(|a| address_to_ergo_tree(a).is_ok_and(|t| t == tree))
                .cloned()
                .ok_or("Unknown input ownership".to_string())
        })
        .collect::<Result<Vec<_>, String>>()?;
    let metadata = watch.metadata.clone();
    let id = insert(Session {
        created: Instant::now(),
        collector: Collector::new(Direction::Response),
        prepared: Some(Arc::new(prepared)),
        verified: None,
        signed: None,
        handle: None,
        node: Some(node),
        request: Some(request),
        watch: Some(watch),
        input_ownership,
    })?;
    Ok(
        serde_json::json!({"session": id, "review": review_value(&review)?, "ownership": metadata})
            .to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn public_watch_build_offline_review_sign_and_verified_return() {
        const KEY: &str = "0488b21e04220c2217000000009216e49a70865823eff5381d6fd33ac96743af1f3051dc4cc8edd66a29a740860326cfc301b0c8d4d815ac721e0551304417e6133c2c9137f9f22c33895a3e1650";
        let watch = WatchSource::account(KEY, 21).unwrap();
        let boxes = [0, 3, 20]
            .iter()
            .map(|i| {
                serde_json::from_value(serde_json::json!({
                    "transactionId": "91".repeat(32), "index": i, "value": 10000000,
                    "ergoTree": address_to_ergo_tree(&watch.addresses[*i as usize]).unwrap(),
                    "creationHeight": 1, "assets": [], "additionalRegisters": {}
                }))
                .unwrap()
            })
            .collect();
        let recipient = address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap();
        // Preparation has no handle or secrets, including input selection and fees.
        let result: serde_json::Value = serde_json::from_str(
            &ergo_tx::dev_fee::with_test_dev_fee(
                DevFeeConfig::custom(recipient.clone(), ARGUS_FEE_NANO),
                || {
                    build_watch_session(
                        watch,
                        1,
                        recipient,
                        25000000,
                        HashMap::new(),
                        "http://unused.invalid".into(),
                        boxes,
                        2000,
                        &wallet_net::client::make_state_context(2000),
                    )
                },
            )
            .unwrap(),
        )
        .unwrap();
        let hot = result["session"].as_str().unwrap().to_string();
        {
            let sessions = recover(SESSIONS.lock());
            let s = sessions.get(&hot).unwrap();
            assert_eq!(s.watch.as_ref().unwrap().metadata["key_depth"], 4);
            assert_eq!(s.input_ownership.len(), 3);
            let addresses = &s.watch.as_ref().unwrap().addresses;
            for i in [0, 3, 20] {
                assert!(s.input_ownership.contains(&addresses[i]));
            }
        }
        let cold = start().unwrap();
        let ps = qr(hot.clone(), true).unwrap();
        assert!(ps.len() > 1);
        for page in ps.into_iter().rev() {
            add(cold.clone(), page.clone()).unwrap();
            add(cold.clone(), page).unwrap();
        }
        assert!(sign(cold.clone(), 1).is_err());
        let handle = register_handle(WalletHandle::create(MnemonicPhrase::parse("lens stadium egg cage hollow noble gate belt impulse vicious middle endless angry buzz crack").unwrap(), "").unwrap());
        let shown: serde_json::Value =
            serde_json::from_str(&review(cold.clone(), handle).unwrap()).unwrap();
        assert_eq!(shown["network"], "Mainnet");
        assert_eq!(shown["fee_nano"], TX_FEE_NANO.to_string());
        // A deliberate larger payment to the developer is still a recipient,
        // not mislabeled as the fixed application fee.
        assert_eq!(shown["outputs"][0]["application_fee"], false);
        assert_eq!(
            shown["outputs"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|o| o["application_fee"] == true)
                .count(),
            1
        );
        sign(cold.clone(), handle).unwrap();
        for page in qr(cold.clone(), true).unwrap().into_iter().rev() {
            add(hot.clone(), page).unwrap();
        }
        let id = verify(hot.clone()).unwrap();
        assert_eq!(
            recover(SESSIONS.lock())
                .get(&hot)
                .unwrap()
                .verified
                .as_ref()
                .unwrap()
                .id(),
            id
        );
        // Any new scan invalidates the verified capability. No unchecked fallback.
        assert!(add(hot.clone(), "hostile".into()).is_err());
        assert!(recover(SESSIONS.lock())
            .get(&hot)
            .unwrap()
            .verified
            .is_none());
        wallet_lock(handle).unwrap();
        assert!(sign(cold.clone(), handle).is_err());
        discard(hot);
        discard(cold);
    }

    #[tokio::test]
    async fn single_address_erg_and_tokens_round_trip_with_same_address_change() {
        const PHRASE: &str = "lens stadium egg cage hollow noble gate belt impulse vicious middle endless angry buzz crack";
        let fixture = WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap();
        // Beyond preloaded indices: the actual signer below has never derived it.
        let address = fixture.derive_address(73).unwrap();
        let foreign =
            WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "other").unwrap();
        let recipient = foreign.derive_address(0).unwrap();
        let token_id = "ab".repeat(32);
        for with_token in [false, true] {
            let watch = WatchSource::address(address.clone()).unwrap();
            let assets = if with_token {
                serde_json::json!([{"tokenId": token_id, "amount": 42}])
            } else {
                serde_json::json!([])
            };
            let boxes = vec![serde_json::from_value(serde_json::json!({
                "transactionId": "91".repeat(32), "index": 0, "value": 10000000,
                "ergoTree": address_to_ergo_tree(&address).unwrap(),
                "creationHeight": 1, "assets": assets, "additionalRegisters": {}
            }))
            .unwrap()];
            let tokens = if with_token {
                HashMap::from([(token_id.clone(), 12)])
            } else {
                HashMap::new()
            };
            let result: serde_json::Value = serde_json::from_str(
                &ergo_tx::dev_fee::with_test_dev_fee(
                    DevFeeConfig::custom(
                        address_to_ergo_tree(ARGUS_FEE_ADDRESS).unwrap(),
                        ARGUS_FEE_NANO,
                    ),
                    || {
                        build_watch_session(
                            watch,
                            0,
                            address_to_ergo_tree(&recipient).unwrap(),
                            2000000,
                            tokens,
                            "http://unused.invalid".into(),
                            boxes,
                            2000,
                            &wallet_net::client::make_state_context(2000),
                        )
                    },
                )
                .unwrap(),
            )
            .unwrap();
            let hot = result["session"].as_str().unwrap().to_string();
            assert_eq!(result["ownership"]["change_address"], address);
            assert!(result["ownership"].get("key_depth").is_none());
            let outputs = result["review"]["outputs"].as_array().unwrap();
            let change = outputs.iter().find(|o| o["owned"] == true).unwrap();
            assert_eq!(change["address"], address);
            assert_eq!(
                change["nano_erg"],
                (10000000 - 2000000 - TX_FEE_NANO - ARGUS_FEE_NANO).to_string()
            );
            if with_token {
                assert_eq!(outputs[0]["tokens"][0]["amount"], "12");
                assert_eq!(change["tokens"][0]["amount"], "30");
            }
            assert!(broadcast(hot.clone())
                .await
                .unwrap_err()
                .contains("no verified response"));
            let cold = start().unwrap();
            for page in qr(hot.clone(), true).unwrap() {
                add(cold.clone(), page).unwrap();
            }
            let wrong = register_handle(
                WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "wrong").unwrap(),
            );
            assert!(review(cold.clone(), wrong).is_err());
            assert!(sign(cold.clone(), wrong).is_err());
            wallet_lock(wrong).unwrap();
            let owner = register_handle(
                WalletHandle::create(MnemonicPhrase::parse(PHRASE).unwrap(), "").unwrap(),
            );
            let shown: serde_json::Value =
                serde_json::from_str(&review(cold.clone(), owner).unwrap()).unwrap();
            assert_eq!(shown, result["review"]);
            sign(cold.clone(), owner).unwrap();
            for page in qr(cold.clone(), true).unwrap() {
                add(hot.clone(), page).unwrap();
            }
            // Even a complete signed response must be verified before broadcast.
            assert!(broadcast(hot.clone())
                .await
                .unwrap_err()
                .contains("no verified response"));
            verify(hot.clone()).unwrap();
            assert!(add(hot.clone(), "invalid".into()).is_err());
            assert!(broadcast(hot.clone())
                .await
                .unwrap_err()
                .contains("no verified response"));
            wallet_lock(owner).unwrap();
            discard(hot);
            discard(cold);
        }
    }

    #[test]
    fn single_address_source_rejects_non_p2pk_and_invalid_addresses() {
        assert!(WatchSource::address("not an address".into()).is_err());
        use ergo_lib::ergotree_ir::chain::address::{NetworkAddress, NetworkPrefix};
        let script_address = NetworkAddress::new(
            NetworkPrefix::Mainnet,
            &ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS,
        )
        .to_base58();
        assert!(WatchSource::address(script_address).is_err());
    }

    #[tokio::test]
    async fn broadcast_without_verified_bytes_never_reaches_a_node() {
        let id = start().unwrap();
        assert!(broadcast(id.clone())
            .await
            .unwrap_err()
            .contains("no verified response"));
        assert!(verify(id.clone()).is_err());
        assert!(sign(id.clone(), 1).is_err());
        discard(id);
    }
    #[test]
    fn native_scan_missing_duplicate_conflict_and_expiry() {
        let id = start().unwrap();
        let first = r#"{"CSR":"part one","n":2,"p":1}"#;
        add(id.clone(), first.into()).unwrap();
        let progress: serde_json::Value =
            serde_json::from_str(&add(id.clone(), first.into()).unwrap()).unwrap();
        assert_eq!(progress["received"], 1);
        assert_eq!(progress["missing"], serde_json::json!([2]));
        assert!(review(id.clone(), 1).unwrap_err().contains("incomplete"));
        assert!(add(id.clone(), r#"{"CSR":"conflict","n":2,"p":1}"#.into()).is_err());
        assert!(add(id.clone(), first.into()).is_err());
        reset(id.clone()).unwrap();
        assert!(add(id.clone(), "{".into()).is_err());
        add(id.clone(), first.into()).unwrap();
        {
            let mut sessions = recover(SESSIONS.lock());
            sessions.get_mut(&id).unwrap().created = Instant::now() - Duration::from_secs(1801);
        }
        assert!(reset(id.clone()).unwrap_err().contains("expired"));
        discard(id);
    }
}
