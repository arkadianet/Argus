import 'dart:convert';

import 'package:argus_wallet/build_info.dart';
import 'package:argus_wallet/services/update_service.dart';
import 'package:argus_wallet/ui/settings/update_notice.dart';
import 'package:argus_wallet/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/update_fakes.dart';

class Stub extends UpdateService {
  Stub({super.platform, super.current});

  void offer(String version) {
    available = ReleaseInfo(version: AppVersion.tryParse(version)!, notes: 'Notes.', assets: const []);
    notifyListeners();
  }
}

Future<void> show(WidgetTester tester, UpdateService svc) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Keyed by the service so a second launch in one test is a fresh widget
  // state, as a real relaunch is, rather than the old one handed a new service.
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [UpdateNotice(key: ObjectKey(svc), updates: svc)]))));
  await tester.pumpAndSettle();
}

void main() {
  late Stub svc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    svc = Stub(platform: FakePlatform(null), current: AppVersion.tryParse('1.0.0-beta.1'));
  });

  testWidgets('says nothing when there is nothing to say', (tester) async {
    await show(tester, svc);
    expect(find.byKey(const Key('update-notice')), findsNothing);
    expect(find.textContaining('available'), findsNothing);
  });

  testWidgets('names the version once a newer release is known', (tester) async {
    await show(tester, svc);
    svc.offer('1.0.0-beta.2');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-notice')), findsOneWidget);
    expect(find.text('Argus 1.0.0-beta.2 is available.'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    expect(find.byTooltip('Dismiss'), findsOneWidget);
  });

  testWidgets('View opens About, where the notes and the download are', (tester) async {
    await show(tester, svc);
    svc.offer('1.0.0-beta.2');
    await tester.pumpAndSettle();
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text('About'), findsOneWidget);
    expect(find.byKey(const Key('update-card')), findsOneWidget);
  });

  testWidgets('dismissing hides it, is remembered, and the next release brings it back', (tester) async {
    await show(tester, svc);
    svc.offer('1.0.0-beta.2');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-notice')), findsNothing);
    expect((await SharedPreferences.getInstance()).getString('argus_update_dismissed'), '1.0.0-beta.2');

    // Another launch: the saved release is still known, the banner stays away.
    SharedPreferences.setMockInitialValues({
      'argus_update_dismissed': '1.0.0-beta.2',
      'argus_update_latest': jsonEncode(ReleaseInfo(version: AppVersion.tryParse('1.0.0-beta.2')!, notes: '', assets: const []).toJson()),
    });
    final relaunched = Stub(platform: FakePlatform(null), current: AppVersion.tryParse('1.0.0-beta.1'));
    await show(tester, relaunched);
    expect(relaunched.available, isNotNull);
    expect(find.byKey(const Key('update-notice')), findsNothing);

    relaunched.offer('1.0.0-beta.3');
    await tester.pumpAndSettle();
    expect(find.text('Argus 1.0.0-beta.3 is available.'), findsOneWidget);
  });

  testWidgets('the Settings hub carries it, and it appears from a saved check without any request', (tester) async {
    // The app-wide service compares with the version this build really is, so
    // the release on offer is always one major version ahead of it.
    final ahead = '${AppVersion.tryParse(appVersion)!.major + 1}.0.0';
    SharedPreferences.setMockInitialValues({
      'argus_update_latest': jsonEncode(ReleaseInfo(version: AppVersion.tryParse(ahead)!, notes: 'Notes.', assets: const []).toJson()),
    });
    // The app-wide service asks Android through its channel; answer it, as a
    // phone would.
    const channel = MethodChannel('com.argus.wallet/update');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'supportedAbis' ? <String>[] : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateNotice), findsOneWidget);
    expect(find.text('Argus $ahead is available.'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-notice')), findsNothing);
    // The rest of the hub is where it was.
    expect(find.text('About Argus'), findsOneWidget);
  });
}
