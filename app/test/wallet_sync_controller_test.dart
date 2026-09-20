import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/services/stealth_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:argus_wallet/services/wallet_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Batch read over [FakeGateway], so tests can exercise the path that knows
/// which endpoint served the balances. The live gateway is always batch.
class _FakeRead implements WalletSyncRead {
  _FakeRead(this.gw, this.addresses);
  final FakeGateway gw;

  /// Carried through: subclasses gate on which addresses were asked for, so
  /// dropping them here silently changes the behaviour under test.
  final List<String> addresses;
  @override
  Future<Map<String, dynamic>> balance(String address) =>
      gw.getBalance(address);
  @override
  Future<HistoryResult> history() => gw.loadHistory(addresses);
  @override
  Future<int> count() => gw.countUnspentBoxes(addresses);
  @override
  Future<String?> servedBy() async => gw.servedByUrl;
}

class FakeGateway implements WalletSyncGateway, WalletSyncBatchGateway {
  /// Null models a read that cannot say which node answered, in which case
  /// nothing may be resolved.
  String? servedByUrl = 'https://served.example';

  @override
  WalletSyncRead startRead(List<String> addresses) =>
      _FakeRead(this, addresses);

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

  bool balanceThrows = false;
  @override
  Future<Map<String, dynamic>> getBalance(String address) async {
    balanceCalls.add(address);
    if (balanceThrows) throw Exception('node down');
    final b = balances[address];
    if (b == null) throw Exception('node down');
    return b;
  }

  final List<String> resolved = [];
  @override
  Future<Map<String, TokenBalance>> resolveTokenNames(
    Iterable<String> ids, {
    required String walletId,
    required String servedBy,
    required bool Function() stillCurrent,
  }) async {
    resolved.addAll(ids);
    resolveProviders.add(servedBy);
    return {
      for (final id in ids)
        if (resolvedNames.containsKey(id))
          id: TokenBalance(id: id, amount: 0, name: resolvedNames[id]),
    };
  }

  /// Names the fake will hand back, so a test can check they reach the UI.
  final Map<String, String> resolvedNames = {};
  final List<String> resolveProviders = [];

  /// Overrides what hydration returns, so a test can supply a fully
  /// resolved descriptor.
  Map<String, TokenBalance>? hydrated;

  @override
  Future<List<TokenBalance>> hydrateTokens(dynamic raw) async {
    if (hydrated != null) {
      return [
        for (final t in (raw as List))
          if (hydrated!.containsKey(t['id'])) hydrated![t['id']]!,
      ];
    }
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
  Future<HistoryResult> loadHistory(
    List<String> addresses, {
    int limit = 20,
  }) async {
    historyCalls++;
    if (historyGate != null) await historyGate!.future;
    if (historyThrows) throw Exception('history down');
    return (rows: history, partial: historyPartial);
  }

  /// When set, history waits on it: models the slow leg of a refresh.
  Completer<void>? historyGate;

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

  bool stealthEnabled = true;

  /// Null models an unreachable explorer.
  StealthScanResult? stealthResult;
  bool stealthThrows = false;
  int stealthCalls = 0;

  @override
  bool get stealthScanEnabled => stealthEnabled;

  @override
  Future<StealthScanResult?> scanStealth() async {
    stealthCalls++;
    if (stealthThrows) throw Exception('explorer down');
    return stealthResult;
  }
}

void main() {
  test('tokens are ordered for display the same way every time', () {
    TokenBalance t(String id, String name, {int emission = 1000}) =>
        TokenBalance(id: id, amount: 1, name: name, decimals: 0, emissionAmount: emission, supplyEvidence: SupplyEvidence.originalEmission, decimalsEvidence: DecimalsEvidence.valid);
    final a = [t('b1', 'kushti'), t('n1', 'Ape', emission: 1), t('a1', 'ergopad'), t('c1', 'Kushti')];
    final ordered = orderTokensForDisplay(a);
    expect(ordered.map((x) => x.id), ['a1', 'b1', 'c1', 'n1'], reason: 'fungible by name then id, NFTs last');
    expect(orderTokensForDisplay(a.reversed.toList()).map((x) => x.id), ['a1', 'b1', 'c1', 'n1'],
        reason: 'input order does not matter');
  });

  _stealthSnapshotTests();
  _quietRefreshTests();
  _broadcastTests();
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

      expect(gw.balanceCalls, ['addr0']); // Read before discovery.
      expect(c.receiveAddress, isNull);
      expect(c.balanceNano, isNull);
      expect(c.phase, SyncPhase.idle);
    });

    test('concurrent callers share one in-flight refresh', () async {
      final a = c.refresh(discover: true);
      final b = c.refresh(discover: false);
      await Future.wait([a, b]);

      expect(gw.discoverCalls, 1);
      expect(gw.historyCalls, 2); // Known set, then expanded set.
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

  group('stealth scan', () {
    setUp(() async {
      gw.balances = {
        'addr0': {'balance_nano_erg': 100, 'tokens': []},
      };
      await c.hydrateAfterUnlock();
    });

    test('folds stealth ERG and tokens into the wallet view', () async {
      gw.stealthResult = StealthScanResult(
        scanned: 20,
        ownedCount: 2,
        totalNanoErg: 750,
        tokens: [StealthToken(id: 'aa', amount: BigInt.from(7))],
        boxIds: const ['b1', 'b2'],
      );

      await c.refresh(discover: false);

      expect(gw.stealthCalls, 1);
      expect(c.stealthNano, 750);
      expect(c.stealthBalanceUnknown, isFalse);
      // Spendable stays what ordinary coin selection can reach.
      expect(c.balanceNano, 100);
      expect(c.routeArgs.spendableNano, 100);
      expect(c.totalNanoWithStealth, 850);
      final aa = c.displayTokens.singleWhere((t) => t.id == 'aa');
      expect(aa.amount, 7);
      expect(aa.stealthAmount, 7);
      expect(c.phase, SyncPhase.synced);
    });

    test('stealth-only ids are never handed to name resolution', () async {
      const ordinary = 'a1';
      const stealthOnly = 's1';
      const both = 'b1';
      // A stealth-only holding is one the ordinary balance does not carry,
      // so it is absent here. Deleting `removeWhere(stealthOnly.contains)`
      // will NOT fail this test, and that is the point being asserted: the
      // containment is structural — candidates are the ids the node itself
      // returned — rather than a filter that could be removed by accident.
      gw.balances = {
        'addr0': {
          'balance_nano_erg': 100,
          'tokens': [
            {'id': ordinary, 'amount': 5},
            {'id': both, 'amount': 5},
          ],
        },
      };
      gw.stealthResult = StealthScanResult(
        scanned: 20,
        ownedCount: 2,
        totalNanoErg: 750,
        tokens: [
          StealthToken(id: stealthOnly, amount: BigInt.from(3)),
          StealthToken(id: both, amount: BigInt.from(2)),
        ],
        boxIds: const ['bx1', 'bx2'],
      );
      gw.resolved.clear();

      await c.refresh(discover: false);
      await c.pendingNameResolution;

      expect(gw.resolved, contains(ordinary),
          reason: 'positive control: ordinary holdings do resolve');
      expect(gw.resolved, contains(both),
          reason: 'held in ordinary boxes too, so the node already has it');
      expect(gw.resolved, isNot(contains(stealthOnly)),
          reason: 'entirely stealth-held, so the node that served these '
              'addresses has never seen this id');
      expect(c.stealthTokens.map((t) => t.id), contains(stealthOnly),
          reason: 'positive control: the holding exists and is displayed, '
              'so its absence above is containment and not a missing token');
    });

    test('a failed balance read resolves nothing from retained state',
        () async {
      // `tokens` survives a failed refresh. Those ids came from a previous
      // response, possibly from another node, so they must not be sent.
      gw.balances = {
        'addr0': {
          'balance_nano_erg': 100,
          'tokens': [
            {'id': 'old', 'amount': 1},
          ],
        },
      };
      await c.refresh(discover: false);
      await c.pendingNameResolution;
      expect(gw.resolved, contains('old'));

      gw.resolved.clear();
      gw.balanceThrows = true;
      await c.refresh(discover: false);
      await c.pendingNameResolution;
      expect(c.tokens.map((t) => t.id), contains('old'),
          reason: 'the holding is still displayed');
      expect(gw.resolved, isEmpty,
          reason: 'but nothing may be re-sent from retained state');
      gw.balanceThrows = false;
    });

    test('resolved names reach the published holdings', () async {
      gw.balances = {
        'addr0': {
          'balance_nano_erg': 100,
          'tokens': [
            {'id': 'a1', 'amount': 5},
          ],
        },
      };
      gw.resolvedNames['a1'] = 'Resolved';

      await c.refresh(discover: false);
      await c.pendingNameResolution;

      expect(c.tokens.single.name, 'Resolved',
          reason: 'a first refresh must not leave the id on screen until '
              'some later hydration happens to pick it up');
      expect(c.tokens.single.amount, 5, reason: 'amount preserved');
      gw.resolvedNames.clear();
    });

    test('retaining a wallet preserves names already on screen', () async {
      gw.balances = {
        'addr0': {
          'balance_nano_erg': 100,
          'tokens': [
            {'id': 'a1', 'amount': 5},
          ],
        },
      };
      gw.resolvedNames['a1'] = 'Resolved';
      await c.refresh(discover: false);
      await c.pendingNameResolution;
      expect(c.tokens.single.name, 'Resolved', reason: 'control');

      c.deactivate();
      c.activateWallet('w1');

      expect(c.tokens.single.name, 'Resolved',
          reason: 'the retained balance view keeps its metadata');
      expect(c.tokens.single.amount, 5, reason: 'the holding itself stays');
      gw.resolvedNames.clear();
    });

    test('nothing resolves when the serving node is unknown', () async {
      gw.balances = {
        'addr0': {
          'balance_nano_erg': 100,
          'tokens': [
            {'id': 'a1', 'amount': 5},
          ],
        },
      };
      gw.servedByUrl = null;
      gw.resolved.clear();

      await c.refresh(discover: false);
      await c.pendingNameResolution;

      expect(gw.resolved, isEmpty,
          reason: 'without knowing who answered, the disclosure argument '
              'does not hold');
      gw.servedByUrl = 'https://served.example';
    });

    test('resolution addresses the node that answered', () async {
      gw.balances = {
        'addr0': {
          'balance_nano_erg': 100,
          'tokens': [
            {'id': 'a1', 'amount': 5},
          ],
        },
      };
      gw.servedByUrl = 'https://fellback.example';
      gw.resolveProviders.clear();

      await c.refresh(discover: false);
      await c.pendingNameResolution;

      expect(gw.resolveProviders, ['https://fellback.example'],
          reason: 'not the configured node, the one that served');
      gw.servedByUrl = 'https://served.example';
    });

    test('a stealth-only collectible keeps its classification', () async {
      // Rebuilding stealth holdings field-by-field dropped the evidence that
      // makes isCollectible true, and stealth-only ids are never resolved,
      // so nothing downstream could put it back.
      gw.hydrated = {
        'nft1': TokenBalance(
          id: 'nft1',
          amount: 0,
          name: 'Art',
          decimals: 0,
          emissionAmount: 1,
          supplyEvidence: SupplyEvidence.originalEmission,
          decimalsEvidence: DecimalsEvidence.valid,
          declaredAssetKind: DeclaredAssetKind.picture,
          metadataState: MetadataState.complete,
        ),
      };
      gw.stealthResult = StealthScanResult(
        scanned: 1,
        ownedCount: 1,
        totalNanoErg: 0,
        tokens: [StealthToken(id: 'nft1', amount: BigInt.one)],
        boxIds: const ['bx'],
      );

      await c.refresh(discover: false);

      final held = c.stealthTokens.singleWhere((t) => t.id == 'nft1');
      expect(held.isCollectible, isTrue,
          reason: 'a resolved collectible held only in stealth must not drop '
              'out of the Collectibles filter');
      expect(held.stealthAmount, 1);
      gw.hydrated = null;
    });

    test('an unreachable explorer leaves the balance unknown, not the sync',
        () async {
      gw.stealthResult = null;

      await c.refresh(discover: false);

      expect(c.stealthBalanceUnknown, isTrue);
      expect(c.stealthNano, 0);
      expect(c.balanceNano, 100);
      // A stealth failure must never degrade the sync phase.
      expect(c.phase, SyncPhase.synced);
    });

    test('a throwing scan is caught and does not fail the refresh', () async {
      gw.stealthThrows = true;

      await c.refresh(discover: false);

      expect(c.stealthBalanceUnknown, isTrue);
      expect(c.phase, SyncPhase.synced);
    });

    test('a later failure keeps the last known stealth balance', () async {
      gw.stealthResult = const StealthScanResult(
        scanned: 20,
        ownedCount: 1,
        totalNanoErg: 500,
        tokens: [],
        boxIds: ['b1'],
      );
      await c.refresh(discover: false);
      expect(c.stealthNano, 500);

      gw.stealthResult = null;
      await c.refresh(discover: false);

      expect(c.stealthNano, 500, reason: 'stale is better than a wrong zero');
      expect(c.stealthBalanceUnknown, isTrue);
    });

    test('with the scan off the explorer is never asked and zero is honest',
        () async {
      gw.stealthEnabled = false;

      await c.refresh(discover: false);

      expect(gw.stealthCalls, 0);
      expect(c.stealthNano, 0);
      expect(c.stealthBalanceUnknown, isFalse);
      expect(c.displayTokens, isEmpty);
    });

    test('reset clears the stealth view', () async {
      gw.stealthResult = StealthScanResult(
        scanned: 1,
        ownedCount: 1,
        totalNanoErg: 42,
        tokens: [StealthToken(id: 'aa', amount: BigInt.one)],
        boxIds: const ['b1'],
      );
      await c.refresh(discover: false);
      expect(c.stealthNano, 42);

      c.reset();

      expect(c.stealthNano, 0);
      expect(c.stealthTokens, isEmpty);
      expect(c.stealthBalanceUnknown, isTrue);
    });
  });
}

// A routine poll should not make the status strip flicker
void _quietRefreshTests() {
  test('a quiet refresh does not announce itself once something is shown', () async {
    final gw = FakeGateway()
      ..discovered = [
        {'index': 0, 'address': 'addr0', 'balance_nano_erg': 100, 'tokens': []},
      ]
      ..nextUnused = 1
      ..balances = {
        'addr0': {'balance_nano_erg': 100, 'tokens': []},
        'addr1': {'balance_nano_erg': 0, 'tokens': []},
      };
    final c = WalletSyncController(gw);
    await c.refresh(discover: true);
    expect(c.phase, SyncPhase.synced);

    final seen = <SyncPhase>[];
    c.addListener(() => seen.add(c.phase));
    await c.refresh(discover: false, quiet: true);
    expect(seen.contains(SyncPhase.syncing), isFalse,
        reason: 'a 20-second poll must not flip the strip to Syncing');
    expect(c.phase, SyncPhase.synced);
  });

  test('the first load still announces itself, quiet or not', () async {
    final gw = FakeGateway()
      ..discovered = [
        {'index': 0, 'address': 'addr0', 'balance_nano_erg': 100, 'tokens': []},
      ]
      ..nextUnused = 1
      ..balances = {
        'addr0': {'balance_nano_erg': 100, 'tokens': []},
        'addr1': {'balance_nano_erg': 0, 'tokens': []},
      };
    final c = WalletSyncController(gw);
    final seen = <SyncPhase>[];
    c.addListener(() => seen.add(c.phase));
    await c.refresh(discover: true, quiet: true);
    expect(seen.first, SyncPhase.syncing, reason: 'nothing was on screen yet');
  });

  test('a quiet refresh still reports a failure', () async {
    final gw = FakeGateway()
      ..discovered = [
        {'index': 0, 'address': 'addr0', 'balance_nano_erg': 100, 'tokens': []},
      ]
      ..nextUnused = 1
      ..balances = {
        'addr0': {'balance_nano_erg': 100, 'tokens': []},
        'addr1': {'balance_nano_erg': 0, 'tokens': []},
      };
    final c = WalletSyncController(gw);
    await c.refresh(discover: true);
    gw.balances.clear();
    await c.refresh(discover: false, quiet: true);
    expect(c.phase, SyncPhase.failed);
  });
}

// The stealth figure a locked wallet inherits must not pretend to be fresh
void _stealthSnapshotTests() {
  FakeGateway gw() => FakeGateway()
    ..discovered = [
      {'index': 0, 'address': 'addr0', 'balance_nano_erg': 100, 'tokens': []},
    ]
    ..nextUnused = 1
    ..balances = {
      'addr0': {'balance_nano_erg': 100, 'tokens': []},
      'addr1': {'balance_nano_erg': 0, 'tokens': []},
    };

  test('a successful scan is stamped with the time it happened', () async {
    final g = gw()..stealthResult = const StealthScanResult(
        scanned: 1, ownedCount: 1, totalNanoErg: 5000000000, tokens: [], boxIds: ['b']);
    final c = WalletSyncController(g);
    await c.refresh(discover: true);
    expect(c.stealthNano, 5000000000);
    expect(c.stealthScannedAt, isNotNull);
    expect(g.savedCache?['stealth_nano_erg'], 5000000000);
    expect(g.savedCache?['stealth_scanned_at'], isNotNull);
  });

  test('a failed scan keeps the old figure and its old timestamp', () async {
    final g = gw()..stealthResult = const StealthScanResult(
        scanned: 1, ownedCount: 1, totalNanoErg: 5000000000, tokens: [], boxIds: ['b']);
    final c = WalletSyncController(g);
    await c.refresh(discover: true);
    final firstStamp = g.savedCache?['stealth_scanned_at'];

    // Now the explorer stops answering.
    g.stealthResult = null;
    await c.refresh(discover: false);
    expect(c.stealthBalanceUnknown, isTrue);
    expect(g.savedCache?['stealth_nano_erg'], 5000000000,
        reason: 'the last figure is still the best known');
    expect(g.savedCache?['stealth_scanned_at'], firstStamp,
        reason: 'but it must not claim to have been checked just now');
  });

  test('turning the scan off clears the figure and its timestamp', () async {
    final g = gw()
      ..stealthResult = const StealthScanResult(
          scanned: 1, ownedCount: 1, totalNanoErg: 5000000000, tokens: [], boxIds: ['b']);
    final c = WalletSyncController(g);
    await c.refresh(discover: true);
    g.stealthEnabled = false;
    await c.refresh(discover: false);
    expect(c.stealthNano, 0);
    expect(c.stealthScannedAt, isNull);
  });
}

void _broadcastTests() {
  late FakeGateway gw;
  late WalletSyncController c;

  group('broadcasts and pending', () {
    setUp(() async {
      gw = FakeGateway();
      c = WalletSyncController(gw);
      gw.discovered = [
        {'address': 'addr0', 'balance_nano_erg': 1000},
      ];
      gw.nextUnused = 1;
      gw.balances = {
        'addr0': {'balance_nano_erg': 1000, 'tokens': []},
        'addr1': {'balance_nano_erg': 0, 'tokens': []},
      };
      gw.history = [
        {'tx_id': 't1', 'height': 10},
      ];
      await c.hydrateAfterUnlock();
      await c.refresh(discover: true);
    });

    test('a broadcast shows as Pending and moves the balance at once', () {
      c.noteBroadcast('sent1', valueNano: -300);
      expect(c.recentTxs.first['tx_id'], 'sent1');
      expect(c.recentTxs.first['height'], 0);
      expect(c.balanceNano, 700);
      expect(c.hasPending, isTrue);
    });

    test('the row and the delta outlive a refresh the node has not caught up with',
        () async {
      c.noteBroadcast('sent1', valueNano: -300);
      await c.refresh(discover: false, quiet: true);
      expect(c.recentTxs.map((t) => t['tx_id']), ['sent1', 't1']);
      expect(c.balanceNano, 700, reason: 'the node still says 1000');
    });

    test("once the node shows the transaction its own figures win", () async {
      c.noteBroadcast('sent1', valueNano: -300);
      // The note's own immediate refresh ran against a node that had not
      // seen the transaction yet.
      await c.refresh(discover: false, quiet: true);
      expect(c.balanceNano, 700);
      gw.balances['addr0'] = {'balance_nano_erg': 690, 'tokens': []};
      gw.history = [
        {'tx_id': 'sent1', 'height': 0},
        {'tx_id': 't1', 'height': 10},
      ];
      await c.refresh(discover: false, quiet: true);
      expect(c.balanceNano, 690);
      expect(c.recentTxs.map((t) => t['tx_id']), ['sent1', 't1']);
      expect(c.recentTxs.first['broadcast'], isNull);
      expect(c.hasPending, isTrue, reason: 'still in the mempool');

      gw.history = [
        {'tx_id': 'sent1', 'height': 11},
        {'tx_id': 't1', 'height': 10},
      ];
      await c.refresh(discover: false, quiet: true);
      expect(c.hasPending, isFalse);
    });

    test('a second note for the same id merges the value without doubling', () {
      c.noteBroadcast('sent1');
      expect(c.balanceNano, 1000);
      c.noteBroadcast('sent1', valueNano: -300);
      c.noteBroadcast('sent1', valueNano: -300);
      expect(c.balanceNano, 700);
      expect(c.recentTxs.where((t) => t['tx_id'] == 'sent1').length, 1);
    });

    test('the balance is published before the slow history leg lands', () async {
      gw.balances['addr0'] = {'balance_nano_erg': 1234, 'tokens': []};
      gw.historyGate = Completer<void>();
      final op = c.refresh(discover: false, quiet: true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.balanceNano, 1234, reason: 'shown while history is still loading');
      expect(c.busy, isTrue);
      gw.historyGate!.complete();
      await op;
      expect(c.phase, SyncPhase.synced);
    });

    test('quiet polls ask the explorer for stealth boxes every third time', () async {
      final before = gw.stealthCalls;
      await c.refresh(discover: false, quiet: true);
      await c.refresh(discover: false, quiet: true);
      expect(gw.stealthCalls, before, reason: 'two quiet polls reuse the last scan');
      await c.refresh(discover: false, quiet: true);
      expect(gw.stealthCalls, before + 1);
      await c.refresh(discover: false);
      expect(gw.stealthCalls, before + 2, reason: 'a pull to refresh always scans');
    });
  });
}
