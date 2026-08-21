import 'package:argus_wallet/ui/pin_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PIN field opens the number pad', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinFields(pin: TextEditingController()),
        ),
      ),
    );
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.keyboardType, TextInputType.number);
  });
}
