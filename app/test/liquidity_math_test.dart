import 'package:argus_wallet/services/liquidity_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deposit and redeem follow the pool ratio and share', () {
    final x = BigInt.from(1000000000000); // 1,000 ERG
    final y = BigInt.from(250000); // 2,500.00 SigUSD
    final lp = BigInt.from(5000000);
    expect(depositCounterpart(x, y, BigInt.from(100000000000)), BigInt.from(25000), reason: '100 ERG needs 250 SigUSD');
    expect(lpReward(x, y, lp, BigInt.from(100000000000), BigInt.from(25000)), BigInt.from(500000), reason: '10% of the supply');
    expect(lpReward(x, y, lp, BigInt.from(100000000000), BigInt.from(1)), BigInt.from(20), reason: 'the short side rules');
    final (xo, yo) = redeemShares(x, y, lp, BigInt.from(500000));
    expect(xo, BigInt.from(100000000000));
    expect(yo, BigInt.from(25000));
    expect(poolShareBps(BigInt.from(500000), lp), 1000);
    expect(initialLpShare(BigInt.from(1000000000000), BigInt.from(250000)), BigInt.from(500000000), reason: 'sqrt(2.5e17)');
    expect(initialLpShare(BigInt.from(4), BigInt.from(9)), BigInt.from(6));
    expect(feeNumFor(0.3), 997);
    expect(feeNumFor(1.0), 990);
  });
}
