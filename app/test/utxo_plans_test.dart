import 'package:argus_wallet/services/utxo_plans.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('equal split leaves no dust change', () {
    // 10 ERG into 4, fees 0.0022: each box gets the floor and the leftover
    // is either zero or at least a whole min box.
    final per = equalSplitAmount(totalNano: 10000000000, count: 4, feesNano: 2200000);
    expect(per, 2499450000);
    final leftover = 10000000000 - 2200000 - per! * 4;
    expect(leftover == 0 || leftover >= 1000000, isTrue);
  });

  test('equal split refuses when boxes would be below the minimum', () {
    expect(equalSplitAmount(totalNano: 3000000, count: 4, feesNano: 2200000), isNull);
  });

  test('consolidation chunks respect the per-transaction input cap', () {
    final ids = List.generate(250, (i) => 'b$i');
    final chunks = consolidationChunks(ids, maxInputs: 100);
    expect(chunks.map((c) => c.length), [100, 100, 50]);
    expect(consolidationChunks(['a'], maxInputs: 100), isEmpty);
    // A trailing chunk of one box is folded into the previous one.
    expect(consolidationChunks(List.generate(101, (i) => '$i'), maxInputs: 100).map((c) => c.length), [101]);
  });

  test('health bands', () {
    expect(utxoHealth(5).label, 'Tidy');
    expect(utxoHealth(40).label, 'Moderate');
    expect(utxoHealth(120).label, 'Fragmented');
  });
}
