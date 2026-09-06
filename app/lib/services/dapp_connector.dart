import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// An error a page receives from the connector, in EIP-12's shape.
class DappError implements Exception {
  const DappError(this.code, this.info);

  /// `-1` invalid request, `-2` internal error, `-3` refused, as Nautilus
  /// numbers them; `1` proof generation failed and `2` user declined for
  /// signing.
  final int code;
  final String info;

  static const invalidRequest = -1;
  static const internal = -2;
  static const refused = -3;
  static const proofFailed = 1;
  static const userDeclined = 2;

  Map<String, dynamic> toJson() => {'code': code, 'info': info};

  @override
  String toString() => 'DappError($code, $info)';
}

/// What the connector needs from the wallet and the screen. The screen
/// implements it with sheets; tests with a fake.
abstract class DappHost {
  /// Ask the user whether `origin` may see the wallet. Once granted the
  /// answer is remembered until the user disconnects the site.
  Future<bool> askConnect(String origin);

  /// Show the transaction and ask for a signature.
  Future<bool> confirmSign(String origin, Map<String, dynamic> summary, int preparationId);

  List<String> get usedAddresses;
  List<String> get unusedAddresses;
  String get changeAddress;
  Future<int> currentHeight();

  /// The wallet's boxes in EIP-12 shape.
  Future<List<Map<String, dynamic>>> utxos();

  /// `{preparation_id, summary}` from the Rust check of an unsigned tx.
  Future<Map<String, dynamic>> prepareSign(String txJson);

  /// The signed transaction JSON for a preparation.
  Future<String> sign(int preparationId);

  /// Broadcast a signed transaction; the id.
  Future<String> submit(String signedTxJson);
}

/// Sites the user let see the wallet, kept on the device.
class DappSitePermissions {
  DappSitePermissions({Future<SharedPreferences> Function()? prefs}) : _prefs = prefs ?? SharedPreferences.getInstance;
  static const key = 'argus_dapp_sites_v1';
  final Future<SharedPreferences> Function() _prefs;
  Set<String>? _granted;

  Future<Set<String>> granted() async {
    if (_granted != null) return _granted!;
    final p = await _prefs();
    return _granted = {...?p.getStringList(key)};
  }

  Future<bool> isGranted(String origin) async => (await granted()).contains(origin);

  Future<void> grant(String origin) async {
    final g = await granted();
    if (g.add(origin)) await (await _prefs()).setStringList(key, g.toList()..sort());
  }

  Future<void> revoke(String origin) async {
    final g = await granted();
    if (g.remove(origin)) await (await _prefs()).setStringList(key, g.toList()..sort());
  }
}

/// Pick boxes until `target` is met: `{nanoErgs?: string, tokens?: [{tokenId, amount?}]}`.
/// Without a target, every box. A token named without an amount means
/// "boxes that carry it". Boxes are taken in the order given.
List<Map<String, dynamic>> selectUtxos(List<Map<String, dynamic>> utxos, Map<String, dynamic>? target) {
  if (target == null) return utxos;
  final wantErg = _big(target['nanoErgs']);
  final tokens = <String, BigInt?>{};
  for (final t in (target['tokens'] as List? ?? const [])) {
    final m = (t as Map).cast<String, dynamic>();
    final id = m['tokenId'] as String?;
    if (id == null) throw const DappError(DappError.invalidRequest, 'A token target needs a tokenId.');
    tokens[id] = m['amount'] == null ? null : _big(m['amount']);
  }
  if (wantErg == null && tokens.isEmpty) return utxos;
  var erg = BigInt.zero;
  final have = <String, BigInt>{};
  bool done() {
    if (wantErg != null && erg < wantErg) return false;
    for (final e in tokens.entries) {
      final need = e.value;
      if (need == null ? !have.containsKey(e.key) : (have[e.key] ?? BigInt.zero) < need) return false;
    }
    return true;
  }

  final out = <Map<String, dynamic>>[];
  for (final u in utxos) {
    if (done()) break;
    final assets = (u['assets'] as List? ?? const []).cast<Map>();
    final relevant = wantErg != null && tokens.isEmpty || assets.any((a) => tokens.containsKey(a['tokenId']));
    if (!relevant && tokens.isNotEmpty) continue;
    out.add(u);
    erg += _big(u['value']) ?? BigInt.zero;
    for (final a in assets) {
      final id = a['tokenId'] as String;
      have[id] = (have[id] ?? BigInt.zero) + (_big(a['amount']) ?? BigInt.zero);
    }
  }
  return out;
}

BigInt? _big(dynamic v) {
  if (v == null) return null;
  if (v is num) return BigInt.from(v);
  final s = v.toString();
  final n = BigInt.tryParse(s);
  if (n == null) throw DappError(DappError.invalidRequest, 'Not an amount: $s');
  return n;
}

/// Balances by asset from EIP-12 boxes; `ERG` for the coin.
Map<String, BigInt> balancesOf(List<Map<String, dynamic>> utxos) {
  final out = <String, BigInt>{'ERG': BigInt.zero};
  for (final u in utxos) {
    out['ERG'] = out['ERG']! + (_big(u['value']) ?? BigInt.zero);
    for (final a in (u['assets'] as List? ?? const []).cast<Map>()) {
      final id = a['tokenId'] as String;
      out[id] = (out[id] ?? BigInt.zero) + (_big(a['amount']) ?? BigInt.zero);
    }
  }
  return out;
}

/// The EIP-12 methods, answered for one page at a time. Every answer is
/// what Nautilus would give, so a dApp written for it works unchanged.
class DappConnector {
  DappConnector(this.host, {DappSitePermissions? permissions}) : permissions = permissions ?? DappSitePermissions();

  final DappHost host;
  final DappSitePermissions permissions;

  /// Origins that called `connect` in this session and were allowed.
  final connected = <String>{};

  /// One request: the method a page called and its arguments. Throws
  /// [DappError] for the page; anything else is an internal error.
  Future<Object?> handle(String origin, String method, List<dynamic> params) async {
    Object? arg(int i) => params.length > i ? params[i] : null;
    switch (method) {
      case 'connect':
        if (connected.contains(origin)) return true;
        final ok = await permissions.isGranted(origin) || await host.askConnect(origin);
        if (!ok) return false;
        await permissions.grant(origin);
        connected.add(origin);
        return true;
      case 'isAuthorized':
        return permissions.isGranted(origin);
      case 'isConnected':
        return connected.contains(origin);
      case 'disconnect':
        connected.remove(origin);
        await permissions.revoke(origin);
        return true;
    }
    if (!connected.contains(origin)) {
      throw const DappError(DappError.refused, 'Not connected. Call ergoConnector.nautilus.connect() first.');
    }
    switch (method) {
      case 'get_utxos':
        final a = arg(0);
        Map<String, dynamic>? target;
        if (a is String) {
          final tokenId = arg(1);
          target = tokenId == null || tokenId == 'ERG'
              ? {'nanoErgs': a}
              : {
                  'tokens': [
                    {'tokenId': tokenId, 'amount': a}
                  ]
                };
        } else if (a is Map) {
          target = a.cast<String, dynamic>();
        } else if (a != null) {
          throw const DappError(DappError.invalidRequest, 'get_utxos takes an amount or a selection target.');
        }
        if (arg(2) != null) throw const DappError(DappError.invalidRequest, 'Pagination is not supported.');
        return selectUtxos(await host.utxos(), target);
      case 'get_balance':
        final which = arg(0) ?? 'ERG';
        final balances = balancesOf(await host.utxos());
        if (which == 'all') {
          return [
            for (final e in balances.entries) {'tokenId': e.key, 'balance': e.value.toString()},
          ];
        }
        return (balances[which] ?? BigInt.zero).toString();
      case 'get_used_addresses':
        if (arg(0) != null) throw const DappError(DappError.invalidRequest, 'Pagination is not supported.');
        return host.usedAddresses;
      case 'get_unused_addresses':
        if (arg(0) != null) throw const DappError(DappError.invalidRequest, 'Pagination is not supported.');
        return host.unusedAddresses;
      case 'get_change_address':
        return host.changeAddress;
      case 'get_current_height':
        return host.currentHeight();
      case 'sign_tx':
        final tx = arg(0);
        if (tx is! Map) throw const DappError(DappError.invalidRequest, 'sign_tx takes an unsigned transaction object.');
        final Map<String, dynamic> prepared;
        try {
          prepared = await host.prepareSign(jsonEncode(tx));
        } catch (e) {
          throw DappError(DappError.proofFailed, 'The transaction could not be checked: ${_message(e)}');
        }
        final id = (prepared['preparation_id'] as num).toInt();
        final summary = (prepared['summary'] as Map).cast<String, dynamic>();
        if (!await host.confirmSign(origin, summary, id)) {
          throw const DappError(DappError.userDeclined, 'The user declined to sign.');
        }
        try {
          return jsonDecode(await host.sign(id));
        } catch (e) {
          throw DappError(DappError.proofFailed, 'Signing failed: ${_message(e)}');
        }
      case 'sign_tx_inputs':
        throw const DappError(DappError.invalidRequest, 'Argus signs whole transactions only (sign_tx).');
      case 'sign_data':
      case 'auth':
        throw const DappError(DappError.invalidRequest, 'Argus does not sign arbitrary data yet.');
      case 'submit_tx':
        final tx = arg(0);
        if (tx is! Map) throw const DappError(DappError.invalidRequest, 'submit_tx takes a signed transaction object.');
        try {
          return await host.submit(jsonEncode(tx));
        } catch (e) {
          throw DappError(DappError.internal, 'The node did not accept the transaction: ${_message(e)}');
        }
    }
    throw DappError(DappError.invalidRequest, 'Unknown method $method.');
  }

  static String _message(Object e) {
    if (e is String) {
      try {
        final m = jsonDecode(e);
        if (m is Map && m['message'] is String) return m['message'] as String;
      } catch (_) {
        // Not JSON.
      }
    }
    return e.toString();
  }
}

/// The script injected into every page: `ergoConnector.nautilus` (and
/// `ergoConnector.argus`) whose methods post to the `ArgusBridge` channel
/// and wait for `window.__argusDapp.resolve`.
const dappInjectedScript = r'''
(function () {
  if (window.__argusDapp) return;
  var pending = {};
  var next = 1;
  var dapp = {
    pending: pending,
    resolve: function (id, ok, payload) {
      var p = pending[id];
      if (!p) return;
      delete pending[id];
      if (ok) p.resolve(payload); else p.reject(payload);
    }
  };
  Object.defineProperty(window, '__argusDapp', { value: dapp, writable: false, configurable: false });
  function call(method, params) {
    return new Promise(function (resolve, reject) {
      var id = next++;
      pending[id] = { resolve: resolve, reject: reject };
      ArgusBridge.postMessage(JSON.stringify({ id: id, method: method, params: params || [] }));
    });
  }
  function context() {
    return Object.freeze({
      get_utxos: function (a, b, c) { return call('get_utxos', [a, b, c]); },
      get_balance: function (t) { return call('get_balance', [t]); },
      get_used_addresses: function (p) { return call('get_used_addresses', [p]); },
      get_unused_addresses: function (p) { return call('get_unused_addresses', [p]); },
      get_change_address: function () { return call('get_change_address', []); },
      get_current_height: function () { return call('get_current_height', []); },
      sign_tx: function (tx) { return call('sign_tx', [tx]); },
      sign_tx_inputs: function (tx, i) { return call('sign_tx_inputs', [tx, i]); },
      sign_data: function (a, m) { return call('sign_data', [a, m]); },
      auth: function (a, m) { return call('auth', [a, m]); },
      submit_tx: function (tx) { return call('submit_tx', [tx]); }
    });
  }
  var ctx = null;
  var api = Object.freeze({
    connect: function (opts) {
      var createErgoObject = !opts || opts.createErgoObject !== false;
      return call('connect', []).then(function (granted) {
        if (granted) { ctx = context(); if (createErgoObject) window.ergo = ctx; }
        return granted;
      });
    },
    isAuthorized: function () { return call('isAuthorized', []); },
    isConnected: function () { return Promise.resolve(ctx !== null); },
    disconnect: function () {
      return call('disconnect', []).then(function (d) {
        if (d) { ctx = null; if (window.ergo) delete window.ergo; }
        return d;
      });
    },
    getContext: function () {
      return ctx ? Promise.resolve(ctx) : Promise.reject({ code: -3, info: 'Not connected.' });
    }
  });
  var connector = window.ergoConnector || {};
  connector.nautilus = api;
  connector.argus = api;
  window.ergoConnector = connector;
  if (!window.ergo_request_read_access) {
    window.ergo_request_read_access = function () { return api.connect(); };
    window.ergo_check_read_access = function () { return api.isConnected(); };
  }
  window.dispatchEvent(new CustomEvent('ergo-wallet:injected', { detail: 'nautilus' }));
})();
''';
