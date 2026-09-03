import '../bridge/argus_error.dart';
import 'amm_service.dart';
import 'dexy_service.dart';
import 'sigmausd_service.dart';

/// One way to acquire a token shortfall, priced.
class RouteQuote {
  const RouteQuote({
    required this.protocol,
    required this.path,
    required this.tokenId,
    required this.acquire,
    required this.held,
    required this.ergCostNano,
    required this.minerFeeNano,
    this.protocolFeeNano = 0,
    this.poolId,
    this.ergIn,
    this.note,
  });

  /// `Dexy`, `AgeUSD`, `Spectrum`.
  final String protocol;

  /// Human path inside the protocol: `FreeMint`, `LP Swap`, `Bank mint`, `Pool`.
  final String path;
  final String tokenId;
  final int acquire;
  final int held;

  /// Estimated ERG leaving the wallet, miner fee included.
  final int ergCostNano;
  final int minerFeeNano;
  final int protocolFeeNano;
  final String? poolId;

  /// Spectrum: ERG paid into the pool (before fee and box value).
  final int? ergIn;
  final String? note;

  String get label => '$protocol · $path';
}

/// A prepared buy-and-send transaction.
class RouteBuild {
  const RouteBuild({
    required this.preparationId,
    required this.protocol,
    required this.path,
    required this.tokenId,
    required this.delivered,
    required this.acquired,
    required this.held,
    required this.ergCostNano,
    required this.minerFeeNano,
    required this.protocolFeeNano,
    required this.changeNanoErg,
  });

  final int preparationId;
  final String protocol;
  final String path;
  final String tokenId;

  /// Tokens the recipient receives: acquired plus held.
  final int delivered;
  final int acquired;
  final int held;

  /// ERG paid for the acquisition (excluding miner fee and box value).
  final int ergCostNano;
  final int minerFeeNano;
  final int protocolFeeNano;
  final int changeNanoErg;
}

abstract class RouteProvider {
  String get protocol;
  bool supports(String tokenId);
  Future<List<RouteQuote>> quote(String tokenId, int acquire, int held);
  Future<RouteBuild> build(
    RouteQuote quote, {
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  });
}

class NoRouteException implements Exception {
  const NoRouteException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Finds the cheapest way to deliver a token the wallet does not fully hold:
/// prices only the shortfall across every protocol that can supply the token,
/// then builds the cheapest route, falling back to the next on failure. Held
/// tokens travel in the same transaction.
class TokenRouter {
  TokenRouter(this._providers);

  final List<RouteProvider> _providers;

  Future<List<RouteQuote>> quote(String tokenId, {required int wanted, required int held}) async {
    final acquire = shortfallFor(wanted: wanted, held: held);
    if (acquire <= 0) return const [];
    final results = await Future.wait([
      for (final p in _providers)
        if (p.supports(tokenId))
          p.quote(tokenId, acquire, held).catchError((_) => <RouteQuote>[]),
    ]);
    final all = [for (final r in results) ...r];
    all.sort((a, b) => a.ergCostNano.compareTo(b.ergCostNano));
    return all;
  }

  Future<RouteBuild> build(
    String tokenId, {
    required int wanted,
    required int held,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  }) async {
    final quotes = await quote(tokenId, wanted: wanted, held: held);
    if (quotes.isEmpty) {
      throw const NoRouteException('No route can supply this token right now.');
    }
    final errors = <String>[];
    for (final q in quotes) {
      final provider = _providers.firstWhere((p) => p.protocol == q.protocol);
      try {
        return await provider.build(q, recipient: recipient, changeAddress: changeAddress, spendAddresses: spendAddresses);
      } catch (e) {
        errors.add('${q.label}: ${_describe(e)}');
      }
    }
    throw NoRouteException(errors.join('; '));
  }

  static String _describe(Object e) {
    if (e is ArgusException) return e.message;
    if (e is String) return ArgusException.fromJson(e).message;
    return e.toString();
  }
}

/// Miner fee the protocol builders reserve (matches the Rust builders).
const _routeMinerFeeNano = 1100000;

/// A token the send screen can offer for buy-and-send.
class BuyableToken {
  const BuyableToken({required this.id, required this.name, required this.decimals, required this.protocol});
  final String id;
  final String name;
  final int decimals;
  final String protocol;
}

// ── Dexy ─────────────────────────────────────────────────────────────────

class DexyRouteProvider implements RouteProvider {
  @override
  String get protocol => 'Dexy';

  DexyVariant? _variantFor(String tokenId) {
    for (final v in DexyVariant.values) {
      if (v.tokenId == tokenId) return v;
    }
    return null;
  }

  @override
  bool supports(String tokenId) => _variantFor(tokenId) != null;

  @override
  Future<List<RouteQuote>> quote(String tokenId, int acquire, int held) async {
    final v = _variantFor(tokenId)!;
    final st = await dexService.state(v);
    return [
      for (final q in dexService.quotesForState(st, acquire))
        RouteQuote(
          protocol: 'Dexy',
          path: q.path,
          tokenId: tokenId,
          acquire: acquire,
          held: held,
          ergCostNano: q.ergCostNano,
          minerFeeNano: _routeMinerFeeNano,
        ),
    ];
  }

  @override
  Future<RouteBuild> build(RouteQuote q, {required String recipient, required String changeAddress, required List<String> spendAddresses}) async {
    final v = _variantFor(q.tokenId)!;
    final DexyBuildResult b;
    if (q.path == 'FreeMint') {
      b = await dexService.buildMint(variant: v, amount: q.acquire, recipient: recipient, changeAddress: changeAddress, spendAddresses: spendAddresses, heldTokens: q.held);
    } else {
      final st = await dexService.state(v);
      final ergIn = dexService.ergInForLpSwapOutput(st, q.acquire);
      b = await dexService.buildSwap(variant: v, direction: 'erg_to_dexy', amount: ergIn, minOutput: q.acquire, recipient: recipient, changeAddress: changeAddress, spendAddresses: spendAddresses, heldTokens: q.held);
    }
    final mint = b.action.startsWith('mint');
    return RouteBuild(
      preparationId: b.preparationId,
      protocol: 'Dexy',
      path: q.path,
      tokenId: q.tokenId,
      delivered: b.tokenAmount,
      acquired: q.acquire,
      held: q.held,
      ergCostNano: mint ? b.ergCostNano : b.inputAmount,
      minerFeeNano: b.minerFee,
      protocolFeeNano: 0,
      changeNanoErg: b.changeNanoErg,
    );
  }
}

// ── AgeUSD (SigmaUSD bank) ────────────────────────────────────────────────

class AgeUsdRouteProvider implements RouteProvider {
  @override
  String get protocol => 'AgeUSD';

  SigmaUsdAction? _mintFor(String tokenId) => switch (tokenId) {
        SigmaUsdTokens.sigUsd => SigmaUsdAction.mintSigUsd,
        SigmaUsdTokens.sigRsv => SigmaUsdAction.mintSigRsv,
        _ => null,
      };

  @override
  bool supports(String tokenId) => _mintFor(tokenId) != null;

  @override
  Future<List<RouteQuote>> quote(String tokenId, int acquire, int held) async {
    final action = _mintFor(tokenId)!;
    final p = await sigmaUsdService.preview(action, acquire);
    if (!p.canExecute) return const [];
    return [
      RouteQuote(
        protocol: 'AgeUSD',
        path: 'Bank mint',
        tokenId: tokenId,
        acquire: acquire,
        held: held,
        ergCostNano: p.totalCostNano,
        minerFeeNano: p.txFeeNano,
        protocolFeeNano: p.protocolFeeNano,
      ),
    ];
  }

  @override
  Future<RouteBuild> build(RouteQuote q, {required String recipient, required String changeAddress, required List<String> spendAddresses}) async {
    final b = await sigmaUsdService.build(
      action: _mintFor(q.tokenId)!,
      amount: q.acquire,
      recipient: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      heldTokens: q.held,
    );
    return RouteBuild(
      preparationId: b.preparationId,
      protocol: 'AgeUSD',
      path: 'Bank mint',
      tokenId: q.tokenId,
      delivered: b.tokenAmount + q.held,
      acquired: q.acquire,
      held: q.held,
      ergCostNano: b.ergAmountNano,
      minerFeeNano: b.minerFee,
      protocolFeeNano: q.protocolFeeNano,
      changeNanoErg: b.changeNanoErg,
    );
  }
}

// ── Spectrum (ERG → token pool) ──────────────────────────────────────────

class SpectrumRouteProvider implements RouteProvider {
  SpectrumRouteProvider({Set<String>? poolTokens}) : _poolTokens = poolTokens;

  /// Token ids with an ERG pool, from the cached pool list. Null = unknown,
  /// in which case any token is tried and the quote decides.
  final Set<String>? _poolTokens;

  @override
  String get protocol => 'Spectrum';

  @override
  bool supports(String tokenId) => _poolTokens == null || _poolTokens.contains(tokenId);

  @override
  Future<List<RouteQuote>> quote(String tokenId, int acquire, int held) async {
    final q = await ammService.quoteExactOutput(toToken: tokenId, outputAmount: acquire);
    final feePct = q.feeDenom == 0 ? 0.0 : (q.feeDenom - q.feeNum) * 100 / q.feeDenom;
    return [
      RouteQuote(
        protocol: 'Spectrum',
        path: 'Pool',
        tokenId: tokenId,
        acquire: acquire,
        held: held,
        ergCostNano: q.ergIn + _routeMinerFeeNano + 1000000,
        minerFeeNano: _routeMinerFeeNano,
        poolId: q.poolId,
        ergIn: q.ergIn,
        note: '${feePct.toStringAsFixed(1)}% pool fee',
      ),
    ];
  }

  @override
  Future<RouteBuild> build(RouteQuote q, {required String recipient, required String changeAddress, required List<String> spendAddresses}) async {
    // Re-quote at build time: the pool moves between quote and confirm.
    final fresh = await ammService.quoteExactOutput(toToken: q.tokenId, outputAmount: q.acquire);
    final b = await ammService.buildSwap(
      fromToken: null,
      toToken: q.tokenId,
      amount: fresh.ergIn,
      minOutput: q.acquire,
      poolId: fresh.poolId,
      recipient: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      heldTokens: q.held,
    );
    return RouteBuild(
      preparationId: b.preparationId,
      protocol: 'Spectrum',
      path: 'Pool',
      tokenId: q.tokenId,
      delivered: b.outputAmount + q.held,
      acquired: b.outputAmount,
      held: q.held,
      ergCostNano: b.inputAmount,
      minerFeeNano: b.minerFee,
      protocolFeeNano: 0,
      changeNanoErg: 0,
    );
  }
}

/// Every token buy-and-send can deliver, from protocol constants plus the
/// cached Spectrum pool list (name and decimals from its token metadata).
Future<List<BuyableToken>> buyableTokens() async {
  final out = <BuyableToken>[
    for (final v in DexyVariant.values)
      BuyableToken(id: v.tokenId, name: v.shortName, decimals: v.decimals, protocol: 'Dexy'),
    const BuyableToken(id: SigmaUsdTokens.sigUsd, name: 'SigUSD', decimals: 2, protocol: 'AgeUSD'),
    const BuyableToken(id: SigmaUsdTokens.sigRsv, name: 'SigRSV', decimals: 0, protocol: 'AgeUSD'),
  ];
  final seen = out.map((t) => t.id).toSet();
  final cached = await AmmPoolCache.load();
  if (cached != null) {
    for (final pool in cached.set.pools) {
      if (pool['pool_type'] != 'N2T' && pool['erg_reserves'] == null) continue;
      final y = pool['token_y'];
      if (y is! Map) continue;
      final id = y['token_id']?.toString() ?? '';
      if (id.isEmpty || !seen.add(id)) continue;
      final meta = cached.set.tokens[id];
      out.add(BuyableToken(
        id: id,
        name: meta?.name ?? y['name']?.toString() ?? '${id.substring(0, 8)}…',
        decimals: meta?.decimals ?? (y['decimals'] as num?)?.toInt() ?? 0,
        protocol: 'Spectrum',
      ));
    }
  }
  return out;
}

/// Token ids with an ERG pool in the cached list, for [SpectrumRouteProvider].
Future<Set<String>> spectrumPoolTokens() async {
  final cached = await AmmPoolCache.load();
  if (cached == null) return {};
  return {
    for (final pool in cached.set.pools)
      if (pool['token_y'] is Map && pool['erg_reserves'] != null)
        (pool['token_y'] as Map)['token_id'].toString(),
  };
}

final tokenRouter = TokenRouter([DexyRouteProvider(), AgeUsdRouteProvider(), SpectrumRouteProvider()]);
