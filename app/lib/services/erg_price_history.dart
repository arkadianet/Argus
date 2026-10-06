import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'oracle_pool.dart';
import 'sigma_registers.dart';

/// How far back an ERG price chart reaches.
enum PriceWindow {
  day('24h', Duration(hours: 24), 1),
  week('7d', Duration(days: 7), 7),
  month('30d', Duration(days: 30), 30);

  const PriceWindow(this.label, this.span, this.coingeckoDays);
  final String label;
  final Duration span;

  /// The `days` CoinGecko's market chart takes for this window.
  final int coingeckoDays;

  /// Blocks in this window at Ergo's two-minute target.
  int get blocks => span.inMinutes ~/ minutesPerBlock;
}

/// Ergo's target block interval. Node history is indexed by height, so
/// heights become times at this rate.
const minutesPerBlock = 2;

/// The long-standing ERG/SigUSD Spectrum pool, used when the pool set has
/// not told the pricer which SigUSD pool is deepest.
const ergSigUsdPoolNft = '9916d75132593c8b07fe18bd8d583bda1652eed7565cf41a4738ddd90fc992ec';

class PricePoint {
  const PricePoint(this.at, this.price);
  final DateTime at;

  /// Display currency per ERG.
  final double price;
}

/// ERG's price over a window, from the source the user picked in Display
/// settings, or why it could not be read.
class ErgPriceHistory {
  const ErgPriceHistory({
    required this.window,
    required this.points,
    required this.sourceLabel,
    required this.currency,
    this.change24hPct,
    this.approximateTimes = false,
    this.stale = false,
  }) : unavailableReason = null;

  const ErgPriceHistory.unavailable({
    required this.window,
    required this.sourceLabel,
    required this.currency,
    required String reason,
  })  : points = const [],
        change24hPct = null,
        approximateTimes = false,
        stale = false,
        unavailableReason = reason;

  final PriceWindow window;

  /// Oldest first.
  final List<PricePoint> points;

  /// Percent change over the last 24 hours, when the history reaches back
  /// that far.
  final double? change24hPct;
  final String sourceLabel;

  /// Lower-case display currency code, e.g. `usd`.
  final String currency;

  /// True when times were derived from block heights at two minutes a
  /// block rather than read from the source.
  final bool approximateTimes;

  /// The newest point is older than the source normally publishes (the
  /// oracle stopped posting, for one).
  final bool stale;

  /// Why there is no history, or null when there is.
  final String? unavailableReason;

  bool get available => unavailableReason == null;
}

/// A price at a block height, in USD per ERG.
typedef HeightPrice = (int height, double usd);

int? _height(Map<String, dynamic> box) =>
    (box['inclusionHeight'] as num?)?.toInt() ?? (box['creationHeight'] as num?)?.toInt();

double? _median(List<double> values) {
  if (values.isEmpty) return null;
  final v = [...values]..sort();
  final mid = v.length ~/ 2;
  return v.length.isOdd ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}

/// ERG/USD per epoch from oracle operator boxes: the median of the ERG_USD
/// entry across the vectors posted for each epoch, at the epoch's newest
/// height. The same aggregation [aggregateOracle] applies to the latest
/// epoch.
List<HeightPrice> oracleHistoryFromBoxes(List<Map<String, dynamic>> boxes) {
  final feed = OraclePool.feeds.indexOf('ERG_USD');
  final byEpoch = <int, List<double>>{};
  final heightOf = <int, int>{};
  for (final b in boxes) {
    final regs = (b['additionalRegisters'] as Map?)?.cast<String, dynamic>() ?? const {};
    final epoch = decodeSigmaInt(regs['R5'] as String? ?? '');
    final vector = decodeSigmaLongColl(regs['R6'] as String? ?? '');
    final height = _height(b);
    if (epoch == null || vector == null || height == null || vector.length <= feed) continue;
    final micro = vector[feed];
    if (micro <= 0) continue;
    byEpoch.putIfAbsent(epoch, () => []).add(micro / OraclePool.priceScale);
    heightOf[epoch] = math.max(heightOf[epoch] ?? 0, height);
  }
  final out = <HeightPrice>[
    for (final e in byEpoch.entries) (heightOf[e.key]!, _median(e.value)!),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

/// ERG/USD at each historical state of an ERG/SigUSD pool box: SigUSD
/// cents over nanoERG. Boxes that are not that pool's layout are skipped.
List<HeightPrice> poolHistoryFromBoxes(List<Map<String, dynamic>> boxes, {required String sigUsdId}) {
  final out = <HeightPrice>[];
  for (final b in boxes) {
    final assets = (b['assets'] as List?) ?? const [];
    final height = _height(b);
    final erg = (b['value'] as num?)?.toDouble() ?? 0;
    if (assets.length < 3 || height == null || erg <= 0) continue;
    final y = (assets[2] as Map).cast<String, dynamic>();
    if (y['tokenId'] != sigUsdId) continue;
    final cents = (y['amount'] as num?)?.toDouble() ?? 0;
    if (cents <= 0) continue;
    out.add((height, (cents / 100) / (erg / 1e9)));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

/// Heights as times, counting back from [tip] at [now].
List<PricePoint> pointsFromHeights(List<HeightPrice> prices, {required int tip, required DateTime now, double scale = 1}) => [
      for (final (h, usd) in prices)
        PricePoint(now.subtract(Duration(minutes: (tip - h) * minutesPerBlock)), usd * scale),
    ];

/// CoinGecko's market chart (`{"prices": [[ms, price], …]}`) as points.
List<PricePoint> coingeckoChartPoints(Map<String, dynamic> json) {
  final out = <PricePoint>[];
  for (final p in (json['prices'] as List?) ?? const []) {
    if (p is! List || p.length < 2 || p[0] is! num || p[1] is! num) continue;
    out.add(PricePoint(DateTime.fromMillisecondsSinceEpoch((p[0] as num).toInt(), isUtc: true), (p[1] as num).toDouble()));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// The price in force at [at]: the last point at or before it. Null when
/// the history does not reach back that far.
double? priceAt(List<PricePoint> points, DateTime at) {
  PricePoint? last;
  for (final p in points) {
    if (p.at.isAfter(at)) break;
    last = p;
  }
  return last?.price;
}

/// Percent change from the price in force [span] before [now] to the newest.
double? changeOver(List<PricePoint> points, Duration span, DateTime now) {
  if (points.isEmpty) return null;
  final then = priceAt(points, now.subtract(span));
  if (then == null || then <= 0) return null;
  return (points.last.price - then) / then * 100;
}

/// Keeps the points inside the window plus the one in force at its start,
/// moved to the start so a chart begins at the window's left edge.
List<PricePoint> clipToWindow(List<PricePoint> points, Duration span, DateTime now) {
  final start = now.subtract(span);
  final before = priceAt(points, start);
  return [
    if (before != null) PricePoint(start, before),
    for (final p in points)
      if (p.at.isAfter(start)) p,
  ];
}

/// A page of boxes that ever held [tokenId], newest first.
typedef BoxPage = Future<List<Map<String, dynamic>>> Function(String node, String tokenId, int offset, int limit);

class HistoryUnavailable implements Exception {
  const HistoryUnavailable(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// The node's history of [tokenId]'s boxes back past [windowBlocks] before
/// [tip], in a bounded number of requests.
///
/// The node lists boxes newest first. The first page usually covers a quiet
/// pool's whole window; when it does not, the box rate seen on it places
/// [samples] small pages evenly across the rest of the window, plus one
/// further back for the price in force at its start. A busy feed (oracle
/// operators post every few blocks) costs at most `samples + 2` requests
/// whatever the window.
Future<List<Map<String, dynamic>>> sampleHistory({
  required BoxPage page,
  required String node,
  required String tokenId,
  required int tip,
  required int windowBlocks,
  int firstPage = 100,
  int samplePage = 16,
  int samples = 12,
}) async {
  final first = await page(node, tokenId, 0, firstPage);
  final all = [...first];
  final heights = first.map(_height).whereType<int>().toList();
  if (heights.isEmpty || first.length < firstPage) return all;
  final start = tip - windowBlocks;
  final newest = heights.reduce(math.max);
  final oldest = heights.reduce(math.min);
  if (oldest <= start) return all;
  // Boxes per block on the first page, then where the window start falls.
  final rate = first.length / math.max(1, newest - oldest + 1);
  final toStart = ((newest - start) * rate).ceil();
  final stride = math.max(samplePage, ((toStart - firstPage) / samples).ceil());
  for (var k = 0; k <= samples; k++) {
    final got = await page(node, tokenId, firstPage + stride * k, samplePage);
    all.addAll(got);
    final h = got.map(_height).whereType<int>();
    if (got.length < samplePage || (h.isNotEmpty && h.reduce(math.min) <= start)) break;
  }
  // New boxes shift the node's pages while sampling; count each box once.
  final seen = <Object?>{};
  return [
    for (final b in all)
      if (seen.add(b['boxId'] ?? identityHashCode(b))) b,
  ];
}

/// The real node request behind [BoxPage]: `/blockchain/box/byTokenId`,
/// which needs the node's extra index.
Future<List<Map<String, dynamic>>> fetchBoxPage(
  String node,
  String tokenId,
  int offset,
  int limit, {
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  final base = node.replaceAll(RegExp(r'/$'), '');
  final res = await c
      .get(Uri.parse('$base/blockchain/box/byTokenId/$tokenId?offset=$offset&limit=$limit'))
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) {
    throw const HistoryUnavailable('This node cannot serve price history: it needs the extra index.');
  }
  final body = jsonDecode(res.body);
  final items = body is List ? body : (body as Map)['items'] as List? ?? const [];
  return items.map((e) => (e as Map).cast<String, dynamic>()).toList();
}

/// CoinGecko's ERG market chart in [fiat] over [days].
Future<Map<String, dynamic>> fetchCoingeckoChart(String fiat, int days, {http.Client? client}) async {
  final c = client ?? http.Client();
  final res = await c
      .get(Uri.parse('https://api.coingecko.com/api/v3/coins/ergo/market_chart?vs_currency=$fiat&days=$days'))
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) throw HistoryUnavailable('CoinGecko answered ${res.statusCode}.');
  return (jsonDecode(res.body) as Map).cast<String, dynamic>();
}
