import 'package:argus_wallet/ui/widgets/empty_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows title, body, and fires the action', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EmptyState(
          icon: Icons.inbox_outlined,
          title: 'No activity yet',
          body: 'Receive to this wallet first.',
          actionLabel: 'Receive',
          onAction: () => taps++,
        ),
      ),
    ));
    expect(find.text('No activity yet'), findsOneWidget);
    expect(find.text('Receive to this wallet first.'), findsOneWidget);
    await tester.tap(find.text('Receive'));
    expect(taps, 1);
  });

  testWidgets('omits the button without an action', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: EmptyState(icon: Icons.inbox_outlined, title: 'Nothing', body: 'b')),
    ));
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });
}
