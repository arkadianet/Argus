import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:argus_wallet/services/apk_signature.dart';
import 'package:argus_wallet/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/apk_fixture.dart';
import 'support/failing_preferences.dart';
import 'support/update_fakes.dart';

final certA = fakeCertificate(1);
final certB = fakeCertificate(2);
final goodApk = signedApk(certA);
final otherKeyApk = signedApk(certB);
final unsignedApk = apk();

const arm64 = 'argus-1.0.0-beta.2-arm64-v8a.apk';
const x86 = 'argus-1.0.0-beta.2-x86_64.apk';
const universal = 'argus-1.0.0-beta.2-universal.apk';

class Harness {
  Harness(this.root) : platform = FakePlatform(Directory('${root.path}/updates')) {
    platform.certificates = [certA];
  }

  final Directory root;
  final FakeGitHub gh = FakeGitHub();
  final FakePlatform platform;
  DateTime now = DateTime.utc(2026, 10, 20, 9);

  Directory get downloads => platform.dir!;

  List<String> get leftovers => downloads.existsSync() ? downloads.listSync().map((e) => e.path.split('/').last).toList() : [];

  UpdateService service({String current = '1.0.0-beta.1'}) => UpdateService(
        platform: platform,
        clientFactory: gh.create,
        clock: () => now,
        current: AppVersion.tryParse(current),
      );

  /// A release on the fake GitHub: asset name to the bytes it serves.
  void publish(String tag, {Map<String, List<int>>? files, bool digests = true, String notes = 'What is new.'}) {
    final served = files ?? {arm64: goodApk, universal: goodApk};
    gh.releaseBody = releaseJson(
      tag,
      body: notes,
      assets: [for (final e in served.entries) assetJson(e.key, e.value, digest: digests)],
    );
    for (final e in served.entries) {
      gh.files[assetUrl(e.key)] = Served.bytes(e.value);
    }
  }

  /// A service that has already found beta.2.
  Future<UpdateService> found({Map<String, List<int>>? files, bool digests = true}) async {
    publish('v1.0.0-beta.2', files: files, digests: digests);
    final svc = service();
    await svc.checkNow();
    expect(svc.available, isNotNull, reason: svc.checkError);
    return svc;
  }
}

void main() {
  late Harness h;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    h = Harness(await Directory.systemTemp.createTemp('update_service_test'));
  });
  tearDown(() => h.root.delete(recursive: true));

  group('the setting', () {
    test('is off by default, and an off service never builds a client', () async {
      final svc = h.service();
      await svc.ensureLoaded();
      expect(svc.enabled, isFalse);
      await svc.checkOnStart();
      expect(h.gh.clientsCreated, 0);
      expect(h.gh.requests, isEmpty);
      expect(svc.lastChecked, isNull);
    });

    test('turned on, it is remembered by the next launch', () async {
      expect(await h.service().setEnabled(true), isTrue);
      final next = h.service();
      await next.ensureLoaded();
      expect(next.enabled, isTrue);
      expect(await next.setEnabled(false), isTrue);
      final last = h.service();
      await last.ensureLoaded();
      expect(last.enabled, isFalse);
    });

    test('switching it on makes no request by itself', () async {
      await h.service().setEnabled(true);
      expect(h.gh.requests, isEmpty);
    });

    test('a write that fails leaves it as it was, in both directions', () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = FailingPreferences({'flutter.argus_update_check': true});
      final on = h.service();
      await on.ensureLoaded();
      expect(on.enabled, isTrue);
      var notified = 0;
      on.addListener(() => notified++);
      expect(await on.setEnabled(false), isFalse);
      expect(on.enabled, isTrue, reason: 'a failed write must not leave the app checking after it looked switched off');
      expect(notified, 0);

      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = FailingPreferences({});
      final off = h.service();
      expect(await off.setEnabled(true), isFalse);
      expect(off.enabled, isFalse);
    });

    test('unreadable preferences leave it off', () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = _ThrowingPreferences();
      final svc = h.service();
      await svc.ensureLoaded();
      expect(svc.enabled, isFalse);
      await svc.checkOnStart();
      expect(h.gh.requests, isEmpty);
    });
  });

  group('the start-up check', () {
    setUp(() => SharedPreferences.setMockInitialValues({'argus_update_check': true}));

    test('asks once, then not again until a day has passed', () async {
      h.publish('v1.0.0-beta.2');
      final start = h.now;
      final first = h.service();
      await first.checkOnStart();
      expect(h.gh.apiRequests, hasLength(1));
      expect(first.lastChecked!.isAtSameMomentAs(start), isTrue);

      // The app is restarted a few hours later, and again just under a day on.
      h.now = start.add(const Duration(hours: 3));
      await h.service().checkOnStart();
      h.now = start.add(const Duration(hours: 23, minutes: 59));
      await h.service().checkOnStart();
      expect(h.gh.apiRequests, hasLength(1));

      h.now = start.add(const Duration(hours: 24));
      await h.service().checkOnStart();
      expect(h.gh.apiRequests, hasLength(2));
    });

    test('a clock set back does not hold the next check off', () async {
      h.publish('v1.0.0-beta.2');
      SharedPreferences.setMockInitialValues({
        'argus_update_check': true,
        'argus_update_last_check': h.now.add(const Duration(days: 10)).millisecondsSinceEpoch,
      });
      await h.service().checkOnStart();
      expect(h.gh.apiRequests, hasLength(1));
    });

    test('an attempt that fails still counts as the day\'s check', () async {
      h.gh.failure = const SocketException('offline');
      final first = h.service();
      await first.checkOnStart();
      expect(h.gh.apiRequests, hasLength(1));
      expect(first.checkError, isNotNull);

      h.now = h.now.add(const Duration(hours: 1));
      await h.service().checkOnStart();
      expect(h.gh.apiRequests, hasLength(1));
    });

    test('does nothing if the setting is turned off again', () async {
      final svc = h.service();
      await svc.setEnabled(false);
      await svc.checkOnStart();
      expect(h.gh.requests, isEmpty);
    });
  });

  group('Check now', () {
    test('works with the setting off, and as often as it is tapped', () async {
      h.publish('v1.0.0-beta.2');
      final svc = h.service();
      await svc.ensureLoaded();
      expect(svc.enabled, isFalse);
      await svc.checkNow();
      await svc.checkNow();
      expect(h.gh.apiRequests, hasLength(2));
      expect(svc.available, isNotNull);
      expect(svc.enabled, isFalse, reason: 'asking once does not switch the setting on');
    });

    test('counts as the day\'s check for the start-up one', () async {
      SharedPreferences.setMockInitialValues({'argus_update_check': true});
      h.publish('v1.0.0-beta.2');
      await h.service().checkNow();
      await h.service().checkOnStart();
      expect(h.gh.apiRequests, hasLength(1));
    });

    test('two taps at once make one request', () async {
      h.publish('v1.0.0-beta.2');
      h.gh.releaseGate = Completer<void>();
      final svc = h.service();
      final a = svc.checkNow();
      final b = svc.checkNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(svc.checking, isTrue);
      h.gh.releaseGate!.complete();
      await Future.wait([a, b]);
      expect(h.gh.apiRequests, hasLength(1));
      expect(svc.checking, isFalse);
    });
  });

  group('what is sent', () {
    test('one HTTPS GET of the latest release with a generic User-Agent and nothing else', () async {
      h.publish('v1.0.0-beta.2');
      await h.service().checkNow();
      final request = h.gh.requests.single;
      expect(request.method, 'GET');
      expect(request.url, latestReleaseUri);
      expect(request.url.toString(), 'https://api.github.com/repos/arkadianet/Argus/releases/latest');
      expect(request.headers, {'user-agent': 'Argus'});
      expect((request as http.Request).bodyBytes, isEmpty);
    });

    test('the download asks for the file with the same single header', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      final request = h.gh.fileRequests.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), assetUrl(arm64));
      expect(request.headers, {'user-agent': 'Argus'});
    });

    test('the client is closed after every request', () async {
      final svc = await h.found();
      expect(h.gh.clientsClosed, h.gh.clientsCreated);
      await svc.downloadAndVerify();
      expect(h.gh.clientsClosed, h.gh.clientsCreated);
    });
  });

  group('the check', () {
    test('finds a newer release, offers it, and keeps it across restarts without asking again', () async {
      h.publish('v1.0.0-beta.2', notes: 'Fixes.');
      final svc = h.service();
      await svc.checkNow();
      expect(svc.available!.version.toString(), '1.0.0-beta.2');
      expect(svc.available!.notes, 'Fixes.');
      expect(svc.noticeVisible, isTrue);
      expect(svc.checkError, isNull);

      final after = h.service();
      await after.ensureLoaded();
      expect(after.available!.version.toString(), '1.0.0-beta.2');
      expect(after.noticeVisible, isTrue);
      expect(h.gh.apiRequests, hasLength(1));
    });

    test('compares like semver: alpha to beta is newer, beta.2 to beta.10 too', () async {
      h.publish('v1.0.0-beta.1');
      final fromAlpha = h.service(current: '1.0.0-alpha.59');
      await fromAlpha.checkNow();
      expect(fromAlpha.available!.version.toString(), '1.0.0-beta.1');

      h.publish('v1.0.0-beta.10');
      final fromBeta2 = h.service(current: '1.0.0-beta.2');
      await fromBeta2.checkNow();
      expect(fromBeta2.available!.version.toString(), '1.0.0-beta.10');
    });

    test('offers nothing when running the latest, or something newer', () async {
      h.publish('v1.0.0-beta.1');
      final same = h.service();
      await same.checkNow();
      expect(same.available, isNull);
      expect(same.checkError, isNull);
      expect(same.lastChecked, isNotNull);

      final ahead = h.service(current: '1.0.0-rc.1');
      await ahead.checkNow();
      expect(ahead.available, isNull);
      expect(ahead.noticeVisible, isFalse);
    });

    test('a saved offer is dropped once the app has caught up with it', () async {
      h.publish('v1.0.0-beta.2');
      await h.service().checkNow();
      final updated = h.service(current: '1.0.0-beta.2');
      await updated.ensureLoaded();
      expect(updated.available, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('argus_update_latest'), isNull);
    });

    test('a saved offer that cannot be read is dropped', () async {
      SharedPreferences.setMockInitialValues({'argus_update_latest': '{not json'});
      final svc = h.service();
      await svc.ensureLoaded();
      expect(svc.available, isNull);
      expect((await SharedPreferences.getInstance()).getString('argus_update_latest'), isNull);
    });

    test('the notice can be dismissed for one version, and returns for the next', () async {
      h.publish('v1.0.0-beta.2');
      final svc = h.service();
      await svc.checkNow();
      await svc.dismissNotice();
      expect(svc.noticeVisible, isFalse);
      expect(svc.available, isNotNull, reason: 'About still shows it');

      final restarted = h.service();
      await restarted.ensureLoaded();
      expect(restarted.noticeVisible, isFalse, reason: 'dismissal is remembered');

      h.publish('v1.0.0-beta.3');
      await restarted.checkNow();
      expect(restarted.available!.version.toString(), '1.0.0-beta.3');
      expect(restarted.noticeVisible, isTrue);
    });

    test('a failed check says why and keeps what was known', () async {
      h.publish('v1.0.0-beta.2');
      final svc = h.service();
      await svc.checkNow();

      Future<String> failWith({int status = 200, Object? failure, List<int>? raw}) async {
        h.gh
          ..releaseStatus = status
          ..failure = failure
          ..rawReleaseBody = raw;
        await svc.checkNow();
        expect(svc.available, isNotNull, reason: 'the earlier finding survives a failed check');
        expect(svc.checking, isFalse);
        return svc.checkError!;
      }

      expect(await failWith(status: 403), contains('limiting'));
      expect(await failWith(status: 429), contains('limiting'));
      expect(await failWith(status: 404), contains('no release'));
      expect(await failWith(status: 500), contains('500'));
      expect(await failWith(failure: const SocketException('x')), contains('Could not reach GitHub'));
      expect(await failWith(failure: http.ClientException('x')), contains('Could not reach GitHub'));
      expect(await failWith(failure: TimeoutException('x')), contains('in time'));
      expect(await failWith(raw: utf8.encode('<html>captive portal</html>')), contains('not understood'));
      expect(await failWith(raw: [0xff, 0xfe, 0x00]), contains('not understood'));
      expect(await failWith(raw: utf8.encode('{"tag_name":"nightly"}')), contains('not understood'));
      expect(await failWith(raw: utf8.encode(jsonEncode(releaseJson('v9.0.0', prerelease: true)))), contains('not understood'));
    });

    test('an answer bigger than any release is refused', () async {
      h.gh.rawReleaseBody = List<int>.filled(maxReleaseJsonBytes + 1, 0x20);
      final svc = h.service();
      await svc.checkNow();
      expect(svc.available, isNull);
      expect(svc.checkError, contains('larger than expected'));
    });

    test('a successful check clears the earlier failure', () async {
      h.gh.failure = const SocketException('x');
      final svc = h.service();
      await svc.checkNow();
      expect(svc.checkError, isNotNull);
      h.gh.failure = null;
      h.publish('v1.0.0-beta.2');
      await svc.checkNow();
      expect(svc.checkError, isNull);
    });
  });

  group('download and verify', () {
    test('a good download is checked, kept under the installer name, and offered', () async {
      final svc = await h.found();
      final stages = <UpdateStage>[];
      svc.addListener(() {
        if (stages.isEmpty || stages.last != svc.stage) stages.add(svc.stage);
      });
      await svc.downloadAndVerify();

      expect(svc.stage, UpdateStage.verified);
      expect(stages, [UpdateStage.downloading, UpdateStage.verifying, UpdateStage.verified]);
      expect(svc.stageMessage, isNull);
      expect(svc.verifiedSigner, certificateSha256(certA));
      expect(svc.downloadedBytes, goodApk.length);
      expect(svc.totalBytes, goodApk.length);
      expect(h.leftovers, ['argus-update.apk']);
      expect(File('${h.downloads.path}/argus-update.apk').readAsBytesSync(), goodApk);
    });

    test('it works when GitHub lists no checksum, on the signer alone', () async {
      final svc = await h.found(digests: false);
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.verified);
    });

    test('a download signed with another key is deleted and called what it is', () async {
      final svc = await h.found(files: {arm64: otherKeyApk, universal: otherKeyApk});
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.rejected);
      expect(svc.stageMessage, contains('not signed by the same key as this app'));
      expect(svc.stageMessage, contains('must not be installed'));
      expect(svc.verifiedSigner, isNull);
      expect(h.leftovers, isEmpty);
      await svc.install();
      expect(h.platform.installed, isEmpty);
    });

    test('a download that does not match GitHub\'s checksum is deleted', () async {
      h.publish('v1.0.0-beta.2');
      // The listing says one thing, the server delivers another, even though
      // the signer is right.
      h.gh.releaseBody = releaseJson('v1.0.0-beta.2', assets: [
        assetJson(arm64, goodApk, digestOverride: 'sha256:${'0' * 64}'),
      ]);
      final svc = h.service();
      await svc.checkNow();
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.rejected);
      expect(svc.stageMessage, contains('checksum'));
      expect(h.leftovers, isEmpty);
    });

    test('an APK with no v2 or v3 signature is deleted, not offered', () async {
      final svc = await h.found(files: {arm64: unsignedApk, universal: unsignedApk});
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.rejected);
      expect(svc.stageMessage, contains('could not be read'));
      expect(h.leftovers, isEmpty);
    });

    test('a file that is not an APK at all is deleted', () async {
      final junk = Uint8List.fromList(List<int>.generate(900, (i) => i & 0xff));
      final svc = await h.found(files: {arm64: junk, universal: junk});
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.rejected);
      expect(h.leftovers, isEmpty);
    });

    test('with this app\'s own key unreadable there is nothing to compare, so nothing is offered', () async {
      final svc = await h.found();
      h.platform.certificates = null;
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.rejected);
      expect(svc.stageMessage, contains('own signing key'));
      expect(h.leftovers, isEmpty);

      h.platform.certificates = const [];
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.rejected);
    });

    test('a key found among several of this app\'s is enough', () async {
      final svc = await h.found();
      h.platform.certificates = [certB, certA];
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.verified);
    });

    test('the build for this CPU is the one fetched', () async {
      final files = {arm64: goodApk, x86: goodApk, universal: goodApk};
      h.platform.abis = ['x86_64', 'x86'];
      final svc = await h.found(files: files);
      expect(svc.assetForDevice!.name, x86);
      await svc.downloadAndVerify();
      expect(h.gh.fileRequests.single.url.toString(), assetUrl(x86));
    });

    test('a phone with no build of its own gets the universal APK', () async {
      h.platform.abis = ['armeabi-v7a'];
      final svc = await h.found();
      await svc.downloadAndVerify();
      expect(h.gh.fileRequests.single.url.toString(), assetUrl(universal));
    });

    test('a release with nothing for this phone says so and fetches nothing', () async {
      final svc = await h.found(files: {x86: goodApk});
      expect(svc.assetForDevice, isNull);
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('no APK for your phone'));
      expect(h.gh.fileRequests, isEmpty);
    });

    test('progress reaches the listeners while it arrives', () async {
      final gate = StreamController<List<int>>();
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served(() => gate.stream);
      final seen = <int>[];
      svc.addListener(() {
        if (svc.stage == UpdateStage.downloading) seen.add(svc.downloadedBytes);
      });
      final done = svc.downloadAndVerify();
      gate.add(goodApk.sublist(0, 100));
      await _until(() => svc.downloadedBytes == 100);
      // Repaints are throttled, so let the clock run before the next chunk.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      gate.add(goodApk.sublist(100, 200));
      await _until(() => svc.downloadedBytes == 200);
      gate.add(goodApk.sublist(200));
      await gate.close();
      await done;
      expect(seen.where((n) => n > 0 && n < goodApk.length), isNotEmpty);
      expect(svc.downloadedBytes, goodApk.length);
    });

    test('the file is only given its .apk name once it has passed', () async {
      final gate = StreamController<List<int>>();
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served(() => gate.stream);
      final done = svc.downloadAndVerify();
      gate.add(goodApk.sublist(0, 100));
      await _until(() => svc.downloadedBytes == 100);
      expect(h.leftovers, ['argus-update.apk.part']);
      gate.add(goodApk.sublist(100));
      await gate.close();
      await done;
      expect(h.leftovers, ['argus-update.apk']);
    });

    test('more bytes than GitHub lists stops the download and leaves nothing', () async {
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served.bytes([...goodApk, ...List<int>.filled(500, 1)]);
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('larger than GitHub lists'));
      expect(h.leftovers, isEmpty);
    });

    test('fewer bytes than GitHub lists is a failed download, not a bad file', () async {
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served.bytes(goodApk.sublist(0, goodApk.length - 1));
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('ended early'));
      expect(h.leftovers, isEmpty);
    });

    test('a file larger than Argus will take is not even requested', () async {
      h.publish('v1.0.0-beta.2');
      h.gh.releaseBody = releaseJson('v1.0.0-beta.2', assets: [
        {...assetJson(arm64, goodApk), 'size': maxApkBytes + 1},
      ]);
      final svc = h.service();
      await svc.checkNow();
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('larger than Argus will accept'));
      expect(h.gh.fileRequests, isEmpty);
    });

    test('an error from GitHub is a failed download', () async {
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served.bytes(const [], status: 404);
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('404'));
      expect(h.leftovers, isEmpty);
    });

    test('a redirect away from GitHub is refused', () async {
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served.bytes(goodApk, finalUrl: Uri.parse('https://cdn.evil.example/a.apk'));
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('redirected away from GitHub'));
      expect(h.leftovers, isEmpty);

      h.gh.files[assetUrl(arm64)] = Served.bytes(goodApk, finalUrl: Uri.parse('http://objects.githubusercontent.com/a.apk'));
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed, reason: 'plain http, even to a GitHub host');

      h.gh.files[assetUrl(arm64)] =
          Served.bytes(goodApk, finalUrl: Uri.parse('https://release-assets.githubusercontent.com/github-production-release-asset/1/a'));
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.verified, reason: 'the CDN GitHub really hands downloads to');
    });

    test('a connection that fails mid-way is a failed download', () async {
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served(() async* {
        yield goodApk.sublist(0, 50);
        throw const SocketException('reset');
      });
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('Could not reach GitHub'));
      expect(h.leftovers, isEmpty);
    });

    test('cancelling stops it, removes the partial file and goes quiet', () async {
      final gate = StreamController<List<int>>();
      addTearDown(gate.close);
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served(() => gate.stream);
      final done = svc.downloadAndVerify();
      gate.add(goodApk.sublist(0, 120));
      await _until(() => svc.downloadedBytes == 120);
      expect(svc.stage, UpdateStage.downloading);
      final closedBefore = h.gh.clientsClosed;

      svc.cancelDownload();
      // The server is still talking and never hangs up; the download must end
      // on its own account, at the next thing it hears.
      gate.add(goodApk.sublist(120, 200));
      await done.timeout(const Duration(seconds: 3));

      expect(svc.stage, UpdateStage.idle);
      expect(svc.stageMessage, 'Download cancelled.');
      expect(h.leftovers, isEmpty);
      expect(h.gh.clientsClosed, greaterThan(closedBefore));
      expect(svc.verifiedSigner, isNull);
    });

    test('cancelling when nothing is downloading does nothing', () async {
      final svc = await h.found();
      svc.cancelDownload();
      expect(svc.stage, UpdateStage.idle);
      expect(svc.stageMessage, isNull);
    });

    test('a download can be tried again after a failure, and replaces the old file', () async {
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served.bytes(goodApk.sublist(0, 10));
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      h.gh.files[assetUrl(arm64)] = Served.bytes(goodApk);
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.verified);
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.verified);
      expect(h.leftovers, ['argus-update.apk']);
    });

    test('a phone with nowhere to keep a download says so', () async {
      final svc = await h.found();
      h.platform.dir = null;
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.failed);
      expect(svc.stageMessage, contains('cannot keep a download'));
    });

    test('while one runs, a check does not disturb it', () async {
      final gate = StreamController<List<int>>();
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served(() => gate.stream);
      final done = svc.downloadAndVerify();
      await _until(() => svc.stage == UpdateStage.downloading);
      final before = h.gh.apiRequests.length;
      await svc.checkNow();
      expect(h.gh.apiRequests.length, before, reason: 'no request while a download is in progress');
      gate.add(goodApk);
      await gate.close();
      await done;
      expect(svc.stage, UpdateStage.verified);
    });

    test('a check that finishes mid-download leaves the download alone', () async {
      final gate = StreamController<List<int>>();
      final svc = await h.found();
      h.gh.files[assetUrl(arm64)] = Served(() => gate.stream);
      // The check starts first and is held at GitHub's door.
      h.gh.releaseGate = Completer<void>();
      h.publish('v1.0.0-beta.3', files: {
        'argus-1.0.0-beta.3-arm64-v8a.apk': goodApk,
        'argus-1.0.0-beta.3-universal.apk': goodApk,
      });
      final check = svc.checkNow();
      await _until(() => h.gh.apiRequests.length == 2);
      final done = svc.downloadAndVerify();
      await _until(() => svc.stage == UpdateStage.downloading);
      gate.add(goodApk.sublist(0, 100));
      await _until(() => svc.downloadedBytes == 100);

      h.gh.releaseGate!.complete();
      await check;
      expect(svc.stage, UpdateStage.downloading);
      expect(svc.available!.version.toString(), '1.0.0-beta.2', reason: 'the release being downloaded stays the offer');
      expect(h.leftovers, ['argus-update.apk.part']);

      gate.add(goodApk.sublist(100));
      await gate.close();
      await done;
      expect(svc.stage, UpdateStage.verified);

      // The next check is free to move on.
      h.gh.releaseGate = null;
      await svc.checkNow();
      expect(svc.available!.version.toString(), '1.0.0-beta.3');
    });

    test('a newer release found later discards a file checked for the older one', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      expect(svc.stage, UpdateStage.verified);
      h.publish('v1.0.0-beta.3', files: {
        'argus-1.0.0-beta.3-arm64-v8a.apk': goodApk,
        'argus-1.0.0-beta.3-universal.apk': goodApk,
      });
      await svc.checkNow();
      expect(svc.available!.version.toString(), '1.0.0-beta.3');
      expect(svc.stage, UpdateStage.idle);
      expect(h.leftovers, isEmpty);
    });

    test('the same release found again keeps the verified file', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      await svc.checkNow();
      expect(svc.stage, UpdateStage.verified);
      expect(h.leftovers, ['argus-update.apk']);
    });

    test('a download left behind by an earlier run is removed at start-up', () async {
      h.downloads.createSync(recursive: true);
      File('${h.downloads.path}/argus-update.apk').writeAsBytesSync(goodApk);
      File('${h.downloads.path}/argus-update.apk.part').writeAsBytesSync([1, 2, 3]);
      await h.service().ensureLoaded();
      expect(h.leftovers, isEmpty);
    });
  });

  group('install', () {
    test('a verified download is handed to the installer', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      await svc.install();
      expect(h.platform.installed, ['${h.downloads.path}/argus-update.apk']);
      expect(h.platform.settingsOpened, 0);
      expect(svc.stage, UpdateStage.verified, reason: 'the installer may be cancelled and tried again');
    });

    test('without Android\'s permission it opens the page that grants it, and installs nothing', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      h.platform.allowInstall = false;
      await svc.install();
      expect(h.platform.settingsOpened, 1);
      expect(h.platform.installed, isEmpty);
      expect(svc.stageMessage, contains('Allow Argus to install apps'));

      h.platform.allowInstall = true;
      await svc.install();
      expect(h.platform.installed, hasLength(1));
    });

    test('an installer that will not open is reported', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      h.platform.installerOpens = false;
      await svc.install();
      expect(svc.stageMessage, contains('could not open its installer'));
    });

    test('nothing is installed before a download has passed', () async {
      final svc = await h.found();
      await svc.install();
      expect(h.platform.installed, isEmpty);
      expect(h.platform.settingsOpened, 0);
    });

    test('a file swapped for another key\'s after the check is caught at install', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      // Same length as the verified file, different signer.
      expect(otherKeyApk.length, goodApk.length);
      File('${h.downloads.path}/argus-update.apk').writeAsBytesSync(otherKeyApk);
      await svc.install();
      expect(h.platform.installed, isEmpty);
      expect(svc.stage, UpdateStage.rejected);
      expect(svc.stageMessage, contains('not signed by the same key'));
      expect(h.leftovers, isEmpty);
    });

    test('a file whose size changed after the check is caught at install', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      File('${h.downloads.path}/argus-update.apk').writeAsBytesSync([...goodApk, 0]);
      await svc.install();
      expect(h.platform.installed, isEmpty);
      expect(svc.stage, UpdateStage.rejected);
    });

    test('a file that vanished is caught at install', () async {
      final svc = await h.found();
      await svc.downloadAndVerify();
      File('${h.downloads.path}/argus-update.apk').deleteSync();
      await svc.install();
      expect(h.platform.installed, isEmpty);
      expect(svc.stage, UpdateStage.rejected);
    });
  });

  group('this app\'s own key', () {
    test('is reported as the SHA-256 of each certificate Android lists', () async {
      h.platform.certificates = [certA, certB];
      expect(await h.service().ownSigningFingerprints(), [certificateSha256(certA), certificateSha256(certB)]);
    });

    test('is null when Android will not say', () async {
      h.platform.certificates = null;
      expect(await h.service().ownSigningFingerprints(), isNull);
      h.platform.certificates = const [];
      expect(await h.service().ownSigningFingerprints(), isNull);
    });
  });

  group('verifyApk against real signatures', () {
    // Archives signed by apksigner; see apk_signature_test.dart.
    final v2Only = File('test/fixtures/signed/v2_only.apk');
    final v2v3 = File('test/fixtures/signed/v2_v3.apk');

    test('passes when the signer is this app\'s key, and names it', () async {
      final own = (await readApkSignersFromFile(v2Only)).first;
      final result = await verifyApk(file: v2Only, fileSha256: 'x', expectedSha256: null, appCertificates: [own]);
      expect(result.verdict, ApkVerdict.verified);
      expect(result.ok, isTrue);
      expect(result.signerSha256, 'b18fade1976d1e326aed3583cd8a2c4eb2ee5cbef390aaf7988fd359d4f9fc3c');
    });

    test('refuses when the signer is some other key', () async {
      final other = (await readApkSignersFromFile(v2v3)).first;
      final result = await verifyApk(file: v2Only, fileSha256: 'x', expectedSha256: null, appCertificates: [other]);
      expect(result.verdict, ApkVerdict.wrongSigner);
      expect(result.signerSha256, 'b18fade1976d1e326aed3583cd8a2c4eb2ee5cbef390aaf7988fd359d4f9fc3c');
    });

    test('a v3 signature is compared the same way', () async {
      final own = (await readApkSignersFromFile(v2v3)).first;
      expect((await verifyApk(file: v2v3, fileSha256: null, expectedSha256: null, appCertificates: [own])).ok, isTrue);
      final other = (await readApkSignersFromFile(v2Only)).first;
      expect((await verifyApk(file: v2v3, fileSha256: null, expectedSha256: null, appCertificates: [other])).verdict, ApkVerdict.wrongSigner);
    });

    test('a wrong checksum is refused before the signature is even read', () async {
      final own = (await readApkSignersFromFile(v2Only)).first;
      final result = await verifyApk(file: v2Only, fileSha256: 'aa' * 32, expectedSha256: 'bb' * 32, appCertificates: [own]);
      expect(result.verdict, ApkVerdict.checksumMismatch);
      expect(result.signerSha256, isNull);
    });

    test('a file that is not there is unreadable, not an exception', () async {
      final own = (await readApkSignersFromFile(v2Only)).first;
      final result = await verifyApk(file: File('${h.root.path}/missing.apk'), fileSha256: null, expectedSha256: null, appCertificates: [own]);
      expect(result.verdict, ApkVerdict.unreadable);
    });
  });

  group('downloadApk on its own', () {
    late File target;
    final asset = ReleaseAsset(name: universal, size: goodApk.length, url: Uri.parse(assetUrl(universal)));

    setUp(() => target = File('${h.root.path}/out.part'));

    test('hashes what it writes while it writes it', () async {
      h.gh.files[assetUrl(universal)] = Served.bytes(goodApk);
      final result = await downloadApk(client: h.gh.create(), asset: asset, into: target, isCancelled: () => false);
      expect(result.sha256, sha256Hex(goodApk));
      expect(result.bytes, goodApk.length);
      expect(target.readAsBytesSync(), goodApk);
    });

    test('gives up on a server that goes quiet', () async {
      final gate = StreamController<List<int>>();
      addTearDown(gate.close);
      h.gh.files[assetUrl(universal)] = Served(() => gate.stream);
      final run = downloadApk(
        client: h.gh.create(),
        asset: asset,
        into: target,
        isCancelled: () => false,
        stallTimeout: const Duration(milliseconds: 80),
      );
      gate.add(goodApk.sublist(0, 10));
      await expectLater(run, throwsA(isA<UpdateException>().having((e) => e.message, 'message', contains('in time'))));
      expect(target.existsSync(), isFalse);
    });

    test('refuses an address that is not GitHub\'s before connecting', () async {
      final bad = ReleaseAsset(name: universal, size: 10, url: Uri.parse('https://evil.example/a.apk'));
      final client = h.gh.create();
      await expectLater(
        downloadApk(client: client, asset: bad, into: target, isCancelled: () => false),
        throwsA(isA<UpdateException>()),
      );
      expect(h.gh.requests, isEmpty);
    });

    test('honours a lower size cap than the default', () async {
      h.gh.files[assetUrl(universal)] = Served.bytes(goodApk);
      await expectLater(
        downloadApk(client: h.gh.create(), asset: asset, into: target, isCancelled: () => false, maxBytes: goodApk.length - 1),
        throwsA(isA<UpdateException>()),
      );
      expect(h.gh.requests, isEmpty);
    });
  });
}

/// Waits for [condition], letting the download and the test interleave.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'timed out waiting');
}

/// A store whose every call throws, as a corrupted one might.
class _ThrowingPreferences extends InMemorySharedPreferencesStore {
  _ThrowingPreferences() : super.empty();

  @override
  Future<Map<String, Object>> getAll() => throw StateError('unreadable');
}
