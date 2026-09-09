import 'package:flutter/material.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/ui/widgets/amount_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [true, false]) {
    testWidgets('optional ERG label and currency toggle fit at 1.6x ($dark)', (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      networkController.fiatPerErg = 2;
      addTearDown(() => networkController.fiatPerErg = null);
      final controller = TextEditingController(text: '1');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: argusTheme(watchful: dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(20), child: AmountEntry(
          controller: controller, label: 'ERG to send with it (optional)',
        ))),
      ));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Enter USD'));
      await tester.pump();
      expect(find.text('Enter ERG'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('fiat text converts to ERG text at the rate', () {
    expect(fiatToErgText('2.00', rate: 0.5), '4');
    expect(fiatToErgText('1', rate: 3), '0.333333333');
    expect(fiatToErgText('', rate: 3), '');
    expect(fiatToErgText('abc', rate: 3), isNull);
  });

  test('ERG text converts to fiat text with two decimals', () {
    expect(ergToFiatText('4', rate: 0.5), '2.00');
    expect(ergToFiatText('0.001', rate: 1.2), '0.00');
    expect(ergToFiatText('', rate: 1), '');
  });

  test('jpy uses no decimals', () {
    expect(ergToFiatText('2', rate: 150, decimals: 0), '300');
  });
}
