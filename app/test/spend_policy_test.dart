import 'package:argus_wallet/services/spend_policy.dart';
import 'package:argus_wallet/ui/settings/security_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/failing_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the default allows spending unconfirmed funds', () {
    expect(defaultSpendUnconfirmed, isTrue);
    expect(SpendPolicy(push: (_) {}).spendUnconfirmed, isTrue);
  });

  test(
    'startup hands the stored choice to the core, loading it first',
    () async {
      SharedPreferences.setMockInitialValues({SpendPolicy.storageKey: false});
      final pushed = <bool>[];
      final policy = SpendPolicy(push: pushed.add);
      // A background isolate never ran load(); apply() must not push the
      // default over the user's choice.
      await policy.apply();
      expect(pushed, [false]);
      expect(policy.spendUnconfirmed, isFalse);
    },
  );

  test('a change is stored, then applied, then announced', () async {
    final pushed = <bool>[];
    final policy = SpendPolicy(push: pushed.add);
    await policy.load();
    var notified = 0;
    policy.addListener(() => notified++);
    await policy.setSpendUnconfirmed(false);
    expect(pushed, [false]);
    expect(notified, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(SpendPolicy.storageKey), isFalse);
    // A fresh start reads it back.
    final again = SpendPolicy(push: (_) {});
    await again.load();
    expect(again.spendUnconfirmed, isFalse);
    // Setting the same value again does nothing.
    await policy.setSpendUnconfirmed(false);
    expect(pushed, [false]);
  });

  test('a failed write leaves the previous policy in force', () async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = FailingPreferences({});
    final pushed = <bool>[];
    final policy = SpendPolicy(push: pushed.add);
    await expectLater(policy.setSpendUnconfirmed(false), throwsStateError);
    expect(policy.spendUnconfirmed, isTrue);
    expect(pushed, isEmpty);
  });

  test('a core that is not up yet does not lose the stored choice', () async {
    final policy = SpendPolicy(push: (_) => throw StateError('bridge down'));
    await policy.setSpendUnconfirmed(false);
    expect(policy.spendUnconfirmed, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(SpendPolicy.storageKey), isFalse);
  });

  testWidgets('Security has the switch and says what turning it off does', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await spendPolicy.load();
    await tester.pumpWidget(const MaterialApp(home: SecuritySettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('Spend unconfirmed funds'), findsOneWidget);
    expect(find.text(spendUnconfirmedNote), findsOneWidget);
    expect(spendUnconfirmedNote, contains('waits for one confirmation'));
    expect(spendUnconfirmedNote, contains('never used again'));
    final toggle = find.byKey(const Key('spend-unconfirmed-switch'));
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(spendPolicy.spendUnconfirmed, isFalse);
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(
      find.text('Off: received funds and change wait for 1 confirmation'),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(SpendPolicy.storageKey), isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(spendPolicy.spendUnconfirmed, isTrue);
  });
}
