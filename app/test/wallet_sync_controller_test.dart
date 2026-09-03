import 'dart:convert';

import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGateway implements WalletSyncGateway {
  bool unlocked = true;
  int pinnedIndex = 0;
  int maxIndex = 5;
  bool unusedChange = false;

  /// Discovery result returned to the controller.
  List<Map<String, dynamic>> discovered = [];
  int nextUnused = 0;

  /// Per-address balance responses. Missing address => throws.
  Map<String, Map<String, dynamic>> balances = {};
  List<Map<String, dynamic>> history = [];
  bool historyPartial = false;
  bool historyThrows = false;
  int unspentCount = 0;
  Map<String, dynamic>? cached;

  int discoverCalls = 0;
  int probeCalls = 0;
  final balanceCalls = <String>[];
  int historyCalls = 0;
  Map<String, dynamic>? savedCache;

  /// Set to lock the wallet after discovery returns.
  bool lockAfterDiscover = false;

  @override
  bool get isUnlocked => unlocked;

  @override
  String? get activeWalletId => 'w1';

  @override
  Future<String> discoverAddresses() async {
    discoverCalls++;
    if (lockAfterDiscover) unlocked = false;
    return jsonEncode({'addresses': discovered, 'next_unused_index': nextUnused});
  }

  @override
  Future<int> getPinnedAddressIndex() async => pinnedIndex;

  @override
  Future<String?> tryDeriveAddress(int index) async =>
      index > maxIndex ? null : 'addr$index';

  @override
  Future<String> deriveAddress(int index) async => 'addr$index';

  @override
  bool useUnusedChangeAddress(String? walletId) => unusedChange;

  @override
  Future<Map<String, dynamic>> getBalance(String address) async {
    balanceCalls.add(address);
    final b = balances[address];
    if (b == null) throw Exception('node down');
    return b;
  }

  @override
  Future<List<TokenBalance>> hydrateTokens(dynamic raw) async {
    final items = raw is List ? raw : const [];
    return [
      for (final t in items)
        if (t is Map)
          TokenBalance(
            id: t['id'] as String,
            amount: (t['amount'] as num).toInt(),
            name: t['name'] as String?,
            decimals: (t['decimals'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> loadHistory(
    List<String> addresses, {
    int limit = 20,
  }) async {
    historyCalls++;
    if (historyThrows) throw Exception('history down');
    return history;
  }

  @override
  bool get lastHistoryPartial => historyPartial;

  @override
  Future<int> countUnspentBoxes(List<String> addresses) async => unspentCount;

  @override
  Future<Map<String, dynamic>?> loadCachedState(String walletKey) async =>
      cached != null && cached!['wallet_id'] == walletKey ? cached : null;

  @override
  Future<void> saveCachedState(Map<String, dynamic> snapshot) async {
    savedCache = snapshot;
  }

  @override
  void probeNetwork() {
    probeCalls++;
  }

  final prefetched = <String>[];
  @override
  Future<void> prefetchTokenMeta(Iterable<String> ids) async => prefetched.addAll(ids);
}

void main() {
  late FakeGateway gw;
  late WalletSyncController c;

  setUp(() {
    gw = FakeGateway();
    c = WalletSyncController(gw);
  });

  group('hydrateAfterUnlock', () {
    test('derives the pinned address and reports synced-from-cache state',
        () async {
      gw.pinnedIndex = 2;
      gw.cached = {
        'wallet_id': 'w1',
        'balance_nano_erg': 5000,
        'used_addresses': [
          {'address': 'addr0', 'balance_nano_erg': 5000},
        ],
        'transactions': [
          {'tx_id': 't1'},
        ],
        'tokens': [
          {'id': 'tok', 'amount': 3, 'name': 'Tok', 'decimals': 0, 'iconUrl': 'https://x/i.png'},
        ],
        'utxo_count': 4,
      };

      final ok = await c.hydrateAfterUnlock();

      expect(ok, isTrue);
      expect(c.receiveAddress, 'addr2');
      expect(c.balanceNano, 5000);
      expect(c.recentTxs.single['tx_id'], 't1');
      expect(c.tokens.single.id, 'tok');
      expect(c.tokens.single.iconUrl, 'https://x/i.png');
      expect(c.utxoCount, 4);
      expect(c.usedAddresses.single['address'], 'addr0');
      expect(c.senderAddress, 'addr0');
      expect(c.pinIssue, isNull);
    });

    test('falls back to index 0 and flags a pinned index beyond range',
        () async {
      gw.pinnedIndex = 9;
      gw.maxIndex = 5;

      final ok = await c.hydrateAfterUnlock();

      expect(ok, isTrue);
      expect(c.receiveAddress, 'addr0');
      expect(c.pinIssue, contains('9'));
    });

    test('returns false and leaves state empty when the wallet is locked',
        () async {
      gw.unlocked = false;

      final ok = await c.hydrateAfterUnlock();

      expect(ok, isFalse);
      expect(c.receiveAddress, isNull);
    });
  });

  group('refresh', () {
    setUp(() async {
      gw.discovered = [
        {'address': 'addr0', 'balance_nano_erg': 100},
        {'address': 'addr1', 'balance_nano_erg': 200},
      ];
      gw.nextUnused = 2;
      gw.balances = {
        'addr0': {'balance_nano_erg': 100, 'tokens': []},
        'addr1': {
          'balance_nano_erg': 250,
          'tokens': [
            {'id': 'tok', 'amount': 3, 'name': 'Tok'},
          ],
        },
        'addr2': {
          'balance_nano_erg': 0,
          'tokens': [
            {'id': 'tok', 'amount': 2, 'name': 'Tok'},
          ],
        },
      };
      gw.history = [
        {'tx_id': 't1'},
        {'tx_id': 't2'},
      ];
      gw.unspentCount = 3;
      await c.hydrateAfterUnlock();
    });

    test('a full refresh discovers, probes, and sums balances across addresses',
        () async {
      await c.refresh(discover: true);

      expect(gw.discoverCalls, 1);
      expect(gw.probeCalls, 1);
      expect(c.receiveAddress, 'addr0');
      expect(c.changeAddress, 'addr0');
      expect(c.usedAddresses.map((a) => a['address']), ['addr0', 'addr1']);
      expect(c.frontierAddresses, ['addr0', 'addr1', 'addr2']);
      expect(c.balanceNano, 350);
      expect(c.tokens.single.amount, 5);
      expect(c.recentTxs.map((t) => t['tx_id']), ['t1', 't2']);
      expect(c.utxoCount, 3);
      expect(c.phase, SyncPhase.synced);
      expect(c.senderAddress, 'addr1');
    });

    test('a light refresh reuses known addresses without rediscovering',
        () async {
      await c.refresh(discover: true);
      gw.balanceCalls.clear();
      gw.balances['addr1'] = {'balance_nano_erg': 999, 'tokens': []};

      await c.refresh(discover: false);

      expect(gw.discoverCalls, 1);
      expect(gw.probeCalls, 1);
      expect(gw.balanceCalls.toSet(), {'addr0', 'addr1', 'addr2'});
      expect(c.balanceNano, 1099);
    });

    test('fresh mode receives and sends change on the next unused address', () async {
      gw.unusedChange = true;

      await c.refresh(discover: true);

      expect(c.receiveAddress, 'addr2');
      expect(c.changeAddress, 'addr2');
    });

    test('reuse mode keeps receive and change on the pinned address', () async {
      gw.pinnedIndex = 1;

      await c.refresh(discover: true);

      expect(c.receiveAddress, 'addr1');
      expect(c.changeAddress, 'addr1');
    });

    test('fresh mode: a pinned index at or beyond the frontier stays the receive address',
        () async {
      gw.unusedChange = true;
      gw.pinnedIndex = 4;

      await c.refresh(discover: true);

      expect(c.receiveAddress, 'addr4');
      expect(c.changeAddress, 'addr2');
    });

    test('an address up to the frontier is queried even without confirmed history',
        () async {
      // Discovery saw history only at index 0 but the frontier is 3 (the
      // node's index lags a consolidation that paid index 2).
      gw.discovered = [
        {'index': 0, 'address': 'addr0', 'balance_nano_erg': 100, 'tokens': []},
      ];
      gw.nextUnused = 3;
      gw.balances['addr2'] = {'balance_nano_erg': 700, 'tokens': []};
      gw.balances['addr3'] = {'balance_nano_erg': 0, 'tokens': []};

      await c.refresh(discover: true);

      expect(gw.balanceCalls.toSet(), containsAll(['addr0', 'addr1', 'addr2', 'addr3']));
      expect(c.balanceNano, 100 + 250 + 700);
    });

    test('keeps the previous balance and reports failure when every node call fails',
        () async {
      await c.refresh(discover: true);
      gw.balances.clear();

      await c.refresh(discover: false);

      expect(c.balanceNano, 350);
      expect(c.phase, SyncPhase.failed);
      expect(c.isStale, isTrue);
    });

    test('reports stale balances when only some addresses fail', () async {
      gw.balances.remove('addr1');

      await c.refresh(discover: true);

      expect(c.balanceNano, 100);
      expect(c.phase, SyncPhase.balancesStale);
      expect(c.isStale, isTrue);
    });

    test('an empty history after a partial failure keeps the old activity',
        () async {
      await c.refresh(discover: true);
      gw.balances.remove('addr1');
      gw.history = [];

      await c.refresh(discover: false);

      expect(c.recentTxs, hasLength(2));
    });

    test('an empty history with no failures clears pending activity', () async {
      await c.refresh(discover: true);
      gw.history = [];

      await c.refresh(discover: false);

      expect(c.recentTxs, isEmpty);
    });

    test('reports partial history when some address histories failed',
        () async {
      gw.historyPartial = true;

      await c.refresh(discover: true);

      expect(c.phase, SyncPhase.historyPartial);
      expect(c.isStale, isFalse);
    });

    test('persists a cache snapshot keyed by the wallet id', () async {
      await c.refresh(discover: true);

      expect(gw.savedCache?['wallet_id'], 'w1');
      expect(gw.savedCache?['balance_nano_erg'], 350);
      expect((gw.savedCache?['transactions'] as List).length, 2);
      expect((gw.savedCache?['tokens'] as List).single['name'], 'Tok');
      expect(gw.savedCache?['utxo_count'], 3);
    });

    test('resets and does not touch the node when locked during discovery',
        () async {
      gw.lockAfterDiscover = true;

      await c.refresh(discover: true);

      expect(gw.balanceCalls, isEmpty);
      expect(c.receiveAddress, isNull);
      expect(c.balanceNano, isNull);
      expect(c.phase, SyncPhase.idle);
    });

    test('concurrent callers share one in-flight refresh', () async {
      final a = c.refresh(discover: true);
      final b = c.refresh(discover: false);
      await Future.wait([a, b]);

      expect(gw.discoverCalls, 1);
      expect(gw.historyCalls, 1);
    });

    test('phase is syncing while a refresh is in flight', () async {
      final phases = <SyncPhase>[];
      c.addListener(() => phases.add(c.phase));

      await c.refresh(discover: false);

      expect(phases.first, SyncPhase.syncing);
      expect(phases.last, SyncPhase.synced);
    });
  });

  test('reset clears every field back to idle', () async {
    gw.balances = {
      'addr0': {'balance_nano_erg': 1, 'tokens': []},
    };
    await c.hydrateAfterUnlock();
    await c.refresh(discover: false);

    c.reset();

    expect(c.receiveAddress, isNull);
    expect(c.balanceNano, isNull);
    expect(c.tokens, isEmpty);
    expect(c.recentTxs, isEmpty);
    expect(c.usedAddresses, isEmpty);
    expect(c.utxoCount, 0);
    expect(c.phase, SyncPhase.idle);
  });

  test('routeArgs mirrors the synced state for pushed screens', () async {
    gw.balances = {
      'addr0': {'balance_nano_erg': 5, 'tokens': []},
    };
    await c.hydrateAfterUnlock();
    await c.refresh(discover: false);

    final a = c.routeArgs;
    expect(a.receiveAddress, 'addr0');
    expect(a.spendableNano, 5);
    expect(a.historyAddresses, ['addr0']);
  });
}
