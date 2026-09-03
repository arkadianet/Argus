import 'dart:convert';

export 'verified_tokens.dart' show isVerifiedToken, verifiedTokenLabels, verifiedToken, cautionedToken, impersonatedToken;

import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as api;
import '../bridge/argus_error.dart';
import 'network_controller.dart';
import 'wallet_service.dart';

/// Tolerance absorbing pool movement between the cached quote and the
/// force-refreshed build.
///
/// This is **not** slippage protection. A direct swap fixes the output amount
/// in the transaction it builds and references the pool box by id, so it either
/// fills at exactly the quoted price or the transaction is invalid. `minOutput`
/// is never read by any contract — the Rust builders only compare against it at
/// build time. Fixed deliberately: there is nothing here a user could tune.
const double kQuoteTolerancePct = 0.5;


class AmmTokenMeta {
  final String name;
  final int decimals;

  const AmmTokenMeta({required this.name, required this.decimals});

  Map<String, dynamic> toJson() => {'name': name, 'decimals': decimals};

  factory AmmTokenMeta.fromJson(Map<String, dynamic> json) => AmmTokenMeta(
        name: json['name'] as String? ?? '',
        decimals: (json['decimals'] as num?)?.toInt() ?? 0,
      );
}

class AmmPoolSet {
  /// True when discovery hit its 1000-box cap and pools may be missing.
  final bool truncated;
  final List<Map<String, dynamic>> pools;
  final Map<String, AmmTokenMeta> tokens;

  const AmmPoolSet({
    required this.truncated,
    required this.pools,
    required this.tokens,
  });

  Map<String, dynamic> toJson() => {
        'truncated': truncated,
        'pools': pools,
        'tokens': tokens.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory AmmPoolSet.fromJson(Map<String, dynamic> json) => AmmPoolSet(
        truncated: json['truncated'] as bool? ?? false,
        pools: ((json['pools'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList(),
        tokens: ((json['tokens'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(
            k as String,
            AmmTokenMeta.fromJson((v as Map).cast<String, dynamic>()),
          ),
        ),
      );
}

/// A pool set read back from disk, with how old it is.
class CachedPoolSet {
  const CachedPoolSet({required this.set, required this.nodeUrl, required this.age});
  final AmmPoolSet set;
  final String? nodeUrl;
  final Duration age;
}

/// On-disk copies of the last pool list and every token's metadata, so the
/// swap picker paints at once and the Rust side skips token lookups it has
/// already done on a previous launch.
class AmmPoolCache {
  static const _poolsKey = 'argus_amm_pools_v1';
  static const _tokensKey = 'argus_amm_tokens_v1';

  static Future<void> save(AmmPoolSet set, {String? nodeUrl}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _poolsKey,
      jsonEncode({
        'saved_at': DateTime.now().millisecondsSinceEpoch,
        'node_url': nodeUrl,
        'set': set.toJson(),
      }),
    );
    await rememberTokens(set.tokens);
  }

  static Future<CachedPoolSet?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_poolsKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = DateTime.fromMillisecondsSinceEpoch((map['saved_at'] as num).toInt());
      return CachedPoolSet(
        set: AmmPoolSet.fromJson((map['set'] as Map).cast<String, dynamic>()),
        nodeUrl: map['node_url'] as String?,
        age: DateTime.now().difference(savedAt),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> rememberTokens(Map<String, AmmTokenMeta> tokens) async {
    if (tokens.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final existing = _decodeTokens(prefs.getString(_tokensKey));
    for (final e in tokens.entries) {
      if (e.value.name.isNotEmpty) existing[e.key] = e.value.toJson();
    }
    await prefs.setString(_tokensKey, jsonEncode(existing));
  }

  /// JSON map of token id → {name, decimals}, for seeding the Rust cache.
  static Future<String?> knownTokensJson() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tokensKey);
    return raw == null || raw.isEmpty ? null : raw;
  }

  static Map<String, dynamic> _decodeTokens(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }
}

class AmmQuote {
  final String poolId;

  /// The pool box this quote was computed from. A direct swap spends the pool
  /// box, so a competing swap invalidates the transaction — this is what lets
  /// the service detect that and re-quote.
  final String boxId;
  final int outputAmount;
  final String outputToken;
  final int minOutput;
  final double priceImpactPct;
  final int feeAmount;
  final double quoteTolerancePct;

  const AmmQuote({
    required this.poolId,
    required this.boxId,
    required this.outputAmount,
    required this.outputToken,
    required this.minOutput,
    required this.priceImpactPct,
    required this.feeAmount,
    required this.quoteTolerancePct,
  });

  factory AmmQuote.fromJson(Map<String, dynamic> json) => AmmQuote(
        poolId: json['pool_id'] as String? ?? '',
        boxId: json['box_id'] as String? ?? '',
        outputAmount: (json['output_amount'] as num?)?.toInt() ?? 0,
        outputToken: json['output_token'] as String? ?? '',
        minOutput: (json['min_output'] as num?)?.toInt() ?? 0,
        priceImpactPct: (json['price_impact_pct'] as num?)?.toDouble() ?? 0,
        feeAmount: (json['fee_amount'] as num?)?.toInt() ?? 0,
        quoteTolerancePct: (json['quote_tolerance_pct'] as num?)?.toDouble() ??
            kQuoteTolerancePct,
      );
}

/// ERG needed for an exact token output from the cheapest Spectrum pool.
class AmmExactQuote {
  const AmmExactQuote({required this.poolId, required this.boxId, required this.ergIn, required this.outputAmount, required this.feeNum, required this.feeDenom, this.ergReserves, this.tokenReserves});
  final String poolId;
  final String boxId;
  final int ergIn;
  final int outputAmount;
  final int feeNum;
  final int feeDenom;
  final int? ergReserves;
  final int? tokenReserves;

  factory AmmExactQuote.fromJson(Map<String, dynamic> j) => AmmExactQuote(
        poolId: j['pool_id'] as String? ?? '',
        boxId: j['box_id'] as String? ?? '',
        ergIn: (j['erg_in'] as num?)?.toInt() ?? 0,
        outputAmount: (j['output_amount'] as num?)?.toInt() ?? 0,
        feeNum: (j['fee_num'] as num?)?.toInt() ?? 0,
        feeDenom: (j['fee_denom'] as num?)?.toInt() ?? 0,
        ergReserves: (j['erg_reserves'] as num?)?.toInt(),
        tokenReserves: (j['token_reserves'] as num?)?.toInt(),
      );
}

class AmmSwapBuild {
  final int preparationId;
  final int inputAmount;
  final String inputToken;
  final int outputAmount;
  final String outputToken;
  final int minOutput;
  final int minerFee;
  final int totalErgCost;

  const AmmSwapBuild({
    required this.preparationId,
    required this.inputAmount,
    required this.inputToken,
    required this.outputAmount,
    required this.outputToken,
    required this.minOutput,
    required this.minerFee,
    required this.totalErgCost,
  });

  factory AmmSwapBuild.fromJson(Map<String, dynamic> json) => AmmSwapBuild(
        preparationId: (json['preparation_id'] as num?)?.toInt() ?? 0,
        inputAmount: (json['input_amount'] as num?)?.toInt() ?? 0,
        inputToken: json['input_token'] as String? ?? '',
        outputAmount: (json['output_amount'] as num?)?.toInt() ?? 0,
        outputToken: json['output_token'] as String? ?? '',
        minOutput: (json['min_output'] as num?)?.toInt() ?? 0,
        minerFee: (json['miner_fee'] as num?)?.toInt() ?? 0,
        totalErgCost: (json['total_erg_cost'] as num?)?.toInt() ?? 0,
      );
}

/// Talk to the FFI for Spectrum direct swaps; every broadcast goes through the
/// shared confirm sheet and then [WalletService.sendErg], exactly like Dexy.
class AmmService {
  String? get _node => networkController.activeUrl;

  BigInt _requireHandle() {
    final handle = walletService.handleId;
    if (handle == null) {
      throw ArgusException(
        code: 'WALLET_LOCKED',
        message: 'Wallet is locked',
      );
    }
    return handle;
  }

  Future<AmmPoolSet> pools({bool forceRefresh = false}) async {
    final raw = await api.ammPools(
      nodeUrl: _node,
      forceRefresh: forceRefresh,
      knownTokensJson: await AmmPoolCache.knownTokensJson(),
    );
    final set = AmmPoolSet.fromJson((jsonDecode(raw) as Map).cast());
    // Fire and forget: the write must not delay the picker.
    AmmPoolCache.save(set, nodeUrl: _node).catchError((_) {});
    return set;
  }

  /// Last pool list from disk, for an instant first paint while [pools]
  /// refreshes. Null when nothing was cached yet.
  Future<AmmPoolSet?> cachedPools() async => (await AmmPoolCache.load())?.set;

  Future<AmmQuote> quote({
    String? fromToken,
    String? toToken,
    required int amount,
  }) async {
    final raw = await api.ammQuote(
      fromToken: fromToken,
      toToken: toToken,
      amount: amount,
      nodeUrl: _node,
    );
    return AmmQuote.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<AmmExactQuote> quoteExactOutput({required String toToken, required int outputAmount}) async {
    final raw = await api.ammQuoteExactOutput(toToken: toToken, outputAmount: outputAmount, nodeUrl: _node);
    return AmmExactQuote.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<AmmSwapBuild> buildSwap({
    String? fromToken,
    String? toToken,
    required int amount,
    required int minOutput,
    required String poolId,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
    int heldTokens = 0,
  }) async {
    final raw = await api.ammBuildSwap(
      handleId: _requireHandle(),
      fromToken: fromToken,
      toToken: toToken,
      amount: amount,
      minOutput: minOutput,
      poolId: poolId,
      recipientAddress: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      nodeUrl: _node,
      heldTokens: heldTokens,
    );
    return AmmSwapBuild.fromJson((jsonDecode(raw) as Map).cast());
  }
}

final ammService = AmmService();

/// The two tradable sides of a pool as `(tokenId, reserveAmount)` pairs;
/// `null` tokenId is ERG.
List<(String?, BigInt)> poolSides(Map<String, dynamic> pool) {
  final y = pool['token_y'] as Map?;
  final yId = y?['token_id'] as String?;
  final yAmt = BigInt.from((y?['amount'] as num?)?.toInt() ?? 0);
  if (pool['pool_type'] == 'T2T') {
    final x = pool['token_x'] as Map?;
    return [
      (
        x?['token_id'] as String?,
        BigInt.from((x?['amount'] as num?)?.toInt() ?? 0),
      ),
      (yId, yAmt),
    ];
  }
  return [
    (null, BigInt.from((pool['erg_reserves'] as num?)?.toInt() ?? 0)),
    (yId, yAmt),
  ];
}

bool poolSupportsPair(Map<String, dynamic> pool, String? from, String? to) {
  final sides = poolSides(pool);
  bool matches(String? t) => sides.any((s) => s.$1 == t);
  return matches(from) && matches(to) && from != to;
}

/// CFMM input-for-output price used to prefill the FROM field when the user
/// types a desired TO amount. Mirrors vendored `calculator::calculate_input`
/// (`(rIn * out * feeDen) / ((rOut - out) * feeNum) + 1`); the authoritative
/// numbers still come from the forward FFI quote — this only seeds the field.
///
/// Returns null for degenerate or exceeding-reserve requests.
BigInt? requiredInputFor({
  required BigInt reservesIn,
  required BigInt reservesOut,
  required BigInt output,
  required int feeNum,
  required int feeDenom,
}) {
  if (reservesIn <= BigInt.zero ||
      reservesOut <= BigInt.zero ||
      output <= BigInt.zero ||
      output >= reservesOut ||
      feeNum <= 0 ||
      feeDenom <= 0) {
    return null;
  }
  final numerator = reservesIn * output * BigInt.from(feeDenom);
  final denominator = (reservesOut - output) * BigInt.from(feeNum);
  if (denominator <= BigInt.zero) return null;
  return numerator ~/ denominator + BigInt.one;
}

/// Cheapest pool (least required input) for receiving [output] of [to] by
/// paying [from]; returns the pool plus its two sides oriented as
/// `(inReserve, outReserve)` for the chosen direction, or null when no pool
/// can fill it.
(Map<String, dynamic>, BigInt inReserve, BigInt outReserve)?
    bestPoolForOutput({
  required List<Map<String, dynamic>> pools,
  required String? from,
  required String? to,
  required BigInt output,
}) {
  Map<String, dynamic>? best;
  var bestInput = BigInt.zero;
  var bestInReserve = BigInt.zero;
  var bestOutReserve = BigInt.zero;
  for (final pool in pools) {
    if (!poolSupportsPair(pool, from, to)) continue;
    final sides = poolSides(pool);
    final (_, rIn) = sides.firstWhere((s) => s.$1 == from);
    final (_, rOut) = sides.firstWhere((s) => s.$1 == to);
    final feeNum = (pool['fee_num'] as num?)?.toInt() ?? 0;
    final feeDenom = (pool['fee_denom'] as num?)?.toInt() ?? 1;
    final required = requiredInputFor(
      reservesIn: rIn,
      reservesOut: rOut,
      output: output,
      feeNum: feeNum,
      feeDenom: feeDenom,
    );
    if (required == null) continue;
    if (best == null || required < bestInput) {
      best = pool;
      bestInput = required;
      bestInReserve = rIn;
      bestOutReserve = rOut;
    }
  }
  if (best == null) return null;
  return (best, bestInReserve, bestOutReserve);
}
