//! One box looked up in a node's mempool: does a pending transaction spend
//! it, and does one create it.
//!
//! Nodes differ. Scala nodes answer both by id
//! (`/transactions/unconfirmed/{inputs,outputs}/byBoxId/{id}`), with their
//! JSON error `{"error":404,"reason":"not-found",...}` for a box the mempool
//! does not hold. The Rust node serves neither route: both come back 404 with
//! an empty body, which says nothing about the box. Its own API answers the
//! spend question at `/api/v1/mempool/by-box-id/{id}` (where a proxy lets it
//! through) and has no lookup for outputs. Every node lists its whole mempool
//! at `/transactions/unconfirmed`.
//!
//! So each question goes to the routes in order, and only the node's own
//! answer counts: a route that does not answer is passed over, never read as
//! "nothing pending". The last resort reads the whole mempool until two
//! passes agree, and when that fails the lookup fails. Which route a node
//! answers on is worked out once and remembered for that node.

use super::*;
use std::collections::HashMap;

/// Where a node answers "does a pending transaction spend this box?".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpendRoute {
    /// `GET /transactions/unconfirmed/inputs/byBoxId/{id}` (Scala nodes).
    InputsByBoxId,
    /// `GET /api/v1/mempool/by-box-id/{id}`: the Rust node's own API.
    Native,
    /// The whole of `GET /transactions/unconfirmed`, read until two passes
    /// agree.
    WholeMempool,
}

/// Where a node answers "which pending transaction creates this box?". The
/// Rust node's own API has no lookup for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputRoute {
    /// `GET /transactions/unconfirmed/outputs/byBoxId/{id}` (Scala nodes).
    OutputsByBoxId,
    /// The whole of `GET /transactions/unconfirmed`, read until two passes
    /// agree.
    WholeMempool,
}

#[derive(Debug, Clone, Copy, Default)]
struct Routes {
    spends: Option<SpendRoute>,
    outputs: Option<OutputRoute>,
}

/// The routes each node answered on, by node URL.
fn learned() -> &'static Mutex<HashMap<String, Routes>> {
    static LEARNED: OnceLock<Mutex<HashMap<String, Routes>>> = OnceLock::new();
    LEARNED.get_or_init(Default::default)
}

/// Forget which routes the node at `node_url` answers mempool lookups on, so
/// the next lookup works them out again: for a node whose software changed
/// under the same address, and for tests that reuse a port.
#[doc(hidden)]
pub fn forget_mempool_routes(node_url: &str) {
    if let Ok(url) = reqwest::Url::parse(node_url) {
        recover(learned().lock()).remove(url.as_str());
    }
}

/// One route's answer about one box.
enum ById<T> {
    /// The node answered.
    Answer(T),
    /// The route is not served here, so nothing was learned about the box: a
    /// 404 without the node's not-found error (the Rust node, or a proxy), a
    /// 403 (a proxy shutting the path), 405 or 501, the Rust node's 409 for a
    /// mempool it cannot filter, or a success that is not the node's JSON.
    Unserved(String),
}

/// The node's own "no such box": 404 with its JSON error. An empty or
/// non-JSON 404 is a path nothing serves, and says nothing about the box.
fn is_not_found(status: u16, body: &str) -> bool {
    status == 404
        && serde_json::from_str::<serde_json::Value>(body).is_ok_and(|error| {
            error["error"].as_u64() == Some(404) && error["reason"].as_str() == Some("not-found")
        })
}

/// An error status from a by-id route: a route not served here, or a failure
/// that says nothing about the route, which fails the lookup.
fn unserved_or_failed<T>(status: u16, body: &str, what: &str) -> Result<ById<T>, String> {
    match status {
        403 | 404 | 405 | 501 => Ok(ById::Unserved(format!("{what}: {status}{}", excerpt(body)))),
        _ => Err(format!("{what} failed ({status}): {body}")),
    }
}

fn excerpt(body: &str) -> String {
    let body = body.trim();
    if body.is_empty() {
        " with no body".into()
    } else {
        format!(" {}", body.chars().take(120).collect::<String>())
    }
}

/// A success that is not the node's JSON, or JSON about another box.
fn read_box_answer<T>(
    status: u16,
    body: &str,
    box_id: &str,
    what: &str,
    found: impl FnOnce(serde_json::Value) -> T,
    absent: T,
) -> Result<ById<T>, String> {
    let Ok(answer) = serde_json::from_str::<serde_json::Value>(body.trim()) else {
        return Ok(ById::Unserved(format!("{what}: {status}{}", excerpt(body))));
    };
    if answer.is_null() {
        return Ok(ById::Answer(absent));
    }
    match answer["boxId"].as_str() {
        Some(id) if id.eq_ignore_ascii_case(box_id) => Ok(ById::Answer(found(answer))),
        _ => Err(format!("{what} for {box_id} answered about something else")),
    }
}

/// Every transaction in a whole-mempool read names its inputs and outputs by
/// box id; one that does not could hide the spend a lookup is asking about.
pub(super) fn check_listed(txs: &[serde_json::Value]) -> Result<(), String> {
    let named = |list: &serde_json::Value| {
        list.as_array()
            .is_some_and(|boxes| boxes.iter().all(|b| b["boxId"].is_string()))
    };
    match txs.iter().all(|tx| named(&tx["inputs"]) && named(&tx["outputs"])) {
        true => Ok(()),
        false => Err("Mempool listing has a transaction without its box ids".into()),
    }
}

fn spends_in(txs: &[serde_json::Value], box_id: &str) -> bool {
    crate::mempool::spent_box_ids(txs)
        .iter()
        .any(|id| id.eq_ignore_ascii_case(box_id))
}

fn created_in(txs: &[serde_json::Value], box_id: &str) -> Option<serde_json::Value> {
    txs.iter()
        .flat_map(|tx| tx["outputs"].as_array().into_iter().flatten())
        .find(|output| {
            output["boxId"]
                .as_str()
                .is_some_and(|id| id.eq_ignore_ascii_case(box_id))
        })
        .cloned()
}

impl ErgoNodeClient {
    fn routes_key(&self) -> String {
        self.inner.url.as_str().to_string()
    }

    fn routes(&self) -> Routes {
        recover(learned().lock())
            .get(&self.routes_key())
            .copied()
            .unwrap_or_default()
    }

    fn learn(&self, update: impl FnOnce(&mut Routes)) {
        update(recover(learned().lock()).entry(self.routes_key()).or_default());
    }

    /// The route this node answers spend lookups on, once worked out.
    pub fn spend_route(&self) -> Option<SpendRoute> {
        self.routes().spends
    }

    /// The route this node answers pending-output lookups on, once worked out.
    pub fn output_route(&self) -> Option<OutputRoute> {
        self.routes().outputs
    }

    async fn get_text(&self, endpoint: &str) -> Result<(u16, String), String> {
        let response = self
            .inner
            .send_get_req(endpoint)
            .await
            .map_err(|e| format!("Node request: {e}"))?;
        let status = response.status().as_u16();
        let text = response.text().await.map_err(|e| format!("Read: {e}"))?;
        Ok((status, text))
    }

    /// The node's whole mempool, read once per check (see
    /// [`Self::pending_complete`]).
    async fn whole_mempool<'a>(
        &self,
        whole: &'a mut Option<Vec<serde_json::Value>>,
    ) -> Result<&'a [serde_json::Value], String> {
        if whole.is_none() {
            *whole = Some(self.pending_complete(Pending::All).await?);
        }
        Ok(whole.as_deref().unwrap_or_default())
    }

    /// Whether a transaction in the node's mempool already spends `box_id`.
    ///
    /// The address reads find a pending spend of a *confirmed* box through
    /// the box's own script. A pending spend of an *unconfirmed* box is listed
    /// under the wallet only when it also pays the wallet, so a box forwarded
    /// whole to someone else is found here, by id, instead.
    ///
    /// Only the node's own answer counts (see the module notes): a node that
    /// answers on none of the routes is an error, never "not spent".
    pub async fn mempool_spends(&self, box_id: &str) -> Result<bool, String> {
        self.spend_lookup(box_id, &mut None).await
    }

    /// [`Self::mempool_spends`], reading the whole mempool into `whole` when
    /// it comes to that, or reusing the read already there.
    async fn spend_lookup(
        &self,
        box_id: &str,
        whole: &mut Option<Vec<serde_json::Value>>,
    ) -> Result<bool, String> {
        if let Some(route) = self.routes().spends {
            match self.spends_on(route, box_id, whole).await? {
                ById::Answer(spent) => return Ok(spent),
                ById::Unserved(why) => {
                    tracing::warn!("{} no longer answers on {route:?}: {why}", self.routes_key());
                    self.learn(|r| r.spends = None);
                }
            }
        }
        // In order. A failure stops here: it says nothing about which route
        // the node serves, so nothing is learned from it.
        let mut passed = Vec::new();
        for route in [SpendRoute::InputsByBoxId, SpendRoute::Native, SpendRoute::WholeMempool] {
            match self.spends_on(route, box_id, whole).await? {
                ById::Answer(spent) => {
                    self.learn(|r| r.spends = Some(route));
                    return Ok(spent);
                }
                ById::Unserved(why) => passed.push(why),
            }
        }
        Err(format!(
            "the node answers no lookup of pending spends: {}",
            passed.join("; ")
        ))
    }

    async fn spends_on(
        &self,
        route: SpendRoute,
        box_id: &str,
        whole: &mut Option<Vec<serde_json::Value>>,
    ) -> Result<ById<bool>, String> {
        match route {
            SpendRoute::InputsByBoxId => {
                let what = "Mempool input lookup";
                let (status, body) = self
                    .get_text(&format!("/transactions/unconfirmed/inputs/byBoxId/{box_id}"))
                    .await?;
                if is_not_found(status, &body) {
                    return Ok(ById::Answer(false));
                }
                if !(200..300).contains(&status) {
                    return unserved_or_failed(status, &body, what);
                }
                read_box_answer(status, &body, box_id, what, |_| true, false)
            }
            SpendRoute::Native => {
                let what = "Native mempool lookup";
                let (status, body) = self
                    .get_text(&format!(
                        "/api/v1/mempool/by-box-id/{}",
                        box_id.to_ascii_lowercase()
                    ))
                    .await?;
                match status {
                    // `{"items":[...spending transactions...],"page":{...}}`.
                    200 => {
                        let page = serde_json::from_str::<serde_json::Value>(&body).ok();
                        let Some(items) = page.as_ref().and_then(|p| p["items"].as_array()) else {
                            return Ok(ById::Unserved(format!("{what}: 200{}", excerpt(&body))));
                        };
                        if !items.is_empty() {
                            return Ok(ById::Answer(true));
                        }
                        // No spender on this page, yet more pages: not an
                        // answer to trust either way.
                        if page.is_some_and(|p| !p["page"]["next_cursor"].is_null()) {
                            return Err(format!(
                                "{what} for {box_id} came back empty with more to come"
                            ));
                        }
                        Ok(ById::Answer(false))
                    }
                    409 => Ok(ById::Unserved(format!(
                        "{what}: 409, mempool filtering is not wired on this node"
                    ))),
                    400 => Err(format!("{what} refused the box id {box_id}: {body}")),
                    _ => unserved_or_failed(status, &body, what),
                }
            }
            SpendRoute::WholeMempool => {
                let txs = self.whole_mempool(whole).await?;
                Ok(ById::Answer(spends_in(txs, box_id)))
            }
        }
    }

    /// The pending output `box_id`, as the node lists it, or `None` when no
    /// pending transaction creates it.
    async fn output_lookup(
        &self,
        box_id: &str,
        whole: &mut Option<Vec<serde_json::Value>>,
    ) -> Result<Option<serde_json::Value>, String> {
        if let Some(route) = self.routes().outputs {
            match self.outputs_on(route, box_id, whole).await? {
                ById::Answer(output) => return Ok(output),
                ById::Unserved(why) => {
                    tracing::warn!("{} no longer answers on {route:?}: {why}", self.routes_key());
                    self.learn(|r| r.outputs = None);
                }
            }
        }
        let mut passed = Vec::new();
        for route in [OutputRoute::OutputsByBoxId, OutputRoute::WholeMempool] {
            match self.outputs_on(route, box_id, whole).await? {
                ById::Answer(output) => {
                    self.learn(|r| r.outputs = Some(route));
                    return Ok(output);
                }
                ById::Unserved(why) => passed.push(why),
            }
        }
        Err(format!(
            "the node answers no lookup of pending outputs: {}",
            passed.join("; ")
        ))
    }

    async fn outputs_on(
        &self,
        route: OutputRoute,
        box_id: &str,
        whole: &mut Option<Vec<serde_json::Value>>,
    ) -> Result<ById<Option<serde_json::Value>>, String> {
        match route {
            OutputRoute::OutputsByBoxId => {
                let what = "Mempool output lookup";
                let (status, body) = self
                    .get_text(&format!("/transactions/unconfirmed/outputs/byBoxId/{box_id}"))
                    .await?;
                if is_not_found(status, &body) {
                    return Ok(ById::Answer(None));
                }
                if !(200..300).contains(&status) {
                    return unserved_or_failed(status, &body, what);
                }
                read_box_answer(status, &body, box_id, what, Some, None)
            }
            OutputRoute::WholeMempool => {
                let txs = self.whole_mempool(whole).await?;
                Ok(ById::Answer(created_in(txs, box_id)))
            }
        }
    }

    /// [`Self::mempool_spends`] for each of `ids`, at most `concurrency`
    /// lookups at a time. Only the first [`UNCONFIRMED_CHECKS`] ids (sorted)
    /// are looked up; the rest are absent from the answer, as is any lookup
    /// that could not run. On a node answered from its whole mempool, one
    /// read of it answers them all.
    pub async fn mempool_spends_each(
        &self,
        mut ids: Vec<String>,
        concurrency: usize,
    ) -> HashMap<String, Result<bool, String>> {
        ids.sort();
        ids.dedup();
        ids.truncate(UNCONFIRMED_CHECKS);
        let mut answers = HashMap::new();
        let Some((first, rest)) = ids.split_first() else {
            return answers;
        };
        // The first lookup works out the route if it is not known yet.
        let mut whole = None;
        let answer = self.spend_lookup(first, &mut whole).await;
        let failed = answer.as_ref().err().cloned();
        answers.insert(first.clone(), answer);
        match self.routes().spends {
            // No route answered: the rest would fail the same way.
            None => {
                let why = failed.unwrap_or_else(|| "no lookup of pending spends answered".into());
                for id in rest {
                    answers.insert(id.clone(), Err(why.clone()));
                }
            }
            Some(SpendRoute::WholeMempool) => {
                for id in rest {
                    let answer = self.spend_lookup(id, &mut whole).await;
                    answers.insert(id.clone(), answer);
                }
            }
            Some(_) => {
                for chunk in rest.chunks(concurrency.max(1)) {
                    let mut lookups = tokio::task::JoinSet::new();
                    for id in chunk {
                        let (client, id) = (self.clone(), id.clone());
                        lookups.spawn(async move {
                            let spent = client.mempool_spends(&id).await;
                            (id, spent)
                        });
                    }
                    while let Some(done) = lookups.join_next().await {
                        if let Ok((id, spent)) = done {
                            answers.insert(id, spent);
                        }
                    }
                }
            }
        }
        answers
    }

    /// Where `box_id` stands: spent by a pending transaction, in the confirmed
    /// UTXO set, created by a pending transaction (with the box, so its owner
    /// can be told), or none of these — spent in a block, or never existed.
    /// A route that does not answer is never read as "none of these".
    pub async fn box_status(&self, box_id: &str) -> Result<BoxStatus, String> {
        let mut whole = None;
        if self.spend_lookup(box_id, &mut whole).await? {
            return Ok(BoxStatus::SpentInMempool);
        }
        let what = "UTXO lookup";
        let (status, body) = self.get_text(&format!("/utxo/byId/{box_id}")).await?;
        if !is_not_found(status, &body) {
            if !(200..300).contains(&status) {
                return Err(format!("{what} failed ({status}): {}", body.trim()));
            }
            return match read_box_answer(status, &body, box_id, what, |_| true, false)? {
                ById::Answer(true) => Ok(BoxStatus::Confirmed),
                _ => Err(format!("{what} for {box_id} gave no box: {}", body.trim())),
            };
        }
        Ok(match self.output_lookup(box_id, &mut whole).await? {
            Some(output) => BoxStatus::Unconfirmed(output),
            None => BoxStatus::Unknown,
        })
    }
}
