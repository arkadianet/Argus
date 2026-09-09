import 'package:argus_wallet/services/duckpools_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/duckpools_screen.dart';
import 'package:argus_wallet/ui/liquidity_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const loan = DuckLoan(pool: 'sigusd', ticker: 'SigUSD', decimals: 2,
    boxId: 'loan', collateralNano: 1000000000000, collateralAmount: 1000000000000,
    loan: 10000, owed: 10100, collateralValue: 20000, threshold: 1400,
    penalty: 400, healthBps: 18000, liquidationValue: 15000,
    liquidatable: false, forcedLiquidationHeight: 2000000);
  const pool = DuckPoolState(pool: 'sigusd', ticker: 'SigUSD', decimals: 2,
    lendToken: 'lend', boxId: 'pool', pooled: 1000000, borrowed: 10000,
    lendCirculating: 100000, utilisationBps: 100, lendTokenPrice: 1,
    walletLendTokens: 100000, walletValue: 100000);
  final liquidity = LiquidityPool({
    'pool_id': 'p', 'pool_type': 'N2T', 'lp_token_id': 'lp',
    'lp_circulating': '100000', 'erg_reserves': '100000000000',
    'token_y': {'token_id': 'token', 'amount': '100000'},
  }, {});
  final sheets = <String, Widget Function()>{
    'add liquidity': () => liquidityAddSheetForTest(liquidity, const WalletRouteArgs(
      senderAddress: 'a', receiveAddress: 'a', changeAddress: 'a', spendableNano: 10000000000)),
    'lend': () => duckOrderSheetForTest(pool, 'lend'),
    'withdraw': () => duckOrderSheetForTest(pool, 'withdraw'),
    'repay': () => duckRepaySheetForTest(loan),
    'collateral': () => duckAdjustSheetForTest(loan),
  };
  for (final entry in sheets.entries) {
    for (final dark in [true, false]) {
      testWidgets('${entry.key} scrolls above a keyboard at 1.6x ($dark)', (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          theme: argusTheme(watchful: dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.6), viewInsets: const EdgeInsets.only(bottom: 300)),
            child: child!,
          ),
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => showModalBottomSheet<void>(context: context,
              isScrollControlled: true, builder: (_) => entry.value()),
            child: const Text('Open'),
          ))),
        ));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (entry.key == 'lend') {
          await tester.enterText(find.byKey(const Key('duck-amount')), '1.001');
          await tester.pump();
          final error = tester.widget<SelectableText>(find.byType(SelectableText));
          expect(error.data, contains('decimal places'));
          final color = error.style!.color!;
          final surface = argusTheme(watchful: dark).colorScheme.surface;
          final a = color.computeLuminance();
          final b = surface.computeLuminance();
          expect(((a > b ? a : b) + .05) / ((a > b ? b : a) + .05), greaterThan(4.5));
        }
        await tester.scrollUntilVisible(find.text('Continue'), 150,
          scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
        expect(tester.getBottomRight(find.text('Continue')).dy, lessThan(340));
      });
    }
  }
}
