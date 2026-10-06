import 'package:argus_wallet/services/utxo_plans.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  InputBoxInput tokenSource(int nano, {BigInt? amount}) => InputBoxInput(
    boxId: 'source',
    address: 'own',
    valueNanoErg: BigInt.from(nano),
    creationHeight: 10,
    assets: [
      InputAsset(tokenId: 'B', amount: amount ?? BigInt.from(500)),
      InputAsset(tokenId: 'A', amount: BigInt.one),
    ],
  );

  group('separate token types', () {
    test('allocates every full token balance and preserves ERG change', () {
      final plan = planSeparateTokens(
        source: tokenSource(1000000000),
        feesNano: 2200000,
      );
      expect(plan.inputBoxIds, ['source']);
      expect(plan.minimumRequiredNano, 4200000);
      expect(plan.outputs, [
        {
          'value_nano_erg': 1000000,
          'tokens': [
            {'id': 'A', 'amount': 1},
          ],
        },
        {
          'value_nano_erg': 1000000,
          'tokens': [
            {'id': 'B', 'amount': 500},
          ],
        },
      ]);
      expect(plan.changeNano, BigInt.from(995800000));
    });

    test('preserves a sub-minimum ERG remainder inside a token output', () {
      final plan = planSeparateTokens(
        source: tokenSource(4200123),
        feesNano: 2200000,
      );
      expect(plan.outputs.first['value_nano_erg'], 1000123);
      expect(plan.changeNano, BigInt.zero);
      expect(
        plan.outputs.fold<int>(
              0,
              (sum, out) => sum + (out['value_nano_erg'] as int),
            ) +
            plan.feesNano,
        4200123,
      );
    });

    test('requires enough ERG and accepts only explicit eligible funding', () {
      final source = tokenSource(1000000);
      final funding = InputBoxInput(
        boxId: 'fund',
        address: 'own',
        valueNanoErg: BigInt.from(5000000),
        creationHeight: 1,
        assets: [],
      );
      expect(
        () => planSeparateTokens(source: source, feesNano: 2200000),
        throwsFormatException,
      );
      final plan = planSeparateTokens(
        source: source,
        funding: [funding],
        feesNano: 2200000,
      );
      expect(plan.inputBoxIds, ['source', 'fund']);
      expect(plan.changeNano, BigInt.from(1800000));
      for (final invalid in [
        source,
        InputBoxInput(
          boxId: 'other',
          address: 'foreign',
          valueNanoErg: BigInt.from(5000000),
          creationHeight: 1,
          assets: [],
        ),
        InputBoxInput(
          boxId: 'tokens',
          address: 'own',
          valueNanoErg: BigInt.from(5000000),
          creationHeight: 1,
          assets: [InputAsset(tokenId: 'C', amount: BigInt.one)],
        ),
      ]) {
        expect(
          () => planSeparateTokens(
            source: source,
            funding: [invalid],
            feesNano: 2200000,
          ),
          throwsFormatException,
        );
      }
    });

    test('retains signed 64-bit token precision and rejects overflow', () {
      final max = BigInt.parse('9223372036854775807');
      final plan = planSeparateTokens(
        source: tokenSource(1000000000, amount: max),
        feesNano: 2200000,
      );
      expect(
        (plan.outputs.last['tokens'] as List).single['amount'],
        max.toInt(),
      );
      expect(
        () => planSeparateTokens(
          source: tokenSource(1000000000, amount: max + BigInt.one),
          feesNano: 2200000,
        ),
        throwsFormatException,
      );
    });
  });

  test('equal split leaves no dust change', () {
    // 10 ERG into 4, fees 0.0022: each box gets the floor and the leftover
    // is either zero or at least a whole min box.
    final per = equalSplitAmount(
      totalNano: 10000000000,
      count: 4,
      feesNano: 2200000,
    );
    expect(per, 2499450000);
    final leftover = 10000000000 - 2200000 - per! * 4;
    expect(leftover == 0 || leftover >= 1000000, isTrue);
  });

  test('equal split refuses when boxes would be below the minimum', () {
    expect(
      equalSplitAmount(totalNano: 3000000, count: 4, feesNano: 2200000),
      isNull,
    );
  });

  test('consolidation chunks respect the per-transaction input cap', () {
    final ids = List.generate(250, (i) => 'b$i');
    final chunks = consolidationChunks(ids, maxInputs: 100);
    expect(chunks.map((c) => c.length), [100, 100, 50]);
    expect(consolidationChunks(['a'], maxInputs: 100), isEmpty);
    // A trailing chunk of one box is folded into the previous one.
    expect(
      consolidationChunks(
        List.generate(101, (i) => '$i'),
        maxInputs: 100,
      ).map((c) => c.length),
      [101],
    );
  });

  test('health bands', () {
    expect(utxoHealth(5).label, 'Tidy');
    expect(utxoHealth(40).label, 'Moderate');
    expect(utxoHealth(120).label, 'Fragmented');
  });
}
