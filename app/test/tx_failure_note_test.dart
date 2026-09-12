import 'package:argus_wallet/bridge/argus_error.dart';
import 'package:argus_wallet/ui/widgets/error_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final code in ['NODE_ERROR', 'SIGNING_FAILED']) {
    testWidgets('refund guidance preserves classification for $code', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTxFailureSheet(
                  context,
                  ArgusException(code: code, message: 'Failure detail'),
                  note:
                      'The proxy remains tracked. Refresh to reconcile before retrying.',
                ),
                child: const Text('Fail'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Fail'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          code == 'NODE_ERROR' ? 'Broadcast may have failed' : 'Signing failed',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          code == 'NODE_ERROR'
              ? 'Check Activity before retrying'
              : 'Nothing was sent.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('The proxy remains tracked.'), findsOneWidget);
      expect(find.textContaining('$code: '), findsOneWidget);
    });
  }
}
