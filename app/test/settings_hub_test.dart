import 'package:argus_wallet/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the hub lists every group and row', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    for (final text in ['Addresses, tools and backup', 'Security', 'Network', 'Display', 'Address book', 'Watch-only', 'About Argus', 'Manage']) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text('No wallet selected'), findsOneWidget);
  });
}
