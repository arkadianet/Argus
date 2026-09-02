import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/transactions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
