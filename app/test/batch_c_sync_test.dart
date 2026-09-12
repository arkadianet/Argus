import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/bridge/frb_generated.dart';
import 'package:argus_wallet/services/public_wallet_sync.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:argus_wallet/ui/wallets_overview_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'batch_a_sync_test.dart' show GatedGateway;

class PublicApi extends RustLibApi {
  final calls = <String>[];
  @override
  Future<void> crateApiInitApp() async {}
  @override
  Future<String> crateApiGetBalance({
    required String address,
    String? nodeUrl,
  }) async {
    calls.add('balance:$address');
    return jsonEncode({
      'balance_nano_erg': 7,
      'tokens': [
        {'id': 'shared-c', 'amount': 2},
      ],
    });
  }

  @override
  Future<String> crateApiGetTransactionHistory({
    required String address,
    String? nodeUrl,
    required BigInt limit,
    required BigInt offset,
  }) async {
    calls.add('history:$address');
    expect(limit.toInt(), 20);
    return '[{"tx_id":"shared-tx","timestamp":10}]';
  }

  @override
  Future<String> crateApiGetTokenInfo({
    required String tokenId,
    String? explorerUrl,
  }) async {
    calls.add('meta:$tokenId');
    return '{"name":"Shared","decimals":2}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Forbidden native capability: ${invocation.memberName}');
}

class MemoryPublic extends PublicWalletGateway {
  final data = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  Completer<void>? gate;
  bool fail = false;
  bool historyFail = false;
  int running = 0;
  int peak = 0;
  Duration latency = Duration.zero;
  @override
  Future<Map<String, dynamic>?> load(String id) async => data[id];
  Future<void> request(String name) async {
    calls.add(name);
    running++;
    if (running > peak) peak = running;
    await gate?.future;
    await Future<void>.delayed(latency);
    running--;
    if (fail) throw StateError('offline');
  }

  @override
  Future<Map<String, dynamic>> balance(String address) async {
    await request('balance:$address');
    return {
      'balance_nano_erg': 7,
      'tokens': [
        {'id': 'shared', 'amount': 2},
      ],
    };
  }

  @override
  Future<List<dynamic>> history(String address) async {
    await request('history:$address');
    if (historyFail) throw StateError('history unavailable');
    return [
      for (var i = 0; i < 8; i++) {'tx_id': 'tx$i', 'timestamp': i},
    ];
  }

  @override
  Future<TokenBalance> metadata(String id, int amount) async =>
      TokenBalance(id: id, amount: amount, name: 'Shared', decimals: 2);
  @override
  Future<void> save(
    String id,
    Map<String, dynamic> snapshot,
    bool Function() valid,
  ) async {
    if (valid()) data[id] = snapshot;
  }
}

void main() {
  final api = PublicApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final at = DateTime(2026, 9, 13);
  const wallets = {'w1': 'a', 'w2': 'b', 'w3': 'c'};

  Future<void> tick(
    PublicWalletSync sync,
    WalletSyncController c,
    GatedGateway active, {
    DateTime? now,
  }) => sync.tick(
    wallets: wallets,
    controller: c,
    activeId: active.walletId,
    unlocked: () => active.unlocked,
    now: now ?? at,
  );

  test(
    'C: live locked-wallet reads use public APIs and global metadata only',
    () async {
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      c.balanceNano = 99;
      final sync = PublicWalletSync(LivePublicWalletGateway());
      await tick(sync, c, active);
      expect(api.calls, [
        'balance:b',
        'history:b',
        'meta:shared-c',
        'balance:c',
        'history:c',
      ]);
      expect(active.discoverCalls, 0);
      expect(active.stealthCalls, 0);
      expect(
        walletService.isUnlocked,
        isFalse,
      ); // No native wallet handle exists.
      expect(c.balanceNano, 99);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('argus_token_meta_v2'), contains('shared-c'));
      final known = await WalletDatabaseService.lastKnownBalance('w2');
      expect(known!.tokens.single.amount, 2);
      expect(known.balanceNano, 7);
      active.walletId = 'w2';
      c.activateWallet('w2');
      expect(
        c.tokens.single.name,
        'Shared',
      ); // Before any hydrate/network await.
      expect(c.recentTxs.single['tx_id'], 'shared-tx');
      expect(c.statusLabel(online: true), contains('known addresses only'));
      expect(c.ownsWallet('w1'), isFalse);
      c.reset();
      active.walletId = 'w3';
      c.activateWallet('w3');
      expect(c.tokens, isEmpty);
    },
  );

  test(
    'C: frontier union, deduplication, aggregation and five recent rows',
    () async {
      final gw = MemoryPublic()
        ..data['w2'] = {
          'wallet_id': 'w2',
          'frontier_addresses': ['b', 'b2', 'b2'],
          'used_addresses': [
            {'address': 'b3'},
          ],
          'primary_address': 'b4',
          'discovered_at': 123,
          'stealth_nano_erg': 456,
          'stealth_scanned_at': 789,
        };
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      await tick(PublicWalletSync(gw), c, active);
      expect(gw.calls.where((v) => v.startsWith('balance:')), [
        'balance:b',
        'balance:b2',
        'balance:b3',
        'balance:b4',
        'balance:c',
      ]);
      final saved = gw.data['w2']!;
      expect(saved['balance_nano_erg'], 28);
      expect((saved['tokens'] as List).single['amount'], 8);
      expect((saved['transactions'] as List).map((t) => t['tx_id']), [
        'tx7',
        'tx6',
        'tx5',
        'tx4',
        'tx3',
      ]);
      expect(saved['discovered_at'], 123);
      expect(saved['stealth_nano_erg'], 456);
      expect(saved['stealth_scanned_at'], 789);
      expect(gw.peak, 1);
    },
  );

  test(
    'C: timer policy skips fresh wallets, throttles and stops off foreground',
    () async {
      final gw = MemoryPublic()
        ..data['w2'] = {'last_successful_sync_at': at.millisecondsSinceEpoch};
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      final sync = PublicWalletSync(gw)..setForeground(false);
      await tick(sync, c, active);
      expect(gw.calls, isEmpty);
      sync.setForeground(true);
      active.unlocked = false;
      await tick(sync, c, active);
      expect(gw.calls, isEmpty);
      active.unlocked = true;
      await tick(sync, c, active);
      expect(gw.calls, ['balance:c', 'history:c']);
      expect(
        sync.isDue(at.add(const Duration(minutes: 4, seconds: 59))),
        isFalse,
      );
      expect(sync.isDue(at.add(const Duration(minutes: 5))), isTrue);
      await tick(
        sync,
        c,
        active,
        now: at.add(const Duration(minutes: 4, seconds: 59)),
      );
      expect(gw.calls.length, 2);
      await tick(sync, c, active, now: at.add(const Duration(minutes: 5)));
      expect(gw.calls.length, 6);
    },
  );

  for (final boundary in ['switch', 'lock', 'delete', 'background']) {
    test('C: delayed result cannot publish after $boundary', () async {
      final gw = MemoryPublic()..gate = Completer<void>();
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      c.balanceNano = 99;
      final sync = PublicWalletSync(gw);
      final work = tick(sync, c, active);
      await Future<void>.delayed(Duration.zero);
      await tick(sync, c, active, now: at.add(const Duration(minutes: 5)));
      expect(
        gw.calls.length,
        1,
      ); // Single flight even when next interval is due.
      switch (boundary) {
        case 'switch':
          active.walletId = 'w2';
          c.activateWallet('w2');
        case 'lock':
          c.reset(); // Native lock may still be pending/unlocked true.
        case 'delete':
          c.forgetWallet('w2');
        case 'background':
          sync.setForeground(false);
          sync.setForeground(true);
      }
      gw.gate!.complete();
      await work;
      expect(gw.calls.length, 1);
      expect(gw.data, isEmpty);
      active.walletId = 'w2';
      c.activateWallet('w2');
      expect(c.tokens, isEmpty);
    });
  }

  test(
    'C: failures preserve snapshot and retry no faster than five minutes',
    () async {
      final old = {
        'wallet_id': 'w2',
        'balance_nano_erg': 123,
        'last_sync_timestamp': 1,
      };
      final gw = MemoryPublic()
        ..data['w2'] = old
        ..fail = true;
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      final sync = PublicWalletSync(gw);
      await tick(sync, c, active);
      expect(gw.data['w2'], same(old));
      expect(gw.calls.length, 2);
      await tick(sync, c, active, now: at.add(const Duration(seconds: 20)));
      expect(gw.calls.length, 2);
    },
  );

  test('C: persistence rejects mismatched owner and revoked save', () async {
    await WalletDatabaseService.savePublicSnapshot('w2', {
      'wallet_id': 'w3',
    }, () => true);
    expect(
      await WalletDatabaseService.loadCachedState(expectedWalletId: 'w2'),
      isNull,
    );
    await WalletDatabaseService.savePublicSnapshot('w2', {
      'wallet_id': 'w2',
    }, () => false);
    expect(
      await WalletDatabaseService.loadCachedState(expectedWalletId: 'w2'),
      isNull,
    );
  });

  test(
    'C: overview reads shared snapshots without independent requests',
    () async {
      await WalletDatabaseService.savePublicSnapshot('w2', {
        'wallet_id': 'w2',
        'balance_nano_erg': 7000000000,
        'tokens': [],
        'public_only': true,
        'last_sync_timestamp': at.millisecondsSinceEpoch,
      }, () => true);
      final calls = api.calls.length;
      expect(
        await overviewWalletBalance(
          WalletInfo(
            walletId: 'w2',
            name: 'Warm',
            createdAt: at,
            address0: 'b',
          ),
        ),
        7000000000,
      );
      expect(
        await overviewWalletBalance(
          WalletInfo(
            walletId: 'unknown',
            name: 'Unknown',
            createdAt: at,
            address0: 'unknown-address',
          ),
        ),
        isNull,
      );
      expect(api.calls.length, calls);
    },
  );

  test(
    'C: public label survives failed active persistence and switches',
    () async {
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      final gw = MemoryPublic();
      await tick(PublicWalletSync(gw), c, active);
      active.walletId = 'w2';
      c.activateWallet('w2');
      c.receiveAddress = 'b';
      c.discoveredAt = DateTime.now();
      await c.refresh(discover: false);
      expect(c.publicSnapshotOnly, isTrue);
      await const LiveWalletSyncGateway().saveCachedState(active.savedCache!);
      final cached = await WalletDatabaseService.loadCachedState(
        expectedWalletId: 'w2',
      );
      expect(cached!['public_only'], isTrue);
      active.walletId = 'w1';
      c.activateWallet('w1');
      active.walletId = 'w2';
      c.activateWallet('w2');
      expect(c.statusLabel(online: true), contains('known addresses only'));
    },
  );

  test('C: a history failure preserves the entire prior snapshot', () async {
    final old = {
      'wallet_id': 'w2',
      'balance_nano_erg': 123,
      'last_sync_timestamp': 1,
    };
    final gw = MemoryPublic()
      ..data['w2'] = old
      ..historyFail = true;
    final active = GatedGateway();
    final c = WalletSyncController(active)..activateWallet('w1');
    await tick(PublicWalletSync(gw), c, active);
    expect(gw.data['w2'], same(old));
    active.walletId = 'w2';
    c.activateWallet('w2');
    expect(c.tokens, isEmpty);
  });

  test(
    'C: active polls do not invalidate warm reads and completion notifies overview',
    () async {
      final gw = MemoryPublic()..gate = Completer<void>();
      final active = GatedGateway();
      final c = WalletSyncController(active)..activateWallet('w1');
      c.receiveAddress = 'a';
      final sync = PublicWalletSync(gw);
      var notifications = 0;
      sync.addListener(() => notifications++);
      final work = tick(sync, c, active);
      await Future<void>.delayed(Duration.zero);
      await c.refresh(discover: false);
      gw.gate!.complete();
      await work;
      expect(gw.data.keys, containsAll(['w2', 'w3']));
      expect(notifications, 1);
    },
  );

  test('C: warm admission refuses active, foreign and revoked snapshots', () {
    final active = GatedGateway();
    final c = WalletSyncController(active)..activateWallet('w1');
    final generation = c.publicGeneration;
    expect(c.rememberPublic('w1', {'wallet_id': 'w1'}, generation), isFalse);
    expect(c.rememberPublic('w2', {'wallet_id': 'w3'}, generation), isFalse);
    c.reset();
    expect(c.rememberPublic('w2', {'wallet_id': 'w2'}, generation), isFalse);
  });

  test('C: three-wallet controlled latency measurement', () async {
    final gw = MemoryPublic()..latency = const Duration(milliseconds: 20);
    final active = GatedGateway();
    final c = WalletSyncController(active)..activateWallet('w1');
    final before = Stopwatch()..start();
    await Future.wait(['b', 'c'].map(gw.balance));
    before.stop();
    final oldCalls = gw.calls.length;
    gw.calls.clear();
    final after = Stopwatch()..start();
    final sync = PublicWalletSync(gw);
    await tick(sync, c, active);
    after.stop();
    final warmCalls = gw.calls.length;
    await tick(sync, c, active, now: at.add(const Duration(seconds: 20)));
    expect(gw.calls.length, warmCalls);
    await tick(sync, c, active, now: at.add(const Duration(minutes: 5)));
    expect(gw.calls.length, warmCalls * 2);
    // ignore: avoid_print
    print(
      'C BENCH: before=$oldCalls calls/${before.elapsedMilliseconds}ms; after=$warmCalls calls/${after.elapsedMilliseconds}ms; ordinary poll=0; five-minute poll=$warmCalls calls',
    );
  });
}
