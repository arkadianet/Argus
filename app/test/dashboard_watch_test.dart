import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/cold_signing_screen.dart';
import 'package:argus_wallet/ui/home/home_rows.dart';
import 'package:argus_wallet/ui/home/watched_wallet.dart';
import 'package:argus_wallet/ui/receive_screen.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:argus_wallet/ui/transactions_screen.dart';
import 'package:argus_wallet/ui/widgets/activity_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_finders.dart';
import 'support/home_harness.dart';

const watched = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

// A3: watched addresses and accounts open the standard wallet page, with
// Send swapped for the offline signer and nothing that needs a key.
void main() {
  final api = HomeApi()..watchDerived = (i) => i == 0 ? watched : 'address-$i';
  late WatchAccount account;
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await watchOnlyService.load();
    api.watchScans = 0;
    account = WatchAccount('0488b21e-account')
      ..snapshot = WatchAccountSnapshot([watched], watched, 0, {}, [], -1);
    watchAccountService.accounts
      ..clear()
      ..add(account);
  });
  tearDown(() => watchAccountService.accounts.clear());

  /// Opens the account from the overview; returns the scans made by then.
  Future<int> openAccount(WidgetTester tester) async {
    FakeKeystore(wallets: const []).install(tester);
    await pumpHome(tester);
    final before = api.watchScans;
    final row = find.byKey(ValueKey('overview-row-watchedAccount-${account.key}'));
    await tester.ensureVisible(row);
    // Marked as watched, not as a wallet that could be unlocked.
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.visibility_outlined)),
      findsOneWidget,
    );
    expect(find.descendant(of: row, matching: find.textContaining('Locked')), findsNothing);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(WatchedWalletPage), findsOneWidget);
    expect(api.watchScans, before, reason: 'Opening an account must not rescan it');
    return before;
  }

  testWidgets('an account opens the standard page and its Receive scans first', (
    tester,
  ) async {
    final scans = await openAccount(tester);
    expect(scans, 0, reason: 'A scanned account is not rescanned at launch');
    // The standard page: bottom navigation, assets and activity sections,
    // with no tab that needs a key.
    for (final label in ['Wallet', 'Activity', 'Settings']) {
      expect(find.widgetWithText(NavigationDestination, label), findsOneWidget);
    }
    expect(find.widgetWithText(NavigationDestination, 'Swap'), findsNothing);
    expect(find.widgetWithText(NavigationDestination, 'Discover'), findsNothing);
    expect(find.text(watchAccountLimitations), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Recent Activity'),
      300,
      scrollable: find.descendant(of: find.byKey(const Key('wallet-list')), matching: find.byType(Scrollable)).first,
    );
    expect(textPlainContaining('Assets'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('watch-action-receive')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('watch-action-receive')));
    await tester.pumpAndSettle();
    expect(api.watchScans, scans + 1, reason: 'Receive keeps its fresh-address scan');
    expect(find.byType(ReceiveScreen), findsOneWidget);
    expect(
      tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel,
      watched,
    );
    expect(find.byKey(const Key('stealth-qr')), findsNothing);
    expect(find.text('USED ADDRESSES'), findsNothing);
    expect(find.textContaining('Cannot see stealth identities'), findsOneWidget);
    await disposeHome(tester);
  });

  testWidgets('an account sends through the existing offline signer flow', (
    tester,
  ) async {
    final scans = await openAccount(tester);
    expect(find.bySemanticsLabel('Send with offline signer'), findsOneWidget);
    expect(find.text('Send'), findsNothing);
    await tester.tap(find.byKey(const Key('watch-action-send')));
    await tester.pumpAndSettle();
    expect(find.byType(ColdWatchSendScreen), findsOneWidget);
    expect(
      tester.widget<ColdWatchSendScreen>(find.byType(ColdWatchSendScreen)).account,
      same(account),
    );
    expect(find.byType(SendScreen), findsNothing);
    expect(api.watchScans, scans);
    await disposeHome(tester);
  });

  testWidgets('an account whose scan failed stays openable, with Receive disabled', (
    tester,
  ) async {
    // No snapshot: the launch pass scans it, and this scan fails.
    account.snapshot = null;
    api.watchDerived = (i) => throw StateError('node down');
    addTearDown(() => api.watchDerived = (i) => i == 0 ? watched : 'address-$i');
    await openAccount(tester);
    expect(account.snapshot, isNull);
    expect(find.textContaining('Account refresh unavailable'), findsWidgets);
    final receive = tester.widget<InkWell>(
      find.byKey(const Key('watch-action-receive')),
    );
    expect(receive.onTap, isNull);
    await disposeHome(tester);
  });

  testWidgets("a watched address shows its own assets and activity, not a signing wallet's", (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': jsonEncode([watched]),
    });
    await watchOnlyService.load();
    api.balances[watched] = {
      'balance_nano_erg': 1000000000,
      'tokens': [
        {'id': 'watched-token', 'amount': 5},
      ],
    };
    api.histories[watched] = [
      {'tx_id': 'watched-tx', 'height': 10, 'timestamp': 1759700000000, 'value_nano_erg': 1000000000},
    ];
    addTearDown(() {
      api.balances.remove(watched);
      api.histories.remove(watched);
    });
    FakeKeystore(wallets: const []).install(tester);
    // Wide enough for the Activity header in the square test font.
    await pumpHome(tester, size: const Size(430, 900));
    final row = find.byKey(const ValueKey('overview-row-watchedAddress-$watched'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(HomeAssetRow), findsNWidgets(2), reason: 'ERG and the one token');
    await tester.scrollUntilVisible(
      find.byType(HomeActivityRow),
      300,
      scrollable: find.descendant(of: find.byKey(const Key('wallet-list')), matching: find.byType(Scrollable)).first,
    );
    expect(find.byType(HomeActivityRow), findsOneWidget);
    // The Activity tab reads this address's own history.
    await tester.tap(find.widgetWithText(NavigationDestination, 'Activity'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionsScreen), findsOneWidget);
    expect(
      tester.widget<TransactionsScreen>(find.byType(TransactionsScreen)).args!.historyAddresses,
      [watched],
    );
    expect(find.byType(ActivityTile), findsOneWidget);
    await disposeHome(tester);
  });

  testWidgets('a watched address reaches offline Send and Receive while locked', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': jsonEncode([watched]),
    });
    await watchOnlyService.load();
    api.balances[watched] = {
      'balance_nano_erg': 25421629296273,
      'tokens': [],
    };
    addTearDown(() => api.balances.remove(watched));
    FakeKeystore(wallets: const []).install(tester);
    await pumpHome(tester);
    final row = find.byKey(const ValueKey('overview-row-watchedAddress-$watched'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    // A summary figure on the panel, not "25421.629296273 ERG".
    expect(plainOf(tester, find.byKey(const Key('wallet-balance'))), '25,421.62 ERG');
    expect(find.bySemanticsLabel('Send with offline signer'), findsOneWidget);
    expect(find.textContaining('change returns to this same address'), findsOneWidget);
    await tester.tap(find.byKey(const Key('watch-action-send')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ColdWatchSendScreen>(find.byType(ColdWatchSendScreen)).address,
      watched,
    );
    expect(find.textContaining('Change, including remaining tokens'), findsOneWidget);
    expect(find.text('Prepare cold request'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('watch-action-receive')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel,
      watched,
    );
    expect(api.watchScans, 0);
    await disposeHome(tester);
  });
}
