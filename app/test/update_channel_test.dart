
import 'package:argus_wallet/services/update_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.argus.wallet/update');
  const platform = AndroidUpdatePlatform();
  final calls = <MethodCall>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
  });

  test('the certificates come back as the bytes Android gave', () async {
    answer((_) async => [
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([4, 5]),
        ]);
    expect(await platform.signingCertificates(), [
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList([4, 5]),
    ]);
    expect(calls.single.method, 'signingCertificates');
  });

  test('the ABIs, in the order Android lists them', () async {
    answer((_) async => ['arm64-v8a', 'armeabi-v7a']);
    expect(await platform.supportedAbis(), ['arm64-v8a', 'armeabi-v7a']);
    expect(calls.single.method, 'supportedAbis');
  });

  test('the download folder is a directory handle, not created by asking', () async {
    answer((_) async => '/data/user/0/app/cache/updates');
    final dir = await platform.downloadDirectory();
    expect(dir!.path, '/data/user/0/app/cache/updates');
    expect(calls.single.method, 'downloadDirectory');
    answer((_) async => '');
    expect(await platform.downloadDirectory(), isNull);
  });

  test('the install permission is asked and its page opened by name', () async {
    answer((call) async => call.method == 'canRequestInstall' ? false : true);
    expect(await platform.canRequestInstall(), isFalse);
    expect(await platform.openInstallSettings(), isTrue);
    expect(calls.map((c) => c.method), ['canRequestInstall', 'openInstallSettings']);
  });

  test('the installer gets the path and nothing else', () async {
    answer((_) async => true);
    expect(await platform.installApk('/cache/updates/argus-update.apk'), isTrue);
    expect(calls.single.method, 'installApk');
    expect(calls.single.arguments, {'path': '/cache/updates/argus-update.apk'});
  });

  test('an answer of null is a no', () async {
    answer((_) async => null);
    expect(await platform.signingCertificates(), isNull);
    expect(await platform.supportedAbis(), isEmpty);
    expect(await platform.downloadDirectory(), isNull);
    expect(await platform.canRequestInstall(), isFalse);
    expect(await platform.openInstallSettings(), isFalse);
    expect(await platform.installApk('/x.apk'), isFalse);
  });

  test('a platform error is a no, never an exception', () async {
    answer((_) async => throw PlatformException(code: 'signing', message: 'boom'));
    expect(await platform.signingCertificates(), isNull);
    expect(await platform.supportedAbis(), isEmpty);
    expect(await platform.downloadDirectory(), isNull);
    expect(await platform.canRequestInstall(), isFalse);
    expect(await platform.openInstallSettings(), isFalse);
    expect(await platform.installApk('/x.apk'), isFalse);
  });

  test('a host with no native side is a no', () async {
    // No handler registered: the call raises MissingPluginException.
    expect(await platform.signingCertificates(), isNull);
    expect(await platform.installApk('/x.apk'), isFalse);
  });

  test('anything but Android never reaches the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    answer((_) async => true);
    expect(platform.supported, isFalse);
    expect(await platform.signingCertificates(), isNull);
    expect(await platform.supportedAbis(), isEmpty);
    expect(await platform.downloadDirectory(), isNull);
    expect(await platform.canRequestInstall(), isFalse);
    expect(await platform.openInstallSettings(), isFalse);
    expect(await platform.installApk('/x.apk'), isFalse);
    expect(calls, isEmpty);
  });
}
