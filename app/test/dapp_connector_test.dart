import 'dart:convert';

import 'package:argus_wallet/services/dapp_connector.dart';
import 'package:argus_wallet/ui/dapp_browser_screen.dart' show unusedAddressesOf;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> box(String id, String value, [List<(String, String)> tokens = const []]) => {
      'boxId': id,
      'value': value,
      'assets': [for (final t in tokens) {'tokenId': t.$1, 'amount': t.$2}],
    };

class FakeHost implements DappHost {
  bool allowConnect = true;
  bool allowSign = true;
  final log = <String>[];
  List<Map<String, dynamic>> boxes = [box('a', '1000'), box('b', '2000', [('t1', '5')]), box('c', '3000', [('t1', '7'), ('t2', '1')])];
  Object? signError;

  @override
  Future<bool> askConnect(String origin) async {
    log.add('ask $origin');
    return allowConnect;
  }

  @override
  Future<bool> confirmSign(String origin, Map<String, dynamic> summary, int preparationId) async {
    log.add('confirm $origin $preparationId ${summary['tx_id']}');
    return allowSign;
  }

  @override
  List<String> get usedAddresses => ['9used1', '9used2'];
  @override
  List<String> get unusedAddresses => ['9fresh'];
  @override
  String get changeAddress => '9used1';
  @override
  Future<int> currentHeight() async => 1234;
  @override
  Future<List<Map<String, dynamic>>> utxos() async => boxes;
  @override
  Future<Map<String, dynamic>> prepareSign(String txJson) async {
    log.add('prepare ${(jsonDecode(txJson) as Map)['inputs']}');
    return {
      'preparation_id': 42,
      'summary': {'tx_id': 'deadbeef'}
    };
  }

  @override
  Future<String> sign(int preparationId) async {
    if (signError != null) throw signError!;
    return jsonEncode({'id': 'signed-$preparationId', 'inputs': []});
  }

  @override
  Future<String> submit(String signedTxJson) async => 'txid-${(jsonDecode(signedTxJson) as Map)['id']}';
}

void main() {
  late FakeHost host;
  late DappConnector c;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    host = FakeHost();
    c = DappConnector(host);
  });

  test('context methods refuse until the site connects', () async {
    await expectLater(c.handle('https://a', 'get_balance', []), throwsA(isA<DappError>().having((e) => e.code, 'code', DappError.refused)));
    expect(await c.handle('https://a', 'isConnected', []), false);
    expect(await c.handle('https://a', 'isAuthorized', []), false);
  });

  test('connect asks once and is remembered on the device', () async {
    expect(await c.handle('https://a', 'connect', []), true);
    expect(await c.handle('https://a', 'connect', []), true);
    expect(host.log, ['ask https://a']);
    expect(await c.handle('https://a', 'isAuthorized', []), true);
    // A new connector (a new browser session) still needs connect, but
    // does not ask again.
    final again = DappConnector(host);
    expect(await again.handle('https://a', 'isConnected', []), false);
    expect(await again.handle('https://a', 'connect', []), true);
    expect(host.log, ['ask https://a']);
    // Refusal is not remembered.
    host.allowConnect = false;
    expect(await c.handle('https://b', 'connect', []), false);
    expect(await c.handle('https://b', 'isAuthorized', []), false);
  });

  test('disconnect forgets the site', () async {
    await c.handle('https://a', 'connect', []);
    expect(await c.handle('https://a', 'disconnect', []), true);
    expect(await c.handle('https://a', 'isConnected', []), false);
    expect(await c.handle('https://a', 'isAuthorized', []), false);
    host.allowConnect = false;
    expect(await c.handle('https://a', 'connect', []), false);
  });

  test('addresses, height and balances', () async {
    await c.handle('https://a', 'connect', []);
    expect(await c.handle('https://a', 'get_used_addresses', []), ['9used1', '9used2']);
    expect(await c.handle('https://a', 'get_unused_addresses', []), ['9fresh']);
    expect(await c.handle('https://a', 'get_change_address', []), '9used1');
    expect(await c.handle('https://a', 'get_current_height', []), 1234);
    expect(await c.handle('https://a', 'get_balance', []), '6000');
    expect(await c.handle('https://a', 'get_balance', ['t1']), '12');
    expect(await c.handle('https://a', 'get_balance', ['nope']), '0');
    expect(await c.handle('https://a', 'get_balance', ['all']), [
      {'tokenId': 'ERG', 'balance': '6000'},
      {'tokenId': 't1', 'balance': '12'},
      {'tokenId': 't2', 'balance': '1'},
    ]);
    await expectLater(c.handle('https://a', 'get_used_addresses', [
      {'page': 1}
    ]), throwsA(isA<DappError>().having((e) => e.code, 'code', DappError.invalidRequest)));
  });

  test('utxos: all, by ERG amount, by token, by target object', () async {
    await c.handle('https://a', 'connect', []);
    List<String> ids(Object? r) => [for (final b in r as List) (b as Map)['boxId'] as String];
    expect(ids(await c.handle('https://a', 'get_utxos', [])), ['a', 'b', 'c']);
    expect(ids(await c.handle('https://a', 'get_utxos', ['2500'])), ['a', 'b']);
    expect(ids(await c.handle('https://a', 'get_utxos', ['6', 't1'])), ['b', 'c']);
    expect(ids(await c.handle('https://a', 'get_utxos', ['5', 't1'])), ['b']);
    expect(ids(await c.handle('https://a', 'get_utxos', ['100', 'ERG'])), ['a']);
    expect(ids(await c.handle('https://a', 'get_utxos', [
      {
        'tokens': [
          {'tokenId': 't2'}
        ]
      }
    ])), ['c']);
    expect(ids(await c.handle('https://a', 'get_utxos', [
      {'nanoErgs': '999999'}
    ])), ['a', 'b', 'c']);
    await expectLater(c.handle('https://a', 'get_utxos', ['x']), throwsA(isA<DappError>()));
    await expectLater(c.handle('https://a', 'get_utxos', [null, null, {}]), throwsA(isA<DappError>()));
  });

  test('sign_tx checks, asks, signs and hands back the signed object', () async {
    await c.handle('https://a', 'connect', []);
    final tx = {
      'inputs': [1],
      'outputs': []
    };
    final signed = await c.handle('https://a', 'sign_tx', [tx]) as Map;
    expect(signed['id'], 'signed-42');
    expect(host.log, ['ask https://a', 'prepare [1]', 'confirm https://a 42 deadbeef']);
    expect(await c.handle('https://a', 'submit_tx', [signed]), 'txid-signed-42');
  });

  test('a declined signature and a failed check are told apart', () async {
    await c.handle('https://a', 'connect', []);
    host.allowSign = false;
    await expectLater(c.handle('https://a', 'sign_tx', [{}]), throwsA(isA<DappError>().having((e) => e.code, 'code', DappError.userDeclined)));
    host.allowSign = true;
    host.signError = '{"code":"TxBuildFailed","message":"no key"}';
    await expectLater(
      c.handle('https://a', 'sign_tx', [{}]),
      throwsA(isA<DappError>().having((e) => e.code, 'code', DappError.proofFailed).having((e) => e.info, 'info', contains('no key'))),
    );
    await expectLater(c.handle('https://a', 'sign_tx', ['tx']), throwsA(isA<DappError>().having((e) => e.code, 'code', DappError.invalidRequest)));
    await expectLater(c.handle('https://a', 'sign_data', ['9a', 'm']), throwsA(isA<DappError>().having((e) => e.code, 'code', DappError.invalidRequest)));
    await expectLater(c.handle('https://a', 'nope', []), throwsA(isA<DappError>()));
  });

  test('unused addresses are the frontier past the used ones, receive included when fresh', () {
    final used = [
      {'address': '9used1'},
      {'address': '9used2'},
    ];
    expect(unusedAddressesOf(used: used, frontier: ['9used1', '9used2', '9fresh1', '9fresh2'], receive: '9fresh1'), ['9fresh1', '9fresh2']);
    expect(unusedAddressesOf(used: used, frontier: ['9used1'], receive: '9new'), ['9new']);
    expect(unusedAddressesOf(used: used, frontier: const [], receive: '9used1'), isEmpty, reason: 'the receive address already has history');
    expect(unusedAddressesOf(used: const [], frontier: const [], receive: ''), isEmpty);
  });

  test('the injected script names both wallets, the bridge and the nonce', () {
    final s = dappInjectedScript('abc123');
    expect(s, contains('connector.nautilus = api'));
    expect(s, contains('connector.argus = api'));
    expect(s, contains('ArgusBridge.postMessage'));
    expect(s, contains('__argusDapp'));
    expect(s, contains("'ergo-wallet:injected'"));
    expect(s, contains("var nonce = 'abc123';"));
    expect(s, contains('nonce: nonce'));
    expect(s, isNot(contains('__NONCE__')));
  });

  test('bridge messages need the current nonce and a method', () {
    final ok = parseBridgeMessage('{"id":1,"nonce":"n1","method":"get_balance","params":["ERG"]}', 'n1');
    expect(ok, isNotNull);
    expect(ok!.id, 1);
    expect(ok.method, 'get_balance');
    expect(ok.params, ['ERG']);
    // An iframe or a stale page does not know the nonce.
    expect(parseBridgeMessage('{"id":1,"method":"get_balance","params":[]}', 'n1'), isNull);
    expect(parseBridgeMessage('{"id":1,"nonce":"old","method":"get_balance","params":[]}', 'n1'), isNull);
    expect(parseBridgeMessage('{"id":1,"nonce":"n1","method":"get_balance"}', ''), isNull, reason: 'no navigation yet');
    expect(parseBridgeMessage('{"id":1,"nonce":"n1","params":[]}', 'n1'), isNull);
    expect(parseBridgeMessage('not json', 'n1'), isNull);
    expect(parseBridgeMessage('[1]', 'n1'), isNull);
    expect(parseBridgeMessage('{"id":2,"nonce":"n1","method":"x","params":"no"}', 'n1')!.params, isEmpty);
  });

  test('origins are scheme, host and port of web pages only', () {
    expect(originOf('https://sigmafi.app/orders?x=1'), 'https://sigmafi.app');
    expect(originOf('http://localhost:8080/'), 'http://localhost:8080');
    expect(originOf('about:blank'), '');
    expect(originOf('file:///etc/passwd'), '');
    expect(originOf(null), '');
  });

  test('a combined target needs both the ERG and the tokens', () {
    final utxos = [box('a', '1000'), box('b', '2000', [('t1', '5')]), box('c', '3000')];
    final picked = selectUtxos(utxos, {
      'nanoErgs': '2500',
      'tokens': [
        {'tokenId': 't1', 'amount': '5'}
      ]
    });
    // Boxes without the token are skipped while a token is wanted, so the
    // ERG comes from the token-bearing boxes; the caller may need more.
    expect(picked.map((b) => b['boxId']), ['b']);
    expect(() => selectUtxos(utxos, {'nanoErgs': 1.5}), throwsA(isA<DappError>()));
  });
}

