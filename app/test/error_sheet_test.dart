import 'package:argus_wallet/ui/widgets/error_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows code and message, offers copy, stays until closed', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: TextButton(
            onPressed: () => showErrorSheet(ctx, code: 'TX_BUILD_FAILED', message: 'not enough ERG'),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('TX_BUILD_FAILED: not enough ERG'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsNothing);
  });
}
