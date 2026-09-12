import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/ui/dashboard_screen.dart';
import 'dart:async';

import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:argus_wallet/ui/assets_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wallet_sync_controller_test.dart' show FakeGateway;

class GatedGateway extends FakeGateway {
  String walletId = 'w1';
  Completer<Map<String, dynamic>>? balanceGate;
  Completer<String>? discoveryGate;
  Completer<StealthScanResult?>? stealthGate;
  @override
  Future<StealthScanResult?> scanStealth() =>
      stealthGate?.future ?? super.scanStealth();
  Completer<Map<String, dynamic>?>? cacheGate;
  @override
  String get activeWalletId => walletId;
  @override
  Future<Map<String, dynamic>> getBalance(String address) =>
      balanceGate?.future ?? super.getBalance(address);
  @override
  Future<String> discoverAddresses() =>
      discoveryGate?.future ?? super.discoverAddresses();
  @override
  Future<Map<String, dynamic>?> loadCachedState(String walletKey) =>
      cacheGate?.future ?? super.loadCachedState(walletKey);
  @override
  Future<List<TokenBalance>> hydrateTokens(dynamic raw) async => [
    for (final t in raw as List)
      TokenBalance(
        id: t['id'] as String,
        amount: t['amount'] as int,
        emissionAmount: t['emissionAmount'] as int?,
      ),
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'BATCH A: wallet switch starts its own refresh and old completion cannot clear it',
    () async {
      final gw = GatedGateway();
      final c = WalletSyncController(gw)..receiveAddress = 'old';
      final oldGate = Completer<Map<String, dynamic>>();
      gw.balanceGate = oldGate;
      final old = c.refresh(discover: false);
      gw.walletId = 'w2';
      c.reset();
      c.receiveAddress = 'new';
      final newGate = Completer<Map<String, dynamic>>();
      gw.balanceGate = newGate;
      final next = c.refresh(discover: false);
      oldGate.complete({'balance_nano_erg': 999, 'tokens': []});
      await old;
      expect(c.busy, isTrue);
      expect(c.balanceNano, isNull);
      expect(gw.savedCache, isNull);
      newGate.complete({'balance_nano_erg': 7, 'tokens': []});
      await next;
      expect(c.balanceNano, 7);
      expect(gw.savedCache?['wallet_id'], 'w2');
    },
  );

  test('BATCH A: wallet identity alone prevents joining old refresh', () async {
    final gw = GatedGateway();
    final c = WalletSyncController(gw)..receiveAddress = 'addr';
    final gate = Completer<Map<String, dynamic>>();
    gw.balanceGate = gate;
    final old = c.refresh(discover: false);
    gw.walletId = 'w2';
    gw.balanceGate = null;
    gw.balances['addr'] = {'balance_nano_erg': 8, 'tokens': []};
    final next = c.refresh(discover: false);
    expect(identical(old, next), isFalse);
    await next;
    gate.complete({'balance_nano_erg': 999, 'tokens': []});
    await old;
    expect(c.balanceNano, 8);
  });

  test('BATCH A: late discovery cannot replace a new wallet address', () async {
    final gw = GatedGateway();
    final gate = Completer<String>();
    gw.discoveryGate = gate;
    final c = WalletSyncController(gw);
    final old = c.refresh(discover: true);
    gw.walletId = 'w2';
    c.reset();
    c.receiveAddress = 'new';
    gate.complete('{"addresses": [], "next_unused_index": 0}');
    await old;
    expect(c.receiveAddress, 'new');
    expect(gw.balanceCalls, isEmpty);
  });

  test(
    'BATCH A: late cache hydrate cannot replace a new wallet balance',
    () async {
      final gw = GatedGateway();
      final gate = Completer<Map<String, dynamic>?>();
      gw.cacheGate = gate;
      final c = WalletSyncController(gw);
      final old = c.hydrateAfterUnlock();
      await Future<void>.delayed(Duration.zero);
      gw.walletId = 'w2';
      c.reset();
      gate.complete({'balance_nano_erg': 999, 'tokens': []});
      expect(await old, isFalse);
      expect(c.balanceNano, isNull);
    },
  );

  test(
    'BATCH A: late stealth scan cannot contaminate a reset of the same wallet',
    () async {
      final gw = GatedGateway()
        ..balances = {
          'addr': {'balance_nano_erg': 1, 'tokens': []},
        };
      final gate = Completer<StealthScanResult?>();
      gw.stealthGate = gate;
      final c = WalletSyncController(gw)..receiveAddress = 'addr';
      final old = c.refresh(discover: false);
      await Future<void>.delayed(Duration.zero);
      c.reset();
      gate.complete(
        const StealthScanResult(
          scanned: 1,
          ownedCount: 1,
          totalNanoErg: 999,
          tokens: [],
          boxIds: ['old'],
        ),
      );
      await old;
      expect(c.stealthNano, 0);
      expect(c.stealthScannedAt, isNull);
      expect(c.phase, SyncPhase.idle);
      expect(gw.savedCache, isNull);
    },
  );

  test('BATCH A: cached NFT emission survives hydration', () async {
    final gw = GatedGateway()
      ..cached = {
        'wallet_id': 'w1',
        'tokens': [
          {'id': 'nft', 'amount': 1, 'emissionAmount': 1},
        ],
      };
    final c = WalletSyncController(gw);
    await c.hydrateAfterUnlock();
    expect(c.tokens.single.emissionAmount, 1);
    expect(c.tokens.single.isNft, isTrue);
    expect(c.statusLabel(online: true), 'Not synced');
  });

  test(
    'BATCH A: database round trip retains validity separately from save time',
    () async {
      final gateway = const LiveWalletSyncGateway();
      await gateway.saveCachedState({
        'wallet_id': 'w1',
        'primary_address': 'addr',
        'used_addresses': <Map<String, dynamic>>[],
        'tokens': <Map<String, dynamic>>[],
        'transactions': <Map<String, dynamic>>[],
        'balance_nano_erg': 1,
        'utxo_count': 1,
        'sync_phase': 'historyPartial',
        'last_successful_sync_at': 123000,
      });
      final snapshot = await WalletDatabaseService.loadCachedState(
        expectedWalletId: 'w1',
      );
      expect(snapshot?['last_successful_sync_at'], 123000);
      expect(snapshot?['sync_phase'], 'historyPartial');
      final c = WalletSyncController(GatedGateway()..cached = snapshot);
      await c.hydrateAfterUnlock();
      expect(c.statusLabel(online: true), 'History incomplete');
      expect(c.lastSyncedAt?.millisecondsSinceEpoch, 123000);
    },
  );

  test(
    'BATCH A: snapshot preserves successful age, phase and NFT emission',
    () async {
      final gw = GatedGateway()
        ..balances = {
          'addr0': {
            'balance_nano_erg': 1,
            'tokens': [
              {'id': 'nft', 'amount': 1, 'emissionAmount': 1},
            ],
          },
        };
      final c = WalletSyncController(gw);
      await c.hydrateAfterUnlock();
      await c.refresh(discover: false);
      final stamp = c.lastSyncedAt;
      gw.cached = gw.savedCache;
      c.reset();
      await c.hydrateAfterUnlock();
      expect(
        c.lastSyncedAt?.millisecondsSinceEpoch,
        stamp?.millisecondsSinceEpoch,
      );
      expect(c.tokens.single.isNft, isTrue);
      expect(c.phase, SyncPhase.synced);
    },
  );

  test('BATCH A: an online node is not evidence that the wallet synced', () {
    final c = WalletSyncController(GatedGateway());
    expect(c.statusLabel(online: true), 'Not synced');
    c.phase = SyncPhase.historyPartial;
    expect(c.statusLabel(online: true), 'History incomplete');
    c.phase = SyncPhase.synced;
    expect(c.statusLabel(online: true), 'Not synced');
    c.lastSyncedAt = DateTime(2026);
    expect(c.statusLabel(online: true), 'Synced');
    c.phase = SyncPhase.syncing;
    expect(c.statusLabel(online: true), 'Syncing…');
    expect(c.lastSyncedAt, DateTime(2026));
  });

  testWidgets('BATCH A: status strip shows successful age during refresh', (
    tester,
  ) async {
    final c = WalletSyncController(GatedGateway())
      ..lastSyncedAt = DateTime.now().subtract(const Duration(minutes: 5))
      ..phase = SyncPhase.syncing;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SyncStatusLine.wallet(
            sync: c,
            online: true,
            statusColor: Colors.green,
            height: 100,
            fragmented: false,
          ),
        ),
      ),
    );
    expect(find.text('Syncing…'), findsOneWidget);
    expect(find.text('5m ago'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);
  });

  testWidgets('BATCH A: Assets follows holdings and clears them on reset', (
    tester,
  ) async {
    walletSyncController.reset();
    walletSyncController.receiveAddress = 'addr';
    walletSyncController.tokens = [
      TokenBalance(id: 'one', amount: 1, name: 'First'),
    ];
    const args = WalletRouteArgs(
      senderAddress: 'addr',
      receiveAddress: 'addr',
      changeAddress: 'addr',
    );
    await tester.pumpWidget(const MaterialApp(home: AssetsScreen(args: args)));
    expect(find.text('First'), findsWidgets);
    walletSyncController.tokens = [
      TokenBalance(id: 'two', amount: 2, name: 'Second'),
    ];
    // reset broadcasts a real controller change; hydration is another notification source.
    walletSyncController.noteBroadcast('test');
    await tester.pump();
    expect(find.text('Second'), findsWidgets);
    expect(find.text('First'), findsNothing);
    walletSyncController.reset();
    await tester.pump();
    expect(find.text('Second'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });
}
