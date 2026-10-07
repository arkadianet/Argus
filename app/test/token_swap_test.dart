import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/privacy_service.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/ui/assets_screen.dart';
import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:argus_wallet/ui/widgets/token_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Swap from a token's own sheet: offered to a signing wallet for a token
// some pool trades, and opening the swap already paying with it.

final _pooled = 'c' * 64;
final _t2tOnly = 'd' * 64;
final _unpooled = 'e' * 64;

Map<String, dynamic> _n2t(String id) => {
      'pool_id': 'n2t-$id',
      'box_id': 'b-$id',
      'pool_type': 'N2T',
      'erg_reserves': 1000000000000,
      'token_y': {'token_id': id, 'amount': 777000000},
      'fee_num': 997,
      'fee_denom': 1000,
    };

Map<String, dynamic> _t2t(String x, String y) => {
      'pool_id': 't2t-$x-$y',
      'pool_type': 'T2T',
      'erg_reserves': 1000000,
      'token_x': {'token_id': x, 'amount': 1000},
      'token_y': {'token_id': y, 'amount': 1000},
    };

class _PoolApi extends RustLibApi {
  @override
  Future<String> crateApiAmmPools({
    String? nodeUrl,
    required bool forceRefresh,
    String? knownTokensJson,
  }) async =>
      jsonEncode({'truncated': false, 'pools': [_n2t(_pooled)], 'tokens': const {}});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => RustLib.initMock(api: _PoolApi()));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
  });

  group('which assets a pool trades', () {
    test('a token in an ERG pool or a token-to-token pool; ERG only in an ERG pool', () {
      final both = AmmPoolSet(
        truncated: false,
        pools: [_n2t(_pooled), _t2t(_t2tOnly, _pooled)],
        tokens: const {},
      );
      expect(both.trades(_pooled), isTrue);
      expect(both.trades(_t2tOnly), isTrue);
      expect(both.trades(_unpooled), isFalse);
      expect(both.trades(null), isTrue, reason: 'ERG');

      final t2t = AmmPoolSet(truncated: false, pools: [_t2t(_t2tOnly, _pooled)], tokens: const {});
      expect(t2t.trades(null), isFalse, reason: 'ERG in a T2T box is only its storage rent');
    });

    test('hasPool reads the last list saved, and says no with none saved', () async {
      expect(await ammService.hasPool(_pooled), isFalse);
      expect(await ammService.hasPool(null), isFalse);
      await AmmPoolCache.save(AmmPoolSet(truncated: false, pools: [_n2t(_pooled)], tokens: const {}));
      expect(await ammService.hasPool(_pooled), isTrue);
      expect(await ammService.hasPool(null), isTrue);
      expect(await ammService.hasPool(_unpooled), isFalse);
    });
  });

  group('the token sheet', () {
    final token = TokenBalance(id: _pooled, amount: 5, name: 'Pooled', decimals: 0);

    Future<void> sheet(WidgetTester tester, {ValueChanged<TokenBalance>? onSwap, Future<bool>? swappable}) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: TokenDetailSheet(
              token: token,
              explorerUrl: 'https://x',
              onSend: (_) {},
              onSwap: onSwap,
              swappable: swappable,
            ),
          ),
        ));

    testWidgets('offers Swap beside Send when the token has a pool', (tester) async {
      TokenBalance? swapped;
      await sheet(tester, onSwap: (t) => swapped = t, swappable: Future.value(true));
      await tester.pump();
      expect(find.byKey(const Key('token-send')), findsOneWidget);
      expect(find.byKey(const Key('token-swap')), findsOneWidget);
      expect(
        tester.getCenter(find.byKey(const Key('token-swap'))).dy,
        tester.getCenter(find.byKey(const Key('token-send'))).dy,
        reason: 'side by side',
      );
      expect(tester.getSize(find.byKey(const Key('token-swap'))).height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('token-swap')));
      expect(swapped?.id, _pooled);
    });

    testWidgets('no Swap for a token no pool trades', (tester) async {
      await sheet(tester, onSwap: (_) {}, swappable: Future.value(false));
      await tester.pump();
      expect(find.byKey(const Key('token-send')), findsOneWidget);
      expect(find.byKey(const Key('token-swap')), findsNothing);
    });

    testWidgets('no Swap where the wallet cannot sign, pool or not', (tester) async {
      await sheet(tester, swappable: Future.value(true));
      await tester.pump();
      expect(find.byKey(const Key('token-swap')), findsNothing);
    });

    testWidgets('Swap closes the sheet before it opens the swap', (tester) async {
      var swaps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTokenDetailSheet(
                context,
                token: token,
                explorerUrl: 'https://x',
                onSwap: (_) => swaps++,
                swappable: Future.value(true),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('token-swap')));
      await tester.pumpAndSettle();
      expect(swaps, 1);
      expect(find.byType(TokenDetailSheet), findsNothing);
    });
  });

  group('the assets list', () {
    final pooled = TokenBalance(id: _pooled, amount: 5, name: 'Pooled', decimals: 0);

    setUp(() async {
      await privacyService.load();
      walletSyncController.reset();
      walletSyncController.tokens = [pooled];
      walletSyncController.balanceNano = 1000000000;
      await AmmPoolCache.save(AmmPoolSet(truncated: false, pools: [_n2t(_pooled)], tokens: const {}));
    });
    tearDown(walletSyncController.reset);

    Future<void> openPooled(WidgetTester tester, {required bool watchOnly}) async {
      await tester.pumpWidget(MaterialApp(
        home: AssetsScreen(
          args: WalletRouteArgs(
            watchOnly: watchOnly,
            senderAddress: 's',
            receiveAddress: 's',
            changeAddress: 's',
            tokens: [pooled],
          ),
        ),
      ));
      await tester.tap(find.text('Pooled').first);
      await tester.pumpAndSettle();
    }

    testWidgets('a signing wallet can swap a pooled token', (tester) async {
      await openPooled(tester, watchOnly: false);
      expect(find.byKey(const Key('token-swap')), findsOneWidget);
    });

    testWidgets('a watched wallet cannot', (tester) async {
      await openPooled(tester, watchOnly: true);
      expect(find.byType(TokenDetailSheet), findsOneWidget);
      expect(find.byKey(const Key('token-swap')), findsNothing);
    });
  });

  group('the swap screen', () {
    setUp(() => networkController.activeUrl = 'https://node.example');
    tearDown(() => networkController.activeUrl = null);

    Future<void> mount(WidgetTester tester, String? from) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: WalletArgsScope(
          args: WalletRouteArgs(
            senderAddress: 'a',
            receiveAddress: 'a',
            changeAddress: 'a',
            spendableNano: 10000000000,
            tokens: [TokenBalance(id: _pooled, amount: 5000, name: 'Pooled', decimals: 2)],
          ),
          child: SwapScreen(initialFrom: from),
        ),
      ));
      await tester.pumpAndSettle();
    }

    String field(WidgetTester tester, String label) {
      final box = find.ancestor(of: find.text(label), matching: find.byType(InputDecorator)).first;
      return tester
          .widgetList<Text>(find.descendant(of: box, matching: find.byType(Text)))
          .map((t) => t.data)
          .where((d) => d != label)
          .first!;
    }

    testWidgets('opened from a token, it pays with that token for ERG', (tester) async {
      await mount(tester, _pooled);
      expect(field(tester, 'From'), 'Pooled');
      expect(field(tester, 'To'), 'ERG');
      expect(find.text('You pay (Pooled)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opened from ERG, ERG is what it pays with', (tester) async {
      await mount(tester, null);
      expect(field(tester, 'From'), 'ERG');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
