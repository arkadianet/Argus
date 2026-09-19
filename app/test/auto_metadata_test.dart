import 'package:argus_wallet/services/metadata_settings.dart';
import 'package:argus_wallet/services/network_controller.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pinnedNodeActive', () {
    test('false while selection is automatic', () {
      final n = NetworkController(configure: (_, __) async {});
      n.activeUrl = 'https://a.example';
      expect(n.pinnedNodeActive, isFalse);
    });

    test('false when failover moved off the pinned node', () {
      final n = NetworkController(configure: (_, __) async {});
      n.preferredUrl = 'https://mine.example';
      n.activeUrl = 'https://fallback.example';
      expect(n.pinnedNodeActive, isFalse);
    });

    test('false while offline', () {
      final n = NetworkController(configure: (_, __) async {});
      n.preferredUrl = 'https://mine.example';
      n.activeUrl = null;
      expect(n.pinnedNodeActive, isFalse);
    });

    test('true when the pinned node is the one serving', () {
      final n = NetworkController(configure: (_, __) async {});
      n.preferredUrl = 'https://mine.example';
      n.activeUrl = 'https://mine.example';
      expect(n.pinnedNodeActive, isTrue);
    });
  });

  group('autoResolveAllowedFor', () {
    bool allowed({
      bool enabled = true,
      bool pinned = true,
      bool stealth = false,
    }) =>
        WalletService.autoResolveAllowedFor(
          enabled: enabled,
          pinnedNodeActive: pinned,
          hasStealth: stealth,
        );

    test('allows a plain holding on a pinned node', () {
      expect(allowed(), isTrue);
    });

    test('refuses while the setting is off', () {
      expect(allowed(enabled: false), isFalse);
    });

    test('refuses on an unpinned node', () {
      expect(allowed(pinned: false), isFalse);
    });

    test('refuses a stealth holding even on a pinned node', () {
      // The node cannot derive stealth boxes from the wallet's public
      // addresses, so it has not already seen these tokens.
      expect(allowed(stealth: true), isFalse);
    });
  });

  group('autoResolveMetadata', () {
    // Rust is not initialised under test, so any call that reaches the FFI
    // throws. Completing normally is what proves the gate short-circuits.
    final holdings = [TokenBalance(id: 'tok', amount: 1)];

    test('does nothing while the setting is off', () async {
      await metadataSettings.setAutoResolve(false);
      final svc = WalletService();
      networkController.preferredUrl = 'https://mine.example';
      networkController.activeUrl = 'https://mine.example';
      await expectLater(svc.autoResolveMetadata(holdings), completes);
    });

    test('does nothing when no node is pinned', () async {
      await metadataSettings.setAutoResolve(true);
      final svc = WalletService();
      networkController.preferredUrl = null;
      networkController.activeUrl = 'https://pool.example';
      await expectLater(svc.autoResolveMetadata(holdings), completes);
    });

    test('does nothing while offline', () async {
      await metadataSettings.setAutoResolve(true);
      final svc = WalletService();
      networkController.preferredUrl = 'https://mine.example';
      networkController.activeUrl = null;
      await expectLater(svc.autoResolveMetadata(holdings), completes);
    });

    tearDown(() async {
      networkController.preferredUrl = null;
      networkController.activeUrl = null;
      await metadataSettings.setAutoResolve(false);
    });
  });

  group('MetadataSettings', () {
    test('defaults to off so an existing install keeps asking', () async {
      final s = MetadataSettings();
      await s.load();
      expect(s.autoResolve, isFalse);
    });

    test('survives a restart', () async {
      final first = MetadataSettings();
      await first.setAutoResolve(true);

      final second = MetadataSettings();
      await second.load();
      expect(second.autoResolve, isTrue);
    });
  });
}
