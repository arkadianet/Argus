import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/session_lock.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/home/unlock_gate.dart';
import 'package:argus_wallet/ui/wallets_overview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_harness.dart';

// A2: the app asks for no key at launch; opening a wallet asks once; a
// cancelled prompt never comes back by itself.
//
// On 1.0.0-beta.1 the launch screen prompted for biometrics, and the resume
// that follows the biometric sheet closing prompted again — whatever the
// user did, the sheet came straight back.

void main() {
  final api = HomeApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({'argus_watch_only_addresses': '[]'});
    await watchOnlyService.load();
    watchAccountService.accounts.clear();
    stealthService.scanEnabled = false;
    // Snapshot figures stay as they are: no public refresh in these tests.
    publicWalletSync.setForeground(false);
  });
  tearDown(() async {
    publicWalletSync.setForeground(true);
    stealthService.scanEnabled = true;
    // A failed test must not hand its unlocked wallet to the next one.
    if (walletService.isUnlocked) await walletService.lock();
  });

  Future<FakeKeystore> launch(
    WidgetTester tester, {
    bool biometric = true,
    String? biometricResult,
  }) async {
    final keystore = FakeKeystore(wallets: ['unlock-w1', 'unlock-w2'], biometric: biometric)
      ..biometricResult = biometricResult;
    keystore.install(tester);
    await tester.runAsync(() async {
      await saveWallet('unlock-w1', name: 'Daily', address0: 'addr0');
      await saveWallet('unlock-w2', name: 'Savings', address0: 'savings0');
    });
    await pumpHome(tester);
    return keystore;
  }

  Future<void> openDaily(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('overview-row-seed-unlock-w1')));
    await tester.pumpAndSettle();
  }

  Future<void> cycle(WidgetTester tester, List<AppLifecycleState> states) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('launch opens on the overview and asks for no key', (tester) async {
    final keystore = await launch(tester);
    expect(find.byType(WalletsOverviewScreen), findsOneWidget);
    expect(find.byType(UnlockGate), findsNothing);
    expect(keystore.prompts, 0);
    // Coming back to the app is not a reason to ask either.
    await cycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    expect(keystore.prompts, 0);
    expect(walletService.isUnlocked, isFalse);
    await disposeHome(tester);
  });

  testWidgets('opening a wallet asks once; a cancel is never followed by another prompt', (
    tester,
  ) async {
    final keystore = await launch(tester);
    await openDaily(tester);
    expect(keystore.prompts, 1);
    // The cancel leaves the locked wallet page: an explicit Unlock and the PIN.
    expect(find.byType(UnlockGate), findsOneWidget);
    expect(find.byKey(const Key('gate-unlock')), findsOneWidget);
    expect(find.byKey(const Key('gate-use-pin')), findsOneWidget);
    expect(find.textContaining('Biometric unlock cancelled'), findsOneWidget);
    // The biometric sheet itself took the window: closing it resumes the
    // app. That resume, and any later one, must not ask again.
    await cycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    expect(keystore.prompts, 1);
    expect(find.byType(UnlockGate), findsOneWidget);
    // Unlock is the retry: one tap, one prompt.
    await tester.tap(find.byKey(const Key('gate-unlock')));
    await tester.pumpAndSettle();
    expect(keystore.prompts, 2);
    await cycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.resumed]);
    expect(keystore.prompts, 2);
    expect(walletService.isUnlocked, isFalse);
    await disposeHome(tester);
  });

  testWidgets('back from the gate is the overview, and asks nothing', (tester) async {
    final keystore = await launch(tester);
    await openDaily(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(WalletsOverviewScreen), findsOneWidget);
    expect(keystore.prompts, 1);
    await disposeHome(tester);
  });

  testWidgets('Use PIN unlocks with the PIN instead', (tester) async {
    final keystore = await launch(tester);
    await openDaily(tester);
    await tester.tap(find.byKey(const Key('gate-use-pin')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), api.goodPin);
    await tester.tap(find.byKey(const Key('gate-unlock-pin')));
    await tester.pumpAndSettle();
    expect(walletService.isUnlocked, isTrue);
    expect(walletService.activeWalletId, 'unlock-w1');
    expect(find.byType(UnlockGate), findsNothing);
    expect(find.widgetWithText(NavigationDestination, 'Activity'), findsOneWidget);
    expect(keystore.prompts, 1);
    await disposeHome(tester);
  });

  testWidgets('a wallet without biometrics opens on its PIN, with no prompt', (tester) async {
    final keystore = await launch(tester, biometric: false);
    await openDaily(tester);
    expect(keystore.prompts, 0);
    expect(find.byKey(const Key('gate-unlock-pin')), findsOneWidget);
    expect(find.byKey(const Key('gate-unlock')), findsNothing);
    await disposeHome(tester);
  });

  testWidgets('after an auto-lock the page shows its gate and does not prompt', (tester) async {
    final keystore = await launch(tester, biometricResult: 'wrap-key');
    await openDaily(tester);
    expect(keystore.prompts, 1);
    expect(walletService.isUnlocked, isTrue);
    expect(find.byType(UnlockGate), findsNothing);
    // Away past the grace window: the real session lock fires, as the app
    // wires it to lifecycle changes.
    for (final state in const [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      sessionLock.onLifecycle(state);
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(sessionLock.grace + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(walletService.isUnlocked, isFalse);
    for (final state in const [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      sessionLock.onLifecycle(state);
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pumpAndSettle();
    }
    expect(walletService.isUnlocked, isFalse);
    expect(find.byType(UnlockGate), findsOneWidget);
    expect(keystore.prompts, 1, reason: 'returning to a locked wallet is not opening it');
    await disposeHome(tester);
  });

  testWidgets('reopening the unlocked wallet from the overview asks nothing', (tester) async {
    final keystore = await launch(tester, biometricResult: 'wrap-key');
    await openDaily(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unlocked'), findsOneWidget, reason: 'the overview row says so');
    await openDaily(tester);
    expect(keystore.prompts, 1);
    expect(find.byType(UnlockGate), findsNothing);
    await disposeHome(tester);
  });

  testWidgets('switching keeps the open wallet until the next one is unlocked', (tester) async {
    final keystore = await launch(tester, biometricResult: 'wrap-key');
    await openDaily(tester);
    expect(walletService.activeWalletId, 'unlock-w1');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    keystore.biometricResult = null;
    await tester.tap(find.byKey(const ValueKey('overview-row-seed-unlock-w2')));
    await tester.pumpAndSettle();
    expect(keystore.prompts, 2);
    expect(find.byType(UnlockGate), findsOneWidget);
    // Cancelled: the first wallet is still the unlocked one.
    expect(walletService.activeWalletId, 'unlock-w1');
    keystore.biometricResult = 'wrap-key';
    await tester.tap(find.byKey(const Key('gate-unlock')));
    await tester.pumpAndSettle();
    expect(walletService.activeWalletId, 'unlock-w2');
    expect(find.byType(UnlockGate), findsNothing);
    await disposeHome(tester);
  });
}
