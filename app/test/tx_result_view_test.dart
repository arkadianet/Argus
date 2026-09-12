import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/widgets/tx_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tx_result_harness.dart';

void main() {
  testWidgets('inline receipt selects and copies full ID and maps explorer', (
    tester,
  ) async {
    final harness = TxResultHarness(tester);
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: true),
        home: Scaffold(
          body: Center(
            child: TxResultView(
              txId: resultTxId,
              headline: 'Signed and sent',
              note: 'Submitted to the network',
              warning: 'The dApp could not be notified.',
              onDismiss: () => dismissed = true,
            ),
          ),
        ),
      ),
    );
    await harness.verifyReceipt(tester);
    expect(find.text('The dApp could not be notified.'), findsOneWidget);
    // Resolve at click time through the controller, including host mappings.
    networkController.explorer = 'https://api.ergoplatform.com';
    await tester.tap(find.text('View on explorer'));
    await tester.pump();
    expect(
      harness.launched,
      'https://explorer.ergoplatform.com/en/transactions/$resultTxId',
    );
    await tester.tap(find.text('Done'));
    expect(dismissed, isTrue);
  });

  testWidgets('sheet persists and dismisses back to working screen', (
    tester,
  ) async {
    final harness = TxResultHarness(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTxResultSheet(
                context,
                txId: resultTxId,
                headline: 'Recovery submitted',
              ),
              child: const Text('Working screen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Working screen'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 2));
    expect(find.text('Recovery submitted'), findsOneWidget);
    await harness.verifyReceipt(tester);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(TxResultView), findsNothing);
    expect(find.text('Working screen'), findsOneWidget);
  });

  testWidgets('receipt scrolls on a small screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = TxResultHarness(tester);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: TxResultView(
              txId: resultTxId,
              headline: 'Recovery submitted',
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await harness.verifyReceipt(tester);
    await tester.ensureVisible(find.text('Done'));
    expect(tester.takeException(), isNull);
  });
}
