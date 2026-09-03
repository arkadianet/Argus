import '../../services/app_fee.dart';
import '../../format.dart';
import '../../services/dexy_service.dart';
import '../confirm_transaction_sheet.dart';

/// What the confirm sheet shows for one Dexy action.
class DexyConfirm {
  const DexyConfirm({
    required this.title,
    required this.rows,
    required this.detail,
    required this.confirmLabel,
  });

  final String title;
  final List<ConfirmTxRow> rows;
  final String detail;
  final String confirmLabel;
}

String _dexy(int amount, DexyVariant v) =>
    '${formatTokenAmount(amount, v.decimals)} ${v.shortName}';

DexyConfirm dexyMintConfirm(DexyBuildResult b, DexyVariant v) => DexyConfirm(
      title: 'Mint ${v.shortName}',
      rows: [
        ConfirmTxRow('Received', _dexy(b.tokenAmount, v)),
        ConfirmTxRow('ERG cost', formatErg(b.ergCostNano)),
        ConfirmTxRow('Miner fee', formatErg(b.minerFee)),
        argusFeeRow(),
      ],
      detail: 'Minted from the Dexy bank at the oracle rate.',
      confirmLabel: 'Sign & broadcast mint',
    );

DexyConfirm dexySwapConfirm(DexyBuildResult b, DexyVariant v) {
  final ergIn = b.direction == 'erg_to_dexy';
  return DexyConfirm(
    title: 'Swap ERG ↔ ${v.shortName}',
    rows: [
      ConfirmTxRow('Pay', ergIn ? formatErg(b.inputAmount) : _dexy(b.inputAmount, v)),
      ConfirmTxRow('Receive', ergIn ? _dexy(b.outputAmount, v) : formatErg(b.outputAmount)),
      ConfirmTxRow('Price impact', '${b.priceImpactPct.toStringAsFixed(2)}%'),
      ConfirmTxRow('Miner fee', formatErg(b.minerFee)),
      argusFeeRow(),
    ],
    detail: 'Rate set by the ${v.shortName} LP pool (${b.feePct.toStringAsFixed(1)}% fee).',
    confirmLabel: 'Sign & broadcast swap',
  );
}

DexyConfirm dexyLiquidityConfirm(DexyBuildResult b, DexyVariant v) {
  final deposit = b.action == 'deposit';
  return DexyConfirm(
    title: deposit ? 'Add liquidity' : 'Remove liquidity',
    rows: deposit
        ? [
            ConfirmTxRow('Deposit ERG', formatErg(b.ergAmount)),
            ConfirmTxRow('Deposit ${v.shortName}', _dexy(b.dexyAmount, v)),
            ConfirmTxRow('Miner fee', formatErg(b.minerFee)),
            argusFeeRow(),
          ]
        : [
            ConfirmTxRow('LP tokens burned', '${b.lpTokens}'),
            ConfirmTxRow('Receive', '${formatErg(b.ergAmount)} + ${_dexy(b.dexyAmount, v)}'),
            ConfirmTxRow('Miner fee', formatErg(b.minerFee)),
            argusFeeRow(),
          ],
    detail: deposit
        ? 'Receives ${formatTokenAmount(b.lpTokens, 0)} LP tokens.'
        : '2% redemption fee applies.',
    confirmLabel: deposit ? 'Sign & broadcast deposit' : 'Sign & broadcast redeem',
  );
}
