import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/session_lock.dart';
import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/ui/widgets/wallet_view_boundary.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'batch_a_sync_test.dart' show GatedGateway;

class SessionApi extends RustLibApi {
  int handles = 0;
  Completer<void>? lockGate;
  @override
  Future<BigInt> crateApiWalletRestore({
    required String encryptedSeedJson,
    String? wrapKey,
  }) async => BigInt.from(++handles);
  @override
  Future<void> crateApiWalletLock({required BigInt handleId}) =>
      lockGate?.future ?? Future.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SharedReadApi extends SessionApi {
  int reads = 0;
  int histories = 0;
  final gate = Completer<String>();
  @override
  Future<String> crateApiGetSyncInputs({
    required List<String> addresses,
    String? nodeUrl,
  }) {
    reads++;
    return gate.future;
  }

  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async {
    histories++;
    return '[{"tx_id":"confirmed","timestamp":1}]';
  }
}

class SharedReadGateway extends LiveWalletSyncGateway {
  const SharedReadGateway();
  @override
  bool get isUnlocked => true;
  @override
  String get activeWalletId => 'w1';
  @override
  bool get stealthScanEnabled => false;
  @override
  Future<void> saveCachedState(Map<String, dynamic> snapshot) async {}
}

void seed(WalletSyncController c, int value) {
  c.receiveAddress = 'addr$value';
  c.changeAddress = 'change$value';
  c.senderAddress = 'sender$value';
  c.balanceNano = value;
  c.tokens = [
    TokenBalance(id: 'token$value', amount: value, emissionAmount: 1),
  ];
  c.recentTxs = [
    {'tx_id': 'tx$value'},
  ];
  c.usedAddresses = [
    {'address': 'used$value'},
  ];
  c.frontierAddresses = ['frontier$value'];
  c.utxoCount = value;
  c.lastSyncedAt = DateTime(2026);
  c.phase = SyncPhase.synced;
  c.stealthNano = value;
}

void main() {
  final api = SharedReadApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'BATCH B: every switch notification is empty or owned by the target',
    () async {
      final gw = GatedGateway();
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      seed(c, 11);
      c.addListener(() {
        if (c.balanceNano != null) {
          final value = gw.walletId == 'w1' ? 11 : 22;
          expect(c.balanceNano, value);
          expect(c.tokens.single.id, 'token$value');
          expect(c.recentTxs.single['tx_id'], 'tx$value');
          expect(c.usedAddresses.single['address'], 'used$value');
          expect(c.frontierAddresses.single, 'frontier$value');
          expect(c.utxoCount, value);
          expect(c.stealthNano, value);
        }
      });
      gw.walletId = 'w2';
      c.activateWallet('w2');
      expect(c.balanceNano, isNull);
      seed(c, 22);
      gw.walletId = 'w1';
      c.activateWallet('w1');
      expect(c.balanceNano, 11); // Synchronous, without awaiting hydration.
      expect(c.lastSyncedAt, DateTime(2026));
      expect(c.changeAddress, 'change11');
      expect(c.senderAddress, 'sender11');
      expect(c.tokens.single.emissionAmount, 1);
      gw.walletId = 'w2';
      c.activateWallet('w2');
      expect(c.balanceNano, 22);
    },
  );

  testWidgets(
    'BATCH B: dashboard boundary never keeps a foreign ledger for a frame',
    (tester) async {
      final gw = GatedGateway();
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      seed(c, 11);
      String labelId = 'w1';
      Widget view() => Directionality(
        textDirection: TextDirection.ltr,
        child: WalletViewBoundary(
          controller: c,
          walletId: labelId,
          unlocked: true,
          ledger: (_) => Text('$labelId:${c.balanceNano}'),
          gate: (_) => const Text('gate'),
        ),
      );
      await tester.pumpWidget(view());
      expect(find.text('w1:11'), findsOneWidget);
      // UI label moves first: the outgoing ledger must vanish in this frame.
      labelId = 'w2';
      await tester.pumpWidget(view());
      expect(find.text('gate'), findsOneWidget);
      expect(find.text('w1:11'), findsNothing);
      gw.walletId = 'w2';
      c.activateWallet('w2');
      seed(c, 22);
      await tester.pumpWidget(view());
      expect(find.text('w2:22'), findsOneWidget);
      // Service moves first: the still-old label must also show only the gate.
      gw.walletId = 'w1';
      c.activateWallet('w1');
      await tester.pumpWidget(view());
      expect(find.text('gate'), findsOneWidget);
      for (final milliseconds in [1, 16, 280]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(find.text('w2:22'), findsNothing);
        expect(find.text('w2:11'), findsNothing);
      }
      labelId = 'w1';
      await tester.pumpWidget(view());
      expect(find.text('w1:11'), findsOneWidget);
    },
  );

  test(
    'BATCH B: delayed A refresh cannot poison remembered A or visible B',
    () async {
      final gw = GatedGateway();
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      seed(c, 11);
      final gate = Completer<Map<String, dynamic>>();
      gw.balanceGate = gate;
      final old = c.refresh(discover: false);
      gw.walletId = 'w2';
      c.activateWallet('w2');
      seed(c, 22);
      gate.complete({'balance_nano_erg': 999, 'tokens': []});
      await old;
      expect(c.balanceNano, 22);
      gw.walletId = 'w1';
      c.activateWallet('w1');
      expect(c.balanceNano, 11);
      expect(c.phase, isNot(SyncPhase.synced));
    },
  );

  test(
    'BATCH B: reset and revocation evict inactive remembered wallets',
    () async {
      final gw = GatedGateway();
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      seed(c, 11);
      c.deactivate();
      c.forgetWallet('w1');
      c.activateWallet('w1');
      expect(c.balanceNano, isNull);
      seed(c, 11);
      c.deactivate();
      c.reset();
      c.activateWallet('w1');
      expect(c.balanceNano, isNull);
    },
  );

  test(
    'BATCH B: remembered addresses refresh before gated discovery',
    () async {
      final gw = GatedGateway()
        ..balances['addr0'] = {'balance_nano_erg': 42, 'tokens': []};
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      final gate = Completer<String>();
      gw.discoveryGate = gate;
      final refresh = c.refresh(discover: true);
      await Future<void>.delayed(Duration.zero);
      expect(gw.balanceCalls, ['addr0']);
      expect(c.balanceNano, 42);
      gate.complete(jsonEncode({'addresses': [], 'next_unused_index': 0}));
      await refresh;
      expect(gw.balanceCalls, ['addr0']); // Unchanged set needs no second read.
    },
  );

  test(
    'BATCH B: persisted frontier survives restart and freshness skips discovery',
    () async {
      final gw = GatedGateway()..nextUnused = 3;
      final c = WalletSyncController(gw);
      for (var i = 0; i <= 3; i++) {
        gw.balances['addr$i'] = {'balance_nano_erg': i, 'tokens': []};
      }
      await c.hydrateAfterUnlock();
      await c.refresh(discover: true);
      await const LiveWalletSyncGateway().saveCachedState(gw.savedCache!);
      final cache = await WalletDatabaseService.loadCachedState(
        expectedWalletId: 'w1',
      );
      gw.cached = cache;
      final cold = WalletSyncController(gw);
      await cold.hydrateAfterUnlock();
      expect(cold.frontierAddresses, ['addr0', 'addr1', 'addr2', 'addr3']);
      gw.balanceCalls.clear();
      final before = gw.discoverCalls;
      await cold.refresh(discover: true, forceDiscovery: false);
      expect(gw.discoverCalls, before);
      expect(gw.balanceCalls, ['addr0', 'addr1', 'addr2', 'addr3']);
      cold.discoveredAt = DateTime.now().subtract(const Duration(minutes: 16));
      await cold.refresh(discover: true, forceDiscovery: false);
      expect(gw.discoverCalls, before + 1);
      await cold.refresh(discover: true); // Manual rescan ignores freshness.
      expect(gw.discoverCalls, before + 2);
      cold.discoveredAt = DateTime.now().subtract(const Duration(minutes: 16));
      await cold.refresh(discover: false, quiet: true);
      expect(
        gw.discoverCalls,
        before + 3,
      ); // Active foreground poll checks age too.
    },
  );

  test(
    'BATCH B: successful discovery persists even when balance reads fail',
    () async {
      final gw = GatedGateway()..nextUnused = 2;
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      await c.refresh(discover: true);
      expect(c.phase, SyncPhase.failed);
      expect(gw.savedCache, isNotNull);
      await const LiveWalletSyncGateway().saveCachedState(gw.savedCache!);
      gw.cached = await WalletDatabaseService.loadCachedState(
        expectedWalletId: 'w1',
      );
      final cold = WalletSyncController(gw);
      await cold.hydrateAfterUnlock();
      expect(cold.frontierAddresses, ['addr0', 'addr1', 'addr2']);
      expect(
        cold.balanceNano,
        isNull,
      ); // Discovery must not manufacture a zero.
      expect(await WalletDatabaseService.lastKnownBalance('w1'), isNull);
    },
  );

  test(
    'BATCH B: fresh receive routing survives restart and pin changes expire discovery',
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
      gw.cached = gw.savedCache;
      final cold = WalletSyncController(gw);
      await cold.hydrateAfterUnlock();
      expect(cold.receiveAddress, 'addr3');
      expect(cold.changeAddress, 'addr3');
      gw.pinnedIndex = 2;
      await cold.hydrateAfterUnlock();
      expect(cold.discoveredAt, isNull);
    },
  );

  testWidgets('BATCH B: deleting an inactive wallet revokes remembered state', (
    tester,
  ) async {
    const channel = MethodChannel('com.argus.wallet/secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    final c = walletSyncController;
    c.reset();
    await walletService.restoreWallet('', walletId: 'deleted');
    seed(c, 11);
    await walletService.lockForSwitch();
    await walletService.restoreWallet('', walletId: 'other');
    seed(c, 22);
    await walletService.deleteWallet('deleted');
    expect(c.balanceNano, 22);
    await walletService.lockForSwitch();
    await walletService.restoreWallet('', walletId: 'deleted');
    expect(c.balanceNano, isNull);
    await walletService.lock();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  test(
    'BATCH B: remembered stealth box IDs belong to the restored wallet',
    () async {
      final gw = GatedGateway()
        ..balances['addr0'] = {'balance_nano_erg': 1, 'tokens': []};
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      gw.stealthResult = const StealthScanResult(
        scanned: 1,
        ownedCount: 1,
        totalNanoErg: 11,
        tokens: [],
        boxIds: ['A-box'],
      );
      await c.refresh(discover: false);
      expect(c.stealthRowBoxIds, ['A-box']);
      gw.walletId = 'w2';
      c.activateWallet('w2');
      expect(c.stealthRowBoxIds, isEmpty);
      gw.walletId = 'w1';
      c.activateWallet('w1');
      expect(c.stealthRowBoxIds, ['A-box']);
    },
  );

  test(
    'BATCH B: live gateway shares inputs and starts history concurrently',
    () async {
      final c = WalletSyncController(const SharedReadGateway())
        ..receiveAddress = 'addr';
      final refresh = c.refresh(discover: false);
      await Future<void>.delayed(Duration.zero);
      expect(api.reads, 1);
      expect(
        api.histories,
        1,
      ); // History started while the input read is gated.
      api.gate.complete(
        jsonEncode({
          'balances': {
            'addr': {'balance_nano_erg': 123, 'tokens': []},
          },
          'pending': [
            {'tx_id': 'pending', 'height': 0},
          ],
          'utxo_count': 7,
        }),
      );
      await refresh;
      expect(c.balanceNano, 123);
      expect(c.utxoCount, 7);
      expect(c.recentTxs.map((tx) => tx['tx_id']), ['pending', 'confirmed']);
      expect(c.phase, SyncPhase.synced);
    },
  );

  testWidgets(
    'BATCH B: service identity publication and auto-lock clear views before frames',
    (tester) async {
      final c = walletSyncController;
      c.reset();
      await walletService.restoreWallet('', walletId: 'A');
      seed(c, 11);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListenableBuilder(
            listenable: Listenable.merge([walletService.currentWalletId, c]),
            builder: (_, _) =>
                Text('${walletService.activeWalletId}:${c.balanceNano}'),
          ),
        ),
      );
      expect(find.text('A:11'), findsOneWidget);
      await walletService.lockForSwitch();
      stealthService.lastScan = const StealthScanResult(
        scanned: 1,
        ownedCount: 1,
        totalNanoErg: 11,
        tokens: [],
        boxIds: ['foreign'],
      );
      await walletService.restoreWallet('', walletId: 'B');
      expect(stealthService.lastScan, isNull);
      await tester.pump();
      expect(find.text('B:null'), findsOneWidget);
      expect(c.ownsWallet('A'), isFalse); // Old dashboard name cannot render B.
      seed(c, 22);
      await walletService.lockForSwitch();
      await walletService.restoreWallet('', walletId: 'A');
      await tester.pump();
      expect(find.text('A:11'), findsOneWidget);
      api.lockGate = Completer<void>();
      final lock = SessionLock(
        onLock: () {
          unawaited(walletService.lock());
        },
        grace: const Duration(milliseconds: 1),
      );
      lock.onLifecycle(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 2));
      expect(
        c.balanceNano,
        isNull,
      ); // Cleared even while native lock is pending.
      api.lockGate!.complete();
      await tester.pump();
      await walletService.restoreWallet('', walletId: 'B');
      await tester.pump();
      expect(
        find.text('B:null'),
        findsOneWidget,
      ); // Auto-lock clears inactive A/B.
      lock.dispose();
      await walletService.lock();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
