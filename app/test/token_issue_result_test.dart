import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/token_tools_screen.dart';
import 'package:argus_wallet/ui/widgets/tx_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/tx_result_harness.dart';

const tokenId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class TokenIssueResultApi extends RustLibApi {
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.one;
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) async {}
  @override
  Future<String> crateApiPrepareMint({
    required BigInt handleId,
    required String senderAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    required String name,
    required String description,
    required int decimals,
    required BigInt amount,
    String? nftKind,
    String? nftContentHashHex,
    String? nftUrl,
    String? nodeUrl,
    PlatformInt64? feeNano,
  }) async => jsonEncode({
    'preparation_id': 1,
    'token_id': tokenId,
    'box_value': 1000000,
    'miner_fee': 1100000,
  });
  @override
  Future<String> crateApiSendErg({
    required BigInt handleId,
    required BigInt preparationId,
  }) async => jsonEncode({'tx_id': resultTxId});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => RustLib.initMock(api: TokenIssueResultApi()));
  tearDownAll(RustLib.dispose);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await walletService.restoreWallet('mock', walletId: 'token-result-test');
  });
  tearDown(() => walletService.lock());

  testWidgets(
    'issuance retains distinct token and transaction IDs with a persistent receipt',
    (tester) async {
      final harness = TxResultHarness(tester);
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
            child: TokenToolsScreen(),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('issue-name')),
        'Receipt token',
      );
      await tester.enterText(find.byKey(const Key('issue-amount')), '100');
      await tester.pump();
      final issue = find.widgetWithText(FilledButton, 'Issue');
      await tester.ensureVisible(issue);
      await tester.pumpAndSettle();
      await tester.tap(issue);
      await tester.pumpAndSettle();
      await tester.ensureVisible(issue.last);
      await tester.tap(issue.last);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(minutes: 2));
      expect(find.byType(TxResultView), findsOneWidget);
      await harness.verifyReceipt(tester);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Token ID'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == tokenId),
        findsOneWidget,
      );
      expect(find.text('Transaction ID'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == resultTxId,
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('View transaction receipt'));
      await tester.tap(find.text('View transaction receipt'));
      await tester.pumpAndSettle();
      expect(find.byType(TxResultView), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
