import 'package:flutter_test/flutter_test.dart';

import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/ui/swap_screen.dart';

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

  group('swap screen labels', () {
    test('quote line states the unit exactly once', () {
      final label = swapQuoteLabel(
        const AmmQuote(
          poolId: 'p',
          boxId: 'b',
          outputAmount: 995000,
          outputToken: 'tok',
          minOutput: 990025,
          priceImpactPct: 0.12,
          feeAmount: 3000,
          slippagePct: 0.5,
        ),
        outputSymbol: 'SigUSD',
        outputDecimals: 2,
      );

      // formatTokenAmount trims trailing zeros, so 995000 raw @ 2 decimals
      // renders as "9950", not "9950.00".
      expect(label, '≈ 9950 SigUSD  ·  impact 0.12%');
      expect('SigUSD'.allMatches(label), hasLength(1));
    });

    test('truncation notice explains a missing pool', () {
      expect(
        poolTruncationNotice(),
        'Pool list was capped — some pairs may be missing.',
      );
    });
  });
}
