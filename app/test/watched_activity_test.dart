import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/watch_only_service.dart';
import 'package:argus_wallet/ui/settings/watch_only_page.dart';
import 'package:argus_wallet/ui/transactions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const watched = '9hY16vzHmmfyVBwKeFGHvb2bMFsG94A1u7To1QWtUokACyFVENQ';

/// A node with one confirmed and one pending transaction for the address.
class ActivityApi extends RustLibApi {
  final pendingAsked = <List<String>>[];

  @override
  Future<String> crateApiGetPendingTransactions({
    required List<String> addresses,
    String? nodeUrl,
  }) async {
    pendingAsked.add(addresses);
    return jsonEncode([
      {
        'tx_id': 'p' * 64,
        'height': 0,
        'timestamp': 0,
        'value_nano_erg': 2500000000,
        'token_ids': [],
        'tokens_received': [],
        'confirmed': false,
      },
    ]);
  }

  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async => offset == BigInt.zero
      ? jsonEncode([
          {
            'tx_id': 'c' * 64,
            'height': 1500000,
            'timestamp': 1700000000000,
            'value_nano_erg': 1000000000,
            'token_ids': [],
            'tokens_received': [],
          },
        ])
      : '[]';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = ActivityApi();
  setUpAll(() => RustLib.initMock(api: api));

  testWidgets('a watched address opens its activity, pending first', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'argus_watch_only_addresses': jsonEncode([watched]),
    });
    await watchOnlyService.load();
    await tester.pumpWidget(const MaterialApp(home: WatchOnlyPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Activity'));
    await tester.pumpAndSettle();

    final screen = tester.widget<TransactionsScreen>(
      find.byType(TransactionsScreen),
    );
    expect(screen.args!.watchOnly, isTrue);
    expect(screen.args!.historyAddresses, [watched]);
    expect(api.pendingAsked.last, [watched]);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Confirmed'), findsOneWidget);
    final pending = tester.getTopLeft(find.text('Pending'));
    final confirmed = tester.getTopLeft(find.text('Confirmed'));
    expect(pending.dy, lessThan(confirmed.dy), reason: 'pending rows lead');
  });
}
