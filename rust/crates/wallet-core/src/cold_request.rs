//! Bounded preflight for the initial offline P2PK policy. No general script or
//! constant parser sees scanned data until this entire grammar has passed.
//! Wire format is unchanged; unsupported contracts/registers are refused.
use crate::cold_signing::PreparedColdTransaction;
use crate::cold_transport::{invalid, ColdError, RequestBytes, MAX_INNER_BYTES};
use ergo_lib::chain::transaction::reduced::ReducedTransaction;
use ergo_lib::ergotree_ir::{chain::ergo_box::ErgoBox, serialization::SigmaSerializable};

const MAX_IO: u64 = 256;
const MAX_TOKENS: u64 = 4096;

struct Cursor<'a>(&'a [u8]);
impl<'a> Cursor<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], ColdError> {
        if n > self.0.len() {
            return Err(invalid("truncated cold request"));
        }
        let (a, b) = self.0.split_at(n);
        self.0 = b;
        Ok(a)
    }
    fn byte(&mut self) -> Result<u8, ColdError> {
        Ok(self.take(1)?[0])
    }
    // Canonical unsigned VLQ, bounded before narrowing or allocation.
    fn number(&mut self, max: u64) -> Result<u64, ColdError> {
        let mut n = 0u64;
        for i in 0..10 {
            let b = self.byte()?;
            if i == 9 && b > 1 {
                return Err(invalid("VLQ overflow"));
            }
            n |= u64::from(b & 127) << (7 * i);
            if b & 128 == 0 {
                if (i > 0 && b == 0) || n > max {
                    return Err(invalid("noncanonical or excessive length/value"));
                }
                return Ok(n);
            }
        }
        Err(invalid("unterminated VLQ"))
    }
    fn zero(&mut self, why: &str) -> Result<(), ColdError> {
        if self.byte()? != 0 {
            return Err(invalid(why));
        }
        Ok(())
    }
    fn end(&self) -> Result<(), ColdError> {
        if self.0.is_empty() {
            Ok(())
        } else {
            Err(invalid("trailing cold request bytes"))
        }
    }
    fn candidate(&mut self, dictionary: Option<u64>, fee: &[u8]) -> Result<(), ColdError> {
        self.number(i64::MAX as u64)?; // value
        if self.0.starts_with(&[0, 8, 0xcd]) {
            self.take(3)?;
            let pk = self.take(33)?;
            if !matches!(pk[0], 2 | 3) {
                return Err(invalid("invalid compressed public key"));
            }
        } else if self.0.starts_with(fee) {
            self.take(fee.len())?;
        } else {
            return Err(invalid(
                "offline signing supports canonical P2PK outputs and the miner fee script only",
            ));
        }
        self.number(u32::MAX as u64)?; // height
        let tokens = self.byte()?;
        for _ in 0..tokens {
            match dictionary {
                Some(0) => return Err(invalid("token index without dictionary")),
                Some(n) => {
                    self.number(n - 1)?;
                }
                None => {
                    self.take(32)?;
                }
            }
            self.number(i64::MAX as u64)?;
        }
        self.zero("offline signing does not support additional registers")
    }
}

/// Parse complete, untrusted EIP-19 JSON under a narrow allocation-safe grammar.
/// Does not establish ownership or authorize signing. Sender is only a hint.
pub fn parse_request(json: &str) -> Result<PreparedColdTransaction, ColdError> {
    let raw = RequestBytes::decode(json)?;
    if raw.inputs.is_empty() || raw.inputs.len() > MAX_IO as usize {
        return Err(invalid("offline request needs 1–256 spending boxes"));
    }
    let fee = ergo_lib::wallet::miner_fee::MINERS_FEE_ADDRESS
        .script()
        .map_err(invalid)?
        .sigma_serialize_bytes()
        .map_err(invalid)?;
    let mut reduced = Cursor(&raw.reduced_tx);
    let message_len = reduced.number(MAX_INNER_BYTES as u64)? as usize;
    let mut message = Cursor(reduced.take(message_len)?);
    let inputs = message.number(MAX_IO)?;
    if inputs as usize != raw.inputs.len() {
        return Err(invalid("missing spending boxes"));
    }
    for _ in 0..inputs {
        message.take(32)?;
        message.zero("reduced transaction contains a spending proof")?;
        message.zero("offline signing does not support context extensions")?;
    }
    message.zero("offline signing does not support data inputs")?;
    let tokens = message.number(MAX_TOKENS)?;
    message.take(tokens as usize * 32)?;
    let outputs = message.number(MAX_IO)?;
    if outputs == 0 {
        return Err(invalid("transaction has no outputs"));
    }
    for _ in 0..outputs {
        message.candidate(Some(tokens), &fee)?;
    }
    message.end()?;
    for _ in 0..inputs {
        if reduced.byte()? != 0xcd {
            return Err(invalid("offline signing requires P2PK reductions"));
        }
        let pk = reduced.take(33)?;
        if !matches!(pk[0], 2 | 3) {
            return Err(invalid("invalid reduced public key"));
        }
        reduced.number(u64::MAX)?;
    }
    reduced.number(u32::MAX as u64)?;
    reduced.end()?;
    for bytes in &raw.inputs {
        let mut b = Cursor(bytes);
        b.candidate(None, &fee)?;
        b.take(32)?;
        b.number(u16::MAX as u64)?;
        b.end()?;
    }
    // The only variable-length constructs now have checked bounds and complete
    // bodies. Trees are fixed P2PK or byte-identical to a locally serialized fee.
    let reduced = ReducedTransaction::sigma_parse_bytes(&raw.reduced_tx).map_err(invalid)?;
    if reduced.sigma_serialize_bytes().map_err(invalid)? != raw.reduced_tx {
        return Err(invalid("noncanonical reduced transaction"));
    }
    let boxes = raw
        .inputs
        .iter()
        .map(|bytes| {
            let b = ErgoBox::sigma_parse_bytes(bytes).map_err(invalid)?;
            if b.sigma_serialize_bytes().map_err(invalid)? != *bytes {
                return Err(invalid("noncanonical box"));
            }
            Ok(b)
        })
        .collect::<Result<Vec<_>, ColdError>>()?;
    // Recomputes box IDs, checks exact input order, and compares every reduction
    // with the actual P2PK script. A forged reduction cannot select another key.
    PreparedColdTransaction::new(reduced, boxes)
}
