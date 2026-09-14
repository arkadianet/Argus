import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/watch_account_service.dart';
import 'package:argus_wallet/ui/cold_signing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final value in ['', 'abc', '0', '-1']) {
    testWidgets('invalid nanoERG amount "$value" names the field', (
      tester,
    ) async {
      final oldNode = networkController.activeUrl;
      addTearDown(() => networkController.activeUrl = oldNode);
      networkController.activeUrl = 'node';
      final account = WatchAccount('key')
        ..snapshot = WatchAccountSnapshot(['a'], 'a', 0, {}, [], -1);
      await tester.pumpWidget(
        MaterialApp(home: ColdWatchSendScreen(account: account)),
      );
      await tester.enterText(find.byType(TextField).at(1), value);
      await tester.tap(find.text('Prepare cold request'));
      await tester.pump();
      expect(
        find.textContaining('Enter a positive whole number for Amount'),
        findsOneWidget,
      );
      expect(find.textContaining('FormatException'), findsNothing);
    });
  }
  for (final value in ['', 'abc', '0', '-1']) {
    testWidgets('invalid token quantity "$value" names the field', (
      tester,
    ) async {
      final oldNode = networkController.activeUrl;
      addTearDown(() => networkController.activeUrl = oldNode);
      networkController.activeUrl = 'node';
      final account = WatchAccount('key')
        ..snapshot = WatchAccountSnapshot(['a'], 'a', 0, {}, [], -1);
      await tester.pumpWidget(
        MaterialApp(home: ColdWatchSendScreen(account: account)),
      );
      await tester.enterText(find.byType(TextField).at(1), '1000000');
      await tester.enterText(find.byType(TextField).at(2), 'token');
      await tester.enterText(find.byType(TextField).at(3), value);
      await tester.tap(find.text('Prepare cold request'));
      await tester.pump();
      expect(
        find.textContaining('Enter a positive whole number for Token quantity'),
        findsOneWidget,
      );
      expect(find.textContaining('FormatException'), findsNothing);
    });
  }
}
