import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _token = 'e91cbc48${'b' * 56}';

class QuoteApi extends RustLibApi {
  final List<int> quoted = [];

  @override
  Future<String> crateApiAmmPools({
    String? nodeUrl,
    required bool forceRefresh,
    String? knownTokensJson,
  }) async => jsonEncode({
    'truncated': false,
    'pools': [
      {
        'pool_id': 'p',
        'box_id': 'b',
        'pool_type': 'N2T',
        'erg_reserves': 1000000000000,
        'token_y': {'token_id': _token, 'amount': 777000000},
        'fee_num': 997,
        'fee_denom': 1000,
      },
    ],
    'tokens': const {},
  });

  @override
  Future<String> crateApiAmmQuote({
    String? fromToken,
    String? toToken,
    required PlatformInt64 amount,
    String? nodeUrl,
  }) async {
    quoted.add(amount);
    return jsonEncode({
      'pool_id': 'p',
      'box_id': 'b',
      'output_amount': 190000,
      'output_token': '',
      'min_output': 189000,
      'price_impact_pct': 0.01,
      'fee_amount': 1,
      'quote_tolerance_pct': 0.5,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = QuoteApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
    api.quoted.clear();
    networkController.activeUrl = 'https://node.example';
  });
  tearDown(() => networkController.activeUrl = null);

  testWidgets(
    'a scale learned under a typed figure keeps the base units it stood for',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: WalletArgsScope(
            args: WalletRouteArgs(
              senderAddress: 'a',
              receiveAddress: 'a',
              changeAddress: 'a',
              spendableNano: 10000000000,
              tokens: [TokenBalance(id: _token, amount: 5000)],
            ),
            child: const SwapScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Pay with the token nothing has described yet.
      await tester.tap(find.text('From'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'e91c');
      await tester.pumpAndSettle();
      await tester.tap(find.text('e91cbc48…').last);
      await tester.pumpAndSettle();
      expect(find.text('You pay (raw units of e91cbc48…)'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '150');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(api.quoted.last, 150, reason: '150 raw units');

      // The catalog learns the token has two decimals while 150 sits there.
      publicTokenCatalog.debugSeed([
        CachedDescriptor(
          id: _token,
          name: 'Named',
          decimals: 2,
          decimalsEvidence: DecimalsEvidence.valid,
        ),
      ]);
      await tester.pump();
      expect(find.text('1.5'), findsOneWidget,
          reason: 'rewritten in the new scale, not reread as 150 tokens');
      expect(find.text('You pay (Named)'), findsOneWidget);
      expect(find.text('Review swap'), findsOneWidget);
      final review = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review swap'),
      );
      expect(review.onPressed, isNull,
          reason: 'the old quote was for the old reading');

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(api.quoted.last, 150,
          reason: 'quoted again for the same base units');

      await tester.pumpWidget(const SizedBox());
    },
  );
}
