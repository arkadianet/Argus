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
    expect(find.text('••••'), findsOneWidget);
  });

  testWidgets('ERG row shows the sigma mark and fiat', (tester) async {
    await tester.pumpWidget(_wrap(AssetTile.erg(balanceNano: 2500000000, fiatText: '≈ \$1.00 USD')));
    expect(find.text('Σ'), findsOneWidget);
    expect(find.text('2.5 ERG'), findsOneWidget);
    expect(find.text('≈ \$1.00 USD'), findsOneWidget);
  });

  testWidgets('tap invokes onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_wrap(AssetTile.token(token, onTap: () => taps++)));
    await tester.tap(find.text('Sigma USD'));
    expect(taps, 1);
  });
}
