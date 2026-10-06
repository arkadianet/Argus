import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/deep_link_controller.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/home/overview_screen.dart';
import 'package:argus_wallet/ui/transactions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_harness.dart';

// A tapped notification or an ErgoPay link parks until a wallet is
// unlocked: the overview says why nothing happened yet, and the link opens
// over the wallet's page once it can.
void main() {
  final api = HomeApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({'argus_watch_only_addresses': '[]'});
    await watchOnlyService.load();
    watchAccountService.accounts.clear();
    stealthService.scanEnabled = false;
    publicWalletSync.setForeground(false);
    deepLinkController.take();
  });
  tearDown(() async {
    deepLinkController.take();
    publicWalletSync.setForeground(true);
    stealthService.scanEnabled = true;
    if (walletService.isUnlocked) await walletService.lock();
  });

  Future<FakeKeystore> launch(WidgetTester tester) async {
    final keystore = FakeKeystore(wallets: ['link-w'])..biometricResult = 'wrap-key';
    keystore.install(tester);
    await tester.runAsync(() => saveWallet('link-w', name: 'Daily', address0: 'addr0'));
    await pumpHome(tester);
    return keystore;
  }

  testWidgets('a notification waits for an unlock, then opens the activity it is about', (tester) async {
    await launch(tester);
    deepLinkController.push('argus://activity');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(OverviewNotice),
        matching: find.text('Unlock a wallet to open what the notification is about.'),
      ),
      findsOneWidget,
    );
    expect(deepLinkController.pending, 'argus://activity', reason: 'parked, not dropped');

    await tester.tap(find.byKey(const ValueKey('overview-row-seed-link-w')));
    await tester.pumpAndSettle();
    expect(walletService.isUnlocked, isTrue);
    expect(deepLinkController.pending, isNull);
    expect(find.byType(TransactionsScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Activity'), findsOneWidget, reason: 'the Activity tab, not the Wallet tab');
    await disposeHome(tester);
  });

  testWidgets('an ErgoPay link says it needs a wallet unlocked', (tester) async {
    await launch(tester);
    deepLinkController.push('ergopay://example.com/request');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(OverviewNotice),
        matching: find.text('Unlock a wallet to continue with the ErgoPay request.'),
      ),
      findsOneWidget,
    );
    await disposeHome(tester);
  });
}
