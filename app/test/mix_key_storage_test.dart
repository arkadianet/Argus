import 'package:argus_wallet/services/secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.argus.wallet/secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'mix key bytes round-trip through the existing hex storage format',
    () async {
      String? stored;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'saveMixKey') {
          stored = (call.arguments as Map)['key'] as String;
          return true;
        }
        return stored;
      });
      final key = Uint8List.fromList([0, 1, 15, 128, 255]);
      await SecureStorageService.saveMixKey(
        walletId: 'w',
        mixId: 0,
        keyBytes: key,
      );
      expect(stored, '00010f80ff');
      final loaded = await SecureStorageService.loadMixKey(
        walletId: 'w',
        mixId: 0,
      );
      expect(loaded, key);
      loaded!.fillRange(0, loaded.length, 0);
      expect(key, [
        0,
        1,
        15,
        128,
        255,
      ], reason: 'the adapter does not own the caller buffer');
      key.fillRange(0, key.length, 0);
    },
  );

  test(
    'legacy stored hex loads as mutable bytes, including uppercase',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => '00aAFF');
      final key = await SecureStorageService.loadMixKey(
        walletId: 'w',
        mixId: 0,
      );
      expect(key, [0, 170, 255]);
      key!.fillRange(0, key.length, 0);
      expect(key, everyElement(0));
    },
  );

  test(
    'missing keys stay missing and malformed keys fail without exposing them',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(
        await SecureStorageService.loadMixKey(walletId: 'w', mixId: 0),
        isNull,
      );
      for (final raw in ['0', '00gg', '+1', '']) {
        messenger.setMockMethodCallHandler(channel, (_) async => raw);
        await expectLater(
          SecureStorageService.loadMixKey(walletId: 'w', mixId: 0),
          throwsA(
            isA<FormatException>().having((e) => e.source, 'source', isNull),
          ),
        );
      }
    },
  );
}
