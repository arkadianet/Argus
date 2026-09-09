import 'package:argus_wallet/ui/mix_screen.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final finished in [true, false]) {
    testWidgets('removing a mix explains the consequence (finished: $finished)', (tester) async {
      bool? removed;
      await tester.pumpWidget(MaterialApp(
        theme: argusTheme(watchful: true),
        home: Builder(builder: (context) => Scaffold(body: TextButton(
          onPressed: () async => removed = await confirmRemoveMix(context, finished: finished),
          child: const Text('Remove'),
        ))),
      ));
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(removed, isNull);
      expect(find.textContaining(finished ? 'completed transfer is unaffected' : 'has not entered'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(removed, isFalse);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(removed, isTrue);
    });
  }
}
