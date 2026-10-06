import 'package:argus_wallet/theme/argus_theme.dart';
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

  testWidgets('a verified token shows its registry ticker, any other its id', (tester) async {
    const comet = '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b';
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'COMET', tokenId: comet)));
    expect(find.text('C'), findsOneWidget, reason: 'not "0", the first character of its id');
    // An unverified token named like a verified one still shows its id.
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'COMET', tokenId: '6de6f46e0c2b8a4f1d3e5a7b9c0d2e4f6a8b0c1d3e5f7a9b0c2d4e6f8a0b1c3d')));
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('the disc stands apart from a dark card', (tester) async {
    final theme = argusTheme(watchful: true);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: ColoredBox(color: theme.colorScheme.surface, child: const Center(child: TokenAvatar(label: 'x', tokenId: 'abc'))),
      ),
    ));
    final disc = tester.widget<Container>(find.descendant(of: find.byType(TokenAvatar), matching: find.byType(Container)));
    final decoration = disc.decoration! as BoxDecoration;
    expect(decoration.color, isNot(theme.colorScheme.surface));
    expect(decoration.border, isNotNull);
  });
}
