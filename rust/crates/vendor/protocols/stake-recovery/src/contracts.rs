//! The deployed v1 pools. Addresses are the source of every contract tree.
//!
//! Full trees bind a box to its pool; templates deliberately omit pool constants.

use crate::error::RecoveryError;
use ergotree_ir::{ergo_tree::ErgoTree, serialization::SigmaSerializable};

/// The pool whose assets and scripts must agree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pool {
    Ergopad,
    Paideia,
    Egio,
}

/// How the key authorizes a full unstake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mechanism {
    Direct,
    PaideiaProxy,
}

/// Published addresses and asset ids for one pool.
#[derive(Debug)]
pub struct PoolContracts {
    pub pool: Pool,
    pub name: &'static str,
    pub active: bool,
    pub mechanism: Mechanism,
    pub stake_address: &'static str,
    pub state_address: &'static str,
    pub state_nft: &'static str,
    pub stake_token: &'static str,
    pub reward_token: &'static str,
    pub reward_decimals: u32,
}

impl Pool {
    pub fn contracts(self) -> &'static PoolContracts {
        match self {
            Self::Ergopad => &ERGOPAD,
            Self::Paideia => &PAIDEIA,
            Self::Egio => &EGIO,
        }
    }
}

impl PoolContracts {
    pub fn stake_tree(&self) -> Result<ErgoTree, RecoveryError> {
        tree_from_address(self.stake_address)
    }
    pub fn state_tree(&self) -> Result<ErgoTree, RecoveryError> {
        tree_from_address(self.state_address)
    }
}

/// Decode the address, then require a fully parsed, canonically serialized script.
pub fn tree_from_address(address: &str) -> Result<ErgoTree, RecoveryError> {
    let hex = ergo_tx::address_to_ergo_tree(address)
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    parse_tree(&hex::decode(hex).map_err(|e| RecoveryError::Serialization(e.to_string()))?)
}

pub(crate) fn parse_tree(bytes: &[u8]) -> Result<ErgoTree, RecoveryError> {
    let tree = ErgoTree::sigma_parse_bytes(bytes)
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    tree.proposition()
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    if tree
        .sigma_serialize_bytes()
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?
        != bytes
    {
        return Err(RecoveryError::Serialization(
            "noncanonical or trailing tree bytes".into(),
        ));
    }
    Ok(tree)
}

/// The Ergopad v1 pool.
pub static ERGOPAD: PoolContracts = PoolContracts {
    pool: Pool::Ergopad,
    active: true,
    mechanism: Mechanism::Direct,
    name: "Ergopad",
    stake_address: "3eiC8caSy3jiCxCmdsiFNFJ1Ykppmsmff2TEpSsXY1Ha7xbpB923Uv2midKVVkxL3CzGbSS2QURhbHMzP9b9rQUKapP1wpUQYPpH8UebbqVFHJYrSwM3zaNEkBkM9RjjPxHCeHtTnmoun7wzjajrikVFZiWurGTPqNnd1prXnASYh7fd9E2Limc2Zeux4UxjPsLc1i3F9gSjMeSJGZv3SNxrtV14dgPGB9mY1YdziKaaqDVV2Lgq3BJC9eH8a3kqu7kmDygFomy3DiM2hYkippsoAW6bYXL73JMx1tgr462C4d2PE7t83QmNMPzQrD826NZWM2c1kehWB6Y1twd5F9JzEs4Lmd2qJhjQgGg4yyaEG9irTC79pBeGUj98frZv1Aaj6xDmZvM22RtGX5eDBBu2C8GgJw3pUYr3fQuGZj7HKPXFVuk3pSTQRqkWtJvnpc4rfiPYYNpM5wkx6CPenQ39vsdeEi36mDL8Eww6XvyN4cQxzJFcSymATDbQZ1z8yqYSQeeDKF6qCM7ddPr5g5fUzcApepqFrGNg7MqGAs1euvLGHhRk7UoeEpofFfwp3Km5FABdzAsdFR9",
    state_address: "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",
    state_nft: "05cde13424a7972fbcd0b43fccbb5e501b1f75302175178fc86d8f243f3f3125",
    stake_token: "1028de73d018f0c9a374b71555c5b8f1390994f2f41633e7b9d68f77735782ee",
    reward_token: "d71693c49a84fbbecd4908c94813b46514b18b67a99952dc1e6e4791556de413",
    reward_decimals: 2,
};

/// The Paideia v1 pool.
pub static PAIDEIA: PoolContracts = PoolContracts {
    pool: Pool::Paideia,
    active: true,
    mechanism: Mechanism::PaideiaProxy,
    name: "Paideia",
    stake_address: "BxjSQHD1hqQFUXbXatkn46YUxM6wVsLkT5HNXJe1N1n3dM2c7X8BtgnLqszJuxoRTnzXzrCrmEjPyLxqstcnW7YkQJ9m7QTmhChBYt1hAFcTWiyVMdaiYYFtxr7qfXKcjsadtfusNhS63ZddciC3wogjrfSE3U2Fy9dhrrKStUVzWhTP22ZuwdDPv8F88WVtdLsu24bbHsv2ntXZJGhvdKnvJL83kJWs9XV582sqUBqX7kL2A5qp6T2Jxgt3gLxcZ99JhUG99YtRsmpuwb94TE5KVTESWA6cD8EdReTbP1kwW77rnJyNfj8KUsy1j7AZuNBUsVBc3oLV4GxYFDvaTNEyNBmGY3dEe8k7UKjUSnqCmYH2QM2cmhtPEdT6UBR9sS4h4YFiGsRHiybjuTSaBUPrzhJ12ESKf8jcaNna9rYprzm8ZnfwNEQFtPJyKfCoJjbwkfsAEirsMcyU3VjPAvKJ2mtu7A3WwXViBSfwUgdCnWkEhdPCRPueAXfN38JXG8HjJeZTPi3VtgcnFobg8Zjp1XtRkTaoj6i4BgyfwCft3sCYgBgmNjXhtFuuozpCiAXWyGMMs5rhJL6FzXsJWiTSML96LdshFnhoPRPi8FXVooURKztnqJowFcpLApL2ou2jfeC4iaxKgtd6zDR6ikFVXMsipVHmBrhan9dheUPnfjeXz9WVPmGLmVkrxnVv",
    state_address: "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",
    state_nft: "b682ad9e8c56c5a0ba7fe2d3d9b2fbd40af989e8870628f4a03ae1022d36f091",
    stake_token: "245957934c20285ada547aa8f2c8e6f7637be86a1985b3e4c36e4e1ad8ce97ab",
    reward_token: "1fd6e032e8476c4aa54c18c1a308dce83940e8f4a28f576440513ed7326ad489",
    reward_decimals: 4,
};

/// The Egio v1 pool.
pub static EGIO: PoolContracts = PoolContracts {
    pool: Pool::Egio,
    active: false,
    mechanism: Mechanism::Direct,
    name: "EGIO",
    stake_address: "3eiC8caSy3jixP2iRTiYygUaYjRXXa45eva19FqeMD24Tykh17yux6MqT4t7FB2kHtFethYZjKhpBQyqSsUWdRWtwz1a8KMNnmEykv5JmT3sA6V6ZNfAtzdV8acRoBXhteVQ8nDMywZ8FvcBVbw6yBvXpcDjXRHzgbb35YHi51xJ9ZooaAmLHqBCJhXVMM1enpUYRxNPXdVZgeGnygmLq6k9LRS7Sp2MKciicyqbWpW8wVnzewmoEkvteCeAHErHkBagdLsYbs9dgBAktqAgwTvTRhLMkC42eWHnenAaFNih4GpReq9tz9AMhDJYWd2n7WVCDnVkDT6CXe8d83jSFkMaoiFoBLGqy5M68jMjUNS2yHuLo1GnyMjukB3y5N1vbyjUFstVPgHCs99e8LGE2QUE5YbX1LBQz934XvZo1heTXVfevmm9bZWBiruiwH7kCcv81tRE2Y22nk6EDMWdyYUYchjK31KqcMRrF2hdWFtocAL3bz3Pniz4zjnrFQQcWMsVypZRzqdWAdKpVjZswP4k4VyBJAerHniekyBQ5FMhtN3kNWUKHXYkhmqSmaiEx2Uw4JiK9KnXapT",
    state_address: "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",
    state_nft: "f419099a27aaa5f6f7d109d8773b1862e8d1857b44aa7d86395940d41eb53806",
    stake_token: "1431964fa6559e969a7bf047405d3f63f7592354d432556f79894a12c4286e81",
    reward_token: "00b1e236b60b95c2c6f8007a9d89bc460fc9e78f98b09faec9449007b40bccf3",
    reward_decimals: 4,
};

/// Single-use Paideia unstake request, including its independent refund branch.
pub const PAIDEIA_PROXY_ADDRESS: &str = "X2skqamNVYtSWVCEm71besi23onPaFEiDYNXnCVn85yZNzNND1o3bjZ6sptnXq2Bg8LW5pbRDPsStpc6r6uFSnxPdh2n5iddkcFVCvz9cMWaMfieTbTyhcoHibxRwTyiw3X8JWGHNZiLNCPiPko3vEthE2Wrq7wZ2utPRngyrZd9SC7gFxKU5p1iSfrfLa4ZJs2hCegzsXSK8uya2MNPyb1DV673horY4k4tynWfkZNViieJhDy8buLTNBFEU1sXFc89FGWmKz4twMiq7acJtytr1bYZA6GHuQAkJC9SLrbxMnrGueyfxYyVEeyeHBvojigudXz5upeEPQyLngcXSVqRJ2BX1ckMbEU7jnc2V2ePvHRxR5MzN2u7r9hR6se1VwyKq8E1deu8BRszHZMkGiujpqu9Up398jq8GKbSXoo4vay8w6ZqnUwttuc5CJ5AoY3hhPf5NgUjVENLjXurFMkmYNZTcVdVvTw5R6h4GTKsLdk8rrGAAPT";
/// Destination committed to by the proxy's incentive hash.
pub const PAIDEIA_INCENTIVE_ADDRESS: &str = "Ujfv3QVGdnTjkkugQDB5qFowFpiq2uK32aa7efP7ptAA4dAsAamzWS1NS4kWKExYR2N781Cgi49dLmerGrH6hQZXg6xgxkyJRKJgPgq3MKrSjxECyPVtSyqmivuV5TDbsoNGQfA9yb4FLjtX9ovdYGZxz8TcESePcBHdTpUeXYRqsbkQkhNNDuF3HfWKmLFbTQTKUti4rFT4zKLKaoCr1Hq4AfEu91i5yTmxvZ14iyGkwduKrA2M54ynk5bryZqU7QiJJ1eQe4CPY8wnTgWUPniNDMzjUQLxrYZjSjJX1L8W7cVdWoMGqVdDuWv1APZokHypm2qtfoC4yFf8QWj9Phdnh3fzbUuQyk9nphXMnGKaNN6byTsZW63a1DZESwPQkY5hhhuYJuTYoGy9Gf2bdxfEgcXvppTnc4yi2AB2wo8XXsUtmH6L39nfrTfWtqiSuCZutvARjbahAjR9riZ6Xcb8JnpdUgz7ZmoRa2bwEj7pnMEd6HGdZRwDGCQn5Ezt1ZS5QEFqfTkfvz4wyiDUvDjM9knYSs2KGVim7CFvQdWtLPuiY8nkTmrrWgTyChAzFjexeYP5V9EaLDbkRRbSRinoAb9VfL9KCkSMNyA55fNkFnmzf94nF2HHfJNGvKvc2hHL73h5ERWoZ139jBH94ZFs99QnYA8zVqohtk8JYxVZfLg6KdR67DVHguNCtMwy98pdxdiHr6McFMZB7Br6RSQmnXa73bCdKZKydxxnf1vTo2MtkMRuq4QgNYgVLJxhdTL6QpR763jTpbjnVWWqe5PDQ7ghDfYC1AnqQvR7AwpVUj47ut4McE7iSUHruUxNr8jHKBUSv5xTNbqhQhGuhwgfte8otdaG8aYE8ezEHXoNiB1cbcAbuDyTjRAmmXqUw8rBxf3twUi7HqnZPGgoaTf4Qjx2nSonyQsRHJFUp2yE3donK9seHPGAHyjfG2FTCHJneEHNY2BTi4bf7E7Yw";

/// Values pinned by the full-unstake branch, in nanoERG.
pub const INCENTIVE_VALUE: i64 = 100_000_000;
pub const EXECUTOR_VALUE: i64 = 2_000_000;
pub const EXECUTION_FEE: i64 = 2_000_000;
/// The refund branch subtracts this from the proxy's value.
pub const REFUND_FEE: i64 = 1_000_000;
/// Funding used by the historical proxy; this is not an exact-value script constraint.
pub const PROXY_VALUE: i64 = 113_000_000;
/// Minimum value Argus uses for protocol outputs.
pub const MIN_BOX_VALUE: i64 = 1_000_000;

/// Check the actual constant the proxy compares with the incentive script hash.
pub fn verify_incentive_commitment() -> Result<(), RecoveryError> {
    use ergotree_ir::mir::constant::TryExtractInto;
    let proxy = tree_from_address(PAIDEIA_PROXY_ADDRESS)?;
    let commitment = proxy
        .get_constant(15)
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?
        .ok_or_else(|| RecoveryError::Invalid("missing incentive commitment".into()))?
        .try_extract_into::<Vec<u8>>()
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    let incentive = tree_from_address(PAIDEIA_INCENTIVE_ADDRESS)?;
    let bytes = incentive
        .sigma_serialize_bytes()
        .map_err(|e| RecoveryError::Serialization(e.to_string()))?;
    if commitment != ergo_chain_types::blake2b256_hash(&bytes).0 {
        return Err(RecoveryError::Invalid(
            "incentive hash does not match proxy commitment".into(),
        ));
    }
    Ok(())
}
