import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/widgets/token_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final token = TokenBalance(id: 'a1b2c3d4e5f6a7b8', amount: 5, name: 'Art', decimals: 0);

  testWidgets('shows the full id, amount and offers send', (tester) async {
    TokenBalance? sent;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TokenDetailSheet(
          token: token,
          explorerUrl: 'https://x/token/a1b2c3d4e5f6a7b8',
          onSend: (t) => sent = t,
        ),
      ),
    ));
    expect(find.text('Art'), findsOneWidget);
    expect(find.text('a1b2c3d4e5f6a7b8'), findsOneWidget);
    expect(find.textContaining('5 Art'), findsOneWidget);
    await tester.tap(find.text('Send Art'));
    expect(sent?.id, token.id);
  });

  testWidgets('hides send when there is no handler', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TokenDetailSheet(token: token, explorerUrl: 'https://x')),
    ));
    expect(find.textContaining('Send'), findsNothing);
  });
}
