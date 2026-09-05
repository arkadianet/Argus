import 'dart:convert';

import 'package:argus_wallet/services/mix_service.dart';
import 'package:argus_wallet/services/mix_start_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only what the flow touches on the service: createMix, prepareEntry,
/// commitEntry.
class ScriptedGateway implements MixGateway {
  final calls = <String>[];
  bool entryOk = true;

  @override
  bool get isUnlocked => true;
  @override
  String? get walletId => 'w';
  @override
  String? get nodeUrl => null;
  @override
  String get explorerBase => 'https://x/';
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
  Future<String> recover(String c, int n) async => '[]';
  @override
  Future<void> notify({required String title, required String body}) async {}
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({'argus_mixing_enabled': true});
    gw = ScriptedGateway();
    service = MixService(gateway: gw, get: fakeExplorer);
    await service.load();
    log = [];
  });

  MixStartFlow flow({
    required List<bool> answers,
    required List<String?> boxes,
    Duration maxWait = const Duration(seconds: 30),
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
        log.add('broadcast:$id');
        return 'tx$id';
      },
      findFundingBox: (needed) async {
        log.add('find');
        return found.isEmpty ? null : found.removeAt(0);
      },
      pollInterval: const Duration(seconds: 10),
      maxWait: maxWait,
      delay: (_) async {},
    );
  }

  test('happy path: fund, confirm, wait for the box, enter, confirm, commit', () async {
    final record = await flow(answers: [true, true], boxes: [null, 'fund1'])
        .start(plan, fundingAddress: '9me');
    expect(record, isNotNull);
    expect(record!.phaseKind, 'half_posted');
    expect((record.state['events'] as List).last['tx_id'], 'tx42');
    final ops = RegExp(r'^(prepareFunding|confirm|broadcast|find)');
    expect(
      log.where(ops.hasMatch),
      [
        'prepareFunding:1006600000',
        'confirm:funding:7',
        'broadcast:7',
        'find',
        'find',
        'confirm:entry:42',
        'broadcast:42',
      ],
    );
    expect(gw.calls, ['newState', 'prepareEntry:fund1']);
    expect(service.records.single.inPool, isTrue);
  });

  test('declining the funding sends nothing and records nothing', () async {
    final record = await flow(answers: [false], boxes: ['fund1']).start(plan, fundingAddress: '9me');
    expect(record, isNull);
    expect(log.where((l) => l.startsWith('broadcast')), isEmpty);
    expect(service.records, isEmpty);
  });

  test('declining the entry leaves a pending mix that can be continued later', () async {
    final f = flow(answers: [true, false, true], boxes: ['fund1', 'fund1']);
    final record = await f.start(plan, fundingAddress: '9me');
    expect(record!.pending, isTrue, reason: 'funded but not entered');
    expect(service.records.single.pending, isTrue);

    // The record remembers its funding size: a moved operator price must
    // not make the box unfindable.
    expect(record.fundingNano, plan.neededNano);
    final found = <int>[];
    final f2 = MixStartFlow(
      service: service,
      prepareFunding: (_) async => throw StateError('not needed'),
      confirm: (_, __, ___) async => true,
      broadcast: (id) async => 'tx$id',
      findFundingBox: (needed) async {
        found.add(needed);
        return 'fund1';
      },
      delay: (_) async {},
    );
    final again = await f2.enter(record, fundingAddress: '9me', neededNano: 999);
    expect(found, [plan.neededNano]);
    expect(again.inPool, isTrue);
    expect(log.where((l) => l.startsWith('broadcast')), ['broadcast:7']);
  });

  test('a funding box that never confirms keeps the mix pending and says so', () async {
    final f = flow(answers: [true], boxes: [], maxWait: const Duration(seconds: 25));
    await expectLater(
      f.start(plan, fundingAddress: '9me'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('not confirmed'))),
    );
    expect(log.where((l) => l == 'find').length, 4, reason: 'polled until the wait ran out');
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
}
