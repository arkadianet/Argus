import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'batch_a_sync_test.dart' show GatedGateway;
import 'batch_b_sync_test.dart' show SessionApi, SharedReadGateway, seed;
import 'batch_c_sync_test.dart' show MemoryPublic;

class ReviewApi extends SessionApi {
  Completer<String>? balanceGate;
  int balanceCalls = 0;
  @override
  Future<String> crateApiGetSyncInputs({
    required List<String> addresses,
    String? nodeUrl,
  }) async => '{"balances":{},"pending":null,"utxo_count":null}';
  @override
  Future<void> crateApiInitApp() async {}
  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) {
    balanceCalls++;
    return balanceGate!.future;
  }

  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async => '[{"tx_id":"confirmed","height":1}]';
}

void main() {
  final api = ReviewApi();
  const channel = MethodChannel('com.argus.wallet/secure_storage');
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    walletSyncController.reset();
  });

  test(
    '114.1 unavailable pending values preserve the activity snapshot',
    () async {
      final c = WalletSyncController(const SharedReadGateway())
        ..receiveAddress = 'addr'
        ..recentTxs = [
          {'tx_id': 'spend', 'value_nano_erg': -1000, 'height': 0},
        ];
      await c.refresh(discover: false);
      expect(c.recentTxs.single['value_nano_erg'], -1000);
      expect(c.phase, SyncPhase.failed);
    },
  );

  testWidgets(
    '114.2 inactive lock preserves active and unrelated remembered wallets',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(() async {
        await walletService.lock();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      final c = walletSyncController;
      await walletService.restoreWallet('', walletId: 'remembered');
      seed(c, 33);
      await walletService.lockForSwitch();
      await walletService.restoreWallet('', walletId: 'deleted');
      seed(c, 11);
      // Keep this native handle open: delete must exercise _lock(inactive).
      await walletService.restoreWallet('', walletId: 'active');
      seed(c, 22);
      await walletService.deleteWallet('deleted');
      expect(walletService.isUnlocked, isTrue);
      expect(walletService.activeWalletId, 'active');
      expect(c.balanceNano, 22);
      expect(c.receiveAddress, 'addr22');
      await walletService.lock('already-locked');
      expect(walletService.isUnlocked, isTrue);
      expect(c.balanceNano, 22);
      await walletService.lockForSwitch();
      await walletService.restoreWallet('', walletId: 'remembered');
      expect(c.balanceNano, 33);
      await walletService.lockForSwitch();
      await walletService.restoreWallet('', walletId: 'deleted');
      expect(c.balanceNano, isNull);
    },
  );

  for (final setting in ['pin', 'unused change']) {
    test(
      '114.3 remembered routing is rehydrated after $setting changes',
      () async {
        final gw = GatedGateway()
          ..unusedChange = true
          ..nextUnused = 3;
        for (var i = 0; i <= 3; i++) {
          gw.balances['addr$i'] = {'balance_nano_erg': i, 'tokens': []};
        }
        final c = WalletSyncController(gw);
        await c.hydrateAfterUnlock();
        await c.refresh(discover: true);
        expect(c.changeAddress, 'addr3');
        c.senderAddress = 'stale-sender';
        gw.cached = gw.savedCache;
        gw.walletId = 'w2';
        c.activateWallet('w2');
        if (setting == 'pin') {
          gw.pinnedIndex = 2;
        } else {
          gw.unusedChange = false;
        }
        gw.walletId = 'w1';
        await c.hydrateAfterUnlock();
        final expected = setting == 'pin' ? 'addr2' : 'addr0';
        expect(c.receiveAddress, expected);
        expect(c.changeAddress, expected);
        expect(c.senderAddress, isNot('stale-sender'));
        expect(c.discoveredAt, isNull);
        gw.discoveryGate = Completer<String>();
        final refresh = c.refresh(discover: true);
        await Future<void>.delayed(Duration.zero);
        expect(c.routeArgs.receiveAddress, expected);
        expect(c.routeArgs.changeAddress, expected);
        gw.discoveryGate!.complete(
          jsonEncode({'addresses': [], 'next_unused_index': 3}),
        );
        await refresh;
      },
    );
  }

  for (final key in ['public_refreshed_at', 'last_successful_sync_at']) {
    test('114.4 future $key is expired', () async {
      final at = DateTime(2026);
      final gw = MemoryPublic()
        ..data['w2'] = {
          key: at.add(const Duration(days: 365)).millisecondsSinceEpoch,
          'balance_nano_erg': 999,
        };
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      await PublicWalletSync(gw).tick(
        wallets: {'w2': 'b'},
        controller: c,
        activeId: 'w1',
        unlocked: () => true,
        now: at,
      );
      expect(gw.calls, ['balance:b', 'history:b']);
      expect(gw.data['w2']!['balance_nano_erg'], 7);
    });
  }
}
