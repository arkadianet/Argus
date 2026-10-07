import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/address_label_service.dart';
import 'package:argus_wallet/services/erg_price_history.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/token_pricer.dart';
import 'package:argus_wallet/services/token_pricing.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/home/erg_price_feed.dart';
import 'package:argus_wallet/ui/home/home_data.dart';
import 'package:argus_wallet/ui/home/home_format.dart';
import 'package:argus_wallet/ui/home/home_models.dart';
import 'package:argus_wallet/ui/home/unlock_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_finders.dart';
import 'support/home_harness.dart';

// The redesigned home as the app feeds it: prices from the pricer and the
// network controller, names and scales from the one token lookup, activity
// worded as the Activity tab words it, and the wallet page's More sheet and
// Discover tab wired to what they open.

const _usdPerErg = 0.24;

/// A pricer whose history is whatever the test says, counting the reads.
class _HistoryPricer extends TokenPricer {
  _HistoryPricer()
      : super(PricerDeps(
          nodeUrl: () => null,
          tipHeight: () => null,
          fiatCode: () => 'usd',
          oracle: (_) async => null,
          coingecko: (_, _) async => const {},
          pools: () async => null,
          poolPrices: (_) async => PoolPriceBook.empty,
          sigRsvPriceNano: () async => null,
          onRate: (_, _) {},
          metadataChanges: ValueNotifier(0),
        ));

  int reads = 0;
  ErgPriceHistory answer = const ErgPriceHistory.unavailable(
    window: PriceWindow.day,
    sourceLabel: 'SigmaUSD oracle',
    currency: 'usd',
    reason: 'No node is connected.',
  );

  @override
  Future<ErgPriceHistory> ergPriceHistory(PriceWindow window) async {
    reads++;
    return answer;
  }
}

ErgPriceHistory _day({String currency = 'aud', String source = 'SigmaUSD oracle', bool stale = false}) {
  final now = DateTime.now();
  return ErgPriceHistory(
    window: PriceWindow.day,
    points: [PricePoint(now.subtract(const Duration(hours: 24)), 0.35), PricePoint(now, 0.36)],
    sourceLabel: source,
    currency: currency,
    change24hPct: 2.9,
    stale: stale,
  );
}

void _price({String via = 'SigmaUSD oracle', String? staleAge, Map<String, TokenPrice> tokens = const {}}) {
  networkController.fiatCode = 'aud';
  networkController.setErgRate(fiatPerErg: 0.36, usdPerErg: _usdPerErg);
  tokenPricer.result = PricingResult(ergUsd: _usdPerErg, ergVia: via, prices: tokens, ergStaleAge: staleAge);
  tokenPricer.fiatPerUsd = 1.5;
  tokenPricer.displayRateKnown = true;
  tokenPricer.stale = staleAge != null;
}

void main() {
  tearDown(() {
    networkController.fiatCode = 'usd';
    networkController.setErgRate(fiatPerErg: null, usdPerErg: null);
    tokenPricer.result = const PricingResult(ergUsd: null, ergVia: null, prices: {});
    tokenPricer.stale = false;
    tokenPricer.pricesAreOld = false;
    tokenPricer.asOf = null;
    tokenPricer.fiatPerUsd = 1;
    tokenPricer.displayRateKnown = true;
  });

  group('the ERG price', () {
    test('names its source and the currency picked, with the day\'s trend', () {
      _price();
      final view = ergPriceView(_day());
      expect(view.fiatPerErg, 0.36);
      expect(view.source, 'SigmaUSD oracle');
      expect(view.points, [0.35, 0.36]);
      expect(view.changePercent, 2.9);
      expect(view.trendSource, isNull);
      expect(view.staleNote, isNull);
      expect(ergAssetRow(10000000000, view).changePercent, 2.9);
      expect(ergAssetRow(10000000000, view).fiatValue, closeTo(3.6, 1e-9));
    });

    test('a stale rate says how old it is, everywhere it shows', () {
      _price(via: 'SigmaUSD oracle, 3 h old', staleAge: '3 h');
      final view = ergPriceView(_day());
      expect(view.source, 'SigmaUSD oracle', reason: 'the age is said once, on its own');
      expect(view.staleNote, '3 h old');
      expect(pricesNote(), 'prices 3 h old');
      final erg = ergAssetRow(10000000000, view);
      expect(erg.priceNote, '3 h old');
      expect(erg.changePercent, isNull, reason: 'no trend presented as current');
    });

    test('a failed refresh keeps the last price, dated', () {
      _price();
      tokenPricer.stale = true;
      tokenPricer.pricesAreOld = true;
      tokenPricer.asOf = DateTime.now().subtract(const Duration(minutes: 12));
      expect(pricesNote(), 'prices as of 12m ago');
      expect(ergPriceView(null).staleNote, 'as of 12m ago');
    });

    test('a rate the currency cannot be converted to is unknown, never zero', () {
      _price();
      networkController.setErgRate(fiatPerErg: null, usdPerErg: _usdPerErg);
      tokenPricer.displayRateKnown = false;
      final view = ergPriceView(_day());
      expect(view.fiatPerErg, isNull);
      expect(view.hasTrend, isFalse);
      expect(view.historyUnavailable, 'AUD rate not known yet');
      expect(holdingsFiat(1000000000, const []).fiat, isNull);
    });

    test('a chart from another feed than today\'s price says so', () {
      _price(via: 'Dexy USD oracle');
      expect(ergPriceView(_day()).trendSource, 'SigmaUSD oracle');
    });

    test('history in another currency, or out of date, is not charted', () {
      _price();
      expect(ergPriceView(_day(currency: 'usd')).hasTrend, isFalse);
      final old = ergPriceView(_day(stale: true));
      expect(old.hasTrend, isFalse);
      expect(old.historyUnavailable, 'SigmaUSD oracle history is out of date');
    });

    test('why there is no history is said', () {
      _price();
      final view = ergPriceView(const ErgPriceHistory.unavailable(
        window: PriceWindow.day,
        sourceLabel: 'SigmaUSD oracle',
        currency: 'aud',
        reason: 'This node has no price history for SigmaUSD oracle yet.',
      ));
      expect(view.historyUnavailable, 'This node has no price history for SigmaUSD oracle yet');
    });
  });

  group('holdings', () {
    test('ERG and every counted token are valued; the rest are counted as unpriced', () {
      _price(tokens: {
        'peg': const TokenPrice(usd: 1, via: 'USD peg', decimals: 2),
        'pool': const TokenPrice(usd: 5, via: 'Spectrum pool', countsInTotal: false, decimals: 0),
      });
      final value = holdingsFiat(1000000000, const [
        (id: 'peg', amount: 250, decimals: 2),
        (id: 'pool', amount: 1, decimals: 0),
        (id: 'nobody', amount: 1, decimals: 0),
      ]);
      expect(value.fiat, closeTo((_usdPerErg + 2.5) * 1.5, 1e-9));
      expect(value.unpriced, 2, reason: 'one unverified, one unpriced');
    });

    test('a token nothing can scale is shown in raw units and left unvalued', () {
      _price();
      final row = tokenAssetRow(TokenBalance(id: 'd7' * 32, amount: 5000));
      expect(row.decimals, isNull);
      expect(row.fiatValue, isNull);
    });

    test('an LP share is marked by the price the pricer gave it', () {
      _price(tokens: {'lp': const TokenPrice(usd: 3, via: 'Spectrum LP share', decimals: 0)});
      final row = tokenAssetRow(TokenBalance(id: 'lp', amount: 2, name: 'ERG_SigUSD_LP'));
      expect(row.kind, AssetKind.lpShare);
      expect(row.fiatValue, closeTo(9, 1e-9));
    });

    test('a token priced by a stopped feed says how old its price is', () {
      _price(tokens: {
        'gold': const TokenPrice.stale(usd: 0.08, source: 'Dexy gold oracle', age: '22 days', decimals: 0),
      });
      final row = tokenAssetRow(TokenBalance(id: 'gold', amount: 10, name: 'DexyGold'));
      expect(row.priceNote, '22 days old');
    });
  });

  group('activity rows', () {
    final counterparty = '9${'a' * 50}';

    test('are worded as the Activity tab words them', () {
      final row = activityRow({
        'tx_id': 't1',
        'height': 0,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'value_nano_erg': -1500000000,
        'counterparty': counterparty,
        'tokens_sent': [
          {'token_id': 'tok', 'amount': 69},
        ],
      }, id: 't1');
      expect(row.title, 'Sent');
      expect(row.pending, isTrue);
      expect(row.counterparty, 'to 9aaaaa…aaaa');
      expect(row.legs.map((l) => spoken(legText(l))), ['−1.5 ERG', '−69 raw units of tok']);
    });

    test('a stealth receipt names no payer', () {
      final row = activityRow({
        'tx_id': 's1',
        'height': 1500000,
        'timestamp': DateTime(2026, 9, 30, 12).millisecondsSinceEpoch,
        'value_nano_erg': 1000000,
        'stealth': true,
      }, id: 's1');
      expect(row.title, 'Received');
      expect(row.counterparty, 'stealth payment');
      expect(row.pending, isFalse);
    });

    test('a swap leads with what came back', () {
      final row = activityRow({
        'tx_id': 'w1',
        'height': 1500000,
        'timestamp': 0,
        'value_nano_erg': -4200000000,
        'counterparty': 'contract-${'b' * 60}',
        'tokens_received': [
          {'token_id': 'rsv', 'amount': 79},
        ],
      }, id: 'w1');
      expect(row.title, 'Swapped');
      expect(row.counterparty, isNull, reason: 'the pool contract says nothing a person can use');
      expect(row.legs.first.amount, BigInt.from(79));
      expect(row.legs.last.amount, BigInt.from(-4200000000));
      expect(row.time, '');
    });
  });

  group('the price feed', () {
    late _HistoryPricer pricer;
    late NetworkController network;
    late DateTime now;
    late ErgPriceFeed feed;

    setUp(() {
      pricer = _HistoryPricer();
      network = NetworkController(configure: (_, _) async {});
      now = DateTime(2026, 10, 7, 9);
      feed = ErgPriceFeed(pricer: pricer, network: network, clock: () => now)..attach();
    });
    tearDown(() => feed.dispose());

    test('reads when the home screen opens, and again only when it must', () async {
      await Future<void>.delayed(Duration.zero);
      expect(pricer.reads, 1);
      expect(feed.history!.available, isFalse);
      // A notification that changes nothing the price depends on.
      network.setErgRate(fiatPerErg: 0.36, usdPerErg: 0.24);
      await Future<void>.delayed(Duration.zero);
      expect(pricer.reads, 1);
      // A new display currency is a new price.
      network.fiatCode = 'aud';
      pricer.answer = _day();
      network.setErgRate(fiatPerErg: 0.36, usdPerErg: 0.24);
      await Future<void>.delayed(Duration.zero);
      expect(pricer.reads, 2);
      expect(feed.history!.available, isTrue);
      // An available answer stands for the pricer's five minutes.
      now = now.add(const Duration(minutes: 4));
      network.setErgRate(fiatPerErg: 0.36, usdPerErg: 0.24);
      await Future<void>.delayed(Duration.zero);
      expect(pricer.reads, 2);
      now = now.add(const Duration(minutes: 2));
      network.setErgRate(fiatPerErg: 0.36, usdPerErg: 0.24);
      await Future<void>.delayed(Duration.zero);
      expect(pricer.reads, 3);
    });
  });

  group('the wallet page', () {
    final api = HomeApi();
    setUpAll(() => RustLib.initMock(api: api));
    setUp(() async {
      SharedPreferences.setMockInitialValues({'argus_watch_only_addresses': '[]'});
      await watchOnlyService.load();
      watchAccountService.accounts.clear();
      stealthService.scanEnabled = false;
      publicWalletSync.setForeground(false);
    });
    tearDown(() async {
      publicWalletSync.setForeground(true);
      stealthService.scanEnabled = true;
      if (walletService.isUnlocked) await walletService.lock();
    });

    Future<FakeKeystore> openWallet(WidgetTester tester) async {
      final keystore = FakeKeystore(wallets: ['wired-w'])..biometricResult = 'wrap-key';
      keystore.install(tester);
      await tester.runAsync(() => saveWallet('wired-w', name: 'Daily', address0: 'addr0'));
      await pumpHome(tester);
      await tester.tap(find.byKey(const ValueKey('overview-row-seed-wired-w')));
      await tester.pumpAndSettle();
      expect(walletService.isUnlocked, isTrue);
      return keystore;
    }

    testWidgets('More locks the wallet to its gate, with no prompt', (tester) async {
      final keystore = await openWallet(tester);
      expect(keystore.prompts, 1);
      await tester.tap(find.byKey(const Key('wallet-action-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wallet-tool-lock')));
      await tester.pumpAndSettle();
      expect(walletService.isUnlocked, isFalse);
      expect(find.byType(UnlockGate), findsOneWidget);
      expect(keystore.prompts, 1, reason: 'locking is not a reason to ask again');
      await disposeHome(tester);
    });

    testWidgets('More lists every address of the wallet, and one can be named', (tester) async {
      await openWallet(tester);
      await tester.tap(find.byKey(const Key('wallet-action-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wallet-tool-addresses')));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('holding-addr0'));
      expect(find.descendant(of: row, matching: find.text('Shown as this wallet')), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Cold storage');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(addressLabelService.labelFor('addr0'), 'Cold storage');
      expect(find.descendant(of: row, matching: textPlainContaining('Cold storage')), findsOneWidget);
      await tester.runAsync(() => addressLabelService.setLabel('addr0', ''));
      await disposeHome(tester);
    });

    testWidgets('Discover explains a protocol before anything opens', (tester) async {
      await openWallet(tester);
      await tester.tap(find.widgetWithText(NavigationDestination, 'Discover'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Discover'), findsOneWidget);
      await tester.tap(find.byKey(const Key('discover-ageusd')));
      await tester.pumpAndSettle();
      expect(find.text('Open AgeUSD'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await disposeHome(tester);
    });
  });
}
