import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/ui/widgets/asset_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

void main() {
  final token = TokenBalance(id: 'a1b2c3d4e5f6', amount: 12345, name: 'Sigma USD', decimals: 2);

  testWidgets('shows ticker, name and grouped amount', (tester) async {
    await tester.pumpWidget(_wrap(AssetTile.token(token)));
    expect(find.text('Sigma'), findsOneWidget);
    expect(find.text('Sigma USD'), findsOneWidget);
    expect(find.text('123.45 Sigma'), findsOneWidget);
  });

  testWidgets('masks amounts when hidden', (tester) async {
    await tester.pumpWidget(_wrap(AssetTile.token(token, hidden: true)));
    expect(find.text('123.45 Sigma'), findsNothing);
    expect(find.text('••••'), findsNWidgets(3));
  });

  testWidgets('token row shows its fiat value and masks it when hidden', (tester) async {
    await tester.pumpWidget(_wrap(AssetTile.token(token, fiatText: '≈ \$123.45')));
    expect(find.text('≈ \$123.45'), findsOneWidget);
    await tester.pumpWidget(_wrap(AssetTile.token(token, fiatText: '≈ \$123.45', hidden: true)));
    expect(find.text('≈ \$123.45'), findsNothing);
    expect(find.text('≈ ••••'), findsOneWidget);
  });

  testWidgets('ERG row shows the sigma mark and fiat', (tester) async {
    await tester.pumpWidget(_wrap(AssetTile.erg(balanceNano: 2500000000, fiatText: '≈ \$1.00 USD')));
    expect(find.text('Σ'), findsOneWidget);
    expect(find.text('2.5 ERG'), findsOneWidget);
    expect(find.text('≈ \$1.00 USD'), findsOneWidget);
  });

  testWidgets('a token nothing can scale says its amount is raw units', (tester) async {
    // No name, no evidence: the zero decimals are a default, not knowledge.
    final unknown = TokenBalance(id: 'e91cbc48' * 8, amount: 5000);
    await tester.pumpWidget(_wrap(AssetTile.token(unknown)));
    expect(find.text('5,000 raw units'), findsOneWidget);
    expect(find.textContaining('5,000 E91CBC'), findsNothing,
        reason: 'base units must not read as whole tokens');
  });

  testWidgets('a known zero scale is a scale', (tester) async {
    final comet = TokenBalance(
      id: '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b',
      amount: 69,
      name: 'COMET',
    );
    await tester.pumpWidget(_wrap(AssetTile.token(comet)));
    expect(find.text('69 COMET'), findsOneWidget);
  });

  testWidgets('tap invokes onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_wrap(AssetTile.token(token, onTap: () => taps++)));
    await tester.tap(find.text('Sigma USD'));
    expect(taps, 1);
  });
}
