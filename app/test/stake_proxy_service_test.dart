import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:argus_wallet/services/stake_proxy_service.dart';
import 'package:argus_wallet/services/wallet_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> prepared() => {
  'wallet_id': 'alice',
  'network': 'mainnet',
  'node': 'node',
  'preparation_id': 7,
  'creation_tx_id': 'signed-id',
  'expected_proxy': {'boxId': 'proxy'},
  'recipient': 'wallet-address',
};

class Gateway implements StakeProxyGateway {
  @override
  String? walletId = 'alice';
  @override
  String network = 'mainnet';
  @override
  String? nodeUrl = 'node';
  int broadcasts = 0, refunds = 0;
  ProxyStatus status = ProxyStatus.pending;
  Completer<ProxyStatus>? lookupWait;
  bool uncertain = false,
      lookupFails = false,
      crash = false,
      switchDuringSign = false;
  @override
  Future<String> sign(int preparationId) async {
    if (switchDuringSign) walletId = 'bob';
    return 'signed';
  }

  @override
  Map<String, dynamic> creationRecord(String signed, String recipient) => {
    'creation_tx_id': 'signed-id',
    'proxy': {'boxId': 'proxy', 'value': '104000000'},
    'key_id': 'key',
    'recipient': recipient,
    'recipient_tree': 'owned-tree',
    'network': 'mainnet',
  };
  @override
  Future<String> broadcast(String signed, String? node) async {
    final persisted = await WalletDatabaseService.loadStakeProxies(
      'alice',
      'mainnet',
    );
    expect(persisted.single['creation_tx_id'], 'signed-id');
    expect(persisted.single['key_id'], 'key');
    expect(persisted.single['recipient'], 'wallet-address');
    expect(persisted.single['recipient_tree'], 'owned-tree');
    expect(persisted.single['wallet_id'], 'alice');
    expect(persisted.single['network'], 'mainnet');
    expect((persisted.single['proxy'] as Map)['boxId'], 'proxy');
    if (crash) throw StateError('simulated process loss before network');
    broadcasts++;
    if (uncertain) throw TimeoutException('accepted by node, response lost');
    return 'signed-id';
  }

  @override
  Future<ProxyStatus> lookup(TrackedStakeProxy record) async {
    if (lookupWait != null) return lookupWait!.future;
    if (lookupFails) throw TimeoutException('lookup unavailable');
    return status;
  }

  @override
  Future<Map<String, dynamic>> prepareRefund(TrackedStakeProxy record) async {
    refunds++;
    // No state, stake, scan or executor exists in this gateway.
    expect(record.proxy['boxId'], 'proxy');
    return {'preparation_id': 8, 'rows': []};
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'real reconciliation adapter distinguishes pending confirmed spent and uncertainty',
    () async {
      final record = TrackedStakeProxy({
        ...Gateway().creationRecord('signed', 'wallet-address'),
        'wallet_id': 'alice',
        'status': 'pending',
      });
      var response = http.Response('', 404);
      final gw = LiveStakeProxyGateway(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/api/v1/boxes/proxy');
          return response;
        }),
      );
      expect(await gw.lookup(record), ProxyStatus.pending);
      response = http.Response(
        jsonEncode({
          'boxId': 'proxy',
          'mainChain': true,
          'settlementHeight': 100,
          'spentTransactionId': null,
        }),
        200,
      );
      expect(await gw.lookup(record), ProxyStatus.confirmed);
      response = http.Response(
        jsonEncode({
          'boxId': 'proxy',
          'mainChain': true,
          'settlementHeight': 100,
          'spentTransactionId': 'refund-id',
        }),
        200,
      );
      expect(await gw.lookup(record), ProxyStatus.spent);
      response = http.Response(
        jsonEncode({
          'boxId': 'proxy',
          'mainChain': false,
          'spentTransactionId': 'old-fork',
        }),
        200,
      );
      expect(await gw.lookup(record), ProxyStatus.pending);
      for (final bad in [
        http.Response('unavailable', 503),
        http.Response(jsonEncode({'boxId': 'proxy'}), 200),
        http.Response(jsonEncode({'boxId': 'foreign'}), 200),
      ]) {
        response = bad;
        await expectLater(gw.lookup(record), throwsStateError);
      }
    },
  );
  test(
    'refund can commit while restart reconciliation is unavailable',
    () async {
      final gw = Gateway();
      final first = StakeProxyService(gateway: gw);
      await first.commitCreation(prepared());
      first.dispose();
      gw.lookupWait = Completer<ProxyStatus>();
      final restarted = StakeProxyService(gateway: gw);
      final loaded = Completer<void>();
      restarted.addListener(() {
        if (restarted.records.isNotEmpty && !loaded.isCompleted)
          loaded.complete();
      });
      final reconciling = restarted.reload();
      await loaded.future;
      final refund = await restarted.prepareRefund(restarted.records.single);
      expect(await restarted.commitRefund(refund), 'signed-id');
      expect(gw.lookupWait!.isCompleted, isFalse);
      gw.lookupWait!.complete(ProxyStatus.confirmed);
      await reconciling;
      restarted.dispose();
    },
  );
  test('creation remains gated in batch 4', () {
    expect(StakeProxyService.creationEnabled, isFalse);
  });
  for (final outcome in ['success', 'crash', 'uncertain']) {
    test(
      'persist before broadcast and restart independently: $outcome',
      () async {
        final gw = Gateway()
          ..uncertain = outcome == 'uncertain'
          ..crash = outcome == 'crash';
        final svc = StakeProxyService(gateway: gw);
        final commit = svc.commitCreation(prepared());
        if (outcome == 'success') {
          expect(await commit, 'signed-id');
        } else {
          await expectLater(commit, throwsA(anything));
        }
        svc.dispose();
        final restarted = StakeProxyService(gateway: gw);
        addTearDown(restarted.dispose);
        await restarted.reload();
        expect(restarted.records.single.status, ProxyStatus.pending);
        gw.status = ProxyStatus.confirmed;
        await restarted.reload();
        expect(restarted.records.single.status, ProxyStatus.confirmed);
        gw.lookupFails = true;
        await restarted.reload();
        expect(restarted.records.single.status, ProxyStatus.confirmed);
        expect(restarted.records.single.note, contains('uncertain'));
        final refund = await restarted.prepareRefund(restarted.records.single);
        gw.uncertain = false;
        gw.crash = false;
        expect(await restarted.commitRefund(refund), 'signed-id');
        expect(gw.refunds, 1);
        gw.lookupFails = false;
        gw.status = ProxyStatus.spent;
        await restarted.reload();
        expect(restarted.records.single.status, ProxyStatus.spent);
        gw.status = ProxyStatus.confirmed;
        await restarted.reload();
        expect(restarted.records.single.status, ProxyStatus.confirmed);
      },
    );
  }
  test('corrupt persistence prevents any broadcast', () async {
    final gw = Gateway();
    SharedPreferences.setMockInitialValues({
      'argus_stake_proxies_v1_mainnet_alice': 'corrupt',
    });
    final svc = StakeProxyService(gateway: gw);
    addTearDown(svc.dispose);
    await expectLater(svc.commitCreation(prepared()), throwsStateError);
    expect(gw.broadcasts, 0);
  });
  test('wallet/network scope is pinned across signing and restart', () async {
    final gw = Gateway()..switchDuringSign = true;
    final svc = StakeProxyService(gateway: gw);
    addTearDown(svc.dispose);
    await expectLater(svc.commitCreation(prepared()), throwsStateError);
    expect(gw.broadcasts, 0);
    gw.walletId = 'alice';
    gw.switchDuringSign = false;
    await svc.commitCreation(prepared());
    gw.walletId = 'bob';
    expect(svc.records, isEmpty);
    await svc.reload();
    expect(svc.records, isEmpty);
    gw.walletId = 'alice';
    gw.network = 'testnet';
    await svc.reload();
    expect(svc.records, isEmpty);
    gw.network = 'mainnet';
    await svc.reload();
    expect(svc.records, hasLength(1));
    final refund = await svc.prepareRefund(svc.records.single);
    gw.walletId = 'bob';
    await expectLater(svc.commitRefund(refund), throwsStateError);
    expect(gw.broadcasts, 1);
  });
  test('uncertain refund retains confirmed creation record', () async {
    final gw = Gateway();
    final svc = StakeProxyService(gateway: gw);
    await svc.commitCreation(prepared());
    gw.status = ProxyStatus.confirmed;
    await svc.reload();
    final refund = await svc.prepareRefund(svc.records.single);
    gw.uncertain = true;
    await expectLater(
      svc.commitRefund(refund),
      throwsA(isA<TimeoutException>()),
    );
    svc.dispose();
    final restarted = StakeProxyService(gateway: gw);
    addTearDown(restarted.dispose);
    await restarted.reload();
    expect(restarted.records.single.status, ProxyStatus.confirmed);
    await restarted.prepareRefund(restarted.records.single);
    expect(gw.refunds, 2);
  });
}
