import 'dart:convert';

import 'package:argus_wallet/bridge/argus_error.dart';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/utxo_management_screen.dart';
import 'package:argus_wallet/ui/widgets/tx_result_view.dart';
import 'package:argus_wallet/ui/widgets/tx_batch_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/tx_result_harness.dart';

class UtxoResultApi extends RustLibApi {
  int submissions = 0;
  int? failAt;
  final preparedKinds = <String>[];

  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}

  String preview(String kind) {
    preparedKinds.add(kind);
    return jsonEncode({
      'preparation_id': 1,
      'input_count': 2,
      'total_erg_in': 10000000000,
      'change_nano_erg': 7997800000,
      'token_count': 0,
      'miner_fee': 1100000,
      'split_count': 2,
      'amount_per_box': 1000000000,
      'total_split': 2000000000,
      'output_count': 2,
      'allocated_erg': 2000000000,
      'has_change': true,
    });
  }

  @override
  Future<String> crateApiPrepareConsolidate({
    required BigInt handleId,
    required List<String> spendAddresses,
    required List<String> selectedBoxIds,
    required String changeAddress,
    String? nodeUrl,
    PlatformInt64? feeNano,
  }) async => preview('consolidate');
  @override
  Future<String> crateApiPrepareSplitErg({
    required BigInt handleId,
    required List<String> spendAddresses,
    required List<String> selectedBoxIds,
    required int count,
    required PlatformInt64 amountPerBoxNano,
    required String changeAddress,
    String? nodeUrl,
    PlatformInt64? feeNano,
  }) async => preview('split');
  @override
  Future<String> crateApiPrepareRestructure({
    required BigInt handleId,
    required List<String> spendAddresses,
    required List<String> selectedBoxIds,
    required String outputsJson,
    required String changeAddress,
    String? nodeUrl,
    PlatformInt64? feeNano,
  }) async => preview('restructure');
  @override
  Future<String> crateApiSendErg({
    required BigInt handleId,
    required BigInt preparationId,
  }) async {
    submissions++;
    if (submissions == failAt)
      throw ArgusException(code: 'NODE_ERROR', message: 'Connection lost');
    return jsonEncode({
      'tx_id': submissions == 1
          ? resultTxId
          : submissions.toRadixString(16).padLeft(64, '0'),
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late UtxoResultApi api;
  String? previousNode;
  setUpAll(() {
    api = UtxoResultApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api.submissions = 0;
    api.failAt = null;
    api.preparedKinds.clear();
    previousNode = networkController.activeUrl;
    networkController.activeUrl = 'https://node.invalid';
    await walletService.restoreWallet('mock', walletId: 'utxo-result-test');
  });
  tearDown(() async {
    networkController.activeUrl = previousNode;
    await walletService.lock();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: argusTheme(watchful: true),
        home: const WalletArgsScope(
          args: WalletRouteArgs(
            senderAddress: 'wallet',
            receiveAddress: 'wallet',
            changeAddress: 'wallet',
            historyAddresses: ['wallet'],
          ),
          child: UtxoManagementScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  MockClient boxes(int count) => MockClient((request) async {
    expect(request.url.host, 'node.invalid');
    final offset = int.parse(request.url.queryParameters['offset']!);
    return http.Response(
      jsonEncode(
        List.generate(
          count,
          (i) => {
            'boxId': i.toRadixString(16).padLeft(64, '0'),
            'value': 5000000000,
            'creationHeight': 100,
            'assets': [],
          },
        ).skip(offset).take(100).toList(),
      ),
      200,
    );
  });

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  for (final flow in ['Consolidate', 'Split', 'Restructure']) {
    testWidgets(
      '$flow submission keeps a selectable receipt and mapped explorer',
      (tester) async {
        await http.runWithClient(() async {
          final harness = TxResultHarness(tester);
          await open(tester);
          await tap(tester, flow);
          if (flow == 'Split') await tap(tester, 'Preview split');
          if (flow == 'Restructure') await tap(tester, 'Preview Restructure');
          await tap(
            tester,
            flow == 'Consolidate'
                ? 'Sign & broadcast'
                : 'Sign & broadcast ${flow.toLowerCase()}',
          );
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpAndSettle();
          expect(api.submissions, 1);
          expect(api.preparedKinds, [flow.toLowerCase()]);
          expect(find.byType(SnackBar), findsNothing);
          await tester.pump(const Duration(minutes: 2));
          expect(find.byType(TxResultView), findsOneWidget);
          expect(
            find.text(
              '${flow == 'Consolidate' ? 'Consolidation' : flow} submitted',
            ),
            findsOneWidget,
          );
          await harness.verifyReceipt(tester);
          expect(harness.launched, networkController.explorerTx(resultTxId));
          await tap(tester, 'Done');
          expect(find.byType(TxResultView), findsNothing);
        }, () => boxes(2));
      },
    );
  }

  testWidgets(
    'multi-batch receipt lists every successful selectable and linkable ID',
    (tester) async {
      await http.runWithClient(() async {
        final harness = TxResultHarness(tester);
        await open(tester);
        await tap(tester, 'Consolidate');
        await tap(tester, 'Sign & broadcast 3');
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(api.submissions, 3);
        expect(find.text('3 of 3 transactions submitted'), findsOneWidget);
        expect(find.textContaining('Stopped early'), findsNothing);
        await tester.pump(const Duration(minutes: 2));
        for (final id in [
          resultTxId,
          '2'.padLeft(64, '0'),
          '3'.padLeft(64, '0'),
        ]) {
          await verifyBatchId(tester, harness, id);
        }
        await tap(tester, 'Done');
        await tester.tap(find.byTooltip('Last consolidation result'));
        await tester.pumpAndSettle();
        expect(find.byType(TxBatchResultView), findsOneWidget);
        await tap(tester, 'Done');
      }, () => boxes(202));
    },
  );

  testWidgets(
    'partial consolidation retains successful IDs and uncertain broadcast warning',
    (tester) async {
      api.failAt = 2;
      await http.runWithClient(() async {
        final harness = TxResultHarness(tester);
        await open(tester);
        await tap(tester, 'Consolidate');
        await tap(tester, 'Sign & broadcast 2');
        expect(api.submissions, 2);
        expect(find.byType(TxResultView), findsNothing);
        expect(find.byType(TxBatchResultView), findsOneWidget);
        expect(
          find.textContaining('Broadcast may have failed'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Stopped early after 1 of 2'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Check Activity before retrying'),
          findsOneWidget,
        );
        await tester.pump(const Duration(minutes: 2));
        await verifyBatchId(tester, harness, resultTxId);
        await tap(tester, 'Done');
        await tester.tap(find.byTooltip('Last consolidation result'));
        await tester.pumpAndSettle();
        expect(find.text('1 of 2 transactions submitted'), findsOneWidget);
        await tap(tester, 'Done');
      }, () => boxes(102));
    },
  );
}

Future<void> verifyBatchId(
  WidgetTester tester,
  TxResultHarness harness,
  String id,
) async {
  expect(
    find.byWidgetPredicate((w) => w is SelectableText && w.data == id),
    findsOneWidget,
  );
  final copy = find.byKey(ValueKey('copy-$id'));
  await tester.ensureVisible(copy);
  await tester.tap(copy);
  await tester.pump();
  expect(harness.copied, id);
  final explorer = find.byKey(ValueKey('explorer-$id'));
  await tester.ensureVisible(explorer);
  await tester.tap(explorer);
  await tester.pump();
  expect(harness.launched, networkController.explorerTx(id));
}
