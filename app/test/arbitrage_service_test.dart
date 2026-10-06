import 'dart:async';
import 'dart:convert';

import 'package:argus_wallet/bridge/argus_error.dart';
import 'package:argus_wallet/services/arbitrage_service.dart';
import 'package:argus_wallet/services/sigmausd_service.dart';
import 'package:argus_wallet/services/wallet_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tok = '9a06d9e545a41fd51eeffc5e20d818073bf820c635e2a9d922269913e0de369d';

/// An opportunity as the Rust scan serialises it.
Map<String, dynamic> opportunityJson({int net = 25000000, bool trusted = true}) => {
      'legs': [
        {
          'pool_id': 'a' * 64,
          'box_id': 'b' * 64,
          'from_token_id': null,
          'to_token_id': tok,
          'amount_in': 46300000000,
          'amount_out': 4629000000,
          'reserve_in': 1000000000000,
          'reserve_out': 10000000000,
          'fee_num': 997,
          'price_impact_pct': 4.43,
        },
        {
          'pool_id': 'c' * 64,
          'box_id': 'd' * 64,
          'from_token_id': tok,
          'to_token_id': null,
          'amount_in': 4629000000,
          'amount_out': 46329400000,
          'reserve_in': 10000000000,
          'reserve_out': 1200000000000,
          'fee_num': 997,
          'price_impact_pct': 31.6,
        },
      ],
      'input_nano': 46300000000,
      'output_nano': 46329400000,
      'gross_profit_nano': net + 4400000,
      'miner_fees_nano': 2200000,
      'app_fees_nano': 2200000,
      'net_profit_nano': net,
      'profit_pct': 0.054,
      'box_min_in_transit_nano': 1000000,
      'capital_nano': 46306400000,
      'unwind_loss_nano': 280000000,
      'optimal_input_nano': 46300000000,
      'sized_to_balance': false,
      'affordable': true,
      'trusted': trusted,
    };

Map<String, dynamic> scanJson({List<Map<String, dynamic>>? opportunities}) => {
      'opportunities': opportunities ?? [opportunityJson()],
      'cycles_checked': 46,
      'pools_in_graph': 88,
      'skipped_busy': 1,
      'skipped_untrusted': 2,
      'height': 1888712,
      'pool_count': 548,
      'truncated': false,
      'mempool_checked': true,
      'costs': {'miner_fee_nano': 1100000, 'app_fee_nano': 1100000, 'box_min_nano': 1000000},
    };

class FakeApi extends ArbitrageApi {
  String? lastScanOptions;
  String? lastPrepare;
  String executeAnswer = jsonEncode({
    'status': 'submitted',
    'tx_ids': ['t1', 't2'],
    'wallet_deltas': [-46302200000, 46327200000],
  });
  final discarded = <BigInt>[];

  @override
  Future<String> scan({String? nodeUrl, required String optionsJson}) async {
    lastScanOptions = optionsJson;
    return jsonEncode(scanJson());
  }

  @override
  Future<String> prepare({required BigInt handleId, required String requestJson, String? nodeUrl}) async {
    lastPrepare = requestJson;
    return jsonEncode({
      ...opportunityJson(),
      'chain_id': 42,
      'tx_ids': ['t1', 't2'],
      'expires_in_secs': 300,
      'wallet_delta_nano': 25000000,
    });
  }

  @override
  void discard(BigInt chainId) => discarded.add(chainId);

  @override
  Future<String> execute({required BigInt handleId, required BigInt chainId}) async => executeAnswer;

  @override
  Future<String> status(BigInt chainId) async => jsonEncode({
        'state': 'stranded',
        'failed_leg': 1,
        'legs': [
          {'tx_id': 't1', 'status': 'pending'},
          {'tx_id': null, 'status': 'not_submitted'},
        ],
        'holding': {'token_id': tok, 'amount': 4629000000, 'box_id': 'e' * 64, 'after_leg': 1},
      });

  @override
  Future<String> prepareUnwind({required BigInt handleId, required BigInt chainId}) async => jsonEncode({
        'preparation_id': 7,
        'pool_id': 'a' * 64,
        'token_id': tok,
        'input_amount': 4629000000,
        'output_amount': 46010000000,
        'miner_fee': 1100000,
        'app_fee': 1100000,
        'price_impact_pct': 4.4,
      });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a scan result parses, costs and skips included', () {
    final r = ArbScanResult.fromJson(scanJson(), DateTime(2026));
    final o = r.opportunities.single;
    expect(o.legs, hasLength(2));
    expect(o.legs.first.fromTokenId, isNull);
    expect(o.legs.first.toTokenId, tok);
    expect(o.netProfitNano, 25000000);
    expect(o.grossProfitNano - o.minerFeesNano - o.appFeesNano, o.netProfitNano, reason: 'every fee is accounted for');
    expect(o.unwindLossNano, 280000000);
    expect(o.key, '${'a' * 64}>${'c' * 64}');
    expect(r.skippedBusy, 1);
    expect(r.skippedUntrusted, 2);
    expect(r.mempoolChecked, isTrue);
    expect(r.minerFeeNano, 1100000);
  });

  test('scan asks for the depth floor, the minimum and only verified tokens', () async {
    final api = FakeApi();
    final s = ArbitrageService(api: api, nodeUrl: () => 'http://node', handle: () => BigInt.one);
    await s.scan(minProfitNano: 5000000, includeUntrusted: false, availableNano: 1000000000);
    final o = jsonDecode(api.lastScanOptions!) as Map;
    expect(o['min_profit_nano'], 5000000);
    expect(o['min_depth_nano'], 50000000000);
    expect(o['include_untrusted'], isFalse);
    expect(o['available_nano'], 1000000000);
    expect(o['trusted_token_ids'], contains(SigmaUsdTokens.sigUsd));
    expect(o['trusted_token_ids'], isNot(contains('472c3d4ecaa08fb7392ff041ee2e6af75f4a558810a74b28600549d5392810e8')),
        reason: 'a cautioned token is not trusted');
  });

  test('prepare sends the route, the minimum and the wallet', () async {
    final api = FakeApi();
    final s = ArbitrageService(api: api, nodeUrl: () => null, handle: () => BigInt.one);
    final o = ArbOpportunity.fromJson(opportunityJson());
    final review = await s.prepare(o, minProfitNano: 1, availableNano: 2, spendAddresses: ['9a'], changeAddress: '9b');
    final req = jsonDecode(api.lastPrepare!) as Map;
    expect(req['legs'], [
      {'pool_id': 'a' * 64, 'from_token_id': null, 'to_token_id': tok},
      {'pool_id': 'c' * 64, 'from_token_id': tok, 'to_token_id': null},
    ]);
    expect(req['min_profit_nano'], 1);
    expect(req['change_address'], '9b');
    expect(review.chainId, 42);
    expect(review.opportunity.netProfitNano, 25000000);
    expect(review.expiresIn, const Duration(minutes: 5));
  });

  test('a locked wallet cannot prepare or sign', () async {
    final s = ArbitrageService(api: FakeApi(), nodeUrl: () => null, handle: () => null);
    expect(
      () => s.prepare(ArbOpportunity.fromJson(opportunityJson()), minProfitNano: 0, spendAddresses: const [], changeAddress: 'x'),
      throwsA(isA<ArgusException>().having((e) => e.code, 'code', 'WALLET_LOCKED')),
    );
    expect(() => s.execute(1), throwsA(isA<ArgusException>()));
  });

  test('every broadcast leg is reported to the wallet with its delta', () async {
    final seen = <(String, int?)>[];
    final previous = walletService.onBroadcast;
    walletService.onBroadcast = (id, delta) => seen.add((id, delta));
    addTearDown(() => walletService.onBroadcast = previous);
    final s = ArbitrageService(api: FakeApi(), nodeUrl: () => null, handle: () => BigInt.one);
    final r = await s.execute(42);
    expect(r.status, ArbExecutionStatus.submitted);
    expect(seen, [('t1', -46302200000), ('t2', 46327200000)]);
  });

  test('a stranded execution names what the wallet holds', () async {
    final api = FakeApi()
      ..executeAnswer = jsonEncode({
        'status': 'stranded',
        'tx_ids': ['t1'],
        'wallet_deltas': [-46302200000],
        'failed_leg': 1,
        'error': 'Double spending attempt',
        'holding': {'token_id': tok, 'amount': 4629000000, 'box_id': 'e' * 64, 'after_leg': 1},
      });
    final s = ArbitrageService(api: api, nodeUrl: () => null, handle: () => BigInt.one);
    final r = await s.execute(42);
    expect(r.status, ArbExecutionStatus.stranded);
    expect(r.failedLeg, 1);
    expect(r.holding!.tokenId, tok);
    expect(r.holding!.amount, 4629000000);
    final st = await s.status(42);
    expect(st.state, ArbChainState.stranded);
    expect(st.legs, [ArbLegStatus.pending, ArbLegStatus.notSubmitted]);
    final u = await s.prepareUnwind(42);
    expect(u.preparationId, 7);
    expect(u.outputNano, 46010000000);
  });

  test('a moved chain asks for a fresh review', () {
    final r = ArbExecution.fromJson({'status': 'moved'});
    expect(r.status, ArbExecutionStatus.moved);
    expect(r.txIds, isEmpty);
  });

  test('the minimum profit is remembered', () async {
    final s = ArbitrageService(api: FakeApi(), nodeUrl: () => null, handle: () => null);
    expect(await s.loadMinProfit(), arbDefaultMinProfitNano);
    await s.saveMinProfit(3000000);
    expect(await s.loadMinProfit(), 3000000);
  });

  group('ArbitrageScanner', () {
    test('scans at once and then on its interval, only while active', () {
      fakeAsync((async) {
        var calls = 0;
        final scanner = ArbitrageScanner(
          interval: const Duration(seconds: 30),
          scan: () async {
            calls++;
            return ArbScanResult.fromJson(scanJson(), DateTime(2026));
          },
        );
        scanner.start();
        async.flushMicrotasks();
        expect(calls, 1);
        expect(scanner.result, isNotNull);
        async.elapse(const Duration(seconds: 61));
        expect(calls, 3);
        scanner.pause();
        async.elapse(const Duration(minutes: 5));
        expect(calls, 3, reason: 'nothing runs in the background');
        scanner.start();
        async.flushMicrotasks();
        expect(calls, 4);
        scanner.dispose();
        async.elapse(const Duration(minutes: 5));
        expect(calls, 4);
      });
    });

    test('a scan that outlives a pause is not published, and errors are kept', () {
      fakeAsync((async) {
        final gate = Completer<ArbScanResult>();
        var fail = false;
        final scanner = ArbitrageScanner(
          scan: () => fail ? Future.error(StateError('node down')) : gate.future,
        );
        scanner.start();
        async.flushMicrotasks();
        expect(scanner.scanning, isTrue);
        scanner.pause();
        gate.complete(ArbScanResult.fromJson(scanJson(), DateTime(2026)));
        async.flushMicrotasks();
        expect(scanner.result, isNull);
        expect(scanner.scanning, isFalse);
        fail = true;
        scanner.start();
        async.flushMicrotasks();
        expect(scanner.error, isA<StateError>());
        scanner.dispose();
      });
    });
  });
}
