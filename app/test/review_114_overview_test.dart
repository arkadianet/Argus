import 'dart:async';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/wallets_overview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_114_test.dart' show ReviewApi;

void main() {
  final api = ReviewApi();
  const channel = MethodChannel('com.argus.wallet/secure_storage');
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('114.5 overview refresh waits for inactive public balances', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'listWalletIds' ? ['overview'] : null,
    );
    await tester.runAsync(
      () => walletService.saveWalletInfo(
        'overview',
        name: 'Overview',
        createdAt: DateTime(2026),
        address0: 'b',
      ),
    );
    publicWalletSync.setForeground(false);
    await walletService.restoreWallet('', walletId: 'active');
    addTearDown(() async {
      publicWalletSync.setForeground(true);
      await walletService.lock();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: WalletOverviewScreen(initializeWalletService: () async {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Overview'),
      findsWidgets,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .toList()
          .toString(),
    );
    expect(walletService.isUnlocked, isTrue);
    publicWalletSync.setForeground(true);
    api.balanceGate = Completer<String>();
    var completed = false;
    final work = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh()
        .then((_) => completed = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.balanceCalls, 1);
    final completedBeforeBalance = completed;
    api.balanceGate!.complete('{"balance_nano_erg":7000000000,"tokens":[]}');
    for (var i = 0; i < 50 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(completed, isTrue);
    await work;
    expect(completedBeforeBalance, isFalse);
    expect(completed, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
