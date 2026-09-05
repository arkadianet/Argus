import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../bridge/api.dart' as bridge;
import 'package:shared_preferences/shared_preferences.dart';

import 'network_controller.dart';
import 'wallet_service.dart';

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
    required this.interestParamNft,
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
  final String interestParamNft;

  static DuckPool fromJson(Map<String, dynamic> m) => DuckPool(
        key: m['key'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        poolNft: m['pool_nft'] as String,
        lendToken: m['lend_token'] as String,
        borrowToken: m['borrow_token'] as String,
        currencyId: m['currency_id'] as String?,
        ergoTree: m['ergo_tree'] as String,
        interestParamNft: m['interest_param_nft'] as String? ?? '',
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
    this.borrowAprBps,
    this.lendAprBps,
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

  /// Yearly rates in basis points, when the interest boxes were read.
  final int? borrowAprBps;
  final int? lendAprBps;

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
        borrowAprBps: (m['borrow_apr_bps'] as num?)?.toInt(),
        lendAprBps: (m['lend_apr_bps'] as num?)?.toInt(),
      );
}

/// An order this wallet posted: a proxy box a bot fills, or that comes
/// back after its refund height.
class DuckOrder {
  DuckOrder({
    required this.kind,
    required this.pool,
    required this.ticker,
    required this.decimals,
    required this.proxyBoxId,
    required this.txId,
    required this.amount,
    required this.expected,
    required this.minOut,
    required this.refundHeight,
    required this.createdAt,
    this.status = 'pending',
    this.outcomeTxId,
    this.received,
    this.lastError,
  });

  /// `lend` or `withdraw`.
  final String kind;
  final String pool;
  final String ticker;
  final int decimals;
  final String proxyBoxId;
  final String txId;

  /// Asset units in (lend) or lend tokens in (withdraw).
  final int amount;

  /// Lend tokens (lend) or asset units (withdraw) expected at the quote.
  final int expected;
  final int minOut;
  final int refundHeight;
  final DateTime createdAt;

  /// `pending`, `refundable`, `filled`, `refunded`, `refund_sent`.
  String status;
  String? outcomeTxId;
  int? received;
  String? lastError;

  bool get open => status == 'pending' || status == 'refundable' || status == 'refund_sent';

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'pool': pool,
        'ticker': ticker,
        'decimals': decimals,
        'proxy_box_id': proxyBoxId,
        'tx_id': txId,
        'amount': amount,
        'expected': expected,
        'min_out': minOut,
        'refund_height': refundHeight,
        'created_at': createdAt.millisecondsSinceEpoch,
        'status': status,
        if (outcomeTxId != null) 'outcome_tx_id': outcomeTxId,
        if (received != null) 'received': received,
        if (lastError != null) 'last_error': lastError,
      };

  static DuckOrder fromJson(Map<String, dynamic> m) => DuckOrder(
        kind: m['kind'] as String,
        pool: m['pool'] as String,
        ticker: m['ticker'] as String,
        decimals: (m['decimals'] as num).toInt(),
        proxyBoxId: m['proxy_box_id'] as String,
        txId: m['tx_id'] as String,
        amount: (m['amount'] as num).toInt(),
        expected: (m['expected'] as num).toInt(),
        minOut: (m['min_out'] as num).toInt(),
        refundHeight: (m['refund_height'] as num).toInt(),
        createdAt: DateTime.fromMillisecondsSinceEpoch((m['created_at'] as num).toInt()),
        status: m['status'] as String? ?? 'pending',
        outcomeTxId: m['outcome_tx_id'] as String?,
        received: (m['received'] as num?)?.toInt(),
        lastError: m['last_error'] as String?,
      );
}

/// The Rust side, behind a seam so the service can be tested without it.
abstract class DuckpoolsGateway {
  String? get nodeUrl;
  String get explorerBase;
  String? get walletId;
  bool get isUnlocked;
  int? get chainHeight;
  String pools();
  String state(String poolBoxesJson, String holdingsJson, String interestBoxesJson);
  String quote(String poolBoxesJson, String poolKey, String kind, int amount, int slippageBps, int refundHeight);
  Future<String> prepareOrder({
    required String poolBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required int slippageBps,
    required int refundAfterBlocks,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
  });
  Future<String> prepareRefund(String proxyBoxJson, String userAddress);
  String orderOutcome(String proxyBoxId, String txJson);
}

class LiveDuckpoolsGateway implements DuckpoolsGateway {
  const LiveDuckpoolsGateway();
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  String get explorerBase => networkController.explorer;
  @override
  String? get walletId => walletService.activeWalletId;
  @override
  bool get isUnlocked => walletService.isUnlocked;
  @override
  int? get chainHeight => networkController.height;
  @override
  String pools() => bridge.duckpoolsPools();
  @override
  String state(String poolBoxesJson, String holdingsJson, String interestBoxesJson) => bridge.duckpoolsState(
        poolBoxesJson: poolBoxesJson,
        holdingsJson: holdingsJson,
        interestBoxesJson: interestBoxesJson,
      );
  @override
  String quote(String poolBoxesJson, String poolKey, String kind, int amount, int slippageBps, int refundHeight) =>
      bridge.duckpoolsQuote(
        poolBoxesJson: poolBoxesJson,
        poolKey: poolKey,
        kind: kind,
        amount: amount,
        slippageBps: slippageBps,
        refundHeight: refundHeight,
      );
  @override
  Future<String> prepareOrder({
    required String poolBoxesJson,
    required String poolKey,
    required String kind,
    required int amount,
    required int slippageBps,
    required int refundAfterBlocks,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
  }) =>
      walletService.duckpoolsPrepareOrder(
        poolBoxesJson: poolBoxesJson,
        poolKey: poolKey,
        kind: kind,
        amount: amount,
        slippageBps: slippageBps,
        refundAfterBlocks: refundAfterBlocks,
        userAddress: userAddress,
        spendAddresses: spendAddresses,
        changeAddress: changeAddress,
      );
  @override
  Future<String> prepareRefund(String proxyBoxJson, String userAddress) =>
      walletService.duckpoolsPrepareRefund(proxyBoxJson: proxyBoxJson, userAddress: userAddress);
  @override
  String orderOutcome(String proxyBoxId, String txJson) =>
      bridge.duckpoolsOrderOutcome(proxyBoxId: proxyBoxId, txJson: txJson);
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

  /// The pool boxes of the last read, for quoting and building orders
  /// without another round trip.
  String? lastPoolBoxesJson;

  /// Orders of the loaded wallet, newest first.
  List<DuckOrder> orders = const [];
  String? _walletId;
  static String _ordersKey(String walletId) => 'argus_duck_orders_v1_$walletId';

  List<DuckOrder> get openOrders => orders.where((o) => o.open).toList();

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

  /// Load this wallet's orders.
  Future<void> load() async {
    _walletId = _gw.walletId;
    final id = _walletId;
    if (id == null) {
      orders = const [];
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_ordersKey(id));
    orders = raw == null
        ? const []
        : [for (final m in (jsonDecode(raw) as List)) DuckOrder.fromJson((m as Map).cast())];
    notifyListeners();
  }

  void reset() {
    _walletId = null;
    orders = const [];
    notifyListeners();
  }

  Future<void> _persistOrders() async {
    final id = _walletId;
    if (id == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ordersKey(id), jsonEncode([for (final o in orders) o.toJson()]));
    notifyListeners();
  }

  /// Read every pool's boxes, node first (by script), explorer when the
  /// node cannot answer, the interest parameter boxes for the rates, and
  /// value `holdings` (token id to amount). The Rust side picks the real
  /// pool box among what sits under a script: the one carrying the pool
  /// NFT exactly once.
  Future<void> refresh(Map<String, int> holdings) async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      final boxes = <dynamic>[];
      final failures = <String>[];
      for (final p in pools) {
        try {
          boxes.addAll(await _boxesUnderScript(p));
        } catch (e) {
          failures.add('${p.ticker}: $e');
        }
      }
      if (boxes.isEmpty && failures.isNotEmpty) {
        throw StateError(failures.first);
      }
      // The parameter boxes share one script and are few; a failure here
      // only costs the rates.
      final params = <dynamic>[];
      for (final p in pools) {
        try {
          params.addAll(await _boxesByToken(p.interestParamNft));
        } catch (_) {
          // No rate for this pool this time.
        }
      }
      lastPoolBoxesJson = jsonEncode(boxes);
      final raw = _gw.state(lastPoolBoxesJson!, jsonEncode(holdings), jsonEncode(params));
      states = [
        for (final m in (jsonDecode(raw) as List)) DuckPoolState.fromJson((m as Map).cast()),
      ];
      lastError = null;
      lastRefreshedAt = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Unspent boxes carrying `tokenId`: node first, explorer second.
  Future<List<dynamic>> _boxesByToken(String tokenId) async {
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final decoded = jsonDecode(await _get(Uri.parse('$node/blockchain/box/unspent/byTokenId/$tokenId?offset=0&limit=10')));
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['items'] is List) return decoded['items'] as List;
      } catch (_) {
        // Fall through.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final body = jsonDecode(await _get(Uri.parse('$base/api/v1/boxes/unspent/byTokenId/$tokenId?offset=0&limit=10')));
    if (body is Map && body['items'] is List) return body['items'] as List;
    throw StateError('no box list');
  }

  /// A box by id with its `spentTransactionId`, or null when neither the
  /// node nor the explorer knows it. Only a body that is the box counts.
  Future<Map<String, dynamic>?> _boxById(String id) async {
    Map<String, dynamic>? accept(String body) {
      final d = jsonDecode(body);
      return d is Map && d['boxId'] == id ? d.cast<String, dynamic>() : null;
    }

    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final b = accept(await _get(Uri.parse('$node/blockchain/box/byId/$id')));
        if (b != null) return b;
      } catch (_) {
        // Fall through.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    try {
      return accept(await _get(Uri.parse('$base/api/v1/boxes/$id')));
    } catch (_) {
      return null;
    }
  }

  /// A transaction by id, or null. Only a body with outputs counts.
  Future<Map<String, dynamic>?> _txById(String id) async {
    Map<String, dynamic>? accept(String body) {
      final d = jsonDecode(body);
      return d is Map && d['outputs'] is List ? d.cast<String, dynamic>() : null;
    }

    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node != null) {
      try {
        final t = accept(await _get(Uri.parse('$node/blockchain/transaction/byId/$id')));
        if (t != null) return t;
      } catch (_) {
        // Fall through.
      }
    }
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    try {
      return accept(await _get(Uri.parse('$base/api/v1/transactions/$id')));
    } catch (_) {
      return null;
    }
  }

  Future<int?> _height() async {
    final known = _gw.chainHeight;
    if (known != null && known > 0) return known;
    final node = _gw.nodeUrl?.replaceAll(RegExp(r'/+$'), '');
    if (node == null) return null;
    try {
      final info = jsonDecode(await _get(Uri.parse('$node/info'))) as Map;
      return (info['fullHeight'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// A quote at the last read pool state. `amount` is asset units for a
  /// lend, lend tokens for a withdraw.
  Map<String, dynamic> quote({
    required String poolKey,
    required String kind,
    required int amount,
    int slippageBps = 100,
  }) {
    final boxes = lastPoolBoxesJson;
    if (boxes == null) throw StateError('Read the pools first');
    return (jsonDecode(_gw.quote(boxes, poolKey, kind, amount, slippageBps, 0)) as Map).cast<String, dynamic>();
  }

  /// Prepare an order. The result carries `preparation_id` for the confirm
  /// sheet and everything [commitOrder] needs.
  Future<Map<String, dynamic>> prepareOrder({
    required String poolKey,
    required String kind,
    required int amount,
    required String userAddress,
    required List<String> spendAddresses,
    required String changeAddress,
    int slippageBps = 100,
    int refundAfterBlocks = 720,
  }) async {
    final boxes = lastPoolBoxesJson;
    if (boxes == null) throw StateError('Read the pools first');
    final raw = await _gw.prepareOrder(
      poolBoxesJson: boxes,
      poolKey: poolKey,
      kind: kind,
      amount: amount,
      slippageBps: slippageBps,
      refundAfterBlocks: refundAfterBlocks,
      userAddress: userAddress,
      spendAddresses: spendAddresses,
      changeAddress: changeAddress,
    );
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  /// Record a broadcast order.
  Future<DuckOrder> commitOrder(Map<String, dynamic> prepared, String txId) async {
    final q = (prepared['quote'] as Map).cast<String, dynamic>();
    final kind = q['kind'] as String;
    final pool = pools.firstWhere((p) => p.key == q['pool']);
    final order = DuckOrder(
      kind: kind,
      pool: pool.key,
      ticker: pool.ticker,
      decimals: pool.decimals,
      proxyBoxId: prepared['proxy_box_id'] as String,
      txId: txId,
      amount: (kind == 'lend' ? q['amount'] : q['lend_tokens']) as int,
      expected: (kind == 'lend' ? q['lend_tokens_expected'] : q['out']) as int,
      minOut: (kind == 'lend' ? q['min_lend_tokens'] : q['min_out']) as int,
      refundHeight: (prepared['refund_height'] as num).toInt(),
      createdAt: DateTime.now(),
    );
    orders = [order, ...orders];
    await _persistOrders();
    return order;
  }

  /// Look at every open order once: still unspent (and refundable once
  /// past its height), filled, or refunded. Never throws.
  Future<void> tickOrders() async {
    if (openOrders.isEmpty || _walletId == null) return;
    final height = await _height();
    var changed = false;
    for (final o in openOrders) {
      try {
        final box = await _boxById(o.proxyBoxId);
        if (box == null) {
          // Not seen yet, or the node forgot it: leave the status alone.
          continue;
        }
        final spentBy = box['spentTransactionId']?.toString();
        if (spentBy == null || spentBy.isEmpty) {
          final next = (height != null && height >= o.refundHeight) ? 'refundable' : 'pending';
          if (o.status == 'refund_sent') continue;
          if (o.status != next) {
            o.status = next;
            changed = true;
          }
          continue;
        }
        final tx = await _txById(spentBy);
        if (tx == null) continue;
        final outcome = (jsonDecode(_gw.orderOutcome(o.proxyBoxId, jsonEncode(tx))) as Map).cast<String, dynamic>();
        final kind = outcome['outcome'] as String? ?? 'unknown';
        if (kind == 'filled') {
          o.status = 'filled';
          o.outcomeTxId = spentBy;
          final assets = (outcome['assets'] as List? ?? const []).cast<Map>();
          o.received = o.kind == 'lend'
              ? int.tryParse(assets.firstWhere((a) => a['token_id'] == pools.firstWhere((p) => p.key == o.pool).lendToken, orElse: () => {'amount': '0'})['amount'].toString())
              : (outcome['value'] as num?)?.toInt();
          changed = true;
        } else if (kind == 'refunded') {
          o.status = 'refunded';
          o.outcomeTxId = spentBy;
          changed = true;
        }
        o.lastError = null;
      } catch (e) {
        o.lastError = e.toString();
        changed = true;
      }
    }
    if (changed) await _persistOrders();
  }

  /// Prepare the refund of a refundable order. The proxy box is read
  /// fresh; the contract lets anyone build this, but only to the user.
  Future<Map<String, dynamic>> prepareRefund(DuckOrder o, {required String userAddress}) async {
    final box = await _boxById(o.proxyBoxId);
    if (box == null) throw StateError('The order box could not be found on chain');
    if ((box['spentTransactionId']?.toString() ?? '').isNotEmpty) {
      throw StateError('The order was already spent; the next check will say how');
    }
    final raw = await _gw.prepareRefund(jsonEncode(box), userAddress);
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<void> markRefundSent(DuckOrder o, String txId) async {
    o.status = 'refund_sent';
    o.outcomeTxId = txId;
    await _persistOrders();
  }

  Future<void> removeOrder(DuckOrder o) async {
    if (o.open) throw StateError('This order is still open');
    orders = orders.where((x) => x.proxyBoxId != o.proxyBoxId).toList();
    await _persistOrders();
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
