import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api/arbitrage.dart' as arb_api;
import '../bridge/argus_error.dart';
import 'network_controller.dart';
import 'token_pricing.dart';
import 'verified_tokens.dart';
import 'wallet_service.dart';

/// Pools on an arbitrage route must be this deep, the same floor that
/// decides whether a pool may set a price: shallow pools are where a pool
/// owner can pull the liquidity out from under a chain.
const arbMinDepthErg = poolDepthFloorErg;

/// Profit below this is not shown unless the user lowers it: small gaps
/// are gone by the time a phone signs.
const arbDefaultMinProfitNano = 10000000;

/// How often the screen re-reads the pools while it is open.
const arbScanInterval = Duration(seconds: 30);

/// How often a broadcast chain is checked while the screen is open.
const arbStatusInterval = Duration(seconds: 10);

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
int? _intOrNull(Object? v) => (v as num?)?.toInt();
double _double(Object? v) => (v as num?)?.toDouble() ?? 0;

/// One swap of a chain: one transaction against one pool.
class ArbLeg {
  const ArbLeg({
    required this.poolId,
    required this.boxId,
    required this.fromTokenId,
    required this.toTokenId,
    required this.amountIn,
    required this.amountOut,
    required this.priceImpactPct,
  });

  final String poolId;
  final String boxId;

  /// Null is ERG.
  final String? fromTokenId;
  final String? toTokenId;
  final int amountIn;
  final int amountOut;
  final double priceImpactPct;

  factory ArbLeg.fromJson(Map<String, dynamic> j) => ArbLeg(
        poolId: j['pool_id'] as String,
        boxId: j['box_id'] as String,
        fromTokenId: j['from_token_id'] as String?,
        toTokenId: j['to_token_id'] as String?,
        amountIn: _int(j['amount_in']),
        amountOut: _int(j['amount_out']),
        priceImpactPct: _double(j['price_impact_pct']),
      );

  Map<String, dynamic> toRouteJson() => {
        'pool_id': poolId,
        'from_token_id': fromTokenId,
        'to_token_id': toTokenId,
      };
}

/// An ERG → … → ERG cycle that returns more ERG than it takes, with every
/// cost a real chain pays already subtracted.
class ArbOpportunity {
  const ArbOpportunity({
    required this.legs,
    required this.inputNano,
    required this.outputNano,
    required this.grossProfitNano,
    required this.minerFeesNano,
    required this.appFeesNano,
    required this.netProfitNano,
    required this.profitPct,
    required this.boxMinInTransitNano,
    required this.capitalNano,
    required this.unwindLossNano,
    required this.optimalInputNano,
    required this.sizedToBalance,
    required this.affordable,
    required this.trusted,
  });

  final List<ArbLeg> legs;
  final int inputNano;
  final int outputNano;

  /// What the pools return over what goes in, after their own fees.
  final int grossProfitNano;
  final int minerFeesNano;
  final int appFeesNano;

  /// Gross minus every leg's miner and Argus fee.
  final int netProfitNano;
  final double profitPct;

  /// ERG riding with the token between legs; the next leg returns it.
  final int boxMinInTransitNano;

  /// ERG the wallet must hold to run the chain.
  final int capitalNano;

  /// ERG lost if only the first leg lands and the token is sold back.
  final int? unwindLossNano;
  final int optimalInputNano;
  final bool sizedToBalance;
  final bool affordable;

  /// Every token on the route is on the verified list.
  final bool trusted;

  /// The pools in trade order: identifies the route across scans.
  String get key => legs.map((l) => l.poolId).join('>');

  factory ArbOpportunity.fromJson(Map<String, dynamic> j) => ArbOpportunity(
        legs: [for (final l in (j['legs'] as List? ?? const [])) ArbLeg.fromJson((l as Map).cast())],
        inputNano: _int(j['input_nano']),
        outputNano: _int(j['output_nano']),
        grossProfitNano: _int(j['gross_profit_nano']),
        minerFeesNano: _int(j['miner_fees_nano']),
        appFeesNano: _int(j['app_fees_nano']),
        netProfitNano: _int(j['net_profit_nano']),
        profitPct: _double(j['profit_pct']),
        boxMinInTransitNano: _int(j['box_min_in_transit_nano']),
        capitalNano: _int(j['capital_nano']),
        unwindLossNano: _intOrNull(j['unwind_loss_nano']),
        optimalInputNano: _int(j['optimal_input_nano']),
        sizedToBalance: j['sized_to_balance'] == true,
        affordable: j['affordable'] != false,
        trusted: j['trusted'] == true,
      );
}

class ArbScanResult {
  const ArbScanResult({
    required this.opportunities,
    required this.scannedAt,
    required this.height,
    required this.poolCount,
    required this.poolsInGraph,
    required this.cyclesChecked,
    required this.skippedBusy,
    required this.skippedUntrusted,
    required this.truncated,
    required this.mempoolChecked,
    required this.minerFeeNano,
    required this.appFeeNano,
  });

  final List<ArbOpportunity> opportunities;
  final DateTime scannedAt;
  final int height;
  final int poolCount;

  /// Pools deep enough to be on a route.
  final int poolsInGraph;
  final int cyclesChecked;

  /// Opportunities left out because a mempool transaction is already
  /// trading one of their pools.
  final int skippedBusy;
  final int skippedUntrusted;
  final bool truncated;

  /// False when the mempool could not be read, so busy pools are unknown.
  final bool mempoolChecked;
  final int minerFeeNano;
  final int appFeeNano;

  factory ArbScanResult.fromJson(Map<String, dynamic> j, DateTime at) {
    final costs = (j['costs'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ArbScanResult(
      opportunities: [
        for (final o in (j['opportunities'] as List? ?? const [])) ArbOpportunity.fromJson((o as Map).cast()),
      ],
      scannedAt: at,
      height: _int(j['height']),
      poolCount: _int(j['pool_count']),
      poolsInGraph: _int(j['pools_in_graph']),
      cyclesChecked: _int(j['cycles_checked']),
      skippedBusy: _int(j['skipped_busy']),
      skippedUntrusted: _int(j['skipped_untrusted']),
      truncated: j['truncated'] == true,
      mempoolChecked: j['mempool_checked'] == true,
      minerFeeNano: _int(costs['miner_fee_nano']),
      appFeeNano: _int(costs['app_fee_nano']),
    );
  }
}

/// A chain built against pools read moments ago, ready to sign.
class ArbChainReview {
  const ArbChainReview({required this.chainId, required this.opportunity, required this.txIds, required this.expiresIn});

  final int chainId;
  final ArbOpportunity opportunity;
  final List<String> txIds;
  final Duration expiresIn;

  factory ArbChainReview.fromJson(Map<String, dynamic> j) => ArbChainReview(
        chainId: _int(j['chain_id']),
        opportunity: ArbOpportunity.fromJson(j),
        txIds: [for (final t in (j['tx_ids'] as List? ?? const [])) t as String],
        expiresIn: Duration(seconds: _int(j['expires_in_secs'])),
      );
}

/// The token a broken chain left in the wallet instead of ERG.
class ArbHolding {
  const ArbHolding({required this.tokenId, required this.amount, required this.boxId, required this.afterLeg});

  final String tokenId;
  final int amount;
  final String? boxId;

  /// The index of the leg that did not land; the leg before it bought this.
  final int afterLeg;

  static ArbHolding? fromJson(Object? v) {
    if (v is! Map) return null;
    return ArbHolding(
      tokenId: v['token_id'] as String,
      amount: _int(v['amount']),
      boxId: v['box_id'] as String?,
      afterLeg: _int(v['after_leg']),
    );
  }
}

enum ArbExecutionStatus { submitted, stranded, rejected, moved }

class ArbExecution {
  const ArbExecution({required this.status, this.txIds = const [], this.failedLeg, this.error, this.holding});

  final ArbExecutionStatus status;
  final List<String> txIds;
  final int? failedLeg;
  final String? error;
  final ArbHolding? holding;

  factory ArbExecution.fromJson(Map<String, dynamic> j) => ArbExecution(
        status: ArbExecutionStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => ArbExecutionStatus.rejected),
        txIds: [for (final t in (j['tx_ids'] as List? ?? const [])) t as String],
        failedLeg: _intOrNull(j['failed_leg']),
        error: j['error'] as String?,
        holding: ArbHolding.fromJson(j['holding']),
      );
}

enum ArbChainState { complete, inFlight, nothingHappened, stranded }

enum ArbLegStatus { notSubmitted, pending, confirmed, missing }

class ArbChainStatus {
  const ArbChainStatus({required this.state, required this.legs, this.failedLeg, this.holding});

  final ArbChainState state;
  final List<ArbLegStatus> legs;
  final int? failedLeg;
  final ArbHolding? holding;

  factory ArbChainStatus.fromJson(Map<String, dynamic> j) => ArbChainStatus(
        state: switch (j['state']) {
          'complete' => ArbChainState.complete,
          'nothing_happened' => ArbChainState.nothingHappened,
          'stranded' => ArbChainState.stranded,
          _ => ArbChainState.inFlight,
        },
        legs: [
          for (final l in (j['legs'] as List? ?? const []))
            switch ((l as Map)['status']) {
              'pending' => ArbLegStatus.pending,
              'confirmed' => ArbLegStatus.confirmed,
              'missing' => ArbLegStatus.missing,
              _ => ArbLegStatus.notSubmitted,
            },
        ],
        failedLeg: _intOrNull(j['failed_leg']),
        holding: ArbHolding.fromJson(j['holding']),
      );
}

/// The stranded token's sale back to ERG, prepared for the confirm sheet.
class ArbUnwind {
  const ArbUnwind({
    required this.preparationId,
    required this.poolId,
    required this.tokenId,
    required this.inputAmount,
    required this.outputNano,
    required this.minerFeeNano,
    required this.appFeeNano,
    required this.priceImpactPct,
  });

  final int preparationId;
  final String poolId;
  final String tokenId;
  final int inputAmount;
  final int outputNano;
  final int minerFeeNano;
  final int appFeeNano;
  final double priceImpactPct;

  factory ArbUnwind.fromJson(Map<String, dynamic> j) => ArbUnwind(
        preparationId: _int(j['preparation_id']),
        poolId: j['pool_id'] as String,
        tokenId: j['token_id'] as String,
        inputAmount: _int(j['input_amount']),
        outputNano: _int(j['output_amount']),
        minerFeeNano: _int(j['miner_fee']),
        appFeeNano: _int(j['app_fee']),
        priceImpactPct: _double(j['price_impact_pct']),
      );
}

/// The Rust calls, injectable for tests.
class ArbitrageApi {
  const ArbitrageApi();

  Future<String> scan({String? nodeUrl, required String optionsJson}) =>
      arb_api.arbitrageScan(nodeUrl: nodeUrl, optionsJson: optionsJson);

  Future<String> prepare({required BigInt handleId, required String requestJson, String? nodeUrl}) =>
      arb_api.arbitragePrepare(handleId: handleId, requestJson: requestJson, nodeUrl: nodeUrl);

  void discard(BigInt chainId) => arb_api.arbitrageDiscard(chainId: chainId);

  Future<String> execute({required BigInt handleId, required BigInt chainId}) =>
      arb_api.arbitrageExecute(handleId: handleId, chainId: chainId);

  Future<String> status(BigInt chainId) => arb_api.arbitrageStatus(chainId: chainId);

  Future<String> prepareUnwind({required BigInt handleId, required BigInt chainId}) =>
      arb_api.arbitragePrepareUnwind(handleId: handleId, chainId: chainId);
}

/// Circular arbitrage across Spectrum pools: what the screen calls.
class ArbitrageService {
  ArbitrageService({ArbitrageApi api = const ArbitrageApi(), String? Function()? nodeUrl, BigInt? Function()? handle})
      : _api = api,
        _nodeUrl = nodeUrl ?? (() => networkController.activeUrl),
        _handle = handle ?? (() => walletService.handleId);

  final ArbitrageApi _api;
  final String? Function() _nodeUrl;
  final BigInt? Function() _handle;

  static const _minProfitKey = 'argus_arb_min_profit_nano';

  BigInt _requireHandle() {
    final h = _handle();
    if (h == null) throw ArgusException(code: 'WALLET_LOCKED', message: 'Wallet is locked');
    return h;
  }

  Future<int> loadMinProfit() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_minProfitKey) ?? arbDefaultMinProfitNano;
  }

  Future<void> saveMinProfit(int nano) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_minProfitKey, nano);
  }

  /// Every opportunity the pools offer right now, read fresh from the node.
  Future<ArbScanResult> scan({required int minProfitNano, required bool includeUntrusted, int? availableNano}) async {
    final raw = await _api.scan(
      nodeUrl: _nodeUrl(),
      optionsJson: jsonEncode({
        'min_profit_nano': minProfitNano,
        'min_depth_nano': (arbMinDepthErg * 1e9).round(),
        'max_legs': 3,
        'available_nano': availableNano,
        'trusted_token_ids': [
          for (final t in verifiedTokens)
            if (t.isVerified) t.id,
        ],
        'include_untrusted': includeUntrusted,
      }),
    );
    return ArbScanResult.fromJson((jsonDecode(raw) as Map).cast(), DateTime.now());
  }

  /// Re-reads the route's pools, re-sizes, builds and checks every leg.
  Future<ArbChainReview> prepare(
    ArbOpportunity o, {
    required int minProfitNano,
    int? availableNano,
    required List<String> spendAddresses,
    required String changeAddress,
  }) async {
    final raw = await _api.prepare(
      handleId: _requireHandle(),
      nodeUrl: _nodeUrl(),
      requestJson: jsonEncode({
        'legs': [for (final l in o.legs) l.toRouteJson()],
        'min_profit_nano': minProfitNano,
        'available_nano': availableNano,
        'spend_addresses': spendAddresses,
        'change_address': changeAddress,
      }),
    );
    return ArbChainReview.fromJson((jsonDecode(raw) as Map).cast());
  }

  void discard(int chainId) => _api.discard(BigInt.from(chainId));

  /// Signs and broadcasts every leg. Each accepted leg is reported to the
  /// wallet like any broadcast, so Activity shows it at once.
  Future<ArbExecution> execute(int chainId) async {
    final raw = await _api.execute(handleId: _requireHandle(), chainId: BigInt.from(chainId));
    final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
    final result = ArbExecution.fromJson(map);
    final deltas = (map['wallet_deltas'] as List?) ?? const [];
    for (var i = 0; i < result.txIds.length; i++) {
      try {
        walletService.onBroadcast?.call(result.txIds[i], i < deltas.length ? _intOrNull(deltas[i]) : null);
      } catch (_) {
        // Activity is a convenience; the chain is already out.
      }
    }
    return result;
  }

  Future<ArbChainStatus> status(int chainId) async =>
      ArbChainStatus.fromJson((jsonDecode(await _api.status(BigInt.from(chainId))) as Map).cast());

  Future<ArbUnwind> prepareUnwind(int chainId) async => ArbUnwind.fromJson(
        (jsonDecode(await _api.prepareUnwind(handleId: _requireHandle(), chainId: BigInt.from(chainId))) as Map).cast(),
      );
}

final arbitrageService = ArbitrageService();

/// Scans while the screen is open and in front, never otherwise: one
/// scan at a time, the newest answer wins.
class ArbitrageScanner extends ChangeNotifier {
  ArbitrageScanner({
    required this.scan,
    this.interval = arbScanInterval,
  });

  final Future<ArbScanResult> Function() scan;
  final Duration interval;

  ArbScanResult? result;
  Object? error;
  bool scanning = false;
  bool _active = false;
  Timer? _timer;
  int _gen = 0;

  bool get active => _active;

  /// Scan now and every [interval] until [stop] or [pause].
  void start() {
    if (_active) return;
    _active = true;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => refresh());
    refresh();
  }

  /// The app went to the background: no scans until [start] again.
  void pause() => stop();

  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    _gen++;
    if (scanning) {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (scanning) return;
    final gen = ++_gen;
    scanning = true;
    notifyListeners();
    try {
      final r = await scan();
      if (gen != _gen) return;
      result = r;
      error = null;
    } catch (e) {
      if (gen != _gen) return;
      error = e;
    } finally {
      if (gen == _gen) {
        scanning = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
