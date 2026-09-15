import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/cold_signing_screen.dart';
import 'package:argus_wallet/ui/dashboard_screen.dart';
import 'package:argus_wallet/ui/receive_screen.dart';
import 'package:argus_wallet/ui/send_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const watched = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

class DashboardApi extends RustLibApi {
  int scans = 0;
  @override
  Future<void> crateApiInitApp() async {}
  @override
  Future<List<String>> crateApiDeriveWatchAddresses({
    required String input,
    required int start,
    required int count,
  }) async {
    scans++;
    return List.generate(
      count,
      (i) => i == 0 ? watched : 'address-${start + i}',
    );
  }

  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) async => '{"balance_nano_erg":0,"tokens":[]}';
  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async => '[]';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = DashboardApi();
  late WatchAccount account;
  const channel = MethodChannel('com.argus.wallet/secure_storage');
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await watchOnlyService.load();
    // Suppress the unrelated connectivity probe, without altering account reads.
    networkController.probing = true;
    api.scans = 0;
    account = WatchAccount('0488b21e-account')
      ..snapshot = WatchAccountSnapshot([watched], watched, 0, {}, [], -1);
    watchAccountService.accounts
      ..clear()
      ..add(account);
  });
  tearDown(() {
    watchAccountService.accounts.clear();
    networkController.probing = false;
  });

  Future<void> openDashboard(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'listWalletIds' ? ['spendable'] : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: DashboardScreen(initializeWalletService: () async {}),
        routes: {'/receive': (_) => const ReceiveScreen()},
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectAccount(WidgetTester tester) async {
    final row = find.byKey(ValueKey('watch-account-${account.key}'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(find.text('Wallet'), findsWidgets);
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.visibility_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('Cannot sign locally'),
      ),
      findsOneWidget,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(row, 200);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(row).selected, isTrue);
    await tester.scrollUntilVisible(find.text(watchAccountLimitations), -200);
    await tester.pumpAndSettle();
    expect(find.text(watchAccountLimitations), findsOneWidget);
    expect(
      api.scans,
      0,
      reason: 'Selecting a cached account must not refresh it',
    );
  }

  testWidgets(
    'main selector distinguishes account and reaches address-only Receive while locked',
    (tester) async {
      await openDashboard(tester);
      await selectAccount(tester);
      await tester.ensureVisible(find.text('Receive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receive'));
      await tester.pumpAndSettle();
      expect(
        api.scans,
        1,
        reason: 'Receive retains its existing fresh-address scan',
      );
      expect(find.byType(ReceiveScreen), findsOneWidget);
      expect(
        tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel,
        watched,
      );
      expect(find.byKey(const Key('stealth-qr')), findsNothing);
      expect(find.text('USED ADDRESSES'), findsNothing);
      expect(
        find.textContaining('Cannot see stealth identities'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('selected account Send opens the existing offline signer flow', (
    tester,
  ) async {
    await openDashboard(tester);
    await selectAccount(tester);
    await tester.ensureVisible(find.text('Send with offline signer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send with offline signer'));
    await tester.pumpAndSettle();
    expect(find.byType(ColdWatchSendScreen), findsOneWidget);
    expect(
      tester
          .widget<ColdWatchSendScreen>(find.byType(ColdWatchSendScreen))
          .account,
      same(account),
    );
    expect(find.byType(SendScreen), findsNothing);
    expect(api.scans, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'uncached account remains selectable with explicit unavailable balance',
    (tester) async {
      account.snapshot = null;
      await openDashboard(tester);
      await selectAccount(tester);
      expect(find.text('Balance unavailable'), findsOneWidget);
      expect(find.text('Refresh account'), findsOneWidget);
      expect(find.text('Receive'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'single watched address reaches offline Send and Receive while locked',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'argus_watch_only_addresses': jsonEncode([watched]),
      });
      await watchOnlyService.load();
      await openDashboard(tester);
      final row = find.byKey(const ValueKey('watch-address-$watched'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Watch-only address'), findsOneWidget);
      expect(find.text('Send with offline signer'), findsOneWidget);
      expect(find.textContaining('change returns to this same address'), findsOneWidget);
      await tester.ensureVisible(find.text('Send with offline signer'));
      await tester.tap(find.text('Send with offline signer'));
      await tester.pumpAndSettle();
      expect(tester.widget<ColdWatchSendScreen>(find.byType(ColdWatchSendScreen)).address, watched);
      expect(find.textContaining('Change, including remaining tokens'), findsOneWidget);
      expect(find.text('Prepare cold request'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Receive'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receive'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel,
        watched,
      );
      expect(api.scans, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
