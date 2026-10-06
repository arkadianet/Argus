import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/services/token_catalog.dart';
import 'package:argus_wallet/services/token_descriptor_store.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/liquidity_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _known = 'aa' * 32;
final _unknown = '6d' * 32;

Map<String, dynamic> _pool(String id, String token, String lp) => {
  'pool_id': id,
  'pool_type': 'N2T',
  'lp_token_id': lp,
  'lp_circulating': '2000',
  'erg_reserves': '1000000000000',
  'token_y': {'token_id': token, 'amount': '349670571986'},
  'fee_num': 997,
  'fee_denom': 1000,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    publicTokenCatalog.debugReset();
  });

  Future<void> show(WidgetTester tester) async {
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
            // Half of the known pool's LP supply.
            tokens: [TokenBalance(id: 'lp-known', amount: 1000)],
          ),
          child: LiquidityScreen(
            readPools: (_) async => AmmPoolSet(
              truncated: false,
              pools: [
                _pool('known', _known, 'lp-known'),
                _pool('unknown', _unknown, 'lp-unknown'),
              ],
              tokens: const {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('pools are titled and scaled from the token lookup', (
    tester,
  ) async {
    publicTokenCatalog.debugSeed([
      CachedDescriptor(id: _known, name: 'Pooled', decimals: 6),
    ]);
    await show(tester);

    expect(find.text('ERG / Pooled'), findsOneWidget);
    expect(
      find.text('500 ERG + 174,835.285993 Pooled'),
      findsOneWidget,
      reason: 'Worth applies the decimals once they are known',
    );
    expect(find.text('1,000 ERG · 349,670.571986 Pooled'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unknown pool token says its reserves are raw units', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('ERG / 6d6d6d6d…'), findsOneWidget);
    expect(
      find.text('1,000 ERG · 349,670,571,986 raw units of 6d6d6d6d…'),
      findsOneWidget,
      reason: 'base units are not passed off as whole tokens',
    );
    expect(tester.takeException(), isNull, reason: 'and the row wraps');
  });

  testWidgets('a scale learned under typed pool reserves keeps their units', (
    tester,
  ) async {
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
            tokens: [TokenBalance(id: _unknown, amount: 5000)],
          ),
          child: LiquidityScreen(
            readPools: (_) async =>
                const AmmPoolSet(truncated: false, pools: [], tokens: {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a pool'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pool-y')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('6d6d6d6d…').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('In raw units'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pool-y-amount')), '150');
    await tester.pump();

    publicTokenCatalog.debugSeed([
      CachedDescriptor(id: _unknown, name: 'Named', decimals: 2),
    ]);
    await tester.pump();
    expect(find.text('1.5'), findsOneWidget,
        reason: 'the reserves typed are the reserves confirmed');
    expect(find.textContaining('In raw units'), findsNothing);
  });

  testWidgets('a name learned while the screen is open shows at once', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('ERG / aaaaaaaa…'), findsOneWidget);
    publicTokenCatalog.debugSeed([
      CachedDescriptor(id: _known, name: 'Pooled', decimals: 6),
    ]);
    walletService.metadataChanges.value++;
    await tester.pump();
    expect(find.text('ERG / Pooled'), findsOneWidget);
  });
}
