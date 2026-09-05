import 'dart:convert';

import 'package:argus_wallet/services/mix_service.dart';
import 'package:argus_wallet/services/mix_start_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only what the flow touches on the service: createMix, prepareEntry,
/// commitEntry, recover.
class ScriptedGateway implements MixGateway {
  final calls = <String>[];
  List<Map<String, dynamic>> recovered = const [];

  @override
  bool get isUnlocked => true;
  @override
  String? get walletId => 'w';
  @override
  String? get nodeUrl => null;
  @override
  String get explorerBase => 'https://x/';
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
  String contractTrees() => '{"half":"aa","full":"bb","fee":"cc","token":"dd"}';

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
    return jsonEncode({
      'mix_id': mixId,
      'ring': {'value': denomination, 'token_id': null, 'token_amount': null},
      'level': level,
      'rounds_target': rounds,
      'rounds_done': 0,
      'round': 0,
      'phase': {'kind': 'pending'},
      'destination_ergo_tree': destinationAddress,
      'created_at': nowUnix,
      'updated_at': nowUnix,
      'events': [],
    });
  }

  @override
  Future<String> prepareEntry({
    required String stateJson,
    required String chainJson,
    required String fundingAddress,
    required String fundingBoxId,
    required List<String> ownHalfBoxIds,
    String? nodeUrl,
    required int nowUnix,
  }) async {
    calls.add('prepareEntry:$fundingBoxId');
    final state = jsonDecode(stateJson) as Map<String, dynamic>;
    state['phase'] = {'kind': 'half_posted', 'box_id': 'half1'};
    state['events'] = [
      {'at': nowUnix, 'action': 'entered_as_alice', 'round': 0, 'tx_id': ''},
    ];
    return jsonEncode({
      'preparation_id': 42,
      'action': 'alice_entry',
      'summary': {'denomination': 1000000000, 'miner_fee_nano': 1100000, 'operator_fee_nano': 5000000},
      'next_state': state,
    });
  }

  @override
  Future<String> rings(String c) async => '{}';
  @override
  Future<String> fundingRequirement(String c, int d, int l, int? f) async => '{}';
  @override
  Future<String> plan(String s, String c, List<String> o) async => '{"action":"wait"}';
  @override
  Future<String> observe(String s, String c, int n) async => s;
  @override
  Future<String> advance(String s, String c, List<String> o, String? n, int t) async => '{}';
  @override
  Future<String> leave(String s, String c, String? d, String? n, int t) async => '{}';
  @override
  Future<String> recover(String c, int n) async => jsonEncode(recovered);
  @override
  Future<void> notify({required String title, required String body}) async {}
  @override
  Future<String> observeWithKey(String s, String c, String k, int n) async => s;
  @override
  Future<String> advanceWithKey(String s, String c, List<String> o, String? n, int t, String k) async => '{}';
}

Future<String> fakeExplorer(Uri uri) async {
  if (uri.path.endsWith('/networkState')) return '{"height":1}';
  return '{"items":[],"total":0}';
}

const plan = MixStartPlan(
  denomination: 1000000000,
  level: 20,
  rounds: 3,
  destinationAddress: '9dest',
  neededNano: 1006600000,
  operatorFeeNano: 5000000,
  minerFeeNano: 1100000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptedGateway gw;
  late MixService service;
  late List<String> log;
  late List<Duration> delays;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'argus_mixing_enabled': true});
    gw = ScriptedGateway();
    service = MixService(gateway: gw, get: fakeExplorer);
    await service.load();
    log = [];
    delays = [];
  });

  /// `boxes` is what each successive lookup finds; `[]` means never.
  /// `failIds` are preparation ids whose broadcast throws.
  MixStartFlow flow({
    required List<bool> answers,
    required List<String?> boxes,
    Duration maxWait = const Duration(seconds: 30),
    Set<int> failIds = const {},
  }) {
    final replies = List<bool>.from(answers);
    final found = List<String?>.from(boxes);
    return MixStartFlow(
      service: service,
      onStatus: log.add,
      prepareFunding: (needed) async {
        log.add('prepareFunding:$needed');
        return const MixPrepared(preparationId: 7, amountNano: 1006600000, minerFeeNano: 1100000);
      },
      confirm: (step, prepared, record) async {
        log.add('confirm:${step.name}:${prepared.preparationId}');
        return replies.removeAt(0);
      },
      broadcast: (id) async {
        log.add('broadcast:$id:records=${service.records.length}');
        if (failIds.contains(id)) throw StateError('node down');
        return MixBroadcast(txId: 'tx$id', outputBoxIds: id == 7 ? ['fund1', 'change1'] : []);
      },
      findFundingBox: (needed, candidates) async {
        log.add('find:$needed:${candidates.join(",")}');
        return found.isEmpty ? null : found.removeAt(0);
      },
      pollInterval: const Duration(seconds: 10),
      maxWait: maxWait,
      delay: (d) async => delays.add(d),
    );
  }

  Iterable<String> ops() => log.where(RegExp(r'^(prepareFunding|confirm|broadcast|find)').hasMatch);

  test('happy path: confirm, record, fund, wait for that box, enter, stage, commit', () async {
    final record = await flow(answers: [true, true], boxes: [null, 'fund1'])
        .start(plan, fundingAddress: '9me');
    expect(record, isNotNull);
    expect(record!.phaseKind, 'half_posted');
    expect((record.state['events'] as List).last['tx_id'], 'tx42');
    expect(record.fundingTxId, 'tx7');
    expect(record.fundingBoxIds, ['fund1', 'change1']);
    expect(record.entryTxId, 'tx42');
    expect(record.entryAttempt, isNull, reason: 'cleared once committed');
    expect(ops(), [
      'prepareFunding:1006600000',
      'confirm:funding:7',
      'broadcast:7:records=1',
      'find:1006600000:fund1,change1',
      'find:1006600000:fund1,change1',
      'confirm:entry:42',
      'broadcast:42:records=1',
    ]);
    expect(gw.calls, ['newState', 'prepareEntry:fund1']);
    expect(service.records.single.inPool, isTrue);
  });

  test('the record is on disk before the funding broadcast', () async {
    await flow(answers: [true, true], boxes: ['fund1']).start(plan, fundingAddress: '9me');
    expect(ops().elementAt(2), 'broadcast:7:records=1');
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('argus_mixes_v1_w')!) as List;
    expect((saved.single as Map)['funding_tx_id'], 'tx7');
  });

  test('declining the funding sends nothing and records nothing', () async {
    final record = await flow(answers: [false], boxes: ['fund1']).start(plan, fundingAddress: '9me');
    expect(record, isNull);
    expect(ops().where((l) => l.startsWith('broadcast')), isEmpty);
    expect(service.records, isEmpty);
  });

  test('declining the entry leaves a pending mix that can be continued later', () async {
    final f = flow(answers: [true, false, true], boxes: ['fund1', 'fund1']);
    final record = await f.start(plan, fundingAddress: '9me');
    expect(record!.pending, isTrue, reason: 'funded but not entered');
    expect(record.entryAttempt, isNull, reason: 'nothing staged when the user declined');

    // Continuing uses the remembered funding size and the funding outputs,
    // not the caller's fallback.
    final again = await f.enter(record, fundingAddress: '9me', neededNano: 999);
    expect(again.inPool, isTrue);
    expect(ops().where((l) => l.startsWith('find')).last, 'find:1006600000:fund1,change1');
  });

  test('a staged entry whose funding box is gone is committed, not sent twice', () async {
    // Simulate a crash between stageEntry and commitEntry: the attempt is
    // on the record and the funding box was spent by the entry.
    final f = flow(answers: [true, true], boxes: ['fund1']);
    final record = await f.start(plan, fundingAddress: '9me');
    final staged = Map<String, dynamic>.from(record!.state);
    record.state = {...staged, 'phase': {'kind': 'pending'}};
    await service.stageEntry(record, staged);
    expect(record.pending, isTrue);

    final resumed = flow(answers: [], boxes: []);
    final after = await resumed.enter(record, fundingAddress: '9me', neededNano: plan.neededNano);
    expect(after.phaseKind, 'half_posted');
    expect(after.entryAttempt, isNull);
    expect(ops().where((l) => l.startsWith('broadcast')).length, 2, reason: 'the two original sends only');
  });

  test('a staged entry whose funding box is still there is built again', () async {
    final f = flow(answers: [true, true], boxes: ['fund1']);
    final record = await f.start(plan, fundingAddress: '9me');
    final staged = Map<String, dynamic>.from(record!.state);
    record.state = {...staged, 'phase': {'kind': 'pending'}};
    await service.stageEntry(record, staged);

    final resumed = flow(answers: [true], boxes: ['fund1', 'fund1']);
    final after = await resumed.enter(record, fundingAddress: '9me', neededNano: plan.neededNano);
    expect(after.phaseKind, 'half_posted');
    expect(gw.calls.where((c) => c.startsWith('prepareEntry')).length, 2);
  });

  test('a failed entry broadcast leaves the staged attempt for the next continue', () async {
    final f = flow(answers: [true, true], boxes: ['fund1'], failIds: {42});
    await expectLater(f.start(plan, fundingAddress: '9me'), throwsStateError);
    final record = service.records.single;
    expect(record.pending, isTrue);
    expect(record.fundingTxId, 'tx7');
    expect(record.entryAttempt, isNotNull, reason: 'we cannot know whether the node took it');
  });

  test('a funding box that never confirms keeps the mix pending and caps the last wait', () async {
    final f = flow(answers: [true], boxes: [], maxWait: const Duration(seconds: 25));
    await expectLater(
      f.start(plan, fundingAddress: '9me'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('not confirmed'))),
    );
    expect(delays, [
      const Duration(seconds: 10),
      const Duration(seconds: 10),
      const Duration(seconds: 5),
    ], reason: 'never sleeps past the budget');
    expect(service.records.single.pending, isTrue, reason: 'the money is on our address; nothing lost');
  });

  test('a mix already in the pool cannot be entered twice', () async {
    final f = flow(answers: [true, true], boxes: ['fund1']);
    final record = await f.start(plan, fundingAddress: '9me');
    expect(
      () => f.enter(record!, fundingAddress: '9me', neededNano: plan.neededNano),
      throwsStateError,
    );
  });

  test('recovery reconciles a pending record the chain says has entered', () async {
    final f = flow(answers: [true, false], boxes: ['fund1']);
    final record = await f.start(plan, fundingAddress: '9me');
    expect(record!.pending, isTrue);
    // The chain has a half box for mix 0 at round 0.
    gw.recovered = [
      {
        ...record.state,
        'phase': {'kind': 'half_posted', 'box_id': 'halfX'},
        'destination_ergo_tree': '',
        'rounds_target': 0,
        'rounds_done': 0,
      }
    ];
    expect(await service.recover(), 1);
    expect(record.phaseKind, 'half_posted');
    expect(record.boxId, 'halfX');
    expect(record.destinationErgoTree, '9dest', reason: 'what only we knew is kept');
    expect(record.roundsTarget, 3);
    expect(service.records.length, 1, reason: 'not duplicated');
  });
}
