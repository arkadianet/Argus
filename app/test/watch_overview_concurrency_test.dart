import 'dart:async';
import 'dart:convert';
import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/dashboard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_finders.dart';

class OverviewApi extends RustLibApi {
  late Completer<List<String>> derive;
  int balances = 0;
  @override
  Future<List<String>> crateApiDeriveWatchAddresses({
    required String input,
    required int start,
    required int count,
  }) => derive.future;
  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) async {
    balances++;
    return '{"balance_nano_erg":7000000000,"tokens":[]}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = OverviewApi();
  setUpAll(() => RustLib.initMock(api: api));
  testWidgets('watched balance displays while account scan is blocked', (
    tester,
  ) async {
    api.derive = Completer<List<String>>();
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': jsonEncode(['watched-address']),
    });
    await watchOnlyService.load();
    watchAccountService.accounts.add(WatchAccount('key'));
    networkController.probing = true;
    const channel = MethodChannel('com.argus.wallet/secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'listWalletIds' ? <String>[] : null,
    );
    // The overview is the launch screen: its launch pass reads the watched
    // address and scans the account, which has no snapshot yet.
    await tester.pumpWidget(
      MaterialApp(
        home: DashboardScreen(initializeWalletService: () async {}),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(api.balances, 1);
    expect(watchAccountService.accounts.single.busy, isTrue);
    expect(find.byKey(const Key('overview-total')), findsOneWidget);
    expect(plainOf(tester, find.byKey(const Key('overview-total'))), '7 ERG');
    expect(find.text('Balance unavailable'), findsNothing);
    // End the pending scan via incomplete derivation, avoiding extra network calls.
    api.derive.complete([]);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(watchAccountService.accounts.single.busy, isFalse);
    await tester.pumpWidget(const SizedBox());
    networkController.probing = false;
    watchAccountService.accounts.clear();
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': '[]',
    });
    await watchOnlyService.load();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });
}
