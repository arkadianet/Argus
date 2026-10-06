import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/address_label_service.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/home/unlock_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dialog_harness.dart';
import 'support/home_harness.dart';
import 'support/render_harness.dart';

// The home screen's dialogs that ask for text or a PIN, answered both ways
// and pumped through their exit animation (see support/dialog_harness.dart).
//
// A file of its own: these record the wallet with saveWallet under
// runAsync, as the home tests do, and a wallet-metadata write the fake clock
// makes later in the same isolate (pinning an address index) would queue
// behind that one and never run.

void main() {
  final api = DialogApi();
  setUpAll(() async {
    RustLib.initMock(api: api);
    // The home is laid out for the app's fonts, as on a phone; the test
    // font's square glyphs overflow it.
    await loadAppFonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': '[]',
      'argus_address_labels': '[]',
    });
    await watchOnlyService.load();
    watchAccountService.accounts.clear();
    await addressLabelService.load();
    stealthService.scanEnabled = false;
    // Snapshot figures stay as they are: no public refresh in these tests.
    publicWalletSync.setForeground(false);
    api.wrappedUnder.clear();
  });

  tearDown(() async {
    publicWalletSync.setForeground(true);
    stealthService.scanEnabled = true;
    if (walletService.isUnlocked) await walletService.lock();
  });

  Future<void> openWallet(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('overview-row-seed-$dialogWallet')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Set a PIN (unlocking a wallet from before PINs): Later, '
      'then Save', (tester) async {
    final keystore = DialogKeystore(pin: false, wrapKey: true)
      ..install(tester);
    await tester.runAsync(() => saveWallet(dialogWallet, name: 'Daily'));
    await pumpHome(tester);

    Future<void> unlock() async {
      await openWallet(tester);
      await tester.tap(find.text('Unlock and set PIN'));
      // The gate's button spins while the dialog is up, so this pumps a
      // while rather than to settle.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Set a PIN'), findsOneWidget);
      await tester.enterText(dialogField('PIN'), '246810');
      await tester.enterText(dialogField('Confirm PIN'), '246810');
    }

    await unlock();
    await answer(tester, 'Later');
    expect(walletService.isUnlocked, isTrue);
    expect(find.byType(UnlockGate), findsNothing);
    expect(api.wrappedUnder, isEmpty);
    expect(keystore.pin, isFalse);

    // Locked again, the wallet asks again, and this time the PIN is set.
    await tester.pumpWidget(const SizedBox());
    await walletService.lock();
    await pumpHome(tester);
    await unlock();
    await answer(tester, 'Save');
    expect(walletService.isUnlocked, isTrue);
    expect(api.wrappedUnder, ['246810']);
    expect(keystore.writes, ['savePinWrap', 'deleteWrapKey']);
    expect(keystore.pin, isTrue);
    await disposeHome(tester);
  });

  testWidgets('Address label (wallet page, More, Addresses): Cancel, then '
      'Save', (tester) async {
    // A PIN and no biometric key: the gate asks for the PIN.
    DialogKeystore().install(tester);
    await tester.runAsync(
      () => saveWallet(dialogWallet, name: 'Daily', address0: 'addr0'),
    );
    await pumpHome(tester);
    await openWallet(tester);
    await tester.enterText(find.byType(TextField), api.goodPin);
    await tester.tap(find.byKey(const Key('gate-unlock-pin')));
    await tester.pumpAndSettle();
    expect(walletService.isUnlocked, isTrue);

    await tester.tap(find.byKey(const Key('wallet-action-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wallet-tool-addresses')));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('holding-addr0'));

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.enterText(dialogField(), 'Savings');
    await answer(tester, 'Cancel');
    expect(addressLabelService.labelFor('addr0'), isNull);

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.enterText(dialogField(), 'Savings');
    await answer(tester, 'Save');
    expect(addressLabelService.labelFor('addr0'), 'Savings');
    await disposeHome(tester);
  });
}
