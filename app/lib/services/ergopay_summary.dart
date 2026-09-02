import '../format.dart';
import '../ui/confirm_transaction_sheet.dart';
import 'wallet_service.dart';

class ErgoPayTokenAmount {
  const ErgoPayTokenAmount(this.id, this.amount);
  final String id;
  final int amount;
}

class ErgoPayOutput {
  const ErgoPayOutput({required this.address, required this.valueNano, required this.tokens, required this.kind});
  final String address;
  final int valueNano;
  final List<ErgoPayTokenAmount> tokens;

  /// `recipient`, `change` or `fee`.
  final String kind;
}

/// What a reduced transaction does, as reported by the Rust
/// `describe_reduced_transaction` call.
class ErgoPaySummary {
  const ErgoPaySummary({
    required this.txId,
    required this.outputs,
    required this.feeNano,
    required this.sentNano,
    required this.changeNano,
    required this.spendNano,
    required this.inputsKnown,
    required this.allInputsOwned,
    required this.inputCount,
    required this.tokensOut,
  });

  final String txId;
  final List<ErgoPayOutput> outputs;
  final int feeNano;
  final int sentNano;
  final int changeNano;

  /// Inputs minus change; null when input values could not be fetched.
  final int? spendNano;
  final bool inputsKnown;
  final bool allInputsOwned;
  final int inputCount;
  final List<ErgoPayTokenAmount> tokensOut;

  List<ErgoPayOutput> get recipients =>
      outputs.where((o) => o.kind == 'recipient').toList();

  factory ErgoPaySummary.fromJson(Map<String, dynamic> j) {
    List<ErgoPayTokenAmount> toks(dynamic raw) => [
          for (final t in (raw as List? ?? const []))
            if (t is Map)
              ErgoPayTokenAmount(
                t['id']?.toString() ?? '',
                (t['amount'] as num?)?.toInt() ?? 0,
              ),
        ];
    return ErgoPaySummary(
      txId: j['tx_id']?.toString() ?? '',
      outputs: [
        for (final o in (j['outputs'] as List? ?? const []))
          if (o is Map)
            ErgoPayOutput(
              address: o['address']?.toString() ?? '',
              valueNano: (o['value_nano_erg'] as num?)?.toInt() ?? 0,
              tokens: toks(o['tokens']),
              kind: o['kind']?.toString() ?? 'recipient',
            ),
      ],
      feeNano: (j['fee_nano_erg'] as num?)?.toInt() ?? 0,
      sentNano: (j['sent_nano_erg'] as num?)?.toInt() ?? 0,
      changeNano: (j['change_nano_erg'] as num?)?.toInt() ?? 0,
      spendNano: (j['spend_nano_erg'] as num?)?.toInt(),
      inputsKnown: j['inputs_known'] == true,
      allInputsOwned: j['all_inputs_owned'] == true,
      inputCount: (j['inputs'] as List?)?.length ?? 0,
      tokensOut: toks(j['tokens_out']),
    );
  }

  /// Something the user should read before signing, or null.
  String? get warning {
    if (!inputsKnown) {
      return 'Input values could not be fetched from the node, so the total '
          'you spend is unknown. Check the outputs carefully.';
    }
    if (!allInputsOwned) {
      return 'Some inputs are not from this wallet. The dApp is adding its '
          'own boxes to this transaction.';
    }
    return null;
  }

  /// Rows for the shared confirm sheet. Token amounts use wallet metadata
  /// for decimals and names when available.
  List<ConfirmTxRow> confirmRows({required List<TokenBalance> tokens}) {
    String tokenText(ErgoPayTokenAmount t) {
      for (final k in tokens) {
        if (k.id == t.id) return '${formatTokenAmount(t.amount, k.decimals)} ${k.label}';
      }
      return '${t.amount} ${shorten(t.id, head: 6, tail: 4)}';
    }

    final spend = spendNano;
    return [
      if (recipients.length > 1)
        ConfirmTxRow('Recipients', '${recipients.length}'),
      ConfirmTxRow('Sent', formatErg(sentNano), bold: spend == null),
      if (tokensOut.isNotEmpty)
        ConfirmTxRow('Tokens out', tokensOut.map(tokenText).join(', ')),
      ConfirmTxRow('Miner fee', formatErg(feeNano)),
      ConfirmTxRow('Change to you', formatErg(changeNano)),
      if (spend != null) ConfirmTxRow('You spend', formatErg(spend), bold: true),
      ConfirmTxRow('Inputs', '$inputCount'),
    ];
  }
}
