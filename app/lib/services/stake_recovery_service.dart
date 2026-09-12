import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as bridge;
import 'network_controller.dart';
import 'wallet_service.dart';

class StakePool {
  StakePool(Map<String, dynamic> m)
    : id = m['id'] as String,
      name = m['name'] as String,
      active = m['active'] as bool,
      tree = m['stake_tree'] as String,
      address = m['stake_address'] as String,
      stateNft = m['state_nft'] as String,
      decimals = m['reward_decimals'] as int;
  final String id, name, tree, address, stateNft;
  final bool active;
  final int decimals;
}

class StakePosition {
  StakePosition(Map<String, dynamic> m)
    : boxId = m['box_id'] as String,
      keyId = m['key_id'] as String,
      rewardAmount = BigInt.parse(m['reward_amount'] as String),
      eligible = m['eligible'] as bool?,
      eligibilityError = m['eligibility_error'] as String?;
  final String boxId, keyId;
  final BigInt rewardAmount;
  final bool? eligible;
  final String? eligibilityError;

  String amount(int decimals) {
    final digits = rewardAmount.toString().padLeft(decimals + 1, '0');
    return decimals == 0
        ? digits
        : '${digits.substring(0, digits.length - decimals)}.${digits.substring(digits.length - decimals)}';
  }
}

enum StakeScanStatus { scanning, complete, incomplete, unavailable }

class StakePoolResult {
  StakePoolResult(this.pool);
  final StakePool pool;
  StakeScanStatus status = StakeScanStatus.scanning;
  List<StakePosition> positions = [];
  Map<String, dynamic>? state;
  String? stateError;
  String? message;
  String? source;
  int scanned = 0;
  Duration elapsed = Duration.zero;
}

/// Candidate ids come from the active wallet's balances, never token names or
/// explorer labels. Pure Rust validates the boxes; this seam owns no parsing.
abstract class StakeRecoveryGateway {
  String? get walletId;
  String get network;
  String? get nodeUrl;
  String get explorerBase;
  String contracts();
  String state(String pool, String box);
  String positions(String pool, String boxes, String keys, String stateBox);
}

class LiveStakeRecoveryGateway implements StakeRecoveryGateway {
  const LiveStakeRecoveryGateway();
  @override
  String? get walletId => walletService.activeWalletId;
  // Argus currently exposes mainnet wallets only. Keep it in every cache key;
  // a future network selector must supply its selected network here.
  @override
  String get network => 'mainnet';
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  String get explorerBase => networkController.explorer;
  @override
  String contracts() => bridge.stakeRecoveryContracts();
  @override
  String state(String pool, String box) =>
      bridge.stakeRecoveryState(poolId: pool, boxJson: box);
  @override
  String positions(String pool, String boxes, String keys, String stateBox) =>
      bridge.stakeRecoveryPositions(
        poolId: pool,
        boxesJson: boxes,
        keysJson: keys,
        stateBoxJson: stateBox,
      );
}

typedef StakeScope = ({
  String? wallet,
  String network,
  String? node,
  String explorer,
});

/// Bounded, node-first discovery. A complete scan alone can establish absence.
/// Cache only positive, unambiguous matches from a completed scan. Never cache
/// negative results: retries must have another chance to find a moved position.
class StakeRecoveryService extends ChangeNotifier {
  StakeRecoveryService({
    StakeRecoveryGateway? gateway,
    http.Client? client,
    this.pageSize = 500,
    this.maxPages = 40,
  }) : assert(pageSize > 0 && pageSize <= 500),
       assert(maxPages > 0),
       _gw = gateway ?? const LiveStakeRecoveryGateway(),
       _client = client ?? http.Client();
  final StakeRecoveryGateway _gw;
  final http.Client _client;
  final int pageSize, maxPages;
  static const timeout = Duration(seconds: 45);
  static const ergopadExplorerFailure =
      'Ergopad scan failed on the configured explorer. Connect an indexed node or retry.';
  List<StakePool>? _pools;
  List<StakePool> get pools => _pools ??= [
    for (final m in jsonDecode(_gw.contracts()) as List)
      StakePool((m as Map).cast()),
  ];
  StakeScope get _scope => (
    wallet: _gw.walletId,
    network: _gw.network,
    node: _gw.nodeUrl,
    explorer: _gw.explorerBase,
  );
  StakeScope? _forScope;
  List<StakePoolResult> _results = [];
  List<StakePoolResult> get results =>
      _forScope == _scope ? List.unmodifiable(_results) : const [];
  int _generation = 0;
  bool _busy = false;
  bool get busy => _busy && _forScope == _scope;

  Future<dynamic> _request(
    Uri uri, {
    String? body,
    bool missingAllowed = false,
  }) async {
    final response =
        await (body == null
                ? _client.get(uri)
                : _client.post(
                    uri,
                    headers: const {'Content-Type': 'application/json'},
                    body: body,
                  ))
            .timeout(timeout);
    if (missingAllowed && response.statusCode == 404) return null;
    if (response.statusCode != 200)
      throw StateError('${uri.host} returned HTTP ${response.statusCode}');
    return jsonDecode(response.body);
  }

  String _base(String url) => url.replaceAll(RegExp(r'/+$'), '');
  List<dynamic> _items(dynamic body) {
    final items = body is List
        ? body
        : body is Map
        ? body['items']
        : null;
    if (items is! List) throw StateError('The server returned no box list');
    return items;
  }

  Future<String?> _indexedNode(StakeScope scope) async {
    if (scope.node == null) return null;
    final node = _base(scope.node!);
    try {
      final info = await _request(Uri.parse('$node/info'));
      if (info is! Map ||
          info['network'] != scope.network ||
          info['fullHeight'] is! int ||
          info['headersHeight'] is! int ||
          info['fullHeight'] <= 0 ||
          info['fullHeight'] < info['headersHeight'] ||
          (info['maxPeerHeight'] is int &&
              info['fullHeight'] < info['maxPeerHeight']))
        return null;
      final index = await _request(Uri.parse('$node/blockchain/indexedHeight'));
      if (index is! Map ||
          index['indexedHeight'] is! int ||
          index['fullHeight'] is! int ||
          index['fullHeight'] < info['fullHeight'] ||
          index['indexedHeight'] < index['fullHeight'])
        return null;
      return node;
    } catch (_) {
      return null; // An absent/lagging index must go to the configured explorer.
    }
  }

  String _cacheKey(StakeScope scope, StakePool pool, String key) =>
      'stake_recovery.v1.${scope.network}.${pool.id}.$key';

  Future<void> refresh(
    Set<String> candidateTokenIds, {
    bool walletTokensComplete = true,
  }) async {
    final scope = _scope;
    if (busy) return;
    final generation = ++_generation;
    _forScope = scope;
    _busy = true;
    _results = [
      for (final pool in pools)
        if (pool.active) StakePoolResult(pool),
    ];
    notifyListeners();
    bool current() => generation == _generation && scope == _scope;
    try {
      if (scope.wallet == null || scope.network != 'mainnet')
        throw StateError('Select a mainnet wallet to scan stakes');
      final keys = candidateTokenIds.map((s) => s.toLowerCase()).toSet();
      if (keys.any((s) => !RegExp(r'^[0-9a-f]{64}$').hasMatch(s)))
        throw StateError('Invalid wallet token id');
      final prefs = await SharedPreferences.getInstance();
      final node = await _indexedNode(scope);
      await Future.wait([
        for (final result in _results)
          _scanPool(result, keys, scope, node, prefs, current).then((_) {
            if (!walletTokensComplete &&
                result.status == StakeScanStatus.complete) {
              result.status = StakeScanStatus.incomplete;
              result.message =
                  'Wallet token balances were still loading, so more positions '
                  'may exist. Anything listed here can still be recovered.';
            }
            if (current()) notifyListeners();
          }),
      ]);
    } catch (e) {
      if (current()) {
        for (final result in _results) {
          result.status = StakeScanStatus.unavailable;
          result.message = '$e';
        }
      }
    } finally {
      if (generation == _generation) {
        _busy = false;
        if (!current()) {
          _forScope = null;
          _results = [];
        }
        notifyListeners();
      }
    }
  }

  Future<void> _scanPool(
    StakePoolResult result,
    Set<String> keys,
    StakeScope scope,
    String? node,
    SharedPreferences prefs,
    bool Function() current,
  ) async {
    final clock = Stopwatch()..start();
    final pool = result.pool;
    final explorer = _base(scope.explorer);
    String stateBox = '';
    // State failure is independent of discovering positions. A position remains
    // visible, with eligibility unknown, even if its state cannot be fetched.
    try {
      dynamic body;
      if (node != null) {
        try {
          body = await _request(
            Uri.parse(
              '$node/blockchain/box/unspent/byTokenId/${pool.stateNft}?offset=0&limit=2',
            ),
          );
        } catch (_) {
          /* explorer fallback */
        }
      }
      body ??= await _request(
        Uri.parse(
          '$explorer/api/v1/boxes/unspent/byTokenId/${pool.stateNft}?offset=0&limit=2',
        ),
      );
      final items = _items(body);
      if (items.length != 1 ||
          (body is Map && body['total'] is num && body['total'] != 1))
        throw StateError('Expected one unspent state NFT box');
      stateBox = jsonEncode(items.single);
      result.state = (jsonDecode(_gw.state(pool.id, stateBox)) as Map).cast();
    } catch (e) {
      stateBox = '';
      result.stateError = 'State unavailable: $e';
    }
    final found = <String, StakePosition>{};
    final ambiguous = <String>{};
    final unresolved = {...keys};
    var rejected = false;
    final failures = <String>[];
    void decode(List<dynamic> boxes, Set<String> candidates) {
      final decoded =
          jsonDecode(
                _gw.positions(
                  pool.id,
                  jsonEncode(boxes),
                  jsonEncode(candidates.toList()),
                  stateBox,
                ),
              )
              as Map;
      if ((decoded['rejected'] as List).isNotEmpty) rejected = true;
      ambiguous.addAll((decoded['ambiguous_keys'] as List).cast<String>());
      for (final m in decoded['positions'] as List) {
        final p = StakePosition((m as Map).cast());
        final previous = found[p.keyId];
        if (previous != null && previous.boxId != p.boxId)
          ambiguous.add(p.keyId);
        found[p.keyId] = p;
      }
      for (final key in ambiguous) {
        found.remove(key);
      }
      result.positions = found.values.toList()
        ..sort((a, b) => a.keyId.compareTo(b.keyId));
    }

    try {
      for (final key in keys) {
        if (!current()) return;
        final cached = prefs.getString(_cacheKey(scope, pool, key));
        if (cached == null) continue;
        try {
          // Exactly one unspent lookup. HTTP errors must not erase the cache or
          // become absence; only 404 or a decoded mismatch triggers rediscovery.
          final uri = node != null
              ? Uri.parse('$node/utxo/byId/$cached')
              : Uri.parse('$explorer/api/v1/boxes/unspent/byBoxId/$cached');
          final box = await _request(uri, missingAllowed: true);
          if (box != null) {
            final decoded =
                jsonDecode(
                      _gw.positions(
                        pool.id,
                        jsonEncode([box]),
                        jsonEncode([key]),
                        stateBox,
                      ),
                    )
                    as Map;
            final positions = decoded['positions'] as List;
            if (positions.length == 1 &&
                positions.single['box_id'] == cached &&
                positions.single['key_id'] == key &&
                (decoded['rejected'] as List).isEmpty &&
                (decoded['ambiguous_keys'] as List).isEmpty) {
              found[key] = StakePosition((positions.single as Map).cast());
              unresolved.remove(key);
              continue;
            }
          }
          await prefs.remove(_cacheKey(scope, pool, key));
        } catch (e) {
          unresolved.remove(
            key,
          ); // Retry this key next refresh, not as an absence.
          failures.add('Cached position could not be checked: $e');
        }
      }
      result.positions = found.values.toList();
      var complete = unresolved.isEmpty;
      if (unresolved.isNotEmpty) {
        // Restart paging at zero on fallback. Keep validated matches from an
        // interrupted source, but never infer absence from those partial pages.
        for (final (source, useNode) in [
          if (node != null) (node, true),
          (explorer, false),
        ]) {
          if (!current()) return;
          result.source = useNode ? 'node' : 'explorer';
          final seen = <String>{};
          try {
            for (var page = 0; page < maxPages; page++) {
              if (!current()) return;
              final offset = page * pageSize;
              final body = useNode
                  ? await _request(
                      Uri.parse(
                        '$source/blockchain/box/unspent/byErgoTree?offset=$offset&limit=$pageSize',
                      ),
                      body: jsonEncode(pool.tree),
                    )
                  : await _request(
                      Uri.parse(
                        '$source/api/v1/boxes/unspent/byAddress/${pool.address}?offset=$offset&limit=$pageSize',
                      ),
                    );
              final boxes = _items(body);
              result.scanned += boxes.length;
              if (boxes.length > pageSize)
                throw StateError('Oversized scan page');
              for (final box in boxes) {
                if (box is! Map ||
                    box['boxId'] is! String ||
                    !seen.add(box['boxId'] as String))
                  throw StateError('Repeated or malformed scan page');
              }
              decode(boxes, unresolved);
              if (current()) notifyListeners();
              // Do not trust a total to truncate paging. A short page is only
              // terminal if the server does not claim more boxes remain.
              if (boxes.length < pageSize) {
                if (body is Map &&
                    body['total'] is num &&
                    seen.length < body['total'])
                  throw StateError('Truncated scan page');
                complete = true;
                break;
              }
            }
            if (complete) break;
            failures.add(
              '${pool.name} scan reached the ${maxPages * pageSize}-box limit',
            );
          } catch (e) {
            if (useNode && seen.isNotEmpty) {
              failures.add(
                '${pool.name} node scan was interrupted; results may be incomplete',
              );
            }
            if (!useNode)
              failures.add(
                pool.id == 'ergopad'
                    ? ergopadExplorerFailure
                    : '${pool.name} scan failed on the configured explorer: $e',
              );
          }
        }
      }
      if (rejected) failures.add('Some boxes failed protocol validation');
      if (ambiguous.isNotEmpty)
        failures.add('Ambiguous positions were excluded');
      result.status = complete && failures.isEmpty
          ? StakeScanStatus.complete
          : result.scanned == 0 && found.isEmpty
          ? StakeScanStatus.unavailable
          : StakeScanStatus.incomplete;
      result.message = failures.isEmpty ? null : failures.join('\n');
      if (result.status == StakeScanStatus.complete && current()) {
        for (final p in found.values) {
          await prefs.setString(_cacheKey(scope, pool, p.keyId), p.boxId);
        }
      }
    } catch (e) {
      result.status = result.scanned > 0 || found.isNotEmpty
          ? StakeScanStatus.incomplete
          : StakeScanStatus.unavailable;
      result.message = '$e';
    } finally {
      result.elapsed = clock.elapsed;
    }
  }

  bool canCommit(Map<String, dynamic> prepared) =>
      prepared['wallet_id'] != null &&
      prepared['wallet_id'] == _gw.walletId &&
      prepared['network'] == _gw.network &&
      prepared['node'] == _gw.nodeUrl &&
      prepared['explorer'] == _gw.explorerBase;

  Future<Map<String, dynamic>> prepareDirect({
    required StakePoolResult result,
    required StakePosition position,
    required String userAddress,
    required List<String> spendAddresses,
    Future<String> Function(String state, String stake, String key)? prepare,
  }) async {
    final scope = _scope;
    if (scope.wallet == null ||
        scope.network != 'mainnet' ||
        !results.contains(result) ||
        result.pool.id != 'ergopad' ||
        position.eligible != true ||
        result.positions.where((p) => p.keyId == position.keyId).length != 1 ||
        !result.positions.contains(position) ||
        result.state == null) {
      throw StateError(
        'Scan this wallet again for an unambiguous recoverable Ergopad position',
      );
    }
    final stateId = result.state!['box_id'] as String;
    final node = await _indexedNode(scope);
    Future<dynamic> read(String id) => _request(
      Uri.parse(
        node == null
            ? '${_base(scope.explorer)}/api/v1/boxes/unspent/byBoxId/$id'
            : '$node/utxo/byId/$id',
      ),
      missingAllowed: true,
    );
    final stake = await read(position.boxId);
    if (stake == null)
      throw StateError(
        'StakeBox moved since the scan. Scan again; nothing was sent.',
      );
    final state = await read(stateId);
    if (state == null)
      throw StateError(
        'Pool state moved since the scan. Scan again; nothing was sent.',
      );
    final decoded =
        jsonDecode(
              _gw.positions(
                'ergopad',
                jsonEncode([stake]),
                jsonEncode([position.keyId]),
                jsonEncode(state),
              ),
            )
            as Map;
    final positions = decoded['positions'] as List;
    if ((decoded['rejected'] as List).isNotEmpty ||
        (decoded['ambiguous_keys'] as List).isNotEmpty ||
        positions.length != 1 ||
        positions.single['box_id'] != position.boxId ||
        positions.single['key_id'] != position.keyId ||
        positions.single['eligible'] != true) {
      throw StateError(
        'Recovery inputs no longer match. Scan again; nothing was sent.',
      );
    }
    if (scope != _scope)
      throw StateError('The wallet or network changed; nothing was sent');
    final raw = await (prepare != null
        ? prepare(jsonEncode(state), jsonEncode(stake), position.keyId)
        : walletService.stakeRecoveryPrepareDirect(
            stateBoxJson: jsonEncode(state),
            stakeBoxJson: jsonEncode(stake),
            keyId: position.keyId,
            userAddress: userAddress,
            spendAddresses: spendAddresses,
            nodeUrl: scope.node,
          ));
    final prepared = (jsonDecode(raw) as Map).cast<String, dynamic>()
      ..['wallet_id'] = scope.wallet
      ..['network'] = scope.network
      ..['node'] = scope.node
      ..['explorer'] = scope.explorer;
    if (!canCommit(prepared))
      throw StateError('The wallet or network changed; nothing was sent');
    return prepared;
  }

  /// Called after confirmation, immediately before native signing. Native
  /// commit repeats UTXO checks and runs transactions/check before broadcast.
  Future<void> revalidateCommit(Map<String, dynamic> prepared) async {
    if (!canCommit(prepared))
      throw StateError('The wallet or network changed; nothing was sent');
    final scope = _scope;
    final node = await _indexedNode(scope);
    final inputs = (prepared['unsigned_tx'] as Map)['inputs'] as List;
    for (var i = 0; i < inputs.length; i++) {
      final id = inputs[i]['boxId'] as String;
      final box = await _request(
        Uri.parse(
          node == null
              ? '${_base(scope.explorer)}/api/v1/boxes/unspent/byBoxId/$id'
              : '$node/utxo/byId/$id',
        ),
        missingAllowed: true,
      );
      if (box == null || box['boxId'] != id) {
        throw StateError(
          '${i == 1 ? 'StakeBox' : 'Recovery input'} moved since preparation. Scan again; nothing was sent.',
        );
      }
    }
    if (!canCommit(prepared))
      throw StateError('The wallet or network changed; nothing was sent');
  }

  @override
  void dispose() {
    ++_generation;
    _client.close();
    super.dispose();
  }
}

final stakeRecoveryService = StakeRecoveryService();
