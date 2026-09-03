import 'package:argus_wallet/services/dexy_service.dart';
import 'package:argus_wallet/ui/dexy/dexy_confirm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const v = DexyVariant.gold;

  test('mint rows show received amount, cost and fee', () {
    const b = DexyBuildResult(preparationId: 1, recipient: 'r', minerFee: 1100000, changeNanoErg: 0, ergCostNano: 2000000000, tokenAmount: 5);
    final c = dexyMintConfirm(b, v);
    expect(c.rows.map((r) => r.label), ['Received', 'ERG cost', 'Miner fee', 'Argus fee']);
    expect(c.rows.first.value, '5 DexyGold');
    expect(c.confirmLabel, contains('mint'));
  });

  test('swap rows flip pay and receive by direction', () {
    const b = DexyBuildResult(preparationId: 1, recipient: 'r', minerFee: 1100000, changeNanoErg: 0, direction: 'erg_to_dexy', inputAmount: 1000000000, outputAmount: 3, priceImpactPct: 0.5, feePct: 0.3);
    final c = dexySwapConfirm(b, v);
    expect(c.rows[0].value, '1 ERG');
    expect(c.rows[1].value, '3 DexyGold');
    expect(c.rows[2].value, '0.50%');
    final back = dexySwapConfirm(DexyBuildResult(preparationId: 1, recipient: 'r', minerFee: 1, changeNanoErg: 0, direction: 'dexy_to_erg', inputAmount: 3, outputAmount: 1000000000), v);
    expect(back.rows[0].value, '3 DexyGold');
    expect(back.rows[1].value, '1 ERG');
  });

  test('liquidity rows differ for deposit and redeem', () {
    const dep = DexyBuildResult(preparationId: 1, recipient: 'r', minerFee: 1, changeNanoErg: 0, action: 'deposit', ergAmount: 1000000000, dexyAmount: 2, lpTokens: 7);
    final d = dexyLiquidityConfirm(dep, v);
    expect(d.title, 'Add liquidity');
    expect(d.rows.first.label, 'Deposit ERG');
    expect(d.detail, contains('7 LP'));
    const red = DexyBuildResult(preparationId: 1, recipient: 'r', minerFee: 1, changeNanoErg: 0, action: 'redeem', ergAmount: 1000000000, dexyAmount: 2, lpTokens: 7);
    final r = dexyLiquidityConfirm(red, v);
    expect(r.title, 'Remove liquidity');
    expect(r.rows.first.label, 'LP tokens burned');
  });
}
