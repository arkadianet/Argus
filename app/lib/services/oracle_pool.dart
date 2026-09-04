import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sigma_registers.dart';

/// Reader for the AVL Multi-Oracle Pool (github.com/cannonQ/AVL-Multi-Oracle-Ergo-Pool).
///
/// The pool box only carries an AVL digest, so instead of the tree we read
/// the operators' data-point boxes: each holds a `Coll[Long]` of every feed
/// in micro-dollars in R6 and the epoch it was posted for in R5. Taking the
/// per-feed median across the boxes posted for the current epoch reproduces
/// what the refresh contract writes into the tree, with no proof server.
class OraclePool {
  static const poolNft = 'f7f008ad8fcaad4490d8e78ab6d3f11efe7213a13f7b243795818b155e1acc92';
  static const oracleToken = 'e5abaf1f0a9442123104cdf4d2d56ddd8065803e842bc6d433e712601133a9bc';

  /// Feed order in the operators' vector (consumer-guide.md, "Feed List").
  static const feeds = <String>[
    'ETH_USD', 'BTC_USD', 'BNB_USD', 'DOGE_USD', 'ADA_USD', 'HNS_USD', 'CKB_USD',
    'ATOM_USD', 'RON_USD', 'SPX', 'DJI', 'XAG_USD', 'XCU_USD', 'BRENT_USD',
    'WTI_USD', 'NGAS_USD', 'LITHIUM_USD', 'ERG_USD', 'XAU_USD', 'FIRO_USD',
  ];

  /// Prices are stored as USD × 1,000,000.
  static const priceScale = 1000000;

  /// A pool refresh older than this many blocks is reported as stale.
  static const staleAfterBlocks = 60;

  /// Prices more than this many epochs behind the pool are reported as
  /// stale, but still used: an old price beats no price at all.
  static const staleAfterEpochs = 4;
}

/// One decoded snapshot: feed symbol → USD.
class OracleSnapshot {
  const OracleSnapshot({
    required this.epoch,
    required this.poolHeight,
    required this.operators,
    required this.usd,
    int? poolEpoch,
  }) : poolEpoch = poolEpoch ?? epoch;

  /// The epoch the prices were actually published for.
  final int epoch;

  /// The epoch the pool box is on, which operators may not have reached.
  final int poolEpoch;

  /// How many epochs behind the pool these prices are.
  int get epochsBehind => poolEpoch - epoch;

  final int poolHeight;

  /// How many operator data points the medians were taken over.
  final int operators;
  final Map<String, double> usd;

  double? operator [](String feed) => usd[feed];

  /// Stale when the pool itself has not refreshed recently, or when the
  /// operators' newest vector is well behind the pool's epoch.
  bool isStale(int? tipHeight) {
    if (epochsBehind > OraclePool.staleAfterEpochs) return true;
    return tipHeight != null && tipHeight - poolHeight > OraclePool.staleAfterBlocks;
  }
}

/// Pure aggregation over node box JSON. Returns null when the pool box is
/// missing or no operator posted a vector for the current epoch.
///
/// Operators post their vector after each refresh with R5 equal to the
/// pool's epoch counter; the refresh that consumes them bumps the counter.
/// Right after a refresh there may be no posts yet, so vectors from the
/// previous epoch are accepted as a fallback, and the newest epoch present
/// wins.
OracleSnapshot? aggregateOracle({
  required Map<String, dynamic>? poolBox,
  required List<Map<String, dynamic>> oracleBoxes,
}) {
  if (poolBox == null) return null;
  final regs = (poolBox['additionalRegisters'] as Map?)?.cast<String, dynamic>() ?? const {};
  final epoch = decodeSigmaInt(regs['R4'] as String? ?? '');
  if (epoch == null) return null;
  final feedCount = decodeSigmaInt(regs['R6'] as String? ?? '') ?? OraclePool.feeds.length;
  final poolHeight = (poolBox['creationHeight'] as num?)?.toInt() ?? 0;

  final byEpoch = <int, List<List<int>>>{};
  for (final b in oracleBoxes) {
    final r = (b['additionalRegisters'] as Map?)?.cast<String, dynamic>() ?? const {};
    final e = decodeSigmaInt(r['R5'] as String? ?? '');
    final v = decodeSigmaLongColl(r['R6'] as String? ?? '');
    if (e == null || v == null || v.length < feedCount) continue;
    // Operators post when they post. Requiring the pool's exact epoch, or
    // the one before it, threw away a perfectly good vector whenever they
    // were a few epochs behind — and with no ERG price the whole wallet
    // shows nothing priced. Take the newest epoch they have actually
    // published, up to the pool's, and report how far back it is.
    if (e > epoch) continue;
    byEpoch.putIfAbsent(e, () => []).add(v);
  }
  if (byEpoch.isEmpty) return null;
  final useEpoch = byEpoch.keys.reduce((a, b) => a > b ? a : b);
  final vectors = byEpoch[useEpoch]!;

  final usd = <String, double>{};
  for (var i = 0; i < OraclePool.feeds.length && i < feedCount; i++) {
    final values = vectors.map((v) => v[i]).where((x) => x > 0).toList()..sort();
    if (values.isEmpty) continue;
    final mid = values.length ~/ 2;
    final median = values.length.isOdd
        ? values[mid].toDouble()
        : (values[mid - 1] + values[mid]) / 2;
    usd[OraclePool.feeds[i]] = median / OraclePool.priceScale;
  }
  return OracleSnapshot(
    epoch: useEpoch,
    poolEpoch: epoch,
    poolHeight: poolHeight,
    operators: vectors.length,
    usd: usd,
  );
}

/// Fetches the pool and operator boxes from a node's blockchain API.
class OraclePoolClient {
  OraclePoolClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<List<Map<String, dynamic>>> _boxes(String node, String tokenId, int limit) async {
    final res = await _client
        .get(Uri.parse('$node/blockchain/box/unspent/byTokenId/$tokenId?offset=0&limit=$limit'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('node returned ${res.statusCode}');
    final body = jsonDecode(res.body);
    final items = body is List ? body : (body as Map)['items'] as List? ?? const [];
    return items.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  Future<OracleSnapshot?> fetch(String nodeUrl) async {
    final node = nodeUrl.replaceAll(RegExp(r'/$'), '');
    final pool = await _boxes(node, OraclePool.poolNft, 1);
    final oracles = await _boxes(node, OraclePool.oracleToken, 50);
    return aggregateOracle(poolBox: pool.isEmpty ? null : pool.first, oracleBoxes: oracles);
  }
}
