import 'dart:convert';

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
