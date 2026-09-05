//! Rosen's tokens map: for each bridged asset, its identity on every
//! chain it exists on. Vendored from the contracts release; the bridge
//! publishes a new one when tokens are added.

use std::collections::BTreeSet;

use serde::Deserialize;

const TOKENS_MAP: &str = include_str!("../assets/tokens_map.json");

#[derive(Debug, Clone, Deserialize)]
struct RawToken {
    #[serde(rename = "tokenId")]
    token_id: String,
    name: String,
    decimals: u8,
    #[serde(default)]
    residency: String,
}

#[derive(Debug, Deserialize)]
struct RawMap {
    version: String,
    tokens: Vec<std::collections::BTreeMap<String, RawToken>>,
}

/// An asset on a target chain.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct BridgeTarget {
    pub chain: &'static str,
    pub token_id: String,
    pub name: String,
    pub decimals: u8,
}

/// An Ergo asset the bridge takes, and where it can go.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct BridgedToken {
    /// The Ergo token id, or `erg` for ERG itself.
    pub ergo_token_id: String,
    pub name: String,
    pub decimals: u8,
    /// `native` when the asset is born on Ergo, `wrapped` when it is
    /// another chain's asset represented here.
    pub residency: String,
    pub targets: Vec<BridgeTarget>,
}

fn intern(chain: &str) -> &'static str {
    match chain {
        "ergo" => "ergo",
        "cardano" => "cardano",
        "bitcoin" => "bitcoin",
        "bitcoin-runes" => "bitcoin-runes",
        "ethereum" => "ethereum",
        "binance" => "binance",
        "base" => "base",
        "doge" => "doge",
        "firo" => "firo",
        _ => "unknown",
    }
}

/// Every bridged token, in the map's order, with its targets.
pub fn token_map() -> Vec<BridgedToken> {
    let raw: RawMap = serde_json::from_str(TOKENS_MAP).expect("vendored tokens map parses");
    let mut out = Vec::new();
    for entry in raw.tokens {
        let Some(ergo) = entry.get("ergo") else { continue };
        let targets = entry
            .iter()
            .filter(|(chain, _)| chain.as_str() != "ergo" && intern(chain) != "unknown")
            .map(|(chain, t)| BridgeTarget {
                chain: intern(chain),
                token_id: t.token_id.clone(),
                name: t.name.clone(),
                decimals: t.decimals,
            })
            .collect();
        out.push(BridgedToken {
            ergo_token_id: ergo.token_id.clone(),
            name: ergo.name.clone(),
            decimals: ergo.decimals,
            residency: ergo.residency.clone(),
            targets,
        });
    }
    out
}

/// The map's version string.
pub fn map_version() -> String {
    serde_json::from_str::<RawMap>(TOKENS_MAP).map(|m| m.version).unwrap_or_default()
}

/// Where an Ergo asset can go, or none when the bridge does not take it.
pub fn bridgeable(ergo_token_id: &str) -> Option<BridgedToken> {
    token_map()
        .into_iter()
        .find(|t| t.ergo_token_id.eq_ignore_ascii_case(ergo_token_id))
}

/// Every target chain any token can go to.
pub fn chains() -> Vec<&'static str> {
    let set: BTreeSet<&'static str> = token_map()
        .iter()
        .flat_map(|t| t.targets.iter().map(|x| x.chain))
        .collect();
    set.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_map_lists_erg_and_the_stablecoins_with_their_targets() {
        let map = token_map();
        assert!(map.len() > 50, "{}", map.len());
        let erg = bridgeable("erg").unwrap();
        assert_eq!(erg.decimals, 9);
        assert!(erg.targets.iter().any(|t| t.chain == "cardano" && t.name == "rsERG"));
        let sigusd = bridgeable("03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04").unwrap();
        assert_eq!(sigusd.name, "SigUSD");
        assert!(sigusd.targets.iter().any(|t| t.chain == "cardano"));
        let rsada = bridgeable("e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297").unwrap();
        assert_eq!(rsada.residency, "wrapped");
        assert_eq!(rsada.targets.iter().find(|t| t.chain == "cardano").unwrap().token_id, "ada");
        assert!(bridgeable("ff").is_none());
        assert!(chains().contains(&"cardano") && chains().contains(&"bitcoin"));
        assert_eq!(map_version(), "7.1.0");
    }
}
