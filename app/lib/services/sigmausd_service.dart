import 'dart:convert';

import '../bridge/api.dart' as api;
import '../bridge/argus_error.dart';
import 'network_controller.dart';
import 'wallet_service.dart';

/// One of the four AgeUSD bank actions.
enum SigmaUsdAction {
  mintSigUsd('mint_sigusd', 'Mint', 'SigUSD', 2),
  redeemSigUsd('redeem_sigusd', 'Redeem', 'SigUSD', 2),
  mintSigRsv('mint_sigrsv', 'Mint', 'SigRSV', 0),
  redeemSigRsv('redeem_sigrsv', 'Redeem', 'SigRSV', 0);

  const SigmaUsdAction(this.code, this.verb, this.tokenName, this.decimals);

  final String code;
  final String verb;
  final String tokenName;
  final int decimals;

  bool get isRedeem => this == SigmaUsdAction.redeemSigUsd ||
      this == SigmaUsdAction.redeemSigRsv;

  static SigmaUsdAction? tryParse(String code) {
    for (final a in SigmaUsdAction.values) {
      if (a.code == code) return a;
    }
    return null;
  }
}

/// Token ids of the AgeUSD protocol on Ergo mainnet.
class SigmaUsdTokens {
  static const sigUsd =
      '03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04';
  static const sigRsv =
      '003bd19d0187117f130b62e1bcab0939929ff5c7709f843c5c4dd158949285d0';
}

/// Live AgeUSD protocol state parsed from bank + oracle boxes.
class SigmaUsdStateData {
  final int bankErgNano;
  final int sigUsdCirculating;
  final int sigRsvCirculating;
  final int oracleNanoErgPerUsd;
  final double reserveRatioPct;
  final int sigUsdPriceNano;
  final int sigRsvPriceNano;
  final int liabilitiesNano;
  final int equityNano;
  final bool canMintSigUsd;
  final bool canMintSigRsv;
  final bool canRedeemSigRsv;
  final int maxSigUsdMintable;
  final int maxSigRsvMintable;
  final int maxSigRsvRedeemable;

  SigmaUsdStateData({
    required this.bankErgNano,
    required this.sigUsdCirculating,
    required this.sigRsvCirculating,
    required this.oracleNanoErgPerUsd,
    required this.reserveRatioPct,
    required this.sigUsdPriceNano,
    required this.sigRsvPriceNano,
    required this.liabilitiesNano,
    required this.equityNano,
    required this.canMintSigUsd,
    required this.canMintSigRsv,
    required this.canRedeemSigRsv,
    required this.maxSigUsdMintable,
    required this.maxSigRsvMintable,
    required this.maxSigRsvRedeemable,
  });

  factory SigmaUsdStateData.fromJson(Map<String, dynamic> json) =>
      SigmaUsdStateData(
        bankErgNano: _i(json, 'bank_erg_nano'),
        sigUsdCirculating: _i(json, 'sigusd_circulating'),
        sigRsvCirculating: _i(json, 'sigrsv_circulating'),
        oracleNanoErgPerUsd: _i(json, 'oracle_erg_per_usd_nano'),
        reserveRatioPct:
            (json['reserve_ratio_pct'] as num?)?.toDouble() ?? 0,
        sigUsdPriceNano: _i(json, 'sigusd_price_nano'),
        sigRsvPriceNano: _i(json, 'sigrsv_price_nano'),
        liabilitiesNano: _i(json, 'liabilities_nano'),
        equityNano: _i(json, 'equity_nano'),
        canMintSigUsd: json['can_mint_sigusd'] as bool? ?? false,
        canMintSigRsv: json['can_mint_sigrsv'] as bool? ?? false,
        canRedeemSigRsv: json['can_redeem_sigrsv'] as bool? ?? false,
        maxSigUsdMintable: _i(json, 'max_sigusd_mintable'),
        maxSigRsvMintable: _i(json, 'max_sigrsv_mintable'),
        maxSigRsvRedeemable: _i(json, 'max_sigrsv_redeemable'),
      );

  /// Availability gate for [action] under the current reserve ratio.
  bool can(SigmaUsdAction action) {
    switch (action) {
      case SigmaUsdAction.mintSigUsd:
        return canMintSigUsd;
      case SigmaUsdAction.redeemSigUsd:
        return true;
      case SigmaUsdAction.mintSigRsv:
        return canMintSigRsv;
      case SigmaUsdAction.redeemSigRsv:
        return canRedeemSigRsv;
    }
  }

  /// Protocol-side cap for minting this action's token.
  int maxFor(SigmaUsdAction action) {
    switch (action) {
      case SigmaUsdAction.mintSigUsd:
        return maxSigUsdMintable;
      case SigmaUsdAction.mintSigRsv:
        return maxSigRsvMintable;
      case SigmaUsdAction.redeemSigUsd:
      case SigmaUsdAction.redeemSigRsv:
        return 0x7fffffffffffffff;
    }
  }
}

/// Cost/proceeds preview for a bank action.
class SigmaUsdPreview {
  final SigmaUsdAction action;
  final int tokenAmount;
  final String tokenName;
  final int ergCostNano;
  final int ergOutNano;
  final int protocolFeeNano;
  final int txFeeNano;
  final int totalCostNano;
  final bool canExecute;
  final String? error;

  SigmaUsdPreview({
    required this.action,
    required this.tokenAmount,
    required this.tokenName,
    required this.ergCostNano,
    required this.ergOutNano,
    required this.protocolFeeNano,
    required this.txFeeNano,
    required this.totalCostNano,
    required this.canExecute,
    this.error,
  });

  factory SigmaUsdPreview.fromJson(Map<String, dynamic> json) =>
      SigmaUsdPreview(
        action: SigmaUsdAction.tryParse(json['action'] as String? ?? '') ??
            SigmaUsdAction.mintSigUsd,
        tokenAmount: _i(json, 'token_amount'),
        tokenName: json['token_name'] as String? ?? '',
        ergCostNano: _i(json, 'erg_cost_nano'),
        ergOutNano: _i(json, 'erg_out_nano'),
        protocolFeeNano: _i(json, 'protocol_fee_nano'),
        txFeeNano: _i(json, 'tx_fee_nano'),
        totalCostNano: _i(json, 'total_cost_nano'),
        canExecute: json['can_execute'] as bool? ?? false,
        error: json['error'] as String?,
      );
}

/// A built (unsigned) SigmaUSD transaction cached for the shared confirm →
/// broadcast flow via [`WalletService.sendErg`].
class SigmaUsdBuildResult {
  final int preparationId;
  final String action;
  final int tokenAmount;
  final String tokenName;
  final int ergAmountNano;
  final int minerFee;
  final int changeNanoErg;

  const SigmaUsdBuildResult({
    required this.preparationId,
    required this.action,
    required this.tokenAmount,
    required this.tokenName,
    required this.ergAmountNano,
    required this.minerFee,
    required this.changeNanoErg,
  });

  factory SigmaUsdBuildResult.fromJson(Map<String, dynamic> json) =>
      SigmaUsdBuildResult(
        preparationId: _i(json, 'preparation_id'),
        action: json['action'] as String? ?? '',
        tokenAmount: _i(json, 'token_amount'),
        tokenName: json['token_name'] as String? ?? '',
        ergAmountNano: _i(json, 'erg_amount_nano'),
        minerFee: _i(json, 'miner_fee'),
        changeNanoErg: _i(json, 'change_nano_erg'),
      );

  SigmaUsdAction? get parsed => SigmaUsdAction.tryParse(action);
}

int _i(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// Talk to the FFI; every broadcast goes through the shared confirm sheet and
/// then [`WalletService.sendErg`].
class SigmaUsdService {
  String? get _node => networkController.activeUrl;

  BigInt _requireHandle() {
    final handle = walletService.handleId;
    if (handle == null) {
      throw ArgusException(code: 'WALLET_LOCKED', message: 'Wallet is locked');
    }
    return handle;
  }

  Future<SigmaUsdStateData> state() async {
    final raw = await api.sigmausdState(nodeUrl: _node);
    return SigmaUsdStateData.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<SigmaUsdPreview> preview(SigmaUsdAction action, int amount) async {
    final raw = await api.sigmausdPreview(
      action: action.code,
      amount: amount,
      nodeUrl: _node,
    );
    return SigmaUsdPreview.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<SigmaUsdBuildResult> build({
    required SigmaUsdAction action,
    required int amount,
    required String recipient,
    required String changeAddress,
    required List<String> spendAddresses,
  }) async {
    final raw = await api.sigmausdBuild(
      handleId: _requireHandle(),
      action: action.code,
      amount: amount,
      recipientAddress: recipient,
      changeAddress: changeAddress,
      spendAddresses: spendAddresses,
      nodeUrl: _node,
    );
    return SigmaUsdBuildResult.fromJson((jsonDecode(raw) as Map).cast());
  }
}

final sigmaUsdService = SigmaUsdService();
