import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/services/mix_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A gateway that answers from canned JSON and records what it was asked.
class FakeGateway implements MixGateway {
  bool unlocked = true;
  String? wallet = 'w1';
  final calls = <String>[];
  final notifications = <String>[];

  /// Script for `observe`, `plan`, `advance`, `leave`, `recover`, keyed by
  /// call name; each is consumed in order, the last repeats.
  final Map<String, List<Object>> script = {};

  Future<Object> _next(String name, {bool log = true}) async {
    if (log) calls.add(name);
    final list = script[name];
    if (list == null || list.isEmpty) throw StateError('no script for $name');
    var v = list.length == 1 ? list.first : list.removeAt(0);
    // A Future in the script holds the call until the test completes it.
    if (v is Future) v = await v as Object;
    if (v is Exception || v is Error) throw v;
    return v;
  }

  @override
  bool get isUnlocked => unlocked;
  @override
  String? get walletId => wallet;
  @override
  String? get nodeUrl => node;
  String? node;
  @override
  String get explorerBase => 'https://explorer/';
  @override
  int? get chainHeight => nodeHeight;
  int? nodeHeight;

  /// Keystore stand-in: "walletId:mixId" → key hex.
  final keys = <String, String>{};
  @override
  Future<String> exportKey(int mixId) async {
    calls.add('exportKey:$mixId');
    return 'key-$mixId';
  }
  @override
  Future<void> saveKey({required String walletId, required int mixId, required String keyHex}) async {
    keys['$walletId:$mixId'] = keyHex;
  }
  @override
  Future<String?> loadKey({required String walletId, required int mixId}) async => keys['$walletId:$mixId'];
  @override
  Future<void> deleteKey({required String walletId, required int mixId}) async {
    keys.remove('$walletId:$mixId');
  }
  @override
  Future<List<({String walletId, int mixId})>> listKeys() async => [
        for (final k in keys.keys)
          (walletId: k.substring(0, k.lastIndexOf(':')), mixId: int.parse(k.substring(k.lastIndexOf(':') + 1))),
      ];

  @override
  String contractTrees() => jsonEncode({'half': 'aa', 'full': 'bb', 'fee': 'cc', 'token': 'dd'});

  @override
  Future<String> newState({
    required int mixId,
    required int denomination,
    String? tokenId,
    int? tokenAmount,
    required int level,
    required int rounds,
    required String destinationAddress,
    required int nowUnix,
  }) async {
    calls.add('newState');
    return jsonEncode(state(mixId: mixId, kind: 'pending', denomination: denomination, target: rounds));
  }

  @override
  Future<String> rings(String chainJson) async => '{"rings":[]}';
  @override
  Future<String> fundingRequirement(String chainJson, int d, int l, int? f) async =>
      '{"needed_nano_erg":1}';
  @override
  Future<String> plan(String stateJson, String chainJson, List<String> own) async =>
      jsonEncode(await _next('plan'));
  @override
  Future<String> observe(String stateJson, String chainJson, int nowUnix) async {
    final v = await _next('observe');
    return v == 'same' ? stateJson : jsonEncode(v);
  }

  @override
  Future<String> advance(String s, String c, List<String> own, String? n, int now) async =>
      jsonEncode(await _next('advance'));
  @override
  Future<String> observeWithKey(String stateJson, String c, String keyHex, int now) async {
    calls.add('withKey:$keyHex');
    final v = await _next('observe', log: false);
    return v == 'same' ? stateJson : jsonEncode(v);
  }

  /// Runs before each keyed advance: a stand-in for the other isolate
  /// writing meanwhile.
  Future<void> Function()? beforeAdvanceWithKey;

  @override
  Future<String> advanceWithKey(String s, String c, List<String> own, String? n, int now, String keyHex) async {
    calls.add('advanceWithKey:$keyHex');
    await beforeAdvanceWithKey?.call();
    return jsonEncode(await _next('advance', log: false));
  }
  @override
  Future<String> leave(String s, String c, String? d, String? n, int now) async =>
      jsonEncode(await _next('leave'));
  @override
  Future<String> recover(String c, int now) async => jsonEncode(await _next('recover'));
  @override
  Future<String> prepareEntry({
    required String stateJson,
    required String chainJson,
    required String fundingAddress,
    required String fundingBoxId,
    required List<String> ownHalfBoxIds,
    String? nodeUrl,
    required int nowUnix,
  }) async =>
      jsonEncode(await _next('prepareEntry'));
  @override
  Future<void> notify({required String title, required String body}) async {
    notifications.add('$title | $body');
  }
}

Map<String, dynamic> state({
  int mixId = 0,
  String kind = 'full_owned',
  String? boxId = 'box1',
  int denomination = 1000000000,
  int done = 1,
  int target = 3,
  int round = 0,
  String destination = '0008cd00',
}) =>
    {
      'mix_id': mixId,
      'ring': {'value': denomination, 'token_id': null, 'token_amount': null},
      'level': 20,
      'rounds_target': target,
      'rounds_done': done,
      'round': round,
      'phase': {
        'kind': kind,
        if (kind == 'half_posted' || kind == 'full_owned') 'box_id': boxId,
        if (kind == 'full_owned') 'role': 'bob',
        if (kind == 'withdrawn') 'tx_id': 'txw',
      },
      'destination_ergo_tree': destination,
      'created_at': 1,
      'updated_at': 1,
      'events': <Map<String, dynamic>>[],
    };

/// Canned explorer: a list page per tree, a box lookup, a spending tx.
class FakeExplorer {
  final requests = <String>[];
  Map<String, Object> boxes = {};
  Map<String, Object> txs = {};
  Map<String, List<Object>> lists = {};
  int height = 1500000;
  bool networkState = true;

  /// Node-side lists, keyed by tree; null means "no extra index".
  Map<String, List<Object>>? nodeLists;

  /// Answer node list queries as `{"items": [...], "total": n}` instead of
  /// a bare array, as some node versions do.
  bool nodeEnvelope = false;
  Map<String, Object> nodeBoxes = {};
  Map<String, Object> nodeTxs = {};

  Future<String> post(Uri uri, String body) async {
    requests.add('POST ${uri.toString()}');
    final lists = nodeLists;
    if (lists == null || !uri.path.contains('/blockchain/box/unspent/byErgoTree')) {
      throw StateError('node returned HTTP 404');
    }
    final tree = jsonDecode(body) as String;
    final all = lists[tree] ?? const [];
    final offset = int.parse(uri.queryParameters['offset'] ?? '0');
    final limit = int.parse(uri.queryParameters['limit'] ?? '500');
    final page = all.skip(offset).take(limit).toList();
    return jsonEncode(nodeEnvelope ? {'items': page, 'total': all.length} : page);
  }

  Future<String> get(Uri uri) async {
    requests.add(uri.toString());
    final p = uri.path;
    if (p.endsWith('/info')) return jsonEncode({'fullHeight': 4242});
    final nb = RegExp(r'/blockchain/box/byId/([0-9a-zA-Z]+)$').firstMatch(p)?.group(1);
    if (nb != null) return jsonEncode(nodeBoxes[nb] ?? (throw StateError('404')));
    final nt = RegExp(r'/blockchain/transaction/byId/([0-9a-zA-Z]+)$').firstMatch(p)?.group(1);
    if (nt != null) return jsonEncode(nodeTxs[nt] ?? (throw StateError('404')));
    if (p.endsWith('/networkState')) {
      if (!networkState) throw StateError('explorer returned HTTP 404 for $p');
      return jsonEncode({'height': height});
    }
    if (p.endsWith('/blocks')) {
      return jsonEncode({
        'items': [
          {'height': 777},
        ],
      });
    }
    final tree = RegExp(r'byErgoTree/([0-9a-f]+)').firstMatch(p)?.group(1);
    if (tree != null) {
      final all = lists[tree] ?? const [];
      final offset = int.parse(uri.queryParameters['offset'] ?? '0');
      final limit = int.parse(uri.queryParameters['limit'] ?? '500');
      final page = all.skip(offset).take(limit).toList();
      return jsonEncode({'items': page, 'total': all.length});
    }
    final box = RegExp(r'/boxes/([0-9a-zA-Z]+)$').firstMatch(p)?.group(1);
    if (box != null) {
      final b = boxes[box];
      if (b == null) throw StateError('404');
      return jsonEncode(b);
    }
    final tx = RegExp(r'/transactions/([0-9a-zA-Z]+)$').firstMatch(p)?.group(1);
    if (tx != null) return jsonEncode(txs[tx] ?? (throw StateError('404')));
    throw StateError('unexpected $uri');
  }
}

Future<MixService> loaded(FakeGateway gw, FakeExplorer ex, List<Map<String, dynamic>> states) async {
  SharedPreferences.setMockInitialValues({
    'argus_mixing_enabled': true,
    'argus_mixes_v1_w1': jsonEncode([
      for (final s in states) {'state': s},
    ]),
  });
  final svc = MixService(gateway: gw, get: ex.get, post: ex.post, clock: () => DateTime.fromMillisecondsSinceEpoch(5000));
  await svc.load();
  return svc;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('records load per wallet and pockets split by whether rounds are done', () async {
    final gw = FakeGateway();
    final svc = await loaded(gw, FakeExplorer(), [
      state(mixId: 0, done: 1, target: 3),
      state(mixId: 1, kind: 'full_owned', boxId: 'b2', done: 3, target: 3),
      state(mixId: 2, kind: 'withdrawn'),
      state(mixId: 3, kind: 'pending', boxId: null),
    ]);
    expect(svc.records.length, 4);
    expect(svc.inMixNano, 1000000000, reason: 'only the unfinished mix is still moving');
    expect(svc.mixedNano, 1000000000, reason: 'the finished-but-not-withdrawn one is mixed');
    expect(svc.active.map((r) => r.mixId), [0, 1]);
    expect(svc.ownHalfBoxIds, isEmpty);

    gw.wallet = 'w2';
    await svc.load();
    expect(svc.records, isEmpty, reason: 'another wallet has its own list');
  });

  test('snapshot pages every list and resolves own boxes through their spending tx', () async {
    final gw = FakeGateway();
    final ex = FakeExplorer()
      ..lists['aa'] = List.generate(501, (i) => {'boxId': 'h$i'})
      ..lists['cc'] = [{'boxId': 'fee'}]
      ..lists['dd'] = [{'boxId': 'tok'}]
      ..boxes['mine'] = {'boxId': 'mine', 'spentTransactionId': 'spender'}
      ..boxes['still'] = {'boxId': 'still', 'spentTransactionId': null}
      ..txs['spender'] = {
        'outputs': [
          {'boxId': 'out0'},
          {'boxId': 'out1'},
        ],
      };
    final svc = await loaded(gw, ex, []);
    final snap = await svc.snapshot(ownBoxIds: ['mine', 'still', 'gone']);
    final json = jsonDecode(snap.json) as Map;
    expect((json['half_boxes'] as List).length, 501 + 1, reason: 'two pages, plus our unspent box');
    expect((json['full_boxes'] as List).map((b) => b['boxId']), ['out0', 'out1', 'still']);
    expect((json['fee_boxes'] as List).length, 1);
    expect((json['token_boxes'] as List).length, 1);
    expect(json['height'], 1500000);
    expect(snap.truncated, isFalse);
    expect(ex.requests.where((r) => r.contains('byErgoTree/aa')).length, 2);
    expect(ex.requests.where((r) => r.contains('byErgoTree/bb')), isEmpty,
        reason: 'a routine tick never lists every full box');
  });

  test('tick observes, plans and advances each active mix, announcing rounds', () async {
    final gw = FakeGateway()
      ..script['observe'] = [state(done: 2, target: 3)]
      ..script['plan'] = [
        {'action': 'remix_as_bob', 'half_box_id': 'x'},
      ]
      ..script['advance'] = [
        {
          'state': state(done: 3, target: 3, boxId: 'box2', round: 1),
          'action': 'remix_bob',
          'tx_id': 'tx9',
        },
      ];
    final ex = FakeExplorer()..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null};
    final svc = await loaded(gw, ex, [state(done: 1, target: 3)]);

    await svc.tick();
    expect(gw.calls, ['observe', 'plan', 'advance']);
    final r = svc.records.single;
    expect(r.roundsDone, 3);
    expect(r.boxId, 'box2');
    expect(r.lastError, isNull);
    expect(gw.notifications, [
      'Mix round 2 of 3 done | 1 ERG is still mixing',
      'Mix round 3 of 3 done | 1 ERG is still mixing',
    ]);
    expect(svc.mixedNano, 1000000000);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('argus_mixes_v1_w1')!) as List;
    expect((saved.single as Map)['state']['rounds_done'], 3, reason: 'persisted');
  });

  test('tick leaves a mix alone when the plan is to wait or the engine says wait', () async {
    final gw = FakeGateway()
      ..script['observe'] = ['same']
      ..script['plan'] = [
        {'action': 'wait', 'reason': 'counterpart_needed'},
      ];
    final svc = await loaded(gw, FakeExplorer(), [state(kind: 'half_posted', done: 0)]);
    await svc.tick();
    expect(gw.calls, ['observe', 'plan']);
    expect(svc.records.single.phaseKind, 'half_posted');
    expect(svc.ownHalfBoxIds, ['box1']);
    expect(gw.notifications, isEmpty);
  });

  test('a failing move lands on the mix and does not stop the others', () async {
    final gw = FakeGateway()
      ..script['observe'] = ['same']
      ..script['plan'] = [
        {'action': 'withdraw', 'reason': 'rounds_done'},
      ]
      ..script['advance'] = [
        Exception('node refused'),
        {'state': state(mixId: 1, kind: 'withdrawn', done: 3), 'action': 'withdraw', 'tx_id': 't'},
      ];
    final svc = await loaded(gw, FakeExplorer(), [
      state(mixId: 0, done: 3, target: 3),
      state(mixId: 1, boxId: 'b2', done: 3, target: 3),
    ]);
    await svc.tick();
    final first = svc.records.firstWhere((r) => r.mixId == 0);
    final second = svc.records.firstWhere((r) => r.mixId == 1);
    expect(first.lastError, contains('node refused'));
    expect(first.phaseKind, 'full_owned', reason: 'state untouched by a failed move');
    expect(second.finished, isTrue);
    expect(gw.notifications.last, startsWith('Mix finished'));
    expect(svc.lastTickError, isNull);
  });

  test('a recovered mix with no destination is not withdrawn on its own', () async {
    final gw = FakeGateway()
      ..script['observe'] = ['same']
      ..script['plan'] = [
        {'action': 'withdraw', 'reason': 'rounds_done'},
      ];
    final svc = await loaded(gw, FakeExplorer(), [state(done: 3, target: 3, destination: '')]);
    await svc.tick();
    expect(gw.calls, ['observe', 'plan'], reason: 'no advance without a destination');
    expect(svc.records.single.needsDestination, isTrue);
  });

  test('tick does nothing while disabled, locked, on another wallet, or already running', () async {
    final gw = FakeGateway();
    final svc = await loaded(gw, FakeExplorer(), [state()]);
    await svc.setEnabled(false);
    await svc.tick();
    await svc.setEnabled(true);
    gw.unlocked = false;
    await svc.tick();
    gw.unlocked = true;
    gw.wallet = 'other';
    await svc.tick();
    expect(gw.calls, isEmpty);
  });

  test('an unreachable explorer is reported on the service, not on a mix', () async {
    final gw = FakeGateway();
    final svc = MixService(gateway: gw, get: (_) async => throw StateError('offline'));
    SharedPreferences.setMockInitialValues({
      'argus_mixing_enabled': true,
      'argus_mixes_v1_w1': jsonEncode([
        {'state': state()},
      ]),
    });
    await svc.load();
    await svc.tick();
    expect(svc.lastTickError, contains('offline'));
    expect(svc.records.single.lastError, isNull);
    expect(gw.calls, isEmpty);
  });

  test('createMix, commitEntry and remove keep the list honest', () async {
    final gw = FakeGateway();
    final svc = await loaded(gw, FakeExplorer(), [state(mixId: 4)]);
    final created = await svc.createMix(
      denomination: 1000000000,
      level: 20,
      rounds: 3,
      destinationAddress: '9abc',
    );
    expect(created.mixId, 5, reason: 'never reuses an index');
    expect(created.pending, isTrue);
    expect(svc.records.first.mixId, 5);

    final next = state(mixId: 5, kind: 'half_posted', boxId: 'hb', done: 0)
      ..['events'] = [
        {'at': 1, 'action': 'entered_as_alice', 'round': 0, 'tx_id': ''},
      ];
    await svc.commitEntry(created, next, 'tx-entry');
    expect(created.phaseKind, 'half_posted');
    expect((created.state['events'] as List).last['tx_id'], 'tx-entry');
    expect(() => svc.remove(created), throwsStateError, reason: 'money is in the pool');

    final done = svc.records.firstWhere((r) => r.mixId == 4);
    done.state = state(mixId: 4, kind: 'withdrawn');
    await svc.remove(done);
    expect(svc.records.map((r) => r.mixId), [5]);
  });

  test('recover adds only mixes the records do not know', () async {
    final gw = FakeGateway()
      ..script['recover'] = [
        [state(mixId: 0, kind: 'half_posted', destination: ''), state(mixId: 7, destination: '')],
      ];
    final ex = FakeExplorer()..lists['bb'] = [{'boxId': 'f1'}];
    final svc = await loaded(gw, ex, [state(mixId: 0)]);
    expect(await svc.recover(), 1);
    expect(svc.records.map((r) => r.mixId), [7, 0]);
    expect(svc.records.first.needsDestination, isTrue);
    expect(ex.requests.where((r) => r.contains('byErgoTree/bb')).length, 1,
        reason: 'recovery needs every full box');
  });

  test('leave records the result and refuses without a destination', () async {
    final gw = FakeGateway()
      ..script['leave'] = [
        {'state': state(kind: 'reclaimed'), 'action': 'reclaim', 'tx_id': 'txr'},
      ];
    final ex = FakeExplorer()..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null};
    final svc = await loaded(gw, ex, [state(kind: 'half_posted', done: 0, destination: '')]);
    expect(() => svc.leave(svc.records.single), throwsStateError);
    final tx = await svc.leave(svc.records.single, destinationAddress: '9abc');
    expect(tx, 'txr');
    expect(svc.records.single.finished, isTrue);
    expect(svc.inMixNano, 0);
  });

  test('unreadable stored records are copied aside and never overwritten', () async {
    final gw = FakeGateway();
    SharedPreferences.setMockInitialValues({
      'argus_mixing_enabled': true,
      'argus_mixes_v1_w1': '{not json',
    });
    final svc = MixService(gateway: gw, get: FakeExplorer().get);
    await svc.load();
    expect(svc.recordsUnreadable, isTrue);
    expect(svc.records, isEmpty);
    await svc.createMix(denomination: 1, level: 20, rounds: 1, destinationAddress: '9a');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('argus_mixes_v1_w1_unreadable'), '{not json');
  });

  test('a removed mix never gives its index, and so its secrets, to a new one', () async {
    final gw = FakeGateway();
    final svc = await loaded(gw, FakeExplorer(), [state(mixId: 6, kind: 'withdrawn')]);
    await svc.remove(svc.records.single);
    expect(svc.records, isEmpty);
    final created = await svc.createMix(
      denomination: 1000000000,
      level: 20,
      rounds: 1,
      destinationAddress: '9a',
    );
    expect(created.mixId, 7);

    // The counter is on disk, so a reload cannot rewind it either.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('argus_mixes_v1_w1_next_id'), 8);
    await svc.remove(created..state = state(mixId: 7, kind: 'reclaimed'));
    final again = MixService(gateway: gw, get: FakeExplorer().get);
    await again.load();
    final next = await again.createMix(
      denomination: 1000000000,
      level: 20,
      rounds: 1,
      destinationAddress: '9a',
    );
    expect(next.mixId, 8);
  });

  test('recovery reserves the indices it finds', () async {
    final gw = FakeGateway()
      ..script['recover'] = [
        [state(mixId: 12, destination: '')],
      ];
    final svc = await loaded(gw, FakeExplorer(), []);
    await svc.recover();
    final created = await svc.createMix(
      denomination: 1000000000,
      level: 20,
      rounds: 1,
      destinationAddress: '9a',
    );
    expect(created.mixId, 13);
  });

  test('an in-pool record without a box id is skipped, not fatal', () async {
    final gw = FakeGateway()
      ..script['observe'] = ['same']
      ..script['plan'] = [
        {'action': 'wait', 'reason': 'counterpart_needed'},
      ];
    final broken = state(mixId: 1, kind: 'half_posted', boxId: null, done: 0);
    (broken['phase'] as Map).remove('box_id');
    final ex = FakeExplorer()..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null};
    final svc = await loaded(gw, ex, [state(mixId: 0), broken]);
    await svc.tick();
    expect(svc.lastTickError, isNull);
    expect(gw.calls.where((c) => c == 'observe').length, 2, reason: 'both mixes were looked at');
  });

  test('leave waits for a running tick instead of racing it for the box', () async {
    final hold = Completer<Object>();
    final gw = FakeGateway()
      ..script['observe'] = [hold.future]
      ..script['plan'] = [
        {'action': 'wait', 'reason': 'counterpart_needed'},
      ]
      ..script['leave'] = [
        {'state': state(kind: 'reclaimed'), 'action': 'reclaim', 'tx_id': 'txr'},
      ];
    final ex = FakeExplorer()..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null};
    final svc = await loaded(gw, ex, [state(kind: 'half_posted', done: 0)]);

    final ticking = svc.tick();
    await Future<void>.delayed(Duration.zero);
    expect(svc.busy, isTrue);
    final leaving = svc.leave(svc.records.single);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(gw.calls, ['observe'], reason: 'leave has not started while the tick runs');

    hold.complete('same');
    await ticking;
    expect(await leaving, 'txr');
    expect(gw.calls, ['observe', 'plan', 'leave']);
    expect(svc.busy, isFalse);
  });

  test('height comes from the node when known, else the explorer, else the newest block', () async {
    final gw = FakeGateway()..nodeHeight = 1234;
    final ex = FakeExplorer();
    final svc = await loaded(gw, ex, []);
    expect((await svc.snapshot()).height, 1234);
    expect(ex.requests.where((r) => r.contains('networkState')), isEmpty);

    gw.nodeHeight = null;
    expect((await svc.snapshot()).height, 1500000, reason: 'explorer networkState');

    // An explorer without networkState (HTTP 404) still yields a height.
    final noState = FakeExplorer()..networkState = false;
    final svc2 = await loaded(gw, noState, []);
    expect((await svc2.snapshot()).height, 777);
    expect(noState.requests.last, contains('/api/v1/blocks?limit=1'));
  });

  test('the snapshot asks the node first and falls back to the explorer per call', () async {
    final gw = FakeGateway()..node = 'http://node/';
    final ex = FakeExplorer()
      ..nodeLists = {
        'aa': [{'boxId': 'nh1'}],
        'cc': [{'boxId': 'nfee'}],
        'dd': [{'boxId': 'ntok'}],
      }
      ..nodeBoxes['mine'] = {'boxId': 'mine', 'spentTransactionId': 'sp'}
      ..nodeTxs['sp'] = {
        'outputs': [
          {'boxId': 'nout'},
        ],
      }
      // The explorer has different answers, which must not be used.
      ..lists['aa'] = [{'boxId': 'eh1'}]
      ..boxes['mine'] = {'boxId': 'mine', 'spentTransactionId': null};
    final svc = await loaded(gw, ex, []);
    final snap = await svc.snapshot(ownBoxIds: ['mine']);
    final json = jsonDecode(snap.json) as Map;
    expect((json['half_boxes'] as List).map((b) => b['boxId']), ['nh1']);
    expect((json['full_boxes'] as List).map((b) => b['boxId']), ['nout']);
    expect((json['fee_boxes'] as List).map((b) => b['boxId']), ['nfee']);
    expect(json['height'], 4242, reason: 'node /info');
    expect(ex.requests.where((r) => r.contains('api/v1')), isEmpty, reason: 'explorer never asked');

    // A node that wraps its answer in an envelope is read the same way.
    ex.nodeEnvelope = true;
    ex.requests.clear();
    final wrapped = await svc.snapshot();
    expect((jsonDecode(wrapped.json) as Map)['half_boxes'].map((b) => b['boxId']), ['nh1']);
    expect(ex.requests.where((r) => r.contains('api/v1')), isEmpty);

    // A node without the extra index: every list comes from the explorer.
    ex.nodeEnvelope = false;
    ex.nodeLists = null;
    ex.requests.clear();
    final snap2 = await svc.snapshot();
    expect((jsonDecode(snap2.json) as Map)['half_boxes'].map((b) => b['boxId']), ['eh1']);
    expect(ex.requests.where((r) => r.startsWith('POST')).length, 3, reason: 'tried the node once per list');
  });

  test('background mixing exports a key when a mix enters, drops it when it ends', () async {
    final gw = FakeGateway();
    final wanted = <bool>[];
    SharedPreferences.setMockInitialValues({'argus_mixing_enabled': true});
    final svc = MixService(gateway: gw, get: FakeExplorer().get, post: FakeExplorer().post, schedule: wanted.add);
    await svc.load();
    expect(svc.backgroundEnabled, isFalse, reason: 'opt in');

    final created = await svc.createMix(denomination: 1000000000, level: 20, rounds: 1, destinationAddress: '9a');
    await svc.commitEntry(created, state(mixId: 0, kind: 'half_posted', boxId: 'hb', done: 0), 'tx');
    expect(gw.keys, isEmpty, reason: 'no key while background mixing is off');

    await svc.setBackgroundEnabled(true);
    expect(gw.keys, {'w1:0': 'key-0'}, reason: 'switching on exports every mix in the pool');
    expect(wanted.last, isFalse, reason: 'in front, the foreground tick drives; no job yet');
    await svc.setForeground(false);
    expect(wanted.last, isTrue, reason: 'in the back, a job is wanted');
    await svc.setForeground(true);

    created.state = state(mixId: 0, kind: 'reclaimed');
    await svc.remove(created);
    expect(gw.keys, isEmpty, reason: 'a removed mix loses its key');
    expect(wanted.last, isFalse, reason: 'nothing left to move');

    await svc.setBackgroundEnabled(false);
    expect(svc.backgroundEnabled, isFalse);
  });

  test('turning mixing off also turns background mixing off and deletes every key', () async {
    final gw = FakeGateway()..keys['w1:3'] = 'k'..keys['other:9'] = 'k';
    SharedPreferences.setMockInitialValues({'argus_mixing_enabled': true, 'argus_mixing_background': true});
    final svc = MixService(gateway: gw, get: FakeExplorer().get, post: FakeExplorer().post);
    await svc.load();
    expect(svc.backgroundEnabled, isTrue);
    await svc.setEnabled(false);
    expect(svc.backgroundEnabled, isFalse);
    expect(gw.keys, isEmpty, reason: 'keys of every wallet are gone');
  });

  test('the headless tick drives every wallet with keys, without an unlocked wallet', () async {
    final gw = FakeGateway()
      ..unlocked = false
      ..wallet = null
      ..keys['w1:0'] = 'key-0'
      ..keys['w2:5'] = 'key-5'
      ..script['observe'] = ['same']
      ..script['plan'] = [
        {'action': 'withdraw', 'reason': 'rounds_done'},
      ]
      ..script['advance'] = [
        {'state': state(mixId: 0, kind: 'withdrawn', done: 3), 'action': 'withdraw', 'tx_id': 'tw'},
        {'state': state(mixId: 5, kind: 'full_owned', boxId: 'b5', done: 2, target: 3), 'action': 'remix_bob', 'tx_id': 'tr'},
      ];
    final ex = FakeExplorer()
      ..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null}
      ..boxes['b5'] = {'boxId': 'b5', 'spentTransactionId': null};
    SharedPreferences.setMockInitialValues({
      'argus_mixing_enabled': true,
      'argus_mixing_background': true,
      'argus_mixes_v1_w1': jsonEncode([
        {'state': state(mixId: 0, done: 3, target: 3)},
      ]),
      'argus_mixes_v1_w2': jsonEncode([
        {'state': state(mixId: 5, boxId: 'b5', done: 1, target: 3)},
        {'state': state(mixId: 6, boxId: 'b6', done: 1, target: 3)},
      ]),
    });
    final svc = MixService(gateway: gw, get: ex.get, post: ex.post);
    await svc.tickHeadless();

    expect(gw.calls.where((c) => c.startsWith('withKey')), ['withKey:key-0', 'withKey:key-5']);
    expect(gw.calls.where((c) => c.startsWith('advanceWithKey')), ['advanceWithKey:key-0', 'advanceWithKey:key-5']);
    expect(gw.calls.where((c) => c == 'observe' || c == 'advance'), isEmpty, reason: 'never the wallet path');
    expect(gw.keys.keys, ['w2:5'], reason: 'the finished mix lost its key');
    expect(gw.notifications.first, startsWith('Mix finished'));

    final prefs = await SharedPreferences.getInstance();
    final w1 = jsonDecode(prefs.getString('argus_mixes_v1_w1')!) as List;
    expect((w1.single as Map)['state']['phase']['kind'], 'withdrawn');
    final w2 = jsonDecode(prefs.getString('argus_mixes_v1_w2')!) as List;
    expect((w2[0] as Map)['state']['rounds_done'], 2);
    expect((w2[1] as Map)['state']['rounds_done'], 1, reason: 'no key, untouched');
  });

  test('the headless tick does nothing unless both switches are on', () async {
    final gw = FakeGateway()..keys['w1:0'] = 'key-0';
    SharedPreferences.setMockInitialValues({'argus_mixing_enabled': true, 'argus_mixing_background': false});
    final svc = MixService(gateway: gw, get: FakeExplorer().get, post: FakeExplorer().post);
    await svc.tickHeadless();
    expect(gw.calls, isEmpty);
  });

  test('background mixing cannot be switched on while the wallet is locked', () async {
    final gw = FakeGateway()..unlocked = false;
    SharedPreferences.setMockInitialValues({'argus_mixing_enabled': true});
    final svc = MixService(gateway: gw, get: FakeExplorer().get, post: FakeExplorer().post);
    await svc.load();
    await expectLater(svc.setBackgroundEnabled(true), throwsStateError);
    expect(svc.backgroundEnabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('argus_mixing_background'), isNull, reason: 'nothing persisted');
  });

  test('loading with background mixing on exports keys that are missing', () async {
    final gw = FakeGateway();
    SharedPreferences.setMockInitialValues({
      'argus_mixing_enabled': true,
      'argus_mixing_background': true,
      'argus_mixes_v1_w1': jsonEncode([
        {'state': state(mixId: 2)},
        {'state': state(mixId: 3, kind: 'withdrawn')},
      ]),
    });
    final svc = MixService(gateway: gw, get: FakeExplorer().get, post: FakeExplorer().post);
    await svc.load();
    expect(gw.keys.keys, ['w1:2'], reason: 'the live mix, not the finished one');
  });

  test('the foreground tick stands down while the app is in the back and the job is on', () async {
    final gw = FakeGateway()..script['observe'] = ['same']..script['plan'] = [{'action': 'wait', 'reason': 'counterpart_needed'}];
    final wanted = <bool>[];
    SharedPreferences.setMockInitialValues({
      'argus_mixing_enabled': true,
      'argus_mixing_background': true,
      'argus_mixes_v1_w1': jsonEncode([{'state': state()}]),
    });
    final ex = FakeExplorer()..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null};
    final svc = MixService(gateway: gw, get: ex.get, post: ex.post, schedule: wanted.add);
    await svc.load();
    expect(wanted.last, isFalse, reason: 'in front: no job');

    await svc.setForeground(false);
    expect(wanted.last, isTrue, reason: 'in the back: the job takes over');
    await svc.tick();
    expect(gw.calls.where((c) => c == 'observe'), isEmpty, reason: 'the UI does not tick meanwhile');

    // The job advanced the mix on disk while the app was in the back.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('argus_mixes_v1_w1', jsonEncode([{'state': state(done: 2, target: 3)}]));
    await svc.setForeground(true);
    expect(svc.records.single.roundsDone, 2, reason: 'coming to the front re-reads the records');
    expect(wanted.last, isFalse, reason: 'in front again: job cancelled');
    await svc.tick();
    expect(gw.calls.where((c) => c == 'observe').length, 1);
  });

  test('a tick yields to an unexpired lease held by the other driver', () async {
    final gw = FakeGateway()..script['observe'] = ['same']..script['plan'] = [{'action': 'wait', 'reason': 'counterpart_needed'}];
    final ex = FakeExplorer()..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null};
    SharedPreferences.setMockInitialValues({
      'argus_mixing_enabled': true,
      'argus_mixes_v1_w1': jsonEncode([{'state': state()}]),
      'argus_mix_lease': 'bg:${5000 + 60000}',
    });
    final svc = MixService(gateway: gw, get: ex.get, post: ex.post, clock: () => DateTime.fromMillisecondsSinceEpoch(5000));
    await svc.load();
    await svc.tick();
    expect(gw.calls, isEmpty, reason: 'the job holds the lease');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('argus_mix_lease', 'bg:${5000 - 1}');
    await svc.tick();
    expect(gw.calls.where((c) => c == 'observe').length, 1, reason: 'an expired lease is taken over');
    expect(prefs.getString('argus_mix_lease'), isNull, reason: 'released after the pass');
  });

  test('the headless tick merges by mix id so a concurrent write is not lost', () async {
    final gw = FakeGateway()
      ..unlocked = false
      ..wallet = null
      ..keys['w1:0'] = 'key-0'
      ..script['observe'] = ['same']
      ..script['plan'] = [{'action': 'withdraw', 'reason': 'rounds_done'}]
      ..script['advance'] = [
        {'state': state(mixId: 0, kind: 'withdrawn', done: 3), 'action': 'withdraw', 'tx_id': 'tw'},
      ];
    final ex = FakeExplorer()..boxes['box1'] = {'boxId': 'box1', 'spentTransactionId': null};
    SharedPreferences.setMockInitialValues({
      'argus_mixing_enabled': true,
      'argus_mixing_background': true,
      'argus_mixes_v1_w1': jsonEncode([
        {'state': state(mixId: 0, done: 3, target: 3)},
        {'state': state(mixId: 1, boxId: 'b1', done: 1, target: 3)},
      ]),
    });
    // While the job works on mix 0, something else records progress on mix 1.
    gw.beforeAdvanceWithKey = () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('argus_mixes_v1_w1', jsonEncode([
        {'state': state(mixId: 0, done: 3, target: 3)},
        {'state': state(mixId: 1, boxId: 'b1', done: 2, target: 3)},
      ]));
    };
    final svc = MixService(gateway: gw, get: ex.get, post: ex.post);
    await svc.tickHeadless();
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('argus_mixes_v1_w1')!) as List;
    expect((saved[0] as Map)['state']['phase']['kind'], 'withdrawn');
    expect((saved[1] as Map)['state']['rounds_done'], 2, reason: 'the concurrent change survived');
    expect(prefs.getString('argus_mix_lease'), isNull);
  });
}
