import 'dart:convert';
import 'dart:math' as math;

import '../bridge/api.dart' as api;
import '../bridge/argus_error.dart';
import 'network_controller.dart';
import 'wallet_service.dart';

/// Dexy protocol variant (DexyGold / DexyUSD).
enum DexyVariant {
  gold(
    'gold',
    'DexyGold',
    '6122f7289e7bb2df2de273e09d4b2756cda6aeb0f40438dc9d257688f451' '83ad',
    0,
    '1 DexyGold = 1 mg of gold',
    'cf74432b2d3ab8a1a934b6326a1004e1a19aec7b357c57209018c4aa3522' '6246',
    'DexyGold',
  ),
  usd(
    'usd',
    'DexyUSD',
    'a55b8735ed1a99e46c2c89f8994aacdf4b1109bdcf682f1e5b34479c6e3' '92669',
    3,
    '1 USE = 1 USD',
    '804a66426283b8281240df8f9de783651986f20ad6391a71b26b9e7d6' 'faad099',
    'USE',
  );

  const DexyVariant(
    this.code,
    this.name,
    this.tokenId,
    this.decimals,
    this.peg,
    this.lpTokenId,
    this.shortName,
  );

  final String code;
  final String name;
  final String tokenId;
  final int decimals;
  final String peg;
  final String lpTokenId;
  final String shortName;
}

/// Pricing for a Dexy mint path (ArbMint / FreeMint / LP swap).
class DexyMintPath {
  final String name;
  final bool available;
  final String? reason;
  final double? ergPerToken;
  final double? tokensPerErg;
  final double? effectiveRate;
  final int? maxTokens;
  final int? remainingToday;
  final double feePercent;
  final bool isBestRate;

  DexyMintPath({
    required this.name,
    required this.available,
    this.reason,
    this.ergPerToken,
    this.tokensPerErg,
    this.effectiveRate,
    this.maxTokens,
    this.remainingToday,
    required this.feePercent,
    required this.isBestRate,
  });

  factory DexyMintPath.fromJson(Map<String, dynamic> json) => DexyMintPath(
        name: json['name'] as String? ?? '',
        available: json['available'] as bool? ?? false,
        reason: json['reason'] as String?,
        ergPerToken: (json['erg_per_token'] as num?)?.toDouble(),
        tokensPerErg: (json['tokens_per_erg'] as num?)?.toDouble(),
        effectiveRate: (json['effective_rate'] as num?)?.toDouble(),
        maxTokens: (json['max_tokens'] as num?)?.toInt(),
        remainingToday: (json['remaining_today'] as num?)?.toInt(),
        feePercent: (json['fee_percent'] as num?)?.toDouble() ?? 0,
        isBestRate: json['is_best_rate'] as bool? ?? false,
      );
}

/// Derived mint/pricing paths for a Dexy variant.
class DexyRates {
  final String variant;
  final String tokenName;
  final int tokenDecimals;
  final int oracleRateNano;
  final double ergPerToken;
  final double tokensPerErg;
  final DexyMintPath arbMint;
  final DexyMintPath freeMint;
  final DexyMintPath lpSwap;

  DexyRates({
    required this.variant,
    required this.tokenName,
    required this.tokenDecimals,
    required this.oracleRateNano,
    required this.ergPerToken,
    required this.tokensPerErg,
    required this.arbMint,
    required this.freeMint,
    required this.lpSwap,
  });

  factory DexyRates.fromJson(Map<String, dynamic> json) {
    final paths = (json['paths'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DexyRates(
      variant: json['variant'] as String? ?? '',
      tokenName: json['token_name'] as String? ?? '',
      tokenDecimals: (json['token_decimals'] as num?)?.toInt() ?? 0,
      oracleRateNano: (json['oracle_rate_nano'] as num?)?.toInt() ?? 0,
      ergPerToken: (json['erg_per_token'] as num?)?.toDouble() ?? 0,
      tokensPerErg: (json['tokens_per_erg'] as num?)?.toDouble() ?? 0,
      arbMint: DexyMintPath.fromJson(
          (paths['arb_mint'] as Map?)?.cast() ?? const {}),
      freeMint: DexyMintPath.fromJson(
          (paths['free_mint'] as Map?)?.cast() ?? const {}),
      lpSwap: DexyMintPath.fromJson(
          (paths['lp_swap'] as Map?)?.cast() ?? const {}),
    );
  }
}

/// Full read-only market snapshot for a Dexy variant.
class DexyState {
  final DexyVariant variant;
  final int bankErgNano;
  final int dexyInBank;
  final int oracleRateNano;
  final int lpErgReserves;
  final int lpDexyReserves;
  final int lpRateNano;
  final int lpTokenReserves;
  final int lpCirculating;
  final int freeMintAvailable;
  final bool canRedeemLp;
  final bool canMint;
  final double rateDifferencePct;
  final int dexyCirculating;
  final DexyRates rates;

  DexyState({
    required this.variant,
    required this.bankErgNano,
    required this.dexyInBank,
    required this.oracleRateNano,
    required this.lpErgReserves,
    required this.lpDexyReserves,
    required this.lpRateNano,
    required this.lpTokenReserves,
    required this.lpCirculating,
    required this.freeMintAvailable,
    required this.canRedeemLp,
    required this.canMint,
    required this.rateDifferencePct,
    required this.dexyCirculating,
    required this.rates,
  });

  /// Lowest effective ERG cost per token among available paths.
  DexyMintPath get bestPath {
    final candidates = [rates.arbMint, rates.freeMint, rates.lpSwap]
        .where((p) => p.available && p.effectiveRate != null)
        .toList();
    if (candidates.isEmpty) return rates.lpSwap;
    candidates.sort((a, b) => a.effectiveRate!.compareTo(b.effectiveRate!));
    return candidates.first;
  }

  factory DexyState.fromJson(Map<String, dynamic> json) {
    final stateMap = (json['state'] as Map?)?.cast<String, dynamic>() ?? {};
    final rates = DexyRates.fromJson(
      (json['rates'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    return DexyState(
      variant: rates.variant == 'usd' ? DexyVariant.usd : DexyVariant.gold,
      bankErgNano: _i(stateMap, 'bank_erg_nano'),
      dexyInBank: _i(stateMap, 'dexy_in_bank'),
      oracleRateNano: _i(stateMap, 'oracle_rate_nano'),
      lpErgReserves: _i(stateMap, 'lp_erg_reserves'),
      lpDexyReserves: _i(stateMap, 'lp_dexy_reserves'),
      lpRateNano: _i(stateMap, 'lp_rate_nano'),
      lpTokenReserves: _i(stateMap, 'lp_token_reserves'),
      lpCirculating: _i(stateMap, 'lp_circulating'),
      freeMintAvailable: _i(stateMap, 'free_mint_available'),
      canRedeemLp: stateMap['can_redeem_lp'] as bool? ?? false,
      canMint: stateMap['can_mint'] as bool? ?? false,
      rateDifferencePct:
          (stateMap['rate_difference_pct'] as num?)?.toDouble() ?? 0,
      dexyCirculating: _i(stateMap, 'dexy_circulating'),
      rates: rates,
    );
  }
}

class DexyMintPreview {
  final int ergCostNano;
  final int txFeeNano;
  final int totalCostNano;
  final int tokenAmount;
  final String tokenName;
  final bool canExecute;
  final String? error;

  DexyMintPreview({
    required this.ergCostNano,
    required this.txFeeNano,
    required this.totalCostNano,
    required this.tokenAmount,
    required this.tokenName,
    required this.canExecute,
    this.error,
  });

  factory DexyMintPreview.fromJson(Map<String, dynamic> json) =>
      DexyMintPreview(
        ergCostNano: _i(json, 'erg_cost_nano'),
        txFeeNano: _i(json, 'tx_fee_nano'),
        totalCostNano: _i(json, 'total_cost_nano'),
        tokenAmount: _i(json, 'token_amount'),
        tokenName: json['token_name'] as String? ?? '',
        canExecute: json['can_execute'] as bool? ?? false,
        error: json['error'] as String?,
      );
}

class DexySwapPreview {
  final int inputAmount;
  final int outputAmount;
  final int minOutput;
  final double priceImpactPct;
  final double feePct;
  final int minerFeeNano;
  final String outputTokenName;
  final bool canExecute;
  final String? error;

  DexySwapPreview({
    required this.inputAmount,
    required this.outputAmount,
    required this.minOutput,
    required this.priceImpactPct,
    required this.feePct,
    required this.minerFeeNano,
    required this.outputTokenName,
    required this.canExecute,
    this.error,
  });

  factory DexySwapPreview.fromJson(Map<String, dynamic> json) =>
      DexySwapPreview(
        inputAmount: _i(json, 'input_amount'),
        outputAmount: _i(json, 'output_amount'),
        minOutput: _i(json, 'min_output'),
        priceImpactPct: (json['price_impact_pct'] as num?)?.toDouble() ?? 0,
        feePct: (json['fee_pct'] as num?)?.toDouble() ?? 0,
        minerFeeNano: _i(json, 'miner_fee_nano'),
        outputTokenName: json['output_token_name'] as String? ?? '',
        canExecute: json['can_execute'] as bool? ?? false,
        error: json['error'] as String?,
      );
}

class DexyLpPreview {
  final String action; // deposit | redeem
  final int requestedErg;
  final int requestedDexy;
  final int consumedErg;
  final int consumedDexy;
  final int lpTokens;
  final int lpAmount;
  final int ergOut;
  final int dexyOut;
  final double redemptionFeePct;
  final int minerFeeNano;
  final bool canExecute;
  final String? error;

  DexyLpPreview({
    required this.action,
    this.requestedErg = 0,
    this.requestedDexy = 0,
    this.consumedErg = 0,
    this.consumedDexy = 0,
    this.lpTokens = 0,
    this.lpAmount = 0,
    this.ergOut = 0,
    this.dexyOut = 0,
    this.redemptionFeePct = 0,
    required this.minerFeeNano,
    required this.canExecute,
    this.error,
  });

  factory DexyLpPreview.fromJson(Map<String, dynamic> json) => DexyLpPreview(
        action: json['action'] as String? ?? '',
        requestedErg: _i(json, 'requested_erg'),
        requestedDexy: _i(json, 'requested_dexy'),
        consumedErg: _i(json, 'consumed_erg'),
        consumedDexy: _i(json, 'consumed_dexy'),
        lpTokens: _i(json, 'lp_tokens'),
        lpAmount: _i(json, 'lp_amount'),
        ergOut: _i(json, 'erg_out'),
        dexyOut: _i(json, 'dexy_out'),
        redemptionFeePct: (json['redemption_fee_pct'] as num?)?.toDouble() ?? 0,
        minerFeeNano: _i(json, 'miner_fee_nano'),
        canExecute: json['can_execute'] as bool? ?? false,
        error: json['error'] as String?,
      );
}

/// A built (unsigned) Dexy transaction cached for the shared confirm → broadcast
/// flow via [`WalletService.sendErg`].
class DexyBuildResult {
  final int preparationId;
  final String action;
  final String direction;
  final int inputAmount;
  final int outputAmount;
  final int minOutput;
  final int minerFee;
  final int changeNanoErg;
  final int ergCostNano;
  final int tokenAmount;
  final String tokenName;
  final double priceImpactPct;
  final double feePct;
  final int ergAmount;
  final int dexyAmount;
  final int lpTokens;
  final String recipient;

  const DexyBuildResult({
    required this.preparationId,
    this.action = '',
    this.direction = '',
    this.inputAmount = 0,
    this.outputAmount = 0,
    this.minOutput = 0,
    required this.minerFee,
    required this.changeNanoErg,
    this.ergCostNano = 0,
    this.tokenAmount = 0,
    this.tokenName = '',
    this.priceImpactPct = 0,
    this.feePct = 0,
    this.ergAmount = 0,
    this.dexyAmount = 0,
    this.lpTokens = 0,
    required this.recipient,
  });

  factory DexyBuildResult.fromJson(Map<String, dynamic> json) {
    final rawAction = json['action'] as String? ?? '';
    final action = rawAction.startsWith('lp_deposit_')
        ? 'deposit'
        : rawAction.startsWith('lp_redeem_')
            ? 'redeem'
            : rawAction;
    return DexyBuildResult(
      preparationId: _i(json, 'preparation_id'),
      action: action,
      direction: json['direction'] as String? ?? '',
      inputAmount: _i(json, 'input_amount'),
      outputAmount: _i(json, 'output_amount'),
      minOutput: _i(json, 'min_output'),
      minerFee: _i(json, 'miner_fee'),
      changeNanoErg: _i(json, 'change_nano_erg'),
      ergCostNano: _i(json, 'erg_cost_nano'),
      tokenAmount: _i(json, 'token_amount'),
      tokenName: json['token_name'] as String? ?? '',
      priceImpactPct: (json['price_impact_pct'] as num?)?.toDouble() ?? 0,
      feePct: (json['fee_pct'] as num?)?.toDouble() ?? 0,
      ergAmount: _i(json, 'erg_amount'),
      dexyAmount: _i(json, 'dexy_amount'),
      lpTokens: _i(json, 'lp_tokens'),
      recipient: json['recipient'] as String? ?? '',
    );
  }
}

int _i(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// An estimated ERG cost for delivering tokens through one route.
class DexyPathQuote {
  final String path;
  final int ergCostNano;

  const DexyPathQuote({required this.path, required this.ergCostNano});
}

const _minerFeeReserveNano = 1100000;

/// Eligibility and cost estimates per route, shared by quoting and building.
class _RoutePlan {
  final bool freeOk;
  final int freeEstimateNano;
  final int swapErgIn;

  const _RoutePlan({
    required this.freeOk,
    required this.freeEstimateNano,
    required this.swapErgIn,
  });
}

/// Talk to the FFI; every broadcast goes through the shared confirm sheet and
/// then [`WalletService.sendErg`] / [`WalletService.signPreparation`].
class DexyService {
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

  Future<DexyState> state(DexyVariant variant) async {
    final raw = await api.dexyState(variant: variant.code, nodeUrl: _node);
    return DexyState.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<DexyMintPreview> previewMint(DexyVariant variant, int amount) async {
    final raw = await api.dexyPreviewMint(
      variant: variant.code,
      amount: amount,
      nodeUrl: _node,
    );
    return DexyMintPreview.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<DexySwapPreview> previewSwap(
    DexyVariant variant,
    String direction,
    int amount, {
    double slippagePct = 0.5,
  }) async {
    final raw = await api.dexyPreviewSwap(
      variant: variant.code,
      direction: direction,
      amount: amount,
      slippagePct: slippagePct,
      nodeUrl: _node,
    );
    return DexySwapPreview.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<DexyLpPreview> previewLp(
    DexyVariant variant,
    String action, {
    int ergAmount = 0,
    int dexyAmount = 0,
    int lpAmount = 0,
  }) async {
    final raw = await api.dexyPreviewLp(
      variant: variant.code,
      action: action,
      ergAmount: ergAmount,
      dexyAmount: dexyAmount,
      lpAmount: lpAmount,
      nodeUrl: _node,
    );
    return DexyLpPreview.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<DexyBuildResult> buildMint({
    required DexyVariant variant,
    required int amount,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  }) async {
    final raw = await api.dexyBuildMint(
      handleId: _requireHandle(),
      variant: variant.code,
      amount: amount,
      recipientAddress: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      nodeUrl: _node,
    );
    return DexyBuildResult.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<DexyBuildResult> buildSwap({
    required DexyVariant variant,
    required String direction,
    required int amount,
    required int minOutput,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  }) async {
    final raw = await api.dexyBuildSwap(
      handleId: _requireHandle(),
      variant: variant.code,
      direction: direction,
      amount: amount,
      minOutput: minOutput,
      recipientAddress: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      nodeUrl: _node,
    );
    return DexyBuildResult.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<DexyBuildResult> buildLpDeposit({
    required DexyVariant variant,
    required int depositErg,
    required int depositDexy,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  }) async {
    final raw = await api.dexyBuildLpDeposit(
      handleId: _requireHandle(),
      variant: variant.code,
      depositErg: depositErg,
      depositDexy: depositDexy,
      recipientAddress: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      nodeUrl: _node,
    );
    return DexyBuildResult.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<DexyBuildResult> buildLpRedeem({
    required DexyVariant variant,
    required int lpToBurn,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  }) async {
    final raw = await api.dexyBuildLpRedeem(
      handleId: _requireHandle(),
      variant: variant.code,
      lpToBurn: lpToBurn,
      recipientAddress: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      nodeUrl: _node,
    );
    return DexyBuildResult.fromJson((jsonDecode(raw) as Map).cast());
  }

  /// ERG needed as LP-swap input to receive at least [tokenOut] tokens.
  /// Inverts the contract formula out = Y·in·f / (X·d + in·f).
  /// Returns 0 when the result cannot be represented as an int.
  int ergInForLpSwapOutput(DexyState st, int tokenOut) {
    final x = st.lpErgReserves;
    final y = st.lpDexyReserves;
    const d = 1000;
    const f = 997; // pass-through portion of the 0.3% fee
    if (tokenOut <= 0 || y <= 0 || tokenOut >= y || x <= 0) return 0;
    final num = BigInt.from(tokenOut) * BigInt.from(x) * BigInt.from(d);
    final den = BigInt.from(f) * BigInt.from(y - tokenOut);
    final ergIn = (num + den - BigInt.one) ~/ den;
    if (!ergIn.isValidInt) return 0;
    return ergIn.toInt();
  }

  /// FreeMint cost in nanoERG for [tokenAmount] *raw* base units.
  ///
  /// `effective_rate` / `erg_per_token` arrive from Rust as ERG per **display**
  /// token (see `DexyRates::from_state`), so converting to nanoERG per raw unit
  /// needs both the 1e9 ERG→nanoERG scale and the token's decimals.
  int _freeMintCostNano(DexyState st, int tokenAmount) {
    final ergPerDisplay =
        st.rates.freeMint.effectiveRate ?? st.rates.ergPerToken;
    final perDisplayUnit = math.pow(10, st.rates.tokenDecimals).toDouble();
    return (ergPerDisplay * tokenAmount * 1e9 / perDisplayUnit).ceil();
  }

  /// Route eligibility and cost estimates shared by [quoteTokenSend] and
  /// [buildTokenSend], so displayed quotes and built routes always agree.
  _RoutePlan _planRoutes(DexyState st, int tokenAmount) {
    final free = st.rates.freeMint;
    final limit = [
      free.maxTokens,
      free.remainingToday,
      st.freeMintAvailable,
    ].whereType<int>().fold<int>(0x7fffffffffffffff, (a, b) => a < b ? a : b);
    final freeOk =
        free.available && tokenAmount <= limit && tokenAmount <= st.dexyInBank;
    var swapErgIn = 0;
    if (st.lpErgReserves > 0 && st.lpDexyReserves > tokenAmount) {
      swapErgIn = ergInForLpSwapOutput(st, tokenAmount);
    }
    final freeEstimateNano = freeOk ? _freeMintCostNano(st, tokenAmount) : 0;
    return _RoutePlan(
      freeOk: freeOk,
      freeEstimateNano: freeEstimateNano,
      swapErgIn: swapErgIn,
    );
  }

  /// Estimated total ERG cost to deliver [tokenAmount] via each executable
  /// path, cheapest first. FreeMint pays bank+buyback at the oracle rate;
  /// LP swap uses pool reserves. No transaction is built.
  Future<List<DexyPathQuote>> quoteTokenSend(
    DexyVariant variant,
    int tokenAmount,
  ) async {
    return quotesForState(await state(variant), tokenAmount);
  }

  /// [quoteTokenSend] against an already-fetched snapshot.
  List<DexyPathQuote> quotesForState(DexyState st, int tokenAmount) {
    final plan = _planRoutes(st, tokenAmount);
    final quotes = <DexyPathQuote>[];
    // Oracle rate per token + miner fee (protocol fees included in rate).
    if (plan.freeOk) {
      quotes.add(DexyPathQuote(
        path: 'FreeMint',
        ergCostNano: plan.freeEstimateNano + _minerFeeReserveNano,
      ));
    }
    if (plan.swapErgIn > 0) {
      quotes.add(DexyPathQuote(
        path: 'LP Swap',
        ergCostNano: plan.swapErgIn + _minerFeeReserveNano,
      ));
    }
    quotes.sort((a, b) => a.ergCostNano.compareTo(b.ergCostNano));
    return quotes;
  }

  /// Deliver exactly [tokenAmount] of [variant] tokens to [recipient] —
  /// external addresses allowed — paying from [spendAddresses] and returning
  /// ERG change to wallet-owned [changeAddress]. Picks the cheapest available
  /// path and falls back to the next on build failure.
  Future<DexyBuildResult> buildTokenSend({
    required DexyVariant variant,
    required int tokenAmount,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  }) async {
    final st = await state(variant);
    final plan = _planRoutes(st, tokenAmount);
    final errors = <String>[];

    final tryFreeFirst = plan.freeOk &&
        (plan.swapErgIn == 0 || plan.freeEstimateNano <= plan.swapErgIn);

    Future<DexyBuildResult> doMint() async {
      return buildMint(
        variant: variant,
        amount: tokenAmount,
        recipient: recipient,
        changeAddress: changeAddress,
        spendAddresses: spendAddresses,
      );
    }

    Future<DexyBuildResult> doSwap() async {
      return buildSwap(
        variant: variant,
        direction: 'erg_to_dexy',
        amount: plan.swapErgIn,
        minOutput: tokenAmount,
        recipient: recipient,
        changeAddress: changeAddress,
        spendAddresses: spendAddresses,
      );
    }

    if (tryFreeFirst) {
      try {
        return await doMint();
      } catch (e) {
        errors.add('FreeMint: $e');
      }
    }
    if (plan.swapErgIn > 0) {
      try {
        return await doSwap();
      } catch (e) {
        errors.add('LP Swap: $e');
      }
    }
    if (!tryFreeFirst && plan.freeOk) {
      try {
        return await doMint();
      } catch (e) {
        errors.add('FreeMint: $e');
      }
    }
    throw ArgusException(
      code: 'NO_ROUTE',
      message: errors.isEmpty
          ? 'No route can supply $tokenAmount ${variant.shortName}'
          : errors.join('; '),
    );
  }
}

final dexService = DexyService();