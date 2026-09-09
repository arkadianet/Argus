import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/transactions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Activity keeps a local broadcast when the node has not seen it', (tester) async {
    walletSyncController.recentTxs = [
      {'tx_id': 'local-send', 'height': 0, 'timestamp': 1, 'broadcast': true},
    ];
    addTearDown(() => walletSyncController.recentTxs = []);
    await tester.pumpWidget(MaterialApp(home: TransactionsScreen(
      args: const WalletRouteArgs(senderAddress: 'a', receiveAddress: 'a', changeAddress: 'a'),
      loadHistory: (_, {required limit, required perAddressOffsets}) async =>
          (rows: <Map<String, dynamic>>[], partial: false),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('No activity yet'), findsNothing);
  });

  testWidgets('node confirmation replaces the local pending row without a duplicate', (tester) async {
    walletSyncController.recentTxs = [
      {'tx_id': 'same-send', 'height': 0, 'timestamp': 1, 'broadcast': true},
    ];
    addTearDown(() => walletSyncController.recentTxs = []);
    await tester.pumpWidget(MaterialApp(home: TransactionsScreen(
      args: const WalletRouteArgs(senderAddress: 'a', receiveAddress: 'a', changeAddress: 'a'),
      loadHistory: (_, {required limit, required perAddressOffsets}) async =>
          (rows: [{'tx_id': 'same-send', 'height': 10, 'timestamp': 1}], partial: false),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.text('Pending'), findsNothing);
  });

  testWidgets('partial history stays visible with a copyable retry reason', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: TransactionsScreen(
      args: const WalletRouteArgs(senderAddress: 'a', receiveAddress: 'a', changeAddress: 'a'),
      loadHistory: (_, {required limit, required perAddressOffsets}) async {
        calls++;
        return (rows: [{'tx_id': 'known', 'height': 1, 'timestamp': 1}], partial: calls == 1);
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('Confirmed'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('Some addresses could not be checked'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('Some addresses could not be checked'), findsNothing);
  });

  testWidgets('a failed older page keeps a visible retry and existing rows', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: TransactionsScreen(
      args: const WalletRouteArgs(senderAddress: 'a', receiveAddress: 'a', changeAddress: 'a'),
      loadHistory: (_, {required limit, required perAddressOffsets}) async {
        calls++;
        if (calls == 2) throw StateError('older page timed out');
        return (rows: calls == 1 ? [for (var i = 0; i < limit; i++)
          {'tx_id': 't$i', 'height': 1, 'timestamp': i + 1}] : <Map<String, dynamic>>[], partial: false);
      },
    )));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -15000));
    await tester.pumpAndSettle();
    expect(find.textContaining('older page timed out'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.textContaining('older page timed out'), findsNothing);
  });

  testWidgets('embedded activity renders without its own app bar', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: TransactionsScreen(
          embedded: true,
          args: WalletRouteArgs(
            senderAddress: 'a',
            receiveAddress: 'a',
            changeAddress: 'a',
            historyAddresses: ['a'],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsNothing);
    // Rust is not initialised in tests, so the load fails and offers a retry.
    expect(find.text('Retry'), findsOneWidget);
  });
}
