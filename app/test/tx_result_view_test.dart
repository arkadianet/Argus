import 'dart:async';
import 'package:argus_wallet/ui/widgets/error_sheet.dart';
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

  for (final fullyDisposed in [false, true]) {
    testWidgets('late receipt survives Back: disposed=$fullyDisposed', (
      tester,
    ) async {
      final broadcast = Completer<String>();
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: Text('Previous screen')),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => _BroadcastScreen(broadcast: broadcast.future),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Broadcast'));
      nav.currentState!.pop();
      if (fullyDisposed) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
      broadcast.complete(resultTxId);
      await tester.pumpAndSettle();
      expect(find.text(resultTxId), findsOneWidget);
      expect(find.text('Recovery submitted'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Previous screen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'repeated completions queue one modal and return IDs immediately',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              return const Scaffold(body: Text('Browser'));
            },
          ),
        ),
      );
      Future<String> submit(String id) async {
        showTxResultSheet(
          context,
          txId: id,
          headline: 'dApp transaction submitted',
        );
        return id;
      }

      final ids = await Future.wait([
        submit('first'),
        submit('second'),
        submit('third'),
      ]);
      expect(ids, ['first', 'second', 'third']);
      queueTxPresentation(
        context,
        (ctx) => showTxFailureSheet(ctx, StateError('node unavailable')),
      );
      await tester.pumpAndSettle();
      for (final id in ids) {
        expect(find.byType(TxResultView, skipOffstage: false), findsOneWidget);
        expect(find.text(id), findsOneWidget);
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Broadcast may have failed'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Browser'), findsOneWidget);
    },
  );

  testWidgets(
    'post-broadcast write failure is a warning with the acknowledged ID',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              return const Scaffold();
            },
          ),
        ),
      );
      final warning = await txBookkeeping(
        () async => throw StateError('disk full'),
      );
      showTxResultSheet(
        context,
        txId: resultTxId,
        headline: 'Pool creation submitted',
        warning: warning,
      );
      await tester.pumpAndSettle();
      expect(find.text(resultTxId), findsOneWidget);
      expect(find.textContaining('disk full'), findsOneWidget);
      expect(find.text('Broadcast may have failed'), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    },
  );

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

class _BroadcastScreen extends StatefulWidget {
  const _BroadcastScreen({required this.broadcast});
  final Future<String> broadcast;
  @override
  State<_BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<_BroadcastScreen>
    with TxReceiptOwner {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () async {
        final id = await widget.broadcast;
        showTxResultSheet(
          receiptContext,
          txId: id,
          headline: 'Recovery submitted',
        );
      },
      child: const Text('Broadcast'),
    ),
  );
}
