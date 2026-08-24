import 'package:flutter_test/flutter_test.dart';

import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/ui/swap_screen.dart';

void main() {
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
        'quote_tolerance_pct': 0.5,
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
          quoteTolerancePct: 0.5,
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

  group('pool helpers', () {
    final n2tErgTok = {
      'pool_id': 'p1',
      'pool_type': 'N2T',
      'erg_reserves': 500000000000, // 500 ERG
      'token_y': {'token_id': 'tok', 'amount': 1000000000}, // 1000 tok @9dp
      'fee_num': 996,
      'fee_denom': 1000,
    };
    final t2t = {
      'pool_id': 'p2',
      'pool_type': 'T2T',
      'token_x': {'token_id': 'a', 'amount': 700},
      'token_y': {'token_id': 'b', 'amount': 1400},
      'fee_num': 996,
      'fee_denom': 1000,
    };

    test('poolSides maps N2T to (ERG, token)', () {
      final sides = poolSides(n2tErgTok);
      expect(sides[0].$1, isNull);
      expect(sides[0].$2, BigInt.from(500000000000));
      expect(sides[1].$1, 'tok');
      expect(sides[1].$2, BigInt.from(1000000000));
    });

    test('poolSides maps T2T sides', () {
      final sides = poolSides(t2t);
      expect(sides[0].$1, 'a');
      expect(sides[1].$1, 'b');
    });

    test('poolSupportsPair requires both sides and distinctness', () {
      expect(poolSupportsPair(n2tErgTok, null, 'tok'), isTrue);
      expect(poolSupportsPair(n2tErgTok, 'tok', null), isTrue);
      expect(poolSupportsPair(n2tErgTok, 'tok', 'other'), isFalse);
      expect(poolSupportsPair(t2t, 'a', 'b'), isTrue);
      // Identical sides are never a tradable pair.
      expect(poolSupportsPair(n2tErgTok, 'tok', 'tok'), isFalse);
    });

    test('requiredInputFor mirrors the CFMM input formula with fee', () {
      final rIn = BigInt.from(500000000000);
      final rOut = BigInt.from(1000000000);
      final out = BigInt.from(10000000);
      final required = requiredInputFor(
        reservesIn: rIn,
        reservesOut: rOut,
        output: out,
        feeNum: 996,
        feeDenom: 1000,
      )!;
      // Independent restatement of calculator.rs calculate_input.
      final expected = rIn * out * BigInt.from(1000) ~/
            ((rOut - out) * BigInt.from(996)) +
        BigInt.one;
      expect(required, expected);
      // Must exceed the naive fee-less ratio — the fee pushes it up.
      expect(
        required,
        greaterThan(rIn * out ~/ rOut),
      );
    });

    test('requiredInputFor rejects degenerate requests', () {
      expect(
        requiredInputFor(
          reservesIn: BigInt.one,
          reservesOut: BigInt.from(100),
          output: BigInt.from(100), // >= reserve
          feeNum: 996,
          feeDenom: 1000,
        ),
        isNull,
      );
    });

    test('bestPoolForOutput picks the pool needing the least input', () {
      // With equal token-side reserves, the pool pricing ERG cheaper
      // (lower rIn/rOut) fills the same output for less input.
      final cheap = {
        'pool_id': 'cheap',
        'pool_type': 'N2T',
        'erg_reserves': 300000000000,
        'token_y': {'token_id': 'tok', 'amount': 1000000000},
        'fee_num': 996,
        'fee_denom': 1000,
      };
      final match = bestPoolForOutput(
        pools: [n2tErgTok, cheap],
        from: null,
        to: 'tok',
        output: BigInt.from(10000000),
      )!;
      expect(match.$1['pool_id'], 'cheap');
    });

    test('bestPoolForOutput returns null when nothing fills the size', () {
      expect(
        bestPoolForOutput(
          pools: [n2tErgTok],
          from: null,
          to: 'tok',
          output: BigInt.from(2000000000), // more than the reserve
        ),
        isNull,
      );
    });
  });
}
