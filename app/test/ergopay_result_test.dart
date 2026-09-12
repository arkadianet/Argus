import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:argus_wallet/services/ergopay_service.dart';

import 'package:argus_wallet/bridge/argus_error.dart';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/ergopay_screen.dart';
import 'package:argus_wallet/ui/widgets/tx_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/tx_result_harness.dart';

/// Mock mode never loads native libraries or contacts a node.
class ErgoPayApi extends RustLibApi {
  int submissions = 0;
  Object? submitError;
  Completer<void>? submitGate;

  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;

  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  @override
  Future<String> crateApiDescribeReducedTransaction({
    required BigInt handleId,
    required List<int> reducedTxBytes,
    String? nodeUrl,
  }) async => jsonEncode({
    'tx_id': resultTxId,
    'inputs_known': true,
    'all_inputs_owned': true,
    'fee_nano_erg': 1000000,
    'outputs': [],
  });

  @override
  Future<String> crateApiSignReducedTransaction({
    required BigInt handleId,
    required List<int> reducedTxBytes,
  }) async => '{"id":"$resultTxId"}';

  @override
  Future<String> crateApiSubmitSignedTransaction({
    required String txJson,
    String? nodeUrl,
  }) async {
    submissions++;
    await submitGate?.future;
    if (submitError != null) throw submitError!;
    return resultTxId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ErgoPayApi api;
  setUpAll(() {
    api = ErgoPayApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api.submissions = 0;
    api.submitError = null;
    api.submitGate = null;
    await walletService.restoreWallet('mock', walletId: 'result-test');
  });
  tearDown(() async {
    await walletService.lock();
  });

  Future<void> reviewAndSubmit(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Review & sign'));
    await tester.tap(find.text('Review & sign'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign & broadcast'));
    await tester.tap(find.text('Sign & broadcast'));
    // The signing spinner remains behind a failure sheet until it is closed.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('ErgoPay submits into shared receipt and Done returns full ID', (
    tester,
  ) async {
    final harness = TxResultHarness(tester);
    String? returned;
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                returned = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ErgoPayScreen(link: 'ergopay:AAEC'),
                  ),
                );
              },
              child: const Text('Open ErgoPay'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open ErgoPay'));
    await tester.pumpAndSettle();
    await reviewAndSubmit(tester);
    expect(api.submissions, 1);
    expect(find.byType(TxResultView), findsOneWidget);
    expect(find.text('Signed and sent'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    await harness.verifyReceipt(tester);
    expect(harness.launchArguments!['useSafariVC'], isFalse);
    expect(harness.launchArguments!['useWebView'], isFalse);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(returned, resultTxId);
    expect(find.text('Open ErgoPay'), findsOneWidget);
  });

  testWidgets('covered ErgoPay route finishes after receipt dismissal', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    api.submitGate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: argusTheme(watchful: true),
        home: const ErgoPayScreen(link: 'ergopay:AAEC'),
      ),
    );
    await tester.pumpAndSettle();
    await reviewAndSubmit(tester);
    expect(api.submissions, 1);
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other screen')),
      ),
    );
    await tester.pumpAndSettle();
    api.submitGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Signed and sent'), findsOneWidget);
    expect(find.text(resultTxId), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Other screen'), findsOneWidget);
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Signed and sent'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('callback failure warns on successful ErgoPay receipt', (
    tester,
  ) async {
    var replies = 0;
    final client = ErgoPayClient(
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'reducedTx': 'AAEC',
              'replyTo': 'https://dapp.invalid/callback',
            }),
            200,
          );
        }
        replies++;
        expect(request.url.toString(), 'https://dapp.invalid/callback');
        expect(jsonDecode(request.body), {'txId': resultTxId});
        return http.Response('unavailable', 503);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: true),
        home: ErgoPayScreen(
          link: 'ergopay://dapp.invalid/request',
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reviewAndSubmit(tester);
    expect(api.submissions, 1);
    expect(replies, 1);
    final receipt = tester.widget<TxResultView>(find.byType(TxResultView));
    expect(receipt.txId, resultTxId);
    expect(receipt.warning, contains('503'));
    expect(find.text('Signed and sent'), findsOneWidget);
    expect(find.text('Broadcast may have failed'), findsNothing);
  });

  testWidgets(
    'Activity update failure cannot turn an acknowledged broadcast into failure',
    (tester) async {
      final previous = walletService.onBroadcast;
      walletService.onBroadcast = (_, _) =>
          throw StateError('Activity update failed');
      addTearDown(() => walletService.onBroadcast = previous);
      await tester.pumpWidget(
        MaterialApp(
          theme: argusTheme(watchful: true),
          home: const ErgoPayScreen(link: 'ergopay:AAEC'),
        ),
      );
      await tester.pumpAndSettle();
      await reviewAndSubmit(tester);
      expect(api.submissions, 1);
      expect(find.byType(TxResultView), findsOneWidget);
      expect(find.text(resultTxId), findsOneWidget);
      expect(find.textContaining('Activity update failed'), findsOneWidget);
      expect(find.text('Broadcast may have failed'), findsNothing);
    },
  );

  testWidgets('ErgoPay uncertain submission shows Activity guidance', (
    tester,
  ) async {
    api.submitError = ArgusException(
      code: 'NODE_ERROR',
      message: 'Connection lost',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: true),
        home: const ErgoPayScreen(link: 'ergopay:AAEC'),
      ),
    );
    await tester.pumpAndSettle();
    await reviewAndSubmit(tester);
    expect(api.submissions, 1);
    expect(find.byType(TxResultView), findsNothing);
    expect(find.text('Broadcast may have failed'), findsOneWidget);
    expect(
      find.textContaining('Check Activity before retrying'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Review & sign'), findsOneWidget);
  });
}
