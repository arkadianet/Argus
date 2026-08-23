import 'package:flutter_test/flutter_test.dart';

import 'package:argus_wallet/services/amm_service.dart';

void main() {
  group('minOutputFor', () {
    test('applies slippage and rounds down', () {
      expect(minOutputFor(1000000, 0.5), 995000);
      expect(minOutputFor(1000000, 0.0), 1000000);
      expect(minOutputFor(3, 50.0), 1);
    });
  });

  group('AmmQuote.fromJson', () {
    test('parses a quote and keeps the pool box it was built from', () {
      final q = AmmQuote.fromJson({
        'pool_id': 'abc',
        'box_id': 'box123',
        'output_amount': 995000,
        'output_token': 'tok',
        'min_output': 990025,
        'price_impact_pct': 0.12,
        'fee_amount': 3000,
        'slippage_pct': 0.5,
      });

      expect(q.poolId, 'abc');
      expect(q.boxId, 'box123', reason: 'contention handling needs the box id');
      expect(q.outputAmount, 995000);
      expect(q.minOutput, 990025);
      expect(q.priceImpactPct, closeTo(0.12, 1e-9));
    });
  });

  group('AmmPoolSet.fromJson', () {
    test('surfaces truncation so a missing pool is explainable', () {
      final set = AmmPoolSet.fromJson({
        'truncated': true,
        'pools': <dynamic>[],
        'tokens': {
          'tok': {'name': 'SigUSD', 'decimals': 2},
        },
      });

      expect(set.truncated, isTrue);
      expect(set.tokens['tok']!.name, 'SigUSD');
      expect(set.tokens['tok']!.decimals, 2);
    });
  });
}
