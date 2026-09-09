import 'package:argus_wallet/services/amm_service.dart';
import 'package:argus_wallet/ui/liquidity_screen.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('pool progress stays with its owner and legacy data is preserved', () async {
    SharedPreferences.setMockInitialValues({'argus_pool_creation_v1': '{"pair":"old"}'});
    final a = PoolCreationStore('a');
    final b = PoolCreationStore('b');
    await a.save({'pair': 'A'});
    expect((await a.load())?['pair'], 'A');
    expect(await b.load(), isNull);
    await b.save({'pair': 'B'});
    await a.save(null);
    expect((await b.load())?['pair'], 'B');
    expect(await a.hasLegacy(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('argus_pool_creation_v1'), '{"pair":"old"}');
  });

  test('the legacy record can be discarded so pool creation is possible again', () async {
    SharedPreferences.setMockInitialValues({'argus_pool_creation_v1': '{"pair":"old"}'});
    final store = PoolCreationStore('a');
    await store.save({'pair': 'A'});
    expect(await store.hasLegacy(), isTrue);
    await store.discardLegacy();
    expect(await store.hasLegacy(), isFalse);
    expect((await store.load())?['pair'], 'A', reason: 'this wallet keeps its own progress');
  });

  testWidgets('capped pool discovery explains missing positions', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(home: LiquidityScreen(
      readPools: (_) async => const AmmPoolSet(truncated: true, pools: [], tokens: {}),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Some pools and your positions may be missing'), findsOneWidget);
    expect(find.textContaining('the list is what Spectrum has today'), findsNothing);
  });

  testWidgets('forgetting pool progress requires explicit confirmation', (tester) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: true),
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () async => answer = await confirmForgetPool(context),
        child: const Text('Forget'),
      ))),
    ));
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(answer, isNull);
    expect(find.textContaining('does not cancel or refund'), findsOneWidget);
    await tester.tap(find.text('Keep progress'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete progress'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });
}
