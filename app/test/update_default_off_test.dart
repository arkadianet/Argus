import 'dart:io';

import 'package:argus_wallet/services/update_service.dart';
import 'package:argus_wallet/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/update_fakes.dart';

/// Counts every HTTP client anything tries to create, and refuses it.
class DenyHttp extends HttpOverrides {
  int clients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw StateError('HTTP client created');
  }
}

/// The privacy promise, from the outside: nothing here may open a connection
/// unless the user turned the check on or asked for one.
void main() {
  late DenyHttp deny;
  HttpOverrides? previous;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    previous = HttpOverrides.current;
    deny = DenyHttp();
    HttpOverrides.global = deny;
  });
  tearDown(() => HttpOverrides.global = previous);

  test('the app-wide service, started the way main() starts it, makes no request while the setting is off', () async {
    await updateService.checkOnStart();
    expect(updateService.enabled, isFalse);
    expect(updateService.lastChecked, isNull);
    expect(deny.clients, 0);
  });

  testWidgets('opening Settings, then About, makes no request', (tester) async {
    // The app-wide service asks Android through its channel; answer it.
    const channel = MethodChannel('com.argus.wallet/update');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'supportedAbis' ? <String>[] : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About Argus'));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates'), findsOneWidget);
    expect(deny.clients, 0);

    // Reading the setting and the saved offer is not a request either.
    await tester.tap(find.byKey(const Key('update-check-toggle')));
    await tester.pumpAndSettle();
    expect(deny.clients, 0, reason: 'switching it on waits for the next start; it asks nothing now');
  });

  test('switched on, a start makes one attempt, and a start the same day none', () async {
    SharedPreferences.setMockInitialValues({'argus_update_check': true});
    final first = UpdateService(platform: FakePlatform(null), current: AppVersion.tryParse('1.0.0-beta.1'));
    await first.checkOnStart();
    expect(deny.clients, 1);
    // Here the client is refused, which shows up as a failed check; it must
    // not leave the service stuck checking.
    expect(first.checkError, isNotNull);
    expect(first.checking, isFalse);

    final sameDay = UpdateService(platform: FakePlatform(null), current: AppVersion.tryParse('1.0.0-beta.1'));
    await sameDay.checkOnStart();
    expect(deny.clients, 1);
  });

  test('Check now is the only way to ask with the setting off, and it asks once per tap', () async {
    final svc = UpdateService(platform: FakePlatform(null), current: AppVersion.tryParse('1.0.0-beta.1'));
    await svc.checkOnStart();
    expect(deny.clients, 0);
    await svc.checkNow();
    expect(deny.clients, 1);
    expect(svc.checking, isFalse);
    await svc.checkNow();
    expect(deny.clients, 2);
  });
}
