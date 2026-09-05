import 'package:argus_wallet/ui/widgets/action_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final actions = [
    HomeAction(icon: Icons.north_east, label: 'Send', onTap: () {}),
    HomeAction(icon: Icons.south_west, label: 'Receive', onTap: () {}),
    HomeAction(icon: Icons.swap_horiz, label: 'Swap', onTap: () {}),
    HomeAction(icon: Icons.blender_outlined, label: 'Mix', onTap: () {}),
  ];

  Future<void> pump(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: HomeActionRow(actions: actions),
        ),
      ),
    ));
  }

  testWidgets('four actions wrap to two rows on a narrow phone, no overflow', (tester) async {
    await pump(tester, 360);
    expect(tester.takeException(), isNull);
    final send = tester.getRect(find.byKey(const Key('home-action-send')));
    final mix = tester.getRect(find.byKey(const Key('home-action-mix')));
    expect(mix.top, greaterThan(send.bottom), reason: 'Mix is on the second row');
    expect(send.width, greaterThanOrEqualTo(homeActionMinWidth));
  });

  testWidgets('four actions share one row when there is room', (tester) async {
    await pump(tester, 520);
    expect(tester.takeException(), isNull);
    final send = tester.getRect(find.byKey(const Key('home-action-send')));
    final mix = tester.getRect(find.byKey(const Key('home-action-mix')));
    expect(mix.top, send.top);
  });
}
