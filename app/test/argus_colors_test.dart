import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ArgusColors follows the palette', (tester) async {
    late ArgusColors light;
    late ArgusColors dark;
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: false),
      home: Builder(builder: (ctx) {
        light = ArgusColors.of(ctx);
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: true),
      home: Builder(builder: (ctx) {
        dark = ArgusColors.of(ctx);
        return const SizedBox();
      }),
    ));
    // MaterialApp animates theme changes; wait for the final palette.
    await tester.pumpAndSettle();
    expect(light.muted, ledgerMuted);
    expect(dark.muted, watchfulMuted);
    expect(light.inset, paper);
    expect(dark.inset, ink);
    expect(light.cardBorder, isNot(dark.cardBorder));
  });
}
