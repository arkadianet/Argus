import 'package:flutter/services.dart';
import 'package:argus_wallet/bridge/argus_error.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/widgets/error_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uncertain broadcasts keep a copyable warning until dismissed', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: true),
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => showTxFailureSheet(context,
          ArgusException(code: 'NODE_ERROR', message: 'Connection closed after submission')),
        child: const Text('Send'),
      ))),
    ));
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Broadcast may have failed'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('Check Activity before retrying'), findsOneWidget);
    expect(find.textContaining('Connection closed after submission'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, contains('NODE_ERROR'));
    expect(copied, contains('Connection closed after submission'));
    expect(tester.takeException(), isNull);
  });

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
