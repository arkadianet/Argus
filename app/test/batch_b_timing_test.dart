// A reproducible controller benchmark, not a device/app launch measurement.
// The dynamic fallbacks let this same harness run against alpha.49 in a cache
// checkout; all I/O delays below are synthetic and printed as such.

import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_a_sync_test.dart' show GatedGateway;

class TimingGateway extends GatedGateway {
  @override
  Future<int> getPinnedAddressIndex() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return 0;
  }

  @override
  Future<String?> tryDeriveAddress(int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return 'addr0';
  }

  @override
  Future<Map<String, dynamic>?> loadCachedState(String walletKey) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return {
      'wallet_id': walletKey,
      'balance_nano_erg': walletKey == 'w1' ? 11 : 22,
      'used_addresses': [],
      'frontier_addresses': ['addr0'],
      'discovered_at': DateTime.now().millisecondsSinceEpoch,
      'discovery_pinned_index': 0,
      'discovery_unused_change': false,
      'tokens': [],
      'transactions': [],
    };
  }

  @override
  Future<String> discoverAddresses() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return super.discoverAddresses();
  }

  @override
  Future<Map<String, dynamic>> getBalance(String address) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return {'balance_nano_erg': 42, 'tokens': []};
  }
}

void leave(WalletSyncController controller) {
  try {
    (controller as dynamic).deactivate();
  } on NoSuchMethodError {
    controller.reset(); // alpha.49 dashboard switch behavior
  }
}

Future<void> launchRefresh(WalletSyncController controller) async {
  try {
    await (controller as dynamic).refresh(
      discover: true,
      forceDiscovery: false,
    );
  } on NoSuchMethodError {
    await controller.refresh(discover: true); // alpha.49 launch behavior
  }
}

void main() {
  test(
    'BATCH B timing: synthetic controller switch, cold launch, refresh',
    () async {
      final switches = <int>[];
      final coldCache = <int>[];
      final coldFresh = <int>[];
      final refreshes = <int>[];
      for (var trial = 0; trial < 3; trial++) {
        final gw = TimingGateway()..stealthEnabled = false;
        final c = WalletSyncController(gw);
        final timer = Stopwatch()..start();
        await c.hydrateAfterUnlock();
        coldCache.add(timer.elapsedMicroseconds);
        await launchRefresh(c);
        coldFresh.add(timer.elapsedMicroseconds);
        leave(c);
        gw.walletId = 'w2';
        await c.hydrateAfterUnlock();
        leave(c);
        gw.walletId = 'w1';
        timer.reset();
        final hydration = c.hydrateAfterUnlock();
        final immediate = c.balanceNano == null
            ? null
            : timer.elapsedMicroseconds;
        await hydration;
        switches.add(immediate ?? timer.elapsedMicroseconds);
        timer.reset();
        await c.refresh(discover: false);
        refreshes.add(timer.elapsedMicroseconds);
        c.dispose();
      }
      // ignore: avoid_print
      print(
        'SYNTHETIC controller microseconds: return=$switches coldCache=$coldCache coldFresh=$coldFresh refresh=$refreshes',
      );
    },
  );
}
