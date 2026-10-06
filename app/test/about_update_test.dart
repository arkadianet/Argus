import 'dart:io';

import 'package:argus_wallet/services/apk_signature.dart';
import 'package:argus_wallet/services/update_service.dart';
import 'package:argus_wallet/ui/settings/about_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/apk_fixture.dart';
import 'support/update_fakes.dart';

/// An update service whose state a test sets directly, and whose buttons
/// record what they were asked to do instead of doing it.
class Stub extends UpdateService {
  Stub({super.platform, super.clientFactory, super.clock, super.current});

  int downloads = 0;
  int cancels = 0;
  int installs = 0;

  void present({
    ReleaseInfo? release,
    UpdateStage stage = UpdateStage.idle,
    String? message,
    int downloaded = 0,
    int? total,
    String? signer,
  }) {
    available = release;
    this.stage = stage;
    stageMessage = message;
    downloadedBytes = downloaded;
    totalBytes = total;
    verifiedSigner = signer;
    notifyListeners();
  }

  @override
  Future<void> downloadAndVerify() async => downloads++;

  @override
  void cancelDownload() => cancels++;

  @override
  Future<void> install() async => installs++;
}

ReleaseInfo release({String notes = 'What is new.', List<ReleaseAsset>? assets}) => ReleaseInfo(
      version: AppVersion.tryParse('1.0.0-beta.2')!,
      notes: notes,
      publishedAt: DateTime.utc(2026, 10, 20),
      assets: assets ??
          [
            ReleaseAsset(name: 'argus-1.0.0-beta.2-arm64-v8a.apk', size: 50254123, url: Uri.parse(assetUrl('argus-1.0.0-beta.2-arm64-v8a.apk'))),
            ReleaseAsset(name: 'argus-1.0.0-beta.2-universal.apk', size: 101372707, url: Uri.parse(assetUrl('argus-1.0.0-beta.2-universal.apk'))),
          ],
    );

void main() {
  late FakePlatform platform;
  late Stub stub;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = FakePlatform(null)..certificates = [fakeCertificate(7)];
    stub = Stub(platform: platform, current: AppVersion.tryParse('1.0.0-beta.1'));
  });

  /// [settle] false for a state with an endless animation, which would never
  /// settle: the indeterminate progress bar.
  Future<void> openAbout(WidgetTester tester, UpdateService svc, {bool settle = true}) async {
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AboutPage(updates: svc)));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Switch toggle(WidgetTester tester) => tester.widget<Switch>(find.byKey(const Key('update-check-toggle')));

  group('the setting', () {
    testWidgets('is off, and says who is asked and what they see', (tester) async {
      await openAbout(tester, stub);
      expect(toggle(tester).value, isFalse);
      expect(find.text('Check for updates'), findsOneWidget);
      expect(find.text('Asks GitHub once a day. GitHub sees your IP address.'), findsOneWidget);
      expect(find.textContaining('api.github.com'), findsOneWidget);
      expect(find.textContaining('Off by default'), findsOneWidget);
    });

    testWidgets('can be switched on and is saved', (tester) async {
      await openAbout(tester, stub);
      await tester.tap(find.byKey(const Key('update-check-toggle')));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isTrue);
      expect(stub.enabled, isTrue);
      expect((await SharedPreferences.getInstance()).getBool('argus_update_check'), isTrue);
    });

    testWidgets('can be switched by tapping its row, and off again', (tester) async {
      await openAbout(tester, stub);
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isTrue);
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('argus_update_check'), isFalse);
    });

    testWidgets('opening About fetches nothing', (tester) async {
      final gh = FakeGitHub();
      final svc = UpdateService(platform: platform, clientFactory: gh.create);
      await openAbout(tester, svc);
      expect(gh.clientsCreated, 0);
    });
  });

  group('Check now', () {
    testWidgets('works with the setting off and reports an up-to-date app', (tester) async {
      final gh = FakeGitHub()..releaseBody = releaseJson('v1.0.0-beta.1');
      final svc = UpdateService(platform: platform, clientFactory: gh.create, current: AppVersion.tryParse('1.0.0-beta.1'));
      await openAbout(tester, svc);
      expect(find.text('Not checked yet'), findsOneWidget);

      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();

      expect(gh.apiRequests, hasLength(1));
      expect(svc.enabled, isFalse);
      expect(find.textContaining('Up to date · checked'), findsOneWidget);
      expect(find.byKey(const Key('update-card')), findsNothing);
    });

    testWidgets('shows an update when there is one', (tester) async {
      final gh = FakeGitHub()..releaseBody = releaseJson('v1.0.0-beta.2', body: 'Fixes and things.');
      final svc = UpdateService(platform: platform, clientFactory: gh.create, current: AppVersion.tryParse('1.0.0-beta.1'));
      await openAbout(tester, svc);
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('update-card')), findsOneWidget);
      expect(find.text('Update available'), findsOneWidget);
      expect(find.textContaining('Argus 1.0.0-beta.2'), findsOneWidget);
      expect(find.textContaining('Version 1.0.0-beta.2 is available'), findsOneWidget);
    });

    testWidgets('says why it failed', (tester) async {
      final gh = FakeGitHub()..failure = const SocketException('offline');
      final svc = UpdateService(platform: platform, clientFactory: gh.create);
      await openAbout(tester, svc);
      await tester.tap(find.text('Check now'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not reach GitHub'), findsOneWidget);
    });
  });

  group('the update card', () {
    testWidgets('is absent when nothing newer is known', (tester) async {
      await openAbout(tester, stub);
      expect(find.byKey(const Key('update-card')), findsNothing);
    });

    testWidgets('names the version and date, and offers the download for this phone', (tester) async {
      await stub.ensureLoaded();
      stub.present(release: release());
      await openAbout(tester, stub);
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('Argus 1.0.0-beta.2 · 20 Oct 2026'), findsOneWidget);
      expect(find.byKey(const Key('update-download')), findsOneWidget);
      expect(find.text('Download and verify'), findsOneWidget);
      expect(find.textContaining('argus-1.0.0-beta.2-arm64-v8a.apk · 47.9 MB'), findsOneWidget);
      await tester.tap(find.byKey(const Key('update-download')));
      expect(stub.downloads, 1);
    });

    testWidgets('keeps the release notes as plain text, with nothing to tap', (tester) async {
      const notes = '## Fixes\n<b>bold</b> <a href="https://evil.example">here</a>\n[click me](https://evil.example/md)\nhttps://evil.example/bare';
      await stub.ensureLoaded();
      stub.present(release: release(notes: notes));

      final launched = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          launched.add(call);
          return true;
        },
      );
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/url_launcher'), null));

      await openAbout(tester, stub);
      expect(find.byKey(const Key('update-notes')), findsNothing, reason: 'collapsed until asked for');
      await tester.tap(find.byKey(const Key('update-notes-toggle')));
      await tester.pumpAndSettle();

      final box = find.byKey(const Key('update-notes'));
      expect(box, findsOneWidget);
      final text = tester.widget<Text>(find.descendant(of: box, matching: find.byType(Text)));
      expect(text.data, notes, reason: 'plain data: not Text.rich, not parsed');
      expect(text.textSpan, isNull);
      expect(find.descendant(of: box, matching: find.byType(SelectableText)), findsNothing);
      expect(find.descendant(of: box, matching: find.byType(GestureDetector)), findsNothing);
      expect(find.descendant(of: box, matching: find.byType(InkWell)), findsNothing);

      // Tapping the text, including over a "link", opens nothing.
      await tester.tap(find.textContaining('click me'));
      await tester.pumpAndSettle();
      expect(launched, isEmpty);

      await tester.tap(find.byKey(const Key('update-notes-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-notes')), findsNothing);
    });

    testWidgets('has no notes toggle when the release has none', (tester) async {
      await stub.ensureLoaded();
      stub.present(release: release(notes: ''));
      await openAbout(tester, stub);
      expect(find.byKey(const Key('update-notes-toggle')), findsNothing);
    });

    testWidgets('shows progress and a way to cancel while downloading', (tester) async {
      await stub.ensureLoaded();
      stub.present(release: release(), stage: UpdateStage.downloading, downloaded: 10 * 1024 * 1024, total: 40 * 1024 * 1024);
      await openAbout(tester, stub);
      expect(find.text('Downloading 10.0 MB of 40.0 MB'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byKey(const Key('update-progress'))).value, 0.25);
      expect(find.byKey(const Key('update-download')), findsNothing);
      await tester.tap(find.byKey(const Key('update-cancel')));
      expect(stub.cancels, 1);
    });

    testWidgets('says when it is checking the key', (tester) async {
      await stub.ensureLoaded();
      stub.present(release: release(), stage: UpdateStage.verifying);
      await openAbout(tester, stub, settle: false);
      expect(find.textContaining('signing key'), findsWidgets);
      expect(find.byKey(const Key('update-install')), findsNothing);
    });

    testWidgets('offers Install only after the key matched', (tester) async {
      await stub.ensureLoaded();
      stub.present(release: release(), stage: UpdateStage.verified, signer: 'e5' * 32);
      await openAbout(tester, stub);
      expect(find.byKey(const Key('update-verified')), findsOneWidget);
      expect(find.textContaining('Signed by the same key as this app'), findsOneWidget);
      expect(find.byKey(const Key('update-download')), findsNothing);
      await tester.tap(find.byKey(const Key('update-install')));
      expect(stub.installs, 1);
    });

    testWidgets('tells a rejected download plainly, offers no install, and lets it be retried', (tester) async {
      const message = 'This download is not signed by the same key as this app, so it must not be installed. It has been deleted.';
      await stub.ensureLoaded();
      stub.present(release: release(), stage: UpdateStage.rejected, message: message);
      await openAbout(tester, stub);
      expect(find.text(message), findsOneWidget);
      expect(find.byKey(const Key('update-install')), findsNothing);
      expect(find.byKey(const Key('update-verified')), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('reports a plain failure without alarm', (tester) async {
      await stub.ensureLoaded();
      stub.present(release: release(), stage: UpdateStage.failed, message: 'The download ended early.');
      await openAbout(tester, stub);
      expect(find.text('The download ended early.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('points at the releases page when this phone has no build to fetch', (tester) async {
      await stub.ensureLoaded();
      stub.present(release: release(assets: const []));
      await openAbout(tester, stub);
      expect(find.byKey(const Key('update-download')), findsNothing);
      expect(find.byKey(const Key('update-open-releases')), findsOneWidget);
      expect(find.text('This release has no APK for your phone.'), findsOneWidget);
    });

    testWidgets('on a host that cannot install, only points at the releases page', (tester) async {
      platform.supported = false;
      await stub.ensureLoaded();
      stub.present(release: release());
      await openAbout(tester, stub);
      expect(find.byKey(const Key('update-download')), findsNothing);
      expect(find.byKey(const Key('update-open-releases')), findsOneWidget);
    });

    // The two tests below run the real service, files and all. Real I/O never
    // completes inside a widget test's fake clock, so the service is driven
    // in the real zone and the page is then pumped to show where it ended.
    testWidgets('a download that really runs ends at Install, with the key matched', (tester) async {
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('about_update_test')))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final cert = fakeCertificate(7);
      final good = signedApk(cert);
      final gh = FakeGitHub()
        ..releaseBody = releaseJson('v1.0.0-beta.2', assets: [assetJson('argus-1.0.0-beta.2-arm64-v8a.apk', good)]);
      gh.files[assetUrl('argus-1.0.0-beta.2-arm64-v8a.apk')] = Served.bytes(good);
      final real = FakePlatform(Directory('${dir.path}/updates'))..certificates = [cert];
      final svc = UpdateService(platform: real, clientFactory: gh.create, current: AppVersion.tryParse('1.0.0-beta.1'));

      await tester.runAsync(() async {
        await svc.checkNow();
        await svc.downloadAndVerify();
      });
      await openAbout(tester, svc);

      expect(svc.stage, UpdateStage.verified);
      expect(find.byKey(const Key('update-install')), findsOneWidget);
      expect(find.textContaining('Signed by the same key as this app'), findsOneWidget);
      expect(find.byKey(const Key('update-message')), findsNothing);

      await tester.runAsync(svc.install);
      expect(real.installed, ['${dir.path}/updates/argus-update.apk']);
    });

    testWidgets('a download signed with another key ends at a plain refusal', (tester) async {
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('about_update_test')))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final foreign = signedApk(fakeCertificate(99));
      final gh = FakeGitHub()
        ..releaseBody = releaseJson('v1.0.0-beta.2', assets: [assetJson('argus-1.0.0-beta.2-arm64-v8a.apk', foreign)]);
      gh.files[assetUrl('argus-1.0.0-beta.2-arm64-v8a.apk')] = Served.bytes(foreign);
      final real = FakePlatform(Directory('${dir.path}/updates'))..certificates = [fakeCertificate(7)];
      final svc = UpdateService(platform: real, clientFactory: gh.create, current: AppVersion.tryParse('1.0.0-beta.1'));

      await tester.runAsync(() async {
        await svc.checkNow();
        await svc.downloadAndVerify();
      });
      await openAbout(tester, svc);

      expect(svc.stage, UpdateStage.rejected);
      expect(find.textContaining('not signed by the same key as this app'), findsOneWidget);
      expect(find.textContaining('must not be installed'), findsOneWidget);
      expect(find.byKey(const Key('update-install')), findsNothing);
      expect(find.byKey(const Key('update-verified')), findsNothing);
      expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  });

  group('this app\'s signing key', () {
    testWidgets('is shown as colon-separated SHA-256, eight bytes to a line', (tester) async {
      final cert = fakeCertificate(7);
      platform.certificates = [cert];
      await openAbout(tester, stub);
      expect(find.text('Signing certificate'), findsOneWidget);
      final shown = tester.widget<Text>(find.byKey(const Key('signing-fingerprint'))).data!;
      final expected = formatFingerprint(certificateSha256(cert));
      expect(shown.split('\n'), hasLength(4));
      expect(shown.replaceAll('\n', ':'), expected);
      expect(shown.split('\n').every((line) => line.split(':').length == 8), isTrue);
    });

    testWidgets('says so when Android will not tell', (tester) async {
      platform.certificates = null;
      await openAbout(tester, stub);
      expect(find.byKey(const Key('signing-fingerprint')), findsNothing);
      expect(find.text('Not available on this device.'), findsOneWidget);
    });

    testWidgets('can be copied', (tester) async {
      final cert = fakeCertificate(7);
      platform.certificates = [cert];
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await openAbout(tester, stub);
      await tester.tap(find.byTooltip('Copy'));
      await tester.pump();
      expect(copied, formatFingerprint(certificateSha256(cert)));
    });
  });
}
