import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/widgets/wallet_token_count.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, WalletTokenCount count) =>
      tester.pumpWidget(
        MaterialApp(
          theme: argusTheme(watchful: false),
          home: Scaffold(body: SizedBox(width: 150, child: count)),
        ),
      );

  testWidgets('wallet count deduplicates holdings and includes NFTs', (
    tester,
  ) async {
    await show(
      tester,
      const WalletTokenCount(
        holdings: [
          (id: 'fungible', amount: 500000),
          (id: 'fungible', amount: 200000),
          (id: 'nft', amount: 1),
          (id: 'spent', amount: 0),
        ],
      ),
    );
    expect(find.text('2 token IDs (incl. NFTs)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached public holdings identify their scope', (tester) async {
    await show(
      tester,
      const WalletTokenCount(
        publicOnly: true,
        holdings: [(id: 'nft', amount: 1)],
      ),
    );
    expect(find.text('1 public token ID (incl. NFTs)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown and hidden holdings never show zero', (tester) async {
    await show(tester, const WalletTokenCount(holdings: null));
    expect(find.byType(Text), findsNothing);
    await show(tester, const WalletTokenCount(holdings: [], hidden: true));
    expect(find.byType(Text), findsNothing);
    await show(tester, const WalletTokenCount(holdings: []));
    expect(find.text('0 token IDs (incl. NFTs)'), findsOneWidget);
  });
}
