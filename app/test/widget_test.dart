import 'package:flutter_test/flutter_test.dart';
import 'package:argus_wallet/main.dart';

void main() {
  testWidgets('App renders dashboard', (WidgetTester tester) async {
    await tester.pumpWidget(const ArgusApp());
    await tester.pump();
    expect(find.text('Argus'), findsWidgets);
  });
}
