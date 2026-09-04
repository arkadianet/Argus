//! Local lightweight database and state tracking for Argus wallet.
//!
//! Stores derived addresses, unspent boxes (UTXOs), transaction history,
//! sync checkpoints, and tracked DeFi/contract lineages (singleton tokens).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::error::CoreError;

/// An address derived by the wallet.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AddressRecord {
    pub index: u32,
    pub address: String,
    pub is_used: bool,
    pub balance_nano_erg: u64,
}

/// A token held in an unspent box.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredToken {
    pub id: String,
    pub amount: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default)]
    pub decimals: u32,
}

/// An unspent box (UTXO) cached locally.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredBox {
    pub box_id: String,
    pub address: String,
    pub ergo_tree: String,
    pub value_nano_erg: u64,
    #[serde(default)]
    pub tokens: Vec<StoredToken>,
    pub creation_height: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spent_tx_id: Option<String>,
    #[serde(default = "default_true")]
    pub is_unspent: bool,
}

fn default_true() -> bool {
    true
}

/// A cached transaction summary.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredTx {
    pub tx_id: String,
    pub height: u64,
    pub timestamp: u64,
    pub value_nano_erg: i64,
    #[serde(default)]
    pub token_ids: Vec<String>,
    #[serde(default)]
    pub address: String,
}

/// A tracked singleton/NFT contract lineage for DeFi state (e.g. Spectrum pools, SigmaUSD bank).
///
/// Follows state chains by following `spentTransactionId` -> output box with `singleton_token_id`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TrackedLineage {
    pub singleton_token_id: String,
    pub protocol_name: String,
    pub root_box_id: String,
    pub current_box_id: String,
    pub last_updated_height: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub box_json: Option<String>,
}

/// Checkpoint tracking sync progress against node height.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SyncCheckpoint {
    pub last_synced_height: u64,
    pub last_sync_timestamp: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub block_id: Option<String>,
}

/// Complete in-memory/serializable local database state.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct WalletDatabase {
    pub addresses: Vec<AddressRecord>,
    pub boxes: Vec<StoredBox>,
    pub transactions: Vec<StoredTx>,
    pub lineages: HashMap<String, TrackedLineage>,
    pub sync: SyncCheckpoint,
}

impl WalletDatabase {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_json(json_str: &str) -> Result<Self, CoreError> {
        serde_json::from_str(json_str).map_err(|e| CoreError::Serialization(e.to_string()))
    }

    pub fn to_json(&self) -> Result<String, CoreError> {
        serde_json::to_string(self).map_err(|e| CoreError::Serialization(e.to_string()))
    }

    /// Record or update a derived address.
    pub fn upsert_address(&mut self, record: AddressRecord) {
        if let Some(existing) = self.addresses.iter_mut().find(|a| a.index == record.index) {
            *existing = record;
        } else {
            self.addresses.push(record);
            self.addresses.sort_by_key(|a| a.index);
        }
    }

    pub fn get_address_0(&self) -> Option<&AddressRecord> {
        self.addresses.iter().find(|a| a.index == 0)
    }

    pub fn get_used_addresses(&self) -> Vec<&AddressRecord> {
        self.addresses.iter().filter(|a| a.is_used).collect()
    }

    /// Upsert unspent boxes, updating existing ones.
    pub fn upsert_boxes(&mut self, new_boxes: Vec<StoredBox>) {
        let mut map: HashMap<String, StoredBox> = self
            .boxes
            .drain(..)
            .map(|b| (b.box_id.clone(), b))
            .collect();
        for b in new_boxes {
            map.insert(b.box_id.clone(), b);
        }
        let mut list: Vec<StoredBox> = map.into_values().collect();
        list.sort_by(|a, b| a.box_id.cmp(&b.box_id));
        self.boxes = list;
    }

    /// Mark a box as spent by a given transaction ID.
    pub fn mark_box_spent(&mut self, box_id: &str, spent_tx_id: &str) {
        if let Some(b) = self.boxes.iter_mut().find(|b| b.box_id == box_id) {
            b.spent_tx_id = Some(spent_tx_id.to_string());
            b.is_unspent = false;
        }
    }

    /// Return all active unspent boxes.
    pub fn get_unspent_boxes(&self) -> Vec<&StoredBox> {
        self.boxes
            .iter()
            .filter(|b| b.is_unspent && b.spent_tx_id.is_none())
            .collect()
    }

    /// Calculate total nanoERG and token balances from unspent boxes.
    pub fn get_total_balances(&self) -> Result<(u64, Vec<StoredToken>), CoreError> {
        let unspent = self.get_unspent_boxes();
        let mut total_erg = 0u64;
        for b in &unspent {
            total_erg = total_erg
                .checked_add(b.value_nano_erg)
                .ok_or_else(|| CoreError::Overflow("Total ERG amount overflow".into()))?;
        }

        let mut tokens_map: HashMap<String, (u64, Option<String>, u32)> = HashMap::new();
        for b in unspent {
            for t in &b.tokens {
                let entry =
                    tokens_map
                        .entry(t.id.clone())
                        .or_insert((0, t.name.clone(), t.decimals));
                entry.0 = entry.0.checked_add(t.amount).ok_or_else(|| {
                    CoreError::Overflow(format!("Token {} amount overflow", t.id))
                })?;
                if entry.1.is_none() && t.name.is_some() {
                    entry.1 = t.name.clone();
                }
            }
        }

        let mut tokens: Vec<StoredToken> = tokens_map
            .into_iter()
            .map(|(id, (amount, name, decimals))| StoredToken {
                id,
                amount,
                name,
                decimals,
            })
            .collect();

        tokens.sort_by(|a, b| a.id.cmp(&b.id));

        Ok((total_erg, tokens))
    }

    /// Upsert transactions.
    pub fn upsert_transactions(&mut self, txs: Vec<StoredTx>) {
        let mut map: HashMap<String, StoredTx> = self
            .transactions
            .drain(..)
            .map(|t| (t.tx_id.clone(), t))
            .collect();
        for t in txs {
            map.insert(t.tx_id.clone(), t);
        }
        let mut list: Vec<StoredTx> = map.into_values().collect();
        // Sort descending by timestamp / height
        list.sort_by(|a, b| {
            b.timestamp
                .cmp(&a.timestamp)
                .then_with(|| b.height.cmp(&a.height))
        });
        self.transactions = list;
    }

    /// Upsert a tracked singleton contract lineage.
    pub fn upsert_lineage(&mut self, lineage: TrackedLineage) {
        self.lineages
            .insert(lineage.singleton_token_id.clone(), lineage);
    }

    /// Get a tracked contract lineage by singleton token ID.
    pub fn get_lineage(&self, singleton_token_id: &str) -> Option<&TrackedLineage> {
        self.lineages.get(singleton_token_id)
    }

    /// Update the sync checkpoint.
    pub fn update_checkpoint(&mut self, height: u64, block_id: Option<String>, timestamp: u64) {
        self.sync = SyncCheckpoint {
            last_synced_height: height,
            last_sync_timestamp: timestamp,
            block_id,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wallet_database_roundtrip() {
        let mut db = WalletDatabase::new();
        db.upsert_address(AddressRecord {
            index: 0,
            address: "9fRAWhdxEsTcdb8PhgnrZfwqa65GLymZMEmK3VN5YnoDxj29397".into(),
            is_used: true,
            balance_nano_erg: 1_000_000_000,
        });
        db.upsert_boxes(vec![StoredBox {
            box_id: "box123".into(),
            address: "9fRAWhdxEsTcdb8PhgnrZfwqa65GLymZMEmK3VN5YnoDxj29397".into(),
            ergo_tree: "0008cd...".into(),
            value_nano_erg: 1_000_000_000,
            tokens: vec![StoredToken {
                id: "tokenA".into(),
                amount: 50,
                name: Some("Token A".into()),
                decimals: 2,
            }],
            creation_height: 1_200_000,
            spent_tx_id: None,
            is_unspent: true,
        }]);
        db.upsert_lineage(TrackedLineage {
            singleton_token_id: "singleton123".into(),
            protocol_name: "Spectrum AMM N2T".into(),
            root_box_id: "rootBox".into(),
            current_box_id: "curBox".into(),
            last_updated_height: 1_200_050,
            box_json: None,
        });

        let json = db.to_json().expect("serialize");
        let parsed = WalletDatabase::from_json(&json).expect("deserialize");
        assert_eq!(db, parsed);

        let (erg, tokens) = parsed.get_total_balances().expect("total balances");
        assert_eq!(erg, 1_000_000_000);
        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].amount, 50);
        assert_eq!(parsed.get_address_0().unwrap().index, 0);
        assert!(parsed.get_lineage("singleton123").is_some());
    }

    #[test]
    fn test_mark_box_spent() {
        let mut db = WalletDatabase::new();
        db.upsert_boxes(vec![StoredBox {
            box_id: "b1".into(),
            address: "addr1".into(),
            ergo_tree: "tree1".into(),
            value_nano_erg: 500,
            tokens: vec![],
            creation_height: 100,
            spent_tx_id: None,
            is_unspent: true,
        }]);
        assert_eq!(db.get_unspent_boxes().len(), 1);

        db.mark_box_spent("b1", "tx_spend_1");
        assert_eq!(db.get_unspent_boxes().len(), 0);
        assert_eq!(db.boxes[0].spent_tx_id.as_deref(), Some("tx_spend_1"));
    }
}
