import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'amm_service.dart';
import 'dexy_service.dart';
import 'network_controller.dart';
import 'oracle_pool.dart';
import 'sigmausd_service.dart';
import 'token_pricing.dart';
import 'verified_tokens.dart';

/// Everything the pricer needs from the outside, injectable for tests.
class PricerDeps {
  PricerDeps({
    required this.nodeUrl,
    required this.tipHeight,
    required this.fiatCode,
    required this.oracle,
    required this.coingecko,
    required this.pools,
    required this.sigRsvPriceNano,
    required this.dexyGoldRateNano,
    required this.onRate,
  });

  final String? Function() nodeUrl;
  final int? Function() tipHeight;
  final String Function() fiatCode;
  final Future<OracleSnapshot?> Function(String node) oracle;

  /// coingecko id → (vs currency → price).
  final Future<Map<String, Map<String, double>>> Function(List<String> ids, List<String> vs) coingecko;
  final Future<AmmPoolSet?> Function() pools;
  final Future<int?> Function() sigRsvPriceNano;
  final Future<int?> Function() dexyGoldRateNano;

  /// Publishes the ERG rate in the display currency (null when unknown).
  final void Function(double? fiatPerErg, double? usdPerErg) onRate;
}

/// Prices every token the wallet can see, from the source the user picked.
class TokenPricer extends ChangeNotifier {
  TokenPricer(this._deps);

  static const _prefKey = 'argus_price_source';
  static const refreshTtl = Duration(minutes: 5);

  final PricerDeps _deps;

  PriceSource source = PriceSource.oracle;
  PricingResult result = const PricingResult(ergUsd: null, ergVia: null, prices: {});

  /// Display-currency units per USD; 1 for USD.
  double fiatPerUsd = 1;
  DateTime? asOf;
  bool stale = false;
  String? lastError;
  bool refreshing = false;

  DateTime? _fetchedAt;
  int _gen = 0;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    source = PriceSource.fromId(prefs.getString(_prefKey));
    notifyListeners();
  }

  Future<void> setSource(PriceSource s) async {
    if (s == source) return;
    source = s;
    result = const PricingResult(ergUsd: null, ergVia: null, prices: {});
    _fetchedAt = null;
    _gen++;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, s.name);
    await refresh(force: true);
  }

  TokenPrice? priceOf(String tokenId) => result[tokenId];

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

  Future<void> refresh({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _fetchedAt != null && now.difference(_fetchedAt!) < refreshTtl) return;
    if (refreshing) return;
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

    final needsGecko = src == PriceSource.coingecko || fiat != 'usd';
    final results = await Future.wait<Object?>([
      src == PriceSource.oracle && node != null ? attempt('oracle', () => _deps.oracle(node)) : Future.value(null),
      needsGecko
          ? attempt('coingecko', () => _deps.coingecko(coingeckoIdsFor(src), ['usd', if (fiat != 'usd') fiat]))
          : Future.value(null),
      attempt('pools', _deps.pools),
      attempt('sigmausd', _deps.sigRsvPriceNano),
      attempt('dexy', _deps.dexyGoldRateNano),
    ]);
    if (gen != _gen) {
      refreshing = false;
      return;
    }
    final oracle = results[0] as OracleSnapshot?;
    final gecko = (results[1] as Map<String, Map<String, double>>?) ?? const {};
    final pools = results[2] as AmmPoolSet?;
    final sigRsv = results[3] as int?;
    final gold = results[4] as int?;

    final geckoUsd = <String, double>{
      for (final e in gecko.entries)
        if (e.value['usd'] != null) e.key: e.value['usd']!,
    };
    result = priceTokens(PricingInputs(
      source: src,
      oracle: oracle,
      coingeckoUsd: geckoUsd,
      pools: pools?.pools ?? const [],
      sigRsvPriceNano: sigRsv,
      dexyGoldRateNano: gold,
      decimalsOf: (id) => pools?.tokens[id]?.decimals ?? knownToken(id)?.decimals ?? 0,
    ));

    final ergo = gecko['ergo'];
    if (fiat == 'usd') {
      fiatPerUsd = 1;
    } else if (ergo != null && ergo['usd'] != null && ergo[fiat] != null && ergo['usd']! > 0) {
      fiatPerUsd = ergo[fiat]! / ergo['usd']!;
    }
    stale = src == PriceSource.oracle && (oracle?.isStale(_deps.tipHeight()) ?? false);
    lastError = errors.isEmpty ? null : errors.join('; ');
    if (result.ergUsd != null) {
      asOf = now;
      _fetchedAt = now;
    }
    final ergUsd = result.ergUsd;
    displayRateKnown = fiat == 'usd' || (ergo?[fiat] != null);
    _deps.onRate(ergUsd == null || !displayRateKnown ? null : ergUsd * fiatPerUsd, ergUsd);
    refreshing = false;
    notifyListeners();
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

final tokenPricer = TokenPricer(PricerDeps(
  nodeUrl: () => networkController.activeUrl,
  tipHeight: () => networkController.height,
  fiatCode: () => networkController.fiatCode,
  oracle: (node) => OraclePoolClient().fetch(node),
  coingecko: (ids, vs) => fetchCoingecko(ids, vs),
  pools: _poolsForPricing,
  sigRsvPriceNano: () async =>
      networkController.activeUrl == null ? null : (await sigmaUsdService.state()).sigRsvPriceNano,
  dexyGoldRateNano: () async =>
      networkController.activeUrl == null ? null : (await dexService.state(DexyVariant.gold)).oracleRateNano,
  onRate: (fiatPerErg, usdPerErg) => networkController.setErgRate(fiatPerErg: fiatPerErg, usdPerErg: usdPerErg),
));
