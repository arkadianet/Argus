import 'package:argus_wallet/ui/token_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget w) => MaterialApp(home: Scaffold(body: Center(child: w)));

void main() {
  testWidgets('shows the first letter when there is no icon', (tester) async {
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'sigusd')));
    expect(find.text('S'), findsOneWidget);
  });

  testWidgets('shows the ERG sigma mark', (tester) async {
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'ERG', isErg: true)));
    expect(find.text('Σ'), findsOneWidget);
  });

  testWidgets('falls back to the letter when the icon fails to load', (tester) async {
    await tester.pumpWidget(_wrap(const TokenAvatar(
      label: 'Tok',
      iconUrl: 'https://invalid.invalid/icon.png',
    )));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('T'), findsOneWidget);
  });
}
