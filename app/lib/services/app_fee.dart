import '../format.dart';
import '../ui/confirm_transaction_sheet.dart';

/// Argus app fee, paid on every transaction the wallet builds (sends, UTXO
/// tools, swaps, mints). ErgoPay transactions are built by the dApp and do
/// not carry it. Must match ARGUS_FEE_* in rust/crates/wallet-ffi/src/api.rs.
const argusFeeNano = 1100000;
const argusFeeAddress = '9iArkadiaZAPVxbUp2XQ8SVA1zGA29rCPhbpVuUaaKW6fWspUZA';

/// Row for every confirm sheet whose transaction pays the fee.
ConfirmTxRow argusFeeRow() => ConfirmTxRow('Argus fee', formatErg(argusFeeNano));

/// ERG a transaction needs on top of what it sends: miner fee plus app fee.
int txOverheadNano({int minerFee = minerFeeDefaultNano}) => minerFee + argusFeeNano;

const minerFeeDefaultNano = 1100000;
