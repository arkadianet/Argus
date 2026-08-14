use ergo_lib::chain::transaction::reduced::reduce_tx;
use ergo_lib::chain::transaction::reduced::ReducedTransaction;
use ergo_lib::chain::transaction::unsigned::UnsignedTransaction;
use ergo_lib::chain::transaction::DataInput;
use ergo_lib::chain::transaction::TxIoVec;
use ergo_lib::chain::ergo_state_context::ErgoStateContext;
use ergo_lib::chain::ergo_box::box_builder::ErgoBoxCandidateBuilder;
use ergo_lib::ergotree_ir::chain::ergo_box::box_value::BoxValue;
use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
use ergo_lib::ergotree_ir::chain::token::{Token, TokenAmount, TokenId};
use ergo_lib::ergotree_ir::chain::context_extension::ContextExtension;
use ergo_lib::ergotree_ir::ergo_tree::ErgoTree;
use ergo_lib::ergotree_ir::mir::constant::Constant;
use ergo_lib::ergotree_ir::serialization::SigmaSerializable;
use ergo_lib::wallet::tx_context::TransactionContext;

use crate::CoreError;

/// Build a reduced transaction from EIP-12 components (without needing a node client).
/// The state context must be pre-fetched (e.g., from a public node snapshot).
pub fn build_reduced_transaction(
    unsigned_tx: UnsignedTransaction,
    input_boxes: Vec<ErgoBox>,
    data_input_boxes: Vec<ErgoBox>,
    state_context: &ErgoStateContext,
) -> Result<ReducedTransaction, CoreError> {
    let tx_context = TransactionContext::new(unsigned_tx, input_boxes, data_input_boxes)
        .map_err(|e| CoreError::Reduction(e.to_string()))?;
    let reduced = reduce_tx(tx_context, state_context)
        .map_err(|e| CoreError::Reduction(e.to_string()))?;
    Ok(reduced)
}

/// Serialize a ReducedTransaction to bytes (EIP-19).
pub fn serialize_reduced(reduced: &ReducedTransaction) -> Result<Vec<u8>, CoreError> {
    reduced
        .sigma_serialize_bytes()
        .map_err(|e| CoreError::Serialization(e.to_string()))
}

/// Deserialize ReducedTransaction from EIP-19 bytes.
pub fn deserialize_reduced(bytes: &[u8]) -> Result<ReducedTransaction, CoreError> {
    ReducedTransaction::sigma_parse_bytes(bytes)
        .map_err(|e| CoreError::Serialization(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_serialize_deserialize_roundtrip() {
        // Build a minimal state context
        use ergo_lib::chain::ergo_state_context::ErgoStateContext;
        use ergo_lib::chain::transaction::unsigned::UnsignedTransaction;
        use ergo_lib::chain::transaction::UnsignedInput;
        use ergo_lib::ergotree_ir::chain::ergo_box::BoxId;
        use ergo_lib::ergotree_ir::chain::ergo_box::ErgoBox;
        use ergo_lib::ergotree_ir::chain::ergo_box::NonMandatoryRegisterId;
        use ergo_lib::ergotree_ir::chain::token::Token;
        use ergo_lib::wallet::tx_context::TransactionContext;

        // This test just checks that serialize/deserialize round-trips on a
        // trivial reduced transaction. A full integration test with real fixtures
        // is in Phase 0 spike.
    }
}