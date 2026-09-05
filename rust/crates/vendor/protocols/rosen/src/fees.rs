//! The minimum-fee box: per token, the bridge keeps one box carrying
//! the fee NFT (and the token, for tokens) whose registers hold a
//! history of fee configurations keyed by the source chain's height.
//!
//! R4 the chains, R5 per configuration the height each chain's entry
//! takes effect at (`-1` when absent), R6 the minimum bridge fees, R7 the
//! network fees, R8 the RSN ratios as `(ratio, divisor)` pairs, R9 the
//! bridge fee ratios out of 10 000. The configuration in force is the
//! last one whose height for the source chain is below the current one.

use ergo_lib::ergotree_ir::mir::constant::{Constant, TryExtractInto};
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;

use crate::{ERGO_CHAIN, MIN_FEE_NFT};

/// `feeRatio` is out of this.
pub const FEE_RATIO_DIVISOR: i128 = 10_000;

#[derive(Debug, thiserror::Error)]
pub enum FeesError {
    #[error("serialization error: {0}")]
    Serialization(String),
    #[error("not the minimum-fee box for this token")]
    NotFeeBox,
    #[error("the fee box has no entry for chain {0}")]
    NoChain(String),
    #[error("no fee configuration covers height {0}")]
    NoHeight(i64),
    #[error("{0} is not a target of this token at this height")]
    NoTarget(String),
}

fn err(m: impl Into<String>) -> FeesError {
    FeesError::Serialization(m.into())
}

/// The terms for one target chain.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ChainFee {
    /// The least the bridge charges, in the token's units.
    pub bridge_fee: i64,
    /// What the target network's payout costs, in the token's units.
    pub network_fee: i64,
    /// The bridge's cut of the amount, out of 10 000; the bridge fee is
    /// the larger of this and `bridge_fee`.
    pub fee_ratio: i64,
    pub rsn_ratio: i64,
    pub rsn_ratio_divisor: i64,
}

/// The whole box, read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeeConfig {
    pub box_id: String,
    pub chains: Vec<String>,
    /// Per configuration, per chain: the height it takes effect, or -1.
    pub heights: Vec<Vec<i64>>,
    pub bridge_fees: Vec<Vec<i64>>,
    pub network_fees: Vec<Vec<i64>>,
    pub rsn_ratios: Vec<Vec<Vec<i64>>>,
    pub fee_ratios: Vec<Vec<i64>>,
}

fn register_hex<'a>(v: &'a serde_json::Value, name: &str) -> Option<&'a str> {
    let r = v.get("additionalRegisters")?.get(name)?;
    r.as_str()
        .or_else(|| r.get("serializedValue").and_then(|s| s.as_str()))
}

fn constant(v: &serde_json::Value, name: &str) -> Result<Constant, FeesError> {
    let h = register_hex(v, name).ok_or_else(|| err(format!("fee box has no {name}")))?;
    let bytes = hex::decode(h).map_err(|e| err(format!("{name}: {e}")))?;
    Constant::sigma_parse_bytes(&bytes).map_err(|e| err(format!("{name}: {e}")))
}

fn assets(v: &serde_json::Value) -> Vec<(String, i64)> {
    v.get("assets")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|t| {
                    Some((
                        t.get("tokenId")?.as_str()?.to_ascii_lowercase(),
                        t.get("amount").and_then(|x| x.as_i64())?,
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

impl FeeConfig {
    /// Whether `v` is the fee box for `token_id` (`erg` for ERG): the fee
    /// NFT and, for a token, that token, and nothing else.
    pub fn is_for(v: &serde_json::Value, token_id: &str) -> bool {
        let a = assets(v);
        let has_nft = a.iter().any(|(id, _)| id == MIN_FEE_NFT);
        if token_id.eq_ignore_ascii_case("erg") {
            has_nft && a.len() == 1
        } else {
            has_nft && a.len() == 2 && a.iter().any(|(id, _)| id.eq_ignore_ascii_case(token_id))
        }
    }

    pub fn parse(v: &serde_json::Value, token_id: &str) -> Result<Self, FeesError> {
        if !Self::is_for(v, token_id) {
            return Err(FeesError::NotFeeBox);
        }
        let chains: Vec<String> = constant(v, "R4")?
            .try_extract_into::<Vec<Vec<u8>>>()
            .map_err(|e| err(format!("R4: {e:?}")))?
            .into_iter()
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .collect();
        let heights: Vec<Vec<i64>> = constant(v, "R5")?
            .try_extract_into::<Vec<Vec<i32>>>()
            .map_err(|e| err(format!("R5: {e:?}")))?
            .into_iter()
            .map(|row| row.into_iter().map(i64::from).collect())
            .collect();
        let longs2 = |name: &str| -> Result<Vec<Vec<i64>>, FeesError> {
            constant(v, name)?
                .try_extract_into::<Vec<Vec<i64>>>()
                .map_err(|e| err(format!("{name}: {e:?}")))
        };
        let bridge_fees = longs2("R6")?;
        let network_fees = longs2("R7")?;
        let rsn_ratios: Vec<Vec<Vec<i64>>> = constant(v, "R8")?
            .try_extract_into::<Vec<Vec<Vec<i64>>>>()
            .map_err(|e| err(format!("R8: {e:?}")))?;
        let fee_ratios = longs2("R9")?;
        let n = heights.len();
        if bridge_fees.len() != n || network_fees.len() != n || rsn_ratios.len() != n || fee_ratios.len() != n {
            return Err(err("fee box registers disagree on the number of configurations"));
        }
        Ok(Self {
            box_id: v
                .get("boxId")
                .and_then(|x| x.as_str())
                .unwrap_or_default()
                .to_string(),
            chains,
            heights,
            bridge_fees,
            network_fees,
            rsn_ratios,
            fee_ratios,
        })
    }

    /// The terms for sending from `from_chain` at `height` to `to_chain`,
    /// as the bridge looks them up: the newest configuration whose height
    /// for the source chain is below `height`.
    pub fn fee_for(&self, from_chain: &str, height: i64, to_chain: &str) -> Result<ChainFee, FeesError> {
        let from = self
            .chains
            .iter()
            .position(|c| c == from_chain)
            .ok_or_else(|| FeesError::NoChain(from_chain.into()))?;
        let to = self
            .chains
            .iter()
            .position(|c| c == to_chain)
            .ok_or_else(|| FeesError::NoChain(to_chain.into()))?;
        for i in (0..self.heights.len()).rev() {
            let from_height = self.heights[i].get(from).copied().unwrap_or(-1);
            if from_height == -1 {
                return Err(FeesError::NoChain(from_chain.into()));
            }
            if from_height < height {
                let bridge_fee = self.bridge_fees[i].get(to).copied().unwrap_or(-1);
                if bridge_fee == -1 {
                    return Err(FeesError::NoTarget(to_chain.into()));
                }
                return Ok(ChainFee {
                    bridge_fee,
                    network_fee: self.network_fees[i][to],
                    fee_ratio: self.fee_ratios[i][to],
                    rsn_ratio: self.rsn_ratios[i][to].first().copied().unwrap_or(0),
                    rsn_ratio_divisor: self.rsn_ratios[i][to].get(1).copied().unwrap_or(1),
                });
            }
        }
        Err(FeesError::NoHeight(height))
    }

    /// The terms for leaving Ergo now.
    pub fn from_ergo(&self, height: i64, to_chain: &str) -> Result<ChainFee, FeesError> {
        self.fee_for(ERGO_CHAIN, height, to_chain)
    }
}

/// What a transfer of `amount` costs and delivers.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct FeeQuote {
    pub amount: i64,
    /// The larger of the minimum bridge fee and the ratio of the amount.
    pub bridge_fee: i64,
    pub network_fee: i64,
    /// What arrives on the other chain, in the token's units.
    pub receiving: i64,
    /// The least amount that delivers anything.
    pub min_transfer: i64,
}

impl ChainFee {
    pub fn quote(&self, amount: i64) -> FeeQuote {
        let variable = (i128::from(amount) * i128::from(self.fee_ratio) / FEE_RATIO_DIVISOR) as i64;
        let bridge_fee = self.bridge_fee.max(variable);
        let min_transfer = self.bridge_fee + self.network_fee + 1;
        FeeQuote {
            amount,
            bridge_fee,
            network_fee: self.network_fee,
            receiving: (amount - bridge_fee - self.network_fee).max(0),
            min_transfer,
        }
    }
}

/// The fee box for `token_id` among `boxes` (any shape), read.
pub fn find_fee_box(boxes: &[serde_json::Value], token_id: &str) -> Result<FeeConfig, FeesError> {
    let mut found: Vec<&serde_json::Value> = boxes.iter().filter(|b| FeeConfig::is_for(b, token_id)).collect();
    match found.len() {
        0 => Err(FeesError::NotFeeBox),
        1 => FeeConfig::parse(found.remove(0), token_id),
        n => Err(err(format!("{n} fee boxes for one token; the bridge keeps one"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> serde_json::Value {
        serde_json::from_str(match name {
            "sigusd" => include_str!("../test/fixtures/minfee_sigusd.json"),
            "rsada" => include_str!("../test/fixtures/minfee_rsada.json"),
            "erg" => include_str!("../test/fixtures/minfee_erg.json"),
            _ => panic!("{name}"),
        })
        .unwrap()
    }

    const SIGUSD: &str = "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04";

    #[test]
    fn the_live_sigusd_fee_box_reads_and_prices_a_transfer_to_cardano() {
        let cfg = FeeConfig::parse(&fixture("sigusd"), SIGUSD).unwrap();
        assert!(cfg.chains.contains(&"cardano".to_string()) && cfg.chains.contains(&"ergo".to_string()), "{:?}", cfg.chains);
        assert_eq!(cfg.heights.len(), cfg.bridge_fees.len());
        let fee = cfg.from_ergo(1_866_700, "cardano").unwrap();
        assert!(fee.bridge_fee > 0 && fee.network_fee > 0, "{fee:?}");
        assert!(fee.fee_ratio > 0 && fee.fee_ratio < 1000, "{fee:?}");
        // 1,000 SigUSD: the ratio beats the minimum; a tiny amount does not.
        let q = fee.quote(100_000);
        assert_eq!(q.bridge_fee, (100_000i64 * fee.fee_ratio / 10_000).max(fee.bridge_fee));
        assert_eq!(q.receiving, 100_000 - q.bridge_fee - fee.network_fee);
        assert_eq!(q.min_transfer, fee.bridge_fee + fee.network_fee + 1);
        let small = fee.quote(10);
        assert_eq!(small.bridge_fee, fee.bridge_fee);
        assert_eq!(small.receiving, 0);
        // A height before every configuration has no terms.
        assert!(matches!(cfg.from_ergo(1, "cardano"), Err(FeesError::NoHeight(_))));
        assert!(matches!(cfg.from_ergo(1_866_700, "mars"), Err(FeesError::NoChain(_))));
    }

    #[test]
    fn erg_and_rsada_have_their_own_boxes_and_the_finder_is_strict() {
        let erg = FeeConfig::parse(&fixture("erg"), "erg").unwrap();
        assert!(erg.from_ergo(1_866_700, "cardano").unwrap().network_fee > 0);
        assert!(FeeConfig::parse(&fixture("erg"), SIGUSD).is_err(), "the ERG box is not SigUSD's");
        let rsada = "e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297";
        let ada = FeeConfig::parse(&fixture("rsada"), rsada).unwrap();
        assert!(ada.from_ergo(1_866_700, "cardano").unwrap().bridge_fee > 0);
        let all = vec![fixture("erg"), fixture("sigusd"), fixture("rsada")];
        assert_eq!(find_fee_box(&all, SIGUSD).unwrap().box_id, fixture("sigusd")["boxId"]);
        assert!(find_fee_box(&all, "ff").is_err());
        assert!(find_fee_box(&[fixture("sigusd"), fixture("sigusd")], SIGUSD).is_err(), "two boxes is a fault");
    }
}
