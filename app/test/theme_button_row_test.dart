import 'package:argus_wallet/theme/argus_theme.dart';
import 'package:argus_wallet/ui/widgets/error_sheet.dart';
import 'package:argus_wallet/ui/utxo_management_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {

  testWidgets('the error sheet lays out under the app theme', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
        child: child!,
      ),
      theme: argusTheme(watchful: true),
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
    expect(tester.takeException(), isNull);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('an inline button keeps its height without demanding the whole line', (tester) async {
    // The theme's own minimum is the full width a page action wants, which
    // a Row or Wrap cannot satisfy; inlineButtonStyle is what opts out.
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: true),
      home: Scaffold(
        body: Row(children: [
          const Text('2 Selected'),
          const Spacer(),
          FilledButton(style: inlineButtonStyle, onPressed: () {}, child: const Text('Consolidate')),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
  for (final watchful in [true, false]) {
    testWidgets('coin selection actions fit narrow enlarged text ($watchful)', (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var split = false;
      await tester.pumpWidget(MaterialApp(
        theme: argusTheme(watchful: watchful),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(bottomSheet: UtxoSelectionActions(
          count: 2,
          onConsolidate: () {},
          onSplit: () => split = true,
        )),
      ));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Split'));
      expect(split, isTrue);
    });
  }


  testWidgets('a page action still fills the width its parent gives it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: argusTheme(watchful: true),
      home: Scaffold(
        body: ListView(children: [
          FilledButton(onPressed: () {}, child: const Text('Start a mix')),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(FilledButton)).width, 800,
        reason: 'the full-width default is what the theme is for');
  });

  testWidgets('every inline button row lays out narrow and enlarged', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final dark in [true, false]) {
      await tester.pumpWidget(MaterialApp(
        theme: argusTheme(watchful: dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(children: [
            UtxoSelectionActions(count: 3, onConsolidate: () {}, onSplit: () {}),
            Wrap(spacing: 8, children: [
              FilledButton.tonal(style: inlineButtonStyle, onPressed: () {}, child: const Text('Continue')),
              OutlinedButton(style: inlineButtonStyle, onPressed: () {}, child: const Text('Withdraw now')),
              FilledButton.tonal(style: inlineButtonStyle, onPressed: () {}, child: const Text('See transaction')),
            ]),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'watchful=$dark');
      expect(find.text('Withdraw now'), findsOneWidget);
    }
  });
}
