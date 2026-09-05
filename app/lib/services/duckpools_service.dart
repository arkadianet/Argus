import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../bridge/api.dart' as bridge;
import 'network_controller.dart';

/// One Duckpools lending pool as deployed.
class DuckPool {
  const DuckPool({
    required this.key,
    required this.ticker,
    required this.decimals,
    required this.poolNft,
    required this.lendToken,
    required this.borrowToken,
    required this.currencyId,
    required this.ergoTree,
  });

  final String key;
  final String ticker;
  final int decimals;
  final String poolNft;
  final String lendToken;
  final String borrowToken;

  /// Null for the ERG pool.
  final String? currencyId;
  final String ergoTree;

  static DuckPool fromJson(Map<String, dynamic> m) => DuckPool(
        key: m['key'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        poolNft: m['pool_nft'] as String,
        lendToken: m['lend_token'] as String,
        borrowToken: m['borrow_token'] as String,
        currencyId: m['currency_id'] as String?,
        ergoTree: m['ergo_tree'] as String,
      );
}

/// A pool right now, and what the wallet holds in it.
class DuckPoolState {
  const DuckPoolState({
    required this.pool,
    required this.ticker,
    required this.decimals,
    required this.lendToken,
    required this.boxId,
    required this.pooled,
    required this.borrowed,
    required this.lendCirculating,
    required this.utilisationBps,
    required this.lendTokenPrice,
    required this.walletLendTokens,
    required this.walletValue,
  });

  final String pool;
  final String ticker;
  final int decimals;
  final String lendToken;
  final String boxId;

  /// Asset units in the pool box.
  final int pooled;

  /// Asset units out on loan (principal).
  final int borrowed;
  final int lendCirculating;

  /// Share of lenders' assets lent out, in basis points.
  final int utilisationBps;

  /// Asset units per lend token, for display.
  final double lendTokenPrice;

  /// The wallet's lend tokens and what they redeem for today.
  final int walletLendTokens;
  final int walletValue;

  bool get hasPosition => walletLendTokens > 0;
  int get totalAssets => pooled + borrowed;

  static DuckPoolState fromJson(Map<String, dynamic> m) => DuckPoolState(
        pool: m['pool'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        lendToken: m['lend_token'] as String,
        boxId: m['box_id'] as String,
        pooled: (m['pooled'] as num).toInt(),
        borrowed: (m['borrowed'] as num).toInt(),
        lendCirculating: (m['lend_circulating'] as num).toInt(),
        utilisationBps: (m['utilisation_bps'] as num).toInt(),
        lendTokenPrice: (m['lend_token_price'] as num).toDouble(),
        walletLendTokens: (m['wallet_lend_tokens'] as num).toInt(),
        walletValue: (m['wallet_value'] as num).toInt(),
      );
}

/// The Rust side, behind a seam so the service can be tested without it.
abstract class DuckpoolsGateway {
  String? get nodeUrl;
  String get explorerBase;
  String pools();
  String state(String poolBoxesJson, String holdingsJson);
}

class LiveDuckpoolsGateway implements DuckpoolsGateway {
  const LiveDuckpoolsGateway();
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  String get explorerBase => networkController.explorer;
  @override
  String pools() => bridge.duckpoolsPools();
  @override
  String state(String poolBoxesJson, String holdingsJson) =>
      bridge.duckpoolsState(poolBoxesJson: poolBoxesJson, holdingsJson: holdingsJson);
}

typedef DuckHttpGet = Future<String> Function(Uri uri);
typedef DuckHttpPost = Future<String> Function(Uri uri, String jsonBody);

const _timeout = Duration(seconds: 45);

Future<String> _httpGet(Uri uri) async {
  final res = await http.get(uri).timeout(_timeout);
  if (res.statusCode != 200) throw StateError('${uri.host} returned HTTP ${res.statusCode}');
  return res.body;
}

Future<String> _httpPost(Uri uri, String body) async {
  final res = await http
      .post(uri, headers: const {'Content-Type': 'application/json'}, body: body)
      .timeout(_timeout);
  if (res.statusCode != 200) throw StateError('${uri.host} returned HTTP ${res.statusCode}');
  return res.body;
}

/// Reads the eight Duckpools pools and values the lend tokens this wallet
/// holds. Read-only: no orders yet.
class DuckpoolsService extends ChangeNotifier {
  DuckpoolsService({DuckpoolsGateway? gateway, DuckHttpGet? get, DuckHttpPost? post})
      : _gw = gateway ?? const LiveDuckpoolsGateway(),
        _get = get ?? _httpGet,
        _post = post ?? _httpPost;

  final DuckpoolsGateway _gw;
  final DuckHttpGet _get;
  final DuckHttpPost _post;

  List<DuckPool>? _pools;

  /// The pools as deployed.
  List<DuckPool> get pools => _pools ??= [
        for (final m in (jsonDecode(_gw.pools()) as List)) DuckPool.fromJson((m as Map).cast()),
      ];

  /// Lend token ids, for spotting positions in a balance.
  List<String> get lendTokenIds => [for (final p in pools) p.lendToken];

  /// Last successful read, in the pools' order.
  List<DuckPoolState> states = const [];
  DateTime? lastRefreshedAt;
  String? lastError;
  bool _busy = false;
  bool get busy => _busy;

  /// Pools the wallet holds lend tokens in.
  List<DuckPoolState> get positions => states.where((s) => s.hasPosition).toList();

  /// "You lend 1.002 ERG · 12.5 SigUSD" or null.
  String? positionLine(String Function(int amount, int decimals) fmt) {
    final parts = [
      for (final s in positions) '${fmt(s.walletValue, s.decimals)} ${s.ticker}',
    ];
    if (parts.isEmpty) return null;
    return 'You lend ${parts.take(2).join(' · ')}';
  }

  /// Read every pool's boxes, node first (by script), explorer when the
  /// node cannot answer, and value `holdings` (token id to amount). The
  /// Rust side picks the real pool box among what sits under a script:
  /// the one carrying the pool NFT exactly once.
  Future<void> refresh(Map<String, int> holdings) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      // Every pool at once: one slow explorer answer must not hold the
      // others, or `_busy`, for its whole timeout.
      final results = await Future.wait([
        for (final p in pools)
          _boxesUnderScript(p).then<(DuckPool, List<dynamic>?, Object?)>(
            (b) => (p, b, null),
            onError: (Object e) => (p, null, e),
          ),
      ]);
      final boxes = <dynamic>[];
      final failures = <String>[];
      final read = <String>{};
      for (final (p, b, e) in results) {
        if (b != null) {
          boxes.addAll(b);
          read.add(p.key);
        } else {
          failures.add('${p.ticker}: $e');
        }
      }
      if (read.isEmpty) {
        throw StateError(failures.first);
      }
      final raw = _gw.state(jsonEncode(boxes), jsonEncode(holdings));
      final fresh = {
        for (final m in (jsonDecode(raw) as List)) (m as Map)['pool'] as String: DuckPoolState.fromJson(m.cast()),
      };
      // A pool that could not be read keeps its last state rather than
      // vanishing, and the failure is reported alongside the fresh data.
      final prior = {for (final s in states) s.pool: s};
      states = [
        for (final p in pools)
          if (fresh[p.key] != null || (!read.contains(p.key) && prior[p.key] != null)) (fresh[p.key] ?? prior[p.key])!,
      ];
      lastError = failures.isEmpty ? null : 'Some pools could not be read: ${failures.join('; ')}';
      lastRefreshedAt = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Unspent boxes under the pool's script. A node that answers, even
  /// with an empty list, is believed; only a node that cannot answer
  /// sends the query to the explorer.
  Future<List<dynamic>> _boxesUnderScript(DuckPool p) async {
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final decoded = jsonDecode(await _post(
          Uri.parse('$node/blockchain/box/unspent/byErgoTree?offset=0&limit=20'),
          jsonEncode(p.ergoTree),
        ));
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['items'] is List) return decoded['items'] as List;
      } catch (_) {
        // Fall through to the explorer.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final body = jsonDecode(
      await _get(Uri.parse('$base/api/v1/boxes/unspent/byErgoTree/${p.ergoTree}?offset=0&limit=20')),
    );
    if (body is Map && body['items'] is List) return body['items'] as List;
    throw StateError('${Uri.parse(base).host} returned no box list');
  }
}

final duckpoolsService = DuckpoolsService();
