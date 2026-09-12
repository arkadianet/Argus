import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'network_controller.dart';
import 'wallet_database_service.dart';
import 'wallet_service.dart';

enum ProxyStatus { pending, confirmed, spent }

class TrackedStakeProxy {
  TrackedStakeProxy(Map<String, dynamic> record)
    : _record = (jsonDecode(jsonEncode(record)) as Map).cast();
  final Map<String, dynamic> _record;
  String get walletId => _record['wallet_id'] as String;
  String get network => _record['network'] as String;
  String get txId => _record['creation_tx_id'] as String;
  String get keyId => _record['key_id'] as String;
  String get recipient => _record['recipient'] as String;
  String get boxId => (_record['proxy'] as Map)['boxId'] as String;
  Map<String, dynamic> get proxy =>
      (jsonDecode(jsonEncode(_record['proxy'])) as Map).cast();
  ProxyStatus get status =>
      ProxyStatus.values.byName(_record['status'] as String);
  List<String> get refundTxIds => List<String>.unmodifiable(
    (_record['refund_tx_ids'] as List?)?.cast<String>() ?? const <String>[],
  );
  String? get spendingTxId => _record['spending_tx_id'] as String?;
  bool refundConfirmed(String txId) =>
      status == ProxyStatus.spent && spendingTxId == txId;
  String? get note => _record['note'] as String?;
  Map<String, dynamic> toJson() =>
      (jsonDecode(jsonEncode(_record)) as Map).cast();
}

abstract class StakeProxyGateway {
  String? get walletId;
  String get network;
  String? get nodeUrl;
  Future<Map<String, dynamic>> prepareRefund(TrackedStakeProxy record);
  Future<String> sign(int preparationId);
  Map<String, dynamic> creationRecord(String signed, String recipient);
  Future<String> broadcast(String signed, String? node);
  Future<ProxyStatus> lookup(TrackedStakeProxy record);
}

class LiveStakeProxyGateway implements StakeProxyGateway {
  LiveStakeProxyGateway({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;
  @override
  String? get walletId => walletService.activeWalletId;
  @override
  String get network => 'mainnet';
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  Future<Map<String, dynamic>> prepareRefund(TrackedStakeProxy record) async =>
      (jsonDecode(
                await walletService.stakeRecoveryPrepareProxy(
                  refundBoxJson: jsonEncode(record.proxy),
                  userAddress: record.recipient,
                  spendAddresses: [record.recipient],
                  nodeUrl: nodeUrl,
                ),
              )
              as Map)
          .cast();
  @override
  Future<String> sign(int preparationId) =>
      walletService.signPreparation(preparationId: preparationId);
  @override
  Map<String, dynamic> creationRecord(String signed, String recipient) =>
      (jsonDecode(walletService.stakeRecoveryProxyRecord(signed, recipient))
              as Map)
          .cast();
  @override
  Future<String> broadcast(String signed, String? node) =>
      walletService.submitSignedTransaction(signed, nodeUrl: node);
  @override
  Future<ProxyStatus> lookup(TrackedStakeProxy record) async {
    final base = networkController.explorer.replaceAll(RegExp(r'/+$'), '');
    final response = await _client
        .get(Uri.parse('$base/api/v1/boxes/${record.boxId}'))
        .timeout(const Duration(seconds: 30));
    // Absence is not failure or proof of a spend: creation may still confirm.
    if (response.statusCode == 404) return ProxyStatus.pending;
    if (response.statusCode != 200)
      throw StateError('Proxy lookup HTTP ${response.statusCode}');
    final box = jsonDecode(response.body) as Map;
    if (box['boxId'] != record.boxId)
      throw StateError('Proxy lookup returned a different box');
    if (box['mainChain'] == false) {
      record._record['spending_tx_id'] = null;
      return ProxyStatus.pending;
    }
    if (box['mainChain'] != true || !box.containsKey('spentTransactionId')) {
      throw StateError('Proxy chain status is incomplete');
    }
    if (box['spentTransactionId'] is String &&
        (box['spentTransactionId'] as String).isNotEmpty) {
      record._record['spending_tx_id'] = box['spentTransactionId'];
      return ProxyStatus.spent;
    }
    if (box['settlementHeight'] == null && box['inclusionHeight'] == null) {
      throw StateError('Proxy confirmation is not yet known');
    }
    record._record['spending_tx_id'] = null;
    return ProxyStatus.confirmed;
  }
}

/// Durable lifecycle independent of StakeRecoveryService and pool discovery.
/// Creation has no UI entry in batch 4; this commit path already enforces the
/// persistence ordering needed when the entry is enabled in batch 5.
class StakeProxyService extends ChangeNotifier {
  StakeProxyService({StakeProxyGateway? gateway})
    : _gw = gateway ?? LiveStakeProxyGateway();
  final StakeProxyGateway _gw;
  static const creationEnabled = false;
  List<TrackedStakeProxy> _records = [];
  ({String? wallet, String network})? _loaded;
  bool _busy = false;
  bool _reconciling = false;
  String? error;
  Future<void> _writes = Future<void>.value();

  // Reconciliation and refund signing may overlap. Merge each update into the
  // latest durable rows so a slow lookup cannot erase a pre-broadcast write.
  Future<void> _updateRows(
    String wallet,
    String network,
    void Function(List<Map<String, dynamic>>) update,
  ) {
    final write = _writes.then((_) async {
      final rows = await WalletDatabaseService.loadStakeProxies(
        wallet,
        network,
      );
      update(rows);
      await WalletDatabaseService.saveStakeProxies(wallet, network, rows);
      if (_scope == (wallet: wallet, network: network)) {
        _loaded = _scope;
        _records = rows.map(TrackedStakeProxy.new).toList();
        notifyListeners();
      }
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }

  bool get busy => _busy || _reconciling;
  ({String? wallet, String network}) get _scope =>
      (wallet: _gw.walletId, network: _gw.network);
  List<TrackedStakeProxy> get records =>
      _loaded == _scope ? List.unmodifiable(_records) : const [];

  Future<void> reload() async {
    if (busy) return;
    final scope = _scope;
    _reconciling = true;
    error = null;
    notifyListeners();
    try {
      final rows = scope.wallet == null
          ? <Map<String, dynamic>>[]
          : await WalletDatabaseService.loadStakeProxies(
              scope.wallet!,
              scope.network,
            );
      final records = rows.map(TrackedStakeProxy.new).toList();
      if (records.any(
        (r) => r.walletId != scope.wallet || r.network != scope.network,
      )) {
        throw StateError('Proxy record wallet or network mismatch');
      }
      if (scope != _scope) return;
      _loaded = scope;
      _records = records;
      notifyListeners(); // refunds are reachable before reconciliation finishes
      for (final record in records) {
        try {
          final status = await _gw.lookup(record);
          // A spent record can reappear after a reorg. Retain it forever.
          record._record['status'] = status.name;
          record._record['note'] = null;
        } catch (e) {
          record._record['note'] = 'Reconciliation uncertain: $e';
        }
      }
      if (scope.wallet != null) {
        await _updateRows(scope.wallet!, scope.network, (rows) {
          for (final row in rows) {
            final boxId = (row['proxy'] as Map)['boxId'];
            final matches = records.where((r) => r.boxId == boxId);
            if (matches.isEmpty) continue;
            final reconciled = matches.single;
            row['status'] = reconciled.status.name;
            row['note'] = reconciled.note;
            row['spending_tx_id'] = reconciled.spendingTxId;
          }
        });
      }
    } catch (e) {
      error = '$e';
    } finally {
      _reconciling = false;
      notifyListeners();
    }
    if (scope != _scope) await reload();
  }

  void _requireScope(String wallet, String network, String? node) {
    if (_gw.walletId != wallet ||
        _gw.network != network ||
        _gw.nodeUrl != node) {
      throw StateError('Wallet or network changed; nothing was broadcast');
    }
  }

  /// Available to the eventual creation confirmation flow. Batch 4 provides
  /// no creation button; this prepares but never signs or broadcasts.
  Future<Map<String, dynamic>> prepareCreation({
    required String stateBoxJson,
    required String stakeBoxJson,
    required String userAddress,
    required List<String> spendAddresses,
  }) async {
    final scope = _scope;
    final node = _gw.nodeUrl;
    if (scope.wallet == null || scope.network != 'mainnet') {
      throw StateError('An unlocked mainnet wallet is required');
    }
    final raw = await walletService.stakeRecoveryPrepareProxy(
      stateBoxJson: stateBoxJson,
      stakeBoxJson: stakeBoxJson,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      nodeUrl: node,
    );
    _requireScope(scope.wallet!, scope.network, node);
    return (jsonDecode(raw) as Map).cast<String, dynamic>()
      ..['wallet_id'] = scope.wallet
      ..['network'] = scope.network
      ..['node'] = node;
  }

  /// Native preparation is immutable. Its expected output is cross-checked
  /// with the canonical box reconstructed from the signed transaction.
  Future<String> commitCreation(Map<String, dynamic> prepared) async {
    if (busy) throw StateError('Proxy operation already in progress');
    final wallet = prepared['wallet_id'] as String;
    final network = prepared['network'] as String;
    final node = prepared['node'] as String?;
    _requireScope(wallet, network, node);
    _busy = true;
    notifyListeners();
    try {
      final signed = await _gw.sign(
        (prepared['preparation_id'] as num).toInt(),
      );
      _requireScope(wallet, network, node);
      final record = _gw.creationRecord(
        signed,
        prepared['recipient'] as String,
      );
      if (record['creation_tx_id'] != prepared['creation_tx_id'] ||
          (record['proxy'] as Map)['boxId'] !=
              (prepared['expected_proxy'] as Map)['boxId'] ||
          record['network'] != network) {
        throw StateError('Signed creation differs from the prepared proxy');
      }
      record['wallet_id'] = wallet;
      record['status'] = ProxyStatus.pending.name;
      record['note'] = 'Submission may be pending; retained until reconciled';
      final rows = await WalletDatabaseService.loadStakeProxies(
        wallet,
        network,
      );
      rows.removeWhere(
        (r) =>
            (r['proxy'] as Map)['boxId'] == (record['proxy'] as Map)['boxId'],
      );
      rows.add(record);
      // This awaited durable write MUST precede the first broadcast attempt.
      // A crash or timeout after this point leaves everything needed to refund.
      await WalletDatabaseService.saveStakeProxies(wallet, network, rows);
      _requireScope(wallet, network, node);
      _loaded = _scope;
      _records = rows.map(TrackedStakeProxy.new).toList();
      notifyListeners();
      return await _gw.broadcast(signed, node);
    } finally {
      // Never delete tracking on an exception, including uncertain submission.
      _busy = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> prepareRefund(TrackedStakeProxy record) async {
    final node = _gw.nodeUrl;
    _requireScope(record.walletId, record.network, node);
    if (!records.contains(record))
      throw StateError('Reload tracked proxies first');
    final prepared = await _gw.prepareRefund(record);
    _requireScope(record.walletId, record.network, node);
    prepared['wallet_id'] = record.walletId;
    prepared['network'] = record.network;
    prepared['node'] = node;
    prepared['proxy_box_id'] = record.boxId;
    return prepared;
  }

  Future<String> commitRefund(Map<String, dynamic> prepared) async {
    if (_busy) throw StateError('Proxy operation already in progress');
    final wallet = prepared['wallet_id'] as String;
    final network = prepared['network'] as String;
    final node = prepared['node'] as String?;
    _requireScope(wallet, network, node);
    _busy = true;
    notifyListeners();
    try {
      // Native signing revalidates the sole proxy input and exact reduction.
      final signed = await _gw.sign(
        (prepared['preparation_id'] as num).toInt(),
      );
      _requireScope(wallet, network, node);
      final txId = (jsonDecode(signed) as Map)['id'] as String;
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(txId)) {
        throw StateError('Signed refund has no valid transaction ID');
      }
      await _updateRows(wallet, network, (rows) {
        final row = rows.singleWhere(
          (r) => (r['proxy'] as Map)['boxId'] == prepared['proxy_box_id'],
        );
        final ids = List<String>.from(row['refund_tx_ids'] as List? ?? []);
        if (!ids.contains(txId)) ids.add(txId);
        row['refund_tx_ids'] = ids;
      });
      // Await persistence before attempting broadcast. An ID records an
      // attempt, never proof of acceptance or a completed refund.
      _requireScope(wallet, network, node);
      return await _gw.broadcast(signed, node);
    } finally {
      // The creation record survives uncertain refunds, too. Only positive
      // chain evidence changes it to spent during reconciliation.
      _busy = false;
      notifyListeners();
    }
  }
}

final stakeProxyService = StakeProxyService();
