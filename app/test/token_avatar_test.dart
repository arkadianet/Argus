import 'package:argus_wallet/services/rosen_tokens.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/token_avatar.dart';
import 'package:argus_wallet/ui/token_logo_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'home_contrast_test.dart' show contrast;

Widget _wrap(Widget w) => MaterialApp(home: Scaffold(body: Center(child: w)));

const _comet = '0cd8c9f416e5b1ca9f986a7f10a84191dfb85941619e49e53c0dc30ebf83324b';

void main() {
  testWidgets('shows the first letter when there is no icon', (tester) async {
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'sigusd')));
    expect(find.text('S'), findsOneWidget);
  });

  testWidgets('ERG shows the Ergo mark, drawn from the bundle', (tester) async {
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'ERG', isErg: true)));
    expect(find.byKey(const Key('token-logo-erg')), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('an icon URL is never fetched: the letter stands in', (tester) async {
    await tester.pumpWidget(_wrap(const TokenAvatar(
      label: 'Tok',
      iconUrl: 'https://invalid.invalid/icon.png',
    )));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('T'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a verified token shows its registry ticker, any other its id', (tester) async {
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'COMET', tokenId: _comet)));
    expect(find.text('C'), findsOneWidget, reason: 'not "0", the first character of its id');
    // An unverified token named like a verified one still shows its id.
    await tester.pumpWidget(_wrap(const TokenAvatar(label: 'COMET', tokenId: '6de6f46e0c2b8a4f1d3e5a7b9c0d2e4f6a8b0c1d3e5f7a9b0c2d4e6f8a0b1c3d')));
    expect(find.text('6'), findsOneWidget);
  });

  group('bundled logos', () {
    test('every logo named has its art, and only Rosen-wrapped chains and ERG have one', () {
      expect(tokenLogoName(isErg: true), 'erg');
      expect(tokenLogoName(tokenId: _comet), isNull, reason: 'COMET has no licensed mark');
      final named = <String>{};
      for (final t in [...rosenNativeTokens, ...rosenWrappedTokens]) {
        final logo = tokenLogoName(tokenId: t.id);
        if (logo == null) continue;
        named.add(logo);
        expect(t.ticker, startsWith('rs'), reason: '${t.ticker} is not a wrapped chain token');
      }
      expect(named, containsAll(['ada', 'btc', 'eth', 'bnb', 'doge']));
      for (final name in [...named, 'erg']) {
        final art = tokenLogoArt[name];
        expect(art, isNotNull, reason: name);
        expect(art!.layers, isNotEmpty, reason: name);
        for (final layer in art.layers) {
          final bounds = layer.path().getBounds();
          expect(bounds.isEmpty, isFalse, reason: name);
          expect(Rect.fromLTWH(-0.5, -0.5, art.size + 1, art.size + 1).contains(bounds.topLeft), isTrue, reason: name);
          expect(Rect.fromLTWH(-0.5, -0.5, art.size + 1, art.size + 1).contains(bounds.bottomRight), isTrue, reason: name);
        }
      }
    });

    testWidgets('a look-alike named rsADA gets no logo', (tester) async {
      await tester.pumpWidget(_wrap(TokenAvatar(label: 'rsADA', tokenId: 'ab' * 32)));
      expect(find.byKey(const Key('token-logo-ada')), findsNothing);
      expect(find.text('A'), findsOneWidget);
    });
  });

  group('monogram discs meet AA in every palette', () {
    for (final palette in allPalettes) {
      test(palette.name, () {
        final short = <String>[];
        for (final verified in [true, false]) {
          for (var i = 0; i < 64; i++) {
            final look = monogramLook(
              brightness: palette.brightness,
              accent: palette.accent,
              accentText: palette.accentText,
              page: palette.surface,
              verified: verified,
              seed: 'token-$i',
            );
            for (final ground in [look.top, look.bottom]) {
              final ratio = contrast(look.letter, ground);
              if (ratio < 4.5) short.add('${verified ? 'verified' : 'seed $i'}: ${ratio.toStringAsFixed(2)}');
            }
            // The disc shows against the page and the sheet it sits on.
            for (final where in [palette.background, palette.surface]) {
              if (contrast(look.top, where) < 1.15 && contrast(look.bottom, where) < 1.15) {
                short.add('${verified ? 'verified' : 'seed $i'} disc vanishes');
              }
            }
          }
        }
        expect(short.toSet(), isEmpty);
      });
    }
  });
}
