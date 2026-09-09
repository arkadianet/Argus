import 'package:shared_preferences/shared_preferences.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/ageusd_screen.dart';
import 'package:argus_wallet/ui/swap_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('AgeUSD load errors stay selectable until retry', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: true), home: const AgeUsdScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.text('Retry'), findsWidgets);
    await tester.pump(const Duration(seconds: 30));
    expect(find.byType(SelectableText), findsWidgets);
  });
  testWidgets('swap load errors can be copied', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: false), home: const SwapScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsWidgets);
  });
}
