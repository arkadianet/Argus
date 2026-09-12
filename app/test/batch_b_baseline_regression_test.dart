// These tests use alpha.49-compatible APIs so they can run unchanged against
// the actual pre-batch source, not just deliberately broken implementations.
import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_a_sync_test.dart' show GatedGateway;
import 'batch_b_timing_test.dart' show leave;

void main() {
  test(
    'BATCH B baseline: a return has remembered figures before async hydration',
    () async {
      final gw = GatedGateway();
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      c.balanceNano = 11;
      leave(c);
      gw.walletId = 'w2';
      await c.hydrateAfterUnlock();
      c.balanceNano = 22;
      leave(c);
      gw.walletId = 'w1';
      final hydration = c.hydrateAfterUnlock();
      final immediate = c.balanceNano;
      await hydration;
      expect(immediate, 11);
    },
  );

  test(
    'BATCH B baseline: known balance arrives before discovery is released',
    () async {
      final gw = GatedGateway()
        ..balances['addr0'] = {'balance_nano_erg': 42, 'tokens': []};
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      final gate = Completer<String>();
      gw.discoveryGate = gate;
      final refresh = c.refresh(discover: true);
      await Future<void>.delayed(Duration.zero);
      final beforeDiscovery = c.balanceNano;
      gate.complete(jsonEncode({'addresses': [], 'next_unused_index': 0}));
      await refresh;
      expect(beforeDiscovery, 42);
    },
  );

  test(
    'BATCH B baseline: cold hydrate retains persisted frontier addresses',
    () async {
      final gw = GatedGateway()
        ..cached = {
          'wallet_id': 'w1',
          'balance_nano_erg': 42,
          'frontier_addresses': ['addr0', 'addr1', 'addr2'],
          'discovered_at': DateTime.now().millisecondsSinceEpoch,
          'tokens': [],
        };
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      expect(c.historyAddresses, ['addr0', 'addr1', 'addr2']);
    },
  );
}
