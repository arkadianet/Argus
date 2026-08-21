import 'package:argus_wallet/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App renders dashboard', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ArgusApp());
    await tester.pump();
    expect(find.text('Argus'), findsWidgets);
  });
}
