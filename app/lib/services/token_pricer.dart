import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api/pricing.dart' as pricing_api;
import 'amm_service.dart';
import 'erg_price_history.dart';
import 'network_controller.dart';
import 'oracle_feeds.dart';
import 'oracle_pool.dart';
import 'sigmausd_service.dart';
import 'token_metadata.dart';
import 'token_pricing.dart';
import 'verified_tokens.dart';
import 'wallet_service.dart';

/// Everything the pricer needs from the outside, injectable for tests.
class PricerDeps {
  PricerDeps({
    required this.nodeUrl,
    required this.tipHeight,
    required this.fiatCode,
    required this.oracle,
    required this.coingecko,
    required this.pools,
    required this.poolPrices,
    required this.sigRsvPriceNano,
    required this.onRate,
    Future<OracleReading?> Function(String node, OracleFeed feed)? oracleReading,
    BoxPage? boxPage,
    Future<Map<String, dynamic>> Function(String fiat, int days)? coingeckoChart,
    DateTime Function()? clock,
    int? Function(String tokenId)? decimalsOf,
    String? Function(String tokenId)? nameOf,
    Listenable? metadataChanges,
    Timer Function(Duration delay, void Function() run)? timer,
  })  : timer = timer ?? Timer.new,
        oracleReading = oracleReading ?? ((node, feed) => fetchOracleReading(node, feed)),
        boxPage = boxPage ?? fetchBoxPage,
        coingeckoChart = coingeckoChart ?? ((fiat, days) => fetchCoingeckoChart(fiat, days)),
        clock = clock ?? DateTime.now,
        decimalsOf = decimalsOf ?? ((id) => tokenDecimals(id)),
        nameOf = nameOf ?? ((id) => tokenName(id)),
        metadataChanges = metadataChanges ?? walletService.metadataChanges;

  final String? Function() nodeUrl;
  final int? Function() tipHeight;
  final String Function() fiatCode;
  final Future<OracleSnapshot?> Function(String node) oracle;

  /// coingecko id → (vs currency → price).
  final Future<Map<String, Map<String, double>>> Function(List<String> ids, List<String> vs) coingecko;
  final Future<AmmPoolSet?> Function() pools;

  /// Prices in ERG for every token and LP token [AmmPoolSet] supports,
  /// computed by the Rust pricing core.
  final Future<PoolPriceBook> Function(AmmPoolSet set) poolPrices;
  final Future<int?> Function() sigRsvPriceNano;

  /// The newest box of a single-rate oracle pool on the node.
  final Future<OracleReading?> Function(String node, OracleFeed feed) oracleReading;

  /// Publishes the ERG rate in the display currency (null when unknown).
  final void Function(double? fiatPerErg, double? usdPerErg) onRate;

  /// Pages of a token's box history from the node, for price history.
  final BoxPage boxPage;

  /// CoinGecko's ERG market chart, for price history under that source.
  final Future<Map<String, dynamic>> Function(String fiat, int days) coingeckoChart;
  final DateTime Function() clock;

  /// A token's decimals from the one token lookup (this wallet's
  /// descriptors, the public pool-token catalog, the curated registry, the
  /// legacy table, and this session's explicit loads), or null when none of
  /// them knows its scale. Every price is converted at this scale.
  final int? Function(String tokenId) decimalsOf;

  /// A token's name from the same lookup, for via labels.
  final String? Function(String tokenId) nameOf;

  /// Fires when the lookup learns a name or a scale, so prices it held back
  /// are worked out again without another read.
  final Listenable metadataChanges;

  /// Schedules a retry after a refresh that came back without a usable
  /// rate.
  final Timer Function(Duration delay, void Function() run) timer;
}

/// Prices every token the wallet can see, from the source the user picked.
class TokenPricer extends ChangeNotifier {
  TokenPricer(this._deps) {
    _deps.metadataChanges.addListener(_reprice);
  }

  static const _prefKey = 'argus_price_source';
  static const _crossKey = 'argus_price_cross_rate_v1';
  static const refreshTtl = Duration(minutes: 5);

  /// Prices shown from an earlier read are said to be old only past this
  /// age. A refresh is due every [refreshTtl]; one that fails leaves the
  /// last good prices up, and while those are under three refresh periods
  /// old they are as current as a wallet's prices need to be. Saying "as of
  /// just now" beside them would flag a price that is not stale.
  static const oldAfter = Duration(minutes: 15);

  /// The display currency's rate against the dollar (AUD per USD) changes
  /// slowly: it is asked again only this often, which keeps the Oracle and
  /// Spectrum sources from calling CoinGecko on every refresh. CoinGecko's
  /// free API answers 429 to a few calls in a row.
  static const crossRateTtl = Duration(hours: 1);

  /// A cross rate older than this is no longer used to show values.
  static const crossRateMaxAge = Duration(days: 2);

  /// The first retry after a refresh without a usable rate; each further
  /// failure doubles it, up to [refreshTtl].
  static const firstRetry = Duration(seconds: 15);

  final PricerDeps _deps;

  PriceSource source = PriceSource.oracle;
  PricingResult result = const PricingResult(ergUsd: null, ergVia: null, prices: {});

  /// Display-currency units per USD; 1 for USD.
  double fiatPerUsd = 1;
  DateTime? asOf;
  bool stale = false;

  /// True when the last refresh produced no rate and the previous prices
  /// are still being shown.
  bool pricesAreOld = false;
  String? lastError;
  bool refreshing = false;

  DateTime? _fetchedAt;
  int _gen = 0;

  /// The last display-currency rate CoinGecko gave, kept across refreshes
  /// and launches so one refused request does not take every value off
  /// screen.
  ({String fiat, double perUsd, DateTime at})? _cross;

  /// Refreshes in a row that came back without a usable rate, and the
  /// retry waiting after them.
  int _failures = 0;
  Timer? _retry;

  /// A retry is waiting: the screen can say the price is being asked for
  /// again rather than that it is gone.
  bool get retrying => _retry != null;

  /// [pricesAreOld], and old enough to say so ([oldAfter]).
  bool get pricesLookOld {
    if (!pricesAreOld) return false;
    final at = asOf;
    return at == null || _deps.clock().difference(at) > oldAfter;
  }
  bool _pendingForcedRefresh = false;

  /// The ERG/SigUSD pool the last price book priced SigUSD from: the pool
  /// whose history the Spectrum source charts.
  String? _sigUsdPoolId;

  /// What the visible prices were last worked out from, and for which
  /// source generation: when the token lookup learns a scale, the prices
  /// are worked out again from these instead of waiting for the next read.
  PricingInputs? _lastInputs;
  int _lastInputsGen = -1;

  /// A token whose scale was unknown at the last refresh was left unpriced;
  /// once the lookup knows it, price it from the same quotes.
  void _reprice() {
    final inputs = _lastInputs;
    if (inputs == null || _lastInputsGen != _gen) return;
    final fresh = priceTokens(inputs);
    if (fresh.ergUsd == null) return;
    result = fresh;
    stale = pricesAreOld || result.ergStale;
    notifyListeners();
  }

  @override
  void dispose() {
    _deps.metadataChanges.removeListener(_reprice);
    _retry?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    source = PriceSource.fromId(prefs.getString(_prefKey));
    final cross = prefs.getString(_crossKey);
    if (cross != null) {
      try {
        final m = jsonDecode(cross) as Map;
        _cross = (
          fiat: m['fiat'] as String,
          perUsd: (m['per_usd'] as num).toDouble(),
          at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()),
        );
      } catch (_) {
        // An unreadable rate is asked for again.
      }
    }
    notifyListeners();
  }

  /// The cached cross rate for [fiat], when it is recent enough to show
  /// values with.
  double? _crossFor(String fiat, DateTime now) {
    final c = _cross;
    if (c == null || c.fiat != fiat || now.difference(c.at) > crossRateMaxAge) return null;
    return c.perUsd;
  }

  /// After a refresh: retry soon while it left no usable rate (none for
  /// ERG, or none for the display currency), backing off, else stand down.
  void _scheduleRetry({required bool usable}) {
    _retry?.cancel();
    _retry = null;
    if (usable) {
      _failures = 0;
      return;
    }
    final delay = firstRetry * (1 << _failures.clamp(0, 5));
    _failures++;
    _retry = _deps.timer(delay > refreshTtl ? refreshTtl : delay, () {
      _retry = null;
      refresh(force: true);
    });
  }

  /// Invalidates old prices immediately so a source switch cannot mix rates.
  Future<void> setSource(PriceSource s) async {
    if (s == source) return;
    source = s;
    result = const PricingResult(ergUsd: null, ergVia: null, prices: {});
    _fetchedAt = null;
    _lastInputs = null;
    _gen++;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, s.name);
    await refresh(force: true);
  }

  Future<void> _saveCross() async {
    final c = _cross;
    if (c == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _crossKey,
        jsonEncode({'fiat': c.fiat, 'per_usd': c.perUsd, 'at': c.at.millisecondsSinceEpoch}),
      );
    } catch (_) {
      // Held for this session either way.
    }
  }

  TokenPrice? priceOf(String tokenId) => result[tokenId];

  /// "Oracle pools · ERG via SigmaUSD oracle" for the settings row. "stale"
  /// goes before the details: the row is cut to two lines, and at large
  /// text sizes only the start survives.
  String get sourceLine {
    final via = result.ergVia;
    if (via == null) return source.label;
    return '${source.label}${stale ? ' · stale' : ''} · ERG via $via';
  }

  /// False when the display currency is not USD and the cross rate is
  /// unknown, in which case no fiat text should be shown.
  bool displayRateKnown = true;

  /// "≈ $12.30" for a token holding in the display currency, or null.
  String? fiatTextFor({required String tokenId, required int amount, required int decimals}) {
    if (!displayRateKnown) return null;
    return networkController.fiatFromUsd(usdOf(tokenId, amount, decimals), fiatPerUsd: fiatPerUsd);
  }

  /// "≈ $0.0125" per whole token, or null when unpriced.
  String? unitFiatText(String tokenId) {
    final p = result[tokenId];
    if (p == null || !displayRateKnown) return null;
    return networkController.fiatFromUsd(p.usd, fiatPerUsd: fiatPerUsd, maxFrac: 6);
  }

  /// Fiat text for a USD total, or null.
  String? fiatTextForUsd(double? usd) =>
      displayRateKnown ? networkController.fiatFromUsd(usd, fiatPerUsd: fiatPerUsd) : null;

  /// USD value of [amount] of [tokenId], or null when unpriced.
  double? usdOf(String tokenId, int amount, int decimals) =>
      holdingUsd(amount: amount, decimals: decimals, price: result[tokenId]);

  /// Publishes usable rates as each branch settles and retains forced requests
  /// made during a fetch, so a source change cannot leave prices empty.
  Future<void> refresh({bool force = false}) async {
    final now = _deps.clock();
    if (!force && _fetchedAt != null && now.difference(_fetchedAt!) < refreshTtl) return;
    if (refreshing) {
      _pendingForcedRefresh |= force;
      return;
    }
    refreshing = true;
    final gen = _gen;
    final src = source;
    final fiat = _deps.fiatCode().toLowerCase();
    final node = _deps.nodeUrl();
    final errors = <String>[];

    Future<T?> attempt<T>(String what, Future<T?> Function() f) async {
      try {
        return await f();
      } catch (e) {
        errors.add('$what: $e');
        return null;
      }
    }

    // The cross rate is asked for only when the one held is old: under the
    // Oracle and Spectrum sources CoinGecko is otherwise not needed at all.
    final held = _cross;
    final crossFresh =
        fiat == 'usd' || (held != null && held.fiat == fiat && now.difference(held.at) < crossRateTtl);
    final needsGecko = src == PriceSource.coingecko || !crossFresh;
    final results = List<Object?>.filled(5, null);

    /// Only the current source may contribute to the visible price snapshot.
    /// Each branch publishes as it settles, so prices show as soon as any
    /// source has them; whether the refresh left the prices old is decided
    /// once, when every branch has settled ([last]), not by whichever
    /// branch answered first.
    void publish({bool last = false}) {
      if (gen != _gen) return;
      final oracle = results[0] as OracleSnapshot?;
      final gecko =
          (results[1] as Map<String, Map<String, double>>?) ?? const {};
      final pooled = results[2] as (AmmPoolSet, PoolPriceBook)?;
      final pools = pooled?.$1;
      final book = pooled?.$2 ?? PoolPriceBook.empty;
      final sigRsv = results[3] as int?;
      final readings = (results[4] as Map<OracleFeed, OracleReading>?) ?? const {};

      final geckoUsd = <String, double>{
        for (final e in gecko.entries)
          if (e.value['usd'] != null) e.key: e.value['usd']!,
      };
      final inputs = PricingInputs(
        source: src,
        oracle: oracle,
        oracles: readings,
        tipHeight: _deps.tipHeight(),
        coingeckoUsd: geckoUsd,
        poolPrices: book,
        sigRsvPriceNano: sigRsv,
        // The one token lookup, read when the prices are worked out: a held
        // token the public catalog has not reached is still scaled by this
        // wallet's own descriptor, and one nothing knows is left unpriced
        // rather than priced per base unit.
        decimalsOf: _deps.decimalsOf,
        nameOf: (id) => knownToken(id)?.ticker ?? _deps.nameOf(id) ?? pools?.tokens[id]?.name,
      );
      final fresh = priceTokens(inputs);
      _sigUsdPoolId = book.tokens[SigmaUsdTokens.sigUsd]?.poolId ?? _sigUsdPoolId;
      // A source that momentarily answers with nothing must not blank every
      // price in the wallet. Keep the last good result and, once the whole
      // refresh is in, say it is old.
      if (fresh.ergUsd != null) {
        result = fresh;
        pricesAreOld = false;
        _lastInputs = inputs;
        _lastInputsGen = gen;
        // Only a read that produced a rate makes the prices current.
        asOf = now;
        _fetchedAt = now;
      } else if (result.ergUsd == null) {
        result = fresh;
      } else if (last) {
        pricesAreOld = true;
      }

      final ergo = gecko['ergo'];
      if (ergo != null && ergo['usd'] != null && ergo[fiat] != null && ergo['usd']! > 0 && fiat != 'usd') {
        _cross = (fiat: fiat, perUsd: ergo[fiat]! / ergo['usd']!, at: now);
        unawaited(_saveCross());
      }
      // The display rate: this refresh's, else the last one held for this
      // currency. A refused CoinGecko call no longer takes the values off.
      final perUsd = fiat == 'usd' ? 1.0 : _crossFor(fiat, now);
      if (perUsd != null) fiatPerUsd = perUsd;
      // Stale only when the ERG rate itself has no current source: a
      // stopped feed for one token is said on that token's row instead.
      stale = pricesAreOld || result.ergStale;
      lastError = errors.isEmpty ? null : errors.join('; ');
      final ergUsd = result.ergUsd;
      displayRateKnown = perUsd != null;
      _deps.onRate(
        ergUsd == null || !displayRateKnown ? null : ergUsd * fiatPerUsd,
        ergUsd,
      );
      notifyListeners();
    }

    final branches = <Future<Object?>>[
      src == PriceSource.oracle && node != null
          ? attempt('oracle', () => _deps.oracle(node))
          : Future.value(null),
      needsGecko
          ? attempt('coingecko', () => _deps.coingecko(coingeckoIdsFor(src), ['usd', if (fiat != 'usd') fiat]))
          : Future.value(null),
      attempt('pools', () async {
        final set = await _deps.pools();
        if (set == null) return null;
        return (set, await _deps.poolPrices(set));
      }),
      attempt('sigmausd', _deps.sigRsvPriceNano),
      attempt('oracle pools', () async {
        if (node == null) return null;
        // Gold prices DexyGold under every source; the dollar pools only
        // matter to the Oracle source.
        final feeds = src == PriceSource.oracle ? OracleFeed.values : const [OracleFeed.dexyGold];
        final got = await Future.wait([
          for (final f in feeds)
            _deps.oracleReading(node, f).catchError((Object e) {
              errors.add('${f.label}: $e');
              return null;
            }),
        ]);
        return <OracleFeed, OracleReading>{
          for (var i = 0; i < feeds.length; i++)
            if (got[i] case final r?) feeds[i]: r,
        };
      }),
    ];
    try {
      await Future.wait([
        for (var i = 0; i < branches.length; i++)
          branches[i].then((value) {
            results[i] = value;
            publish();
          }),
      ]);
      publish(last: true);
      if (gen == _gen) _scheduleRetry(usable: !pricesAreOld && result.ergUsd != null && displayRateKnown);
    } finally {
      refreshing = false;
      if (_pendingForcedRefresh) {
        _pendingForcedRefresh = false;
        await refresh(force: true);
      } else if (gen == _gen) {
        notifyListeners();
      }
    }
  }

  final Map<String, (DateTime, ErgPriceHistory)> _history = {};

  /// How long an answer saying history is unavailable is kept: short, so a
  /// node that was still starting up is asked again soon.
  static const _unavailableTtl = Duration(seconds: 30);

  /// ERG's price over [window] in the display currency, from the source
  /// picked in Display settings, with its 24-hour change.
  ///
  /// - Oracle pools: the SigmaUSD oracle pool's past boxes, the rate that
  ///   source prices ERG at (needs the node's extra index).
  /// - Spectrum pools: the deepest ERG/SigUSD pool's past boxes from the
  ///   node (needs the extra index).
  /// - CoinGecko: its market chart in the display currency, from the host
  ///   that source already uses.
  ///
  /// Read on demand and kept in memory for [refreshTtl]; nothing polls in
  /// the background. Node sources give USD, converted at today's cross
  /// rate, and their times come from block heights at two minutes a block
  /// ([ErgPriceHistory.approximateTimes]). When history cannot be read the
  /// answer says why ([ErgPriceHistory.unavailableReason]) instead of
  /// throwing.
  Future<ErgPriceHistory> ergPriceHistory(PriceWindow window) async {
    final src = source;
    final fiat = _deps.fiatCode().toLowerCase();
    final node = _deps.nodeUrl();
    final key = '${src.name}|${window.name}|$fiat|$node';
    final now = _deps.clock();
    final cached = _history[key];
    if (cached != null) {
      final ttl = cached.$2.available ? refreshTtl : _unavailableTtl;
      if (now.difference(cached.$1) < ttl) return cached.$2;
    }

    final label = switch (src) {
      PriceSource.oracle => 'SigmaUSD oracle',
      PriceSource.spectrum => 'Spectrum ERG/SigUSD',
      PriceSource.coingecko => 'CoinGecko',
    };
    ErgPriceHistory answer;
    try {
      answer = src == PriceSource.coingecko
          ? await _coingeckoHistory(window, fiat, label, now)
          : await _nodeHistory(window, fiat, label, now, node, src);
    } catch (e) {
      final reason = e is HistoryUnavailable ? e.reason : 'Price history could not be read: $e';
      answer = ErgPriceHistory.unavailable(window: window, sourceLabel: label, currency: fiat, reason: reason);
    }
    _history[key] = (now, answer);
    return answer;
  }

  Future<ErgPriceHistory> _coingeckoHistory(PriceWindow window, String fiat, String label, DateTime now) async {
    final points = coingeckoChartPoints(await _deps.coingeckoChart(fiat, window.coingeckoDays));
    if (points.isEmpty) throw const HistoryUnavailable('CoinGecko returned no history.');
    return ErgPriceHistory(
      window: window,
      points: clipToWindow(points, window.span, now),
      sourceLabel: label,
      currency: fiat,
      change24hPct: changeOver(points, const Duration(hours: 24), now),
    );
  }

  Future<ErgPriceHistory> _nodeHistory(
    PriceWindow window,
    String fiat,
    String label,
    DateTime now,
    String? node,
    PriceSource src,
  ) async {
    if (node == null) throw const HistoryUnavailable('No node is connected.');
    final tip = _deps.tipHeight();
    if (tip == null) throw const HistoryUnavailable('The node height is not known yet.');
    if (fiat != 'usd' && !displayRateKnown) {
      throw HistoryUnavailable('The ${fiat.toUpperCase()} rate is not known yet.');
    }
    // The Oracle source's ERG rate is the SigmaUSD oracle pool's, so its
    // history is that pool's past boxes; the Spectrum source's is the
    // ERG/SigUSD pool's.
    final oracle = src == PriceSource.oracle;
    final boxes = await sampleHistory(
      page: _deps.boxPage,
      node: node,
      tokenId: oracle ? OracleFeed.sigmaUsd.nft : (_sigUsdPoolId ?? ergSigUsdPoolNft),
      tip: tip,
      // Every window is at least a day, so the 24-hour change is covered.
      windowBlocks: window.blocks,
    );
    final byHeight = oracle
        ? oracleRateHistory(boxes)
        : poolHistoryFromBoxes(boxes, sigUsdId: SigmaUsdTokens.sigUsd);
    if (byHeight.isEmpty) throw HistoryUnavailable('This node has no price history for $label yet.');
    final points = pointsFromHeights(byHeight, tip: tip, now: now, scale: fiat == 'usd' ? 1.0 : fiatPerUsd);
    return ErgPriceHistory(
      window: window,
      points: clipToWindow(points, window.span, now),
      sourceLabel: label,
      currency: fiat,
      change24hPct: changeOver(points, const Duration(hours: 24), now),
      approximateTimes: true,
      stale: oracle && tip - byHeight.last.$1 > OracleFeed.sigmaUsd.staleAfterBlocks,
    );
  }
}

/// Real CoinGecko simple-price call: `ids` × `vs` in one request.
Future<Map<String, Map<String, double>>> fetchCoingecko(
  List<String> ids,
  List<String> vs, {
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  final res = await c
      .get(Uri.parse(
          'https://api.coingecko.com/api/v3/simple/price?ids=${ids.join(',')}&vs_currencies=${vs.join(',')}'))
      .timeout(const Duration(seconds: 8));
  if (res.statusCode != 200) throw Exception('CoinGecko ${res.statusCode}');
  final map = (jsonDecode(res.body) as Map).cast<String, dynamic>();
  return {
    for (final e in map.entries)
      e.key: {
        for (final p in (e.value as Map).entries)
          if (p.value is num) p.key as String: (p.value as num).toDouble(),
      },
  };
}

/// Pools from disk when recent, otherwise a node refresh.
Future<AmmPoolSet?> _poolsForPricing() async {
  final cached = await AmmPoolCache.load();
  if (cached != null && cached.age < const Duration(minutes: 15)) return cached.set;
  if (networkController.activeUrl == null) return cached?.set;
  try {
    return await ammService.pools();
  } catch (_) {
    return cached?.set;
  }
}

/// The pool set priced by the Rust core (`wallet-amm`): deepest pool above
/// the depth floor, one hop for tokens without one, LP shares.
Future<PoolPriceBook> rustPoolPrices(AmmPoolSet set) async {
  final raw = await pricing_api.pricingPoolPrices(
    poolsJson: jsonEncode(set.pools),
    optionsJson: jsonEncode(poolPricingOptions()),
  );
  return PoolPriceBook.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
}

final tokenPricer = TokenPricer(PricerDeps(
  nodeUrl: () => networkController.activeUrl,
  tipHeight: () => networkController.height,
  fiatCode: () => networkController.fiatCode,
  oracle: (node) => OraclePoolClient().fetch(node),
  coingecko: (ids, vs) => fetchCoingecko(ids, vs),
  pools: _poolsForPricing,
  poolPrices: rustPoolPrices,
  sigRsvPriceNano: () async =>
      networkController.activeUrl == null ? null : (await sigmaUsdService.state()).sigRsvPriceNano,
  onRate: (fiatPerErg, usdPerErg) => networkController.setErgRate(fiatPerErg: fiatPerErg, usdPerErg: usdPerErg),
));
