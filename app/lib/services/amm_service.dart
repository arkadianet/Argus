import 'dart:convert';

import '../bridge/api.dart' as api;
import '../bridge/argus_error.dart';
import 'network_controller.dart';
import 'wallet_service.dart';

/// Default slippage, matching the Dexy convention in [DexyService].
const double kDefaultSlippagePct = 0.5;

/// Minimum acceptable output after slippage. Floors, so the built minimum is
/// never above what was quoted.
int minOutputFor(int output, double slippagePct) =>
    (output * (100 - slippagePct) / 100).floor();

class AmmTokenMeta {
  final String name;
  final int decimals;

  const AmmTokenMeta({required this.name, required this.decimals});

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
  final double slippagePct;

  const AmmQuote({
    required this.poolId,
    required this.boxId,
    required this.outputAmount,
    required this.outputToken,
    required this.minOutput,
    required this.priceImpactPct,
    required this.feeAmount,
    required this.slippagePct,
  });

  factory AmmQuote.fromJson(Map<String, dynamic> json) => AmmQuote(
        poolId: json['pool_id'] as String? ?? '',
        boxId: json['box_id'] as String? ?? '',
        outputAmount: (json['output_amount'] as num?)?.toInt() ?? 0,
        outputToken: json['output_token'] as String? ?? '',
        minOutput: (json['min_output'] as num?)?.toInt() ?? 0,
        priceImpactPct: (json['price_impact_pct'] as num?)?.toDouble() ?? 0,
        feeAmount: (json['fee_amount'] as num?)?.toInt() ?? 0,
        slippagePct:
            (json['slippage_pct'] as num?)?.toDouble() ?? kDefaultSlippagePct,
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
    final raw = await api.ammPools(nodeUrl: _node, forceRefresh: forceRefresh);
    return AmmPoolSet.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<AmmQuote> quote({
    String? fromToken,
    String? toToken,
    required int amount,
    double slippagePct = kDefaultSlippagePct,
  }) async {
    final raw = await api.ammQuote(
      fromToken: fromToken,
      toToken: toToken,
      amount: amount,
      slippagePct: slippagePct,
      nodeUrl: _node,
    );
    return AmmQuote.fromJson((jsonDecode(raw) as Map).cast());
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
    );
    return AmmSwapBuild.fromJson((jsonDecode(raw) as Map).cast());
  }
}

final ammService = AmmService();
