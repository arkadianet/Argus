import 'package:argus_wallet/ui/dashboard_screen.dart';
import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [true, false]) {
    testWidgets('home status wraps at narrow width and 1.6x ($dark)', (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: argusTheme(watchful: dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
        home: const Scaffold(body: Padding(padding: EdgeInsets.all(38),
          child: SyncStatusLine(status: 'Out of sync', statusColor: rust,
            height: 1999999, count: 12345, fragmented: true, age: '10 minutes ago'),
        )),
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('Block 1,999,999'), findsOneWidget);
      expect(find.text('12345 UTXOs · Fragmented'), findsOneWidget);
      expect(tester.getTopLeft(find.text('10 minutes ago')).dy,
        greaterThan(tester.getTopLeft(find.text('Out of sync')).dy));
    });
  }
}
