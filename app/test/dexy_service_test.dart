import 'package:flutter_test/flutter_test.dart';

import 'package:argus_wallet/services/dexy_service.dart';
import 'package:argus_wallet/ui/dexy_screen.dart';
import 'package:argus_wallet/ui/send_screen.dart';

/// Builds a USE (3-decimal) market snapshot in the same JSON shape the Rust
/// bridge returns. [effectiveRate] is ERG per *display* token, matching
/// `DexyRates::from_state` in `rust/crates/vendor/protocols/dexy/src/rates.rs`.
DexyState _useState({
  required double effectiveRate,
  required int lpErgReserves,
  required int lpDexyReserves,
}) {
  return DexyState.fromJson({
    'state': {
      'bank_erg_nano': 500000000000,
      'dexy_in_bank': 100000000,
      'oracle_rate_nano': 3700000,
      'lp_erg_reserves': lpErgReserves,
      'lp_dexy_reserves': lpDexyReserves,
      'lp_rate_nano': lpDexyReserves > 0 ? lpErgReserves ~/ lpDexyReserves : 0,
      'lp_token_reserves': 1000000,
      'lp_circulating': 1000000,
      'free_mint_available': 100000000,
      'can_redeem_lp': true,
      'can_mint': true,
      'rate_difference_pct': 0.0,
      'dexy_circulating': 100000000,
    },
    'rates': {
      'variant': 'usd',
      'token_name': 'DexyUSD',
      'token_decimals': 3,
      'oracle_rate_nano': 3700000,
      'erg_per_token': 3.7,
      'tokens_per_erg': 1 / 3.7,
      'peg_description': '1 USE = 0.001 USD',
      'paths': {
        'arb_mint': {'name': 'ArbMint', 'available': false},
        'free_mint': {
          'name': 'FreeMint',
          'available': true,
          'erg_per_token': 3.7,
          'effective_rate': effectiveRate,
          'max_tokens': 100000000,
          'remaining_today': 100000000,
          'fee_percent': 0.5,
          'is_best_rate': true,
        },
        'lp_swap': {'name': 'LP Swap', 'available': true},
      },
    },
  });
}

void main() {
  // 1 display USE == 1000 raw units at 3 decimals.
  const oneUse = 1000;
  const minerFeeReserveNano = 1100000;

  group('quotesForState', () {
    test('FreeMint prices the oracle rate per display token, not per raw unit',
        () {
      final st = _useState(
        effectiveRate: 3.7185, // ERG per display USE, oracle + 0.5% bank fee
        lpErgReserves: 0,
        lpDexyReserves: 0,
      );

      final quotes = dexService.quotesForState(st, oneUse);

      expect(quotes, hasLength(1));
      expect(quotes.single.path, 'FreeMint');
      // 3.7185 ERG + miner fee reserve, expressed in nanoERG.
      expect(
        quotes.single.ergCostNano,
        closeTo(3718500000 + minerFeeReserveNano, 100),
      );
    });

    test('quotes sort cheapest first when the LP pool undercuts FreeMint', () {
      final st = _useState(
        effectiveRate: 3.7185,
        lpErgReserves: 36885000000000, // pool prices 1 USE at ~3.6999 ERG
        lpDexyReserves: 10000000,
      );

      final quotes = dexService.quotesForState(st, oneUse);

      expect(quotes.map((q) => q.path), ['LP Swap', 'FreeMint']);
      expect(quotes.first.ergCostNano, lessThan(quotes.last.ergCostNano));
    });
  });

  group('route planning guards', () {
    test('a non-positive amount yields no routes', () {
      final st = _useState(
        effectiveRate: 3.7185,
        lpErgReserves: 3700000000000,
        lpDexyReserves: 1000000,
      );

      expect(dexService.quotesForState(st, 0), isEmpty);
      expect(dexService.quotesForState(st, -1), isEmpty);
      // Positive amounts are unaffected.
      expect(dexService.quotesForState(st, oneUse), isNotEmpty);
    });
  });

  group('shortfall top-up', () {
    test('only the missing amount is acquired', () {
      expect(shortfallFor(wanted: 1000, held: 266), 734);
    });

    test('holding enough needs no acquisition', () {
      expect(shortfallFor(wanted: 1000, held: 1000), 0);
      expect(shortfallFor(wanted: 1000, held: 5000), 0);
    });

    test('holding none acquires the whole amount', () {
      expect(shortfallFor(wanted: 1000, held: 0), 1000);
    });
  });

  group('LP deposit pairing', () {
    // Pool holds 3700 ERG against 1000 USE, so one whole USE pairs with 3.7 ERG.
    DexyState pool() => _useState(
          effectiveRate: 3.7185,
          lpErgReserves: 3700000000000,
          lpDexyReserves: 1000000,
        );

    test('derives the ERG needed to pair a USE amount', () {
      // 0.26 USE at 3 decimals is 260 raw units.
      expect(ergForDexyDeposit(pool(), 260), 962000000); // 0.962 ERG
    });

    test('derives the USE needed to pair an ERG amount', () {
      expect(dexyForErgDeposit(pool(), 962000000), 260);
    });

    // Round up, so the entered side is fully consumed rather than partly
    // refunded by calculate_lp_deposit's min-of-shares rule.
    test('rounds the pair up so the entered side is not left over', () {
      expect(ergForDexyDeposit(pool(), 1), 3700000);
      expect(dexyForErgDeposit(pool(), 3700001), 2);
    });

    test('an empty pool cannot be paired', () {
      final empty = _useState(
        effectiveRate: 3.7185,
        lpErgReserves: 0,
        lpDexyReserves: 0,
      );
      expect(ergForDexyDeposit(empty, 260), 0);
      expect(dexyForErgDeposit(empty, 962000000), 0);
    });
  });

  group('LP deposit MAX clamping', () {
    DexyState pool() => _useState(
          effectiveRate: 3.7185,
          lpErgReserves: 3700000000000,
          lpDexyReserves: 1000000,
        );

    // MAX on either side must not propose a pair the other side cannot cover,
    // otherwise the sheet fills in an amount the user does not hold.
    test('token MAX is capped by the ERG the wallet can pair with it', () {
      // 1000 raw USE would need 3.7 ERG, but only 1.85 ERG is spendable.
      final capped = maxPairableDexy(pool(), tokenBalance: 1000, ergAvailable: 1850000000);
      expect(capped, 500);
      expect(ergForDexyDeposit(pool(), capped), lessThanOrEqualTo(1850000000));
    });

    test('token MAX keeps the full balance when ERG covers it', () {
      expect(
        maxPairableDexy(pool(), tokenBalance: 260, ergAvailable: 5000000000),
        260,
      );
    });

    test('ERG MAX is capped by the tokens the wallet can pair with it', () {
      // 3.7 ERG would need 1000 raw USE, but only 260 are held.
      final capped = maxPairableErg(pool(), ergAvailable: 3700000000, tokenBalance: 260);
      expect(capped, 962000000);
    });

    test('nothing is pairable without a balance on both sides', () {
      expect(maxPairableDexy(pool(), tokenBalance: 0, ergAvailable: 5000000000), 0);
      expect(maxPairableErg(pool(), ergAvailable: 0, tokenBalance: 260), 0);
    });
  });

  group('send screen labels', () {
    test('quote line states the ERG unit exactly once', () {
      final label = dexyQuoteLabel(
        const DexyPathQuote(path: 'FreeMint', ergCostNano: 3719600000),
        cheapest: true,
      );

      expect(label, '≈ 3.7196 ERG via FreeMint  ·  cheapest');
      expect('ERG'.allMatches(label), hasLength(1));
    });

    test('quote line marks only the cheapest route', () {
      final label = dexyQuoteLabel(
        const DexyPathQuote(path: 'LP Swap', ergCostNano: 3700970000),
        cheapest: false,
      );

      expect(label, '≈ 3.70097 ERG via LP Swap');
    });

    test('asset labels name the token, not the protocol', () {
      expect(dexyAssetLabel(DexyVariant.usd), 'USE · buy & send');
      expect(dexyAmountLabel(DexyVariant.usd), 'USE amount to deliver');
    });
  });

  group('dexy screen labels', () {
    test('mint titles name the token, not the protocol', () {
      expect(dexyMintTitle(DexyVariant.usd), 'Mint USE');
      expect(dexyMintTitle(DexyVariant.gold), 'Mint DexyGold');
    });

    test('holdings header names the token, not the protocol', () {
      expect(dexyHoldingsTitle(DexyVariant.usd), 'Your USE');
      expect(dexyHoldingsTitle(DexyVariant.gold), 'Your DexyGold');
    });
  });

  group('peg descriptions', () {
    // USE carries 3 decimals and the oracle divisor turns nanoERG/USD into
    // nanoERG per *raw* unit (constants.rs:85), so one whole USE is 1 USD.
    // Every amount in the UI is a display amount, so the peg must say so.
    test('one display USE is pegged to one USD', () {
      expect(DexyVariant.usd.peg, '1 USE = 1 USD');
    });

    test('one display DexyGold is pegged to one milligram', () {
      expect(DexyVariant.gold.peg, '1 DexyGold = 1 mg of gold');
    });
  });
}
