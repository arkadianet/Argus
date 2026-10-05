import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/argus_theme.dart';
import 'wallet_service.dart';

export 'utxo_tools_controller.dart' show dustThresholdNano;

/// Inputs per consolidation transaction. Ergo allows far more, but this
/// keeps each transaction well inside block cost limits and node timeouts.
const consolidationMaxInputs = 100;

/// A reviewed allocation for separating all token types in one source box.
/// Funding boxes must be ERG-only at the same address, matching the core's
/// ownership check. The transaction builder independently rechecks inputs.
class SeparateTokensPlan {
  const SeparateTokensPlan({
    required this.source,
    required this.inputs,
    required this.assets,
    required this.outputs,
    required this.ergPerBoxNano,
    required this.feesNano,
    required this.totalNano,
    required this.changeNano,
  });

  final InputBoxInput source;
  final List<InputBoxInput> inputs;
  final List<InputAsset> assets;
  final List<Map<String, dynamic>> outputs;
  final int ergPerBoxNano;
  final int feesNano;
  final BigInt totalNano;
  final BigInt changeNano;

  List<String> get inputBoxIds => inputs.map((b) => b.boxId).toList();
  int get minimumRequiredNano => assets.length * ergPerBoxNano + feesNano;
}

SeparateTokensPlan planSeparateTokens({
  required InputBoxInput source,
  List<InputBoxInput> funding = const [],
  required int feesNano,
  int ergPerBoxNano = minBoxNano,
}) {
  if (source.address == null || source.address!.isEmpty) {
    throw const FormatException(
      'Refresh boxes to identify the source address.',
    );
  }
  if (ergPerBoxNano < minBoxNano || feesNano < 0) {
    throw const FormatException('Each token box needs at least 0.001 ERG.');
  }
  final ids = {source.boxId};
  for (final box in funding) {
    if (!ids.add(box.boxId) ||
        box.assets.isNotEmpty ||
        box.address != source.address) {
      throw const FormatException(
        'Funding must be separate ERG-only boxes at the source address.',
      );
    }
  }
  final maxAmount = BigInt.parse('9223372036854775807');
  final totals = <String, BigInt>{};
  for (final asset in source.assets) {
    final amount = (totals[asset.tokenId] ?? BigInt.zero) + asset.amount;
    if (asset.tokenId.isEmpty ||
        asset.amount <= BigInt.zero ||
        amount > maxAmount) {
      throw const FormatException(
        'The source contains an invalid token amount.',
      );
    }
    totals[asset.tokenId] = amount;
  }
  if (totals.length < 2 || totals.length > 150) {
    throw const FormatException(
      'Choose a box holding between 2 and 150 token types.',
    );
  }
  final tokenIds = totals.keys.toList()..sort();
  final assets = [
    for (final id in tokenIds) InputAsset(tokenId: id, amount: totals[id]!),
  ];
  final inputs = [source, ...funding];
  if (inputs.any((box) => box.valueNanoErg <= BigInt.zero)) {
    throw const FormatException(
      'The selected boxes contain an invalid ERG value.',
    );
  }
  final total = inputs.fold(BigInt.zero, (sum, b) => sum + b.valueNanoErg);
  final required =
      BigInt.from(assets.length) * BigInt.from(ergPerBoxNano) +
      BigInt.from(feesNano);
  if (total > maxAmount || required > maxAmount) {
    throw const FormatException(
      'The selected ERG amount exceeds the transaction limit.',
    );
  }
  if (total < required) {
    throw FormatException(
      'Add ${formatNanoErg(required - total)} in funding boxes.',
    );
  }
  var change = total - required;
  // A sub-minimum ERG remainder cannot become a change box. Preserve it
  // in the first token box instead of adding it to fees or discarding it.
  final extraInFirst = change > BigInt.zero && change < BigInt.from(minBoxNano)
      ? change.toInt()
      : 0;
  if (extraInFirst > 0) change = BigInt.zero;
  final outputs = <Map<String, dynamic>>[
    for (var i = 0; i < assets.length; i++)
      {
        'value_nano_erg': ergPerBoxNano + (i == 0 ? extraInFirst : 0),
        'tokens': [
          {'id': assets[i].tokenId, 'amount': assets[i].amount.toInt()},
        ],
      },
  ];
  return SeparateTokensPlan(
    source: source,
    inputs: List.unmodifiable(inputs),
    assets: List.unmodifiable(assets),
    outputs: List.unmodifiable(outputs),
    ergPerBoxNano: ergPerBoxNano,
    feesNano: feesNano,
    totalNano: total,
    changeNano: change,
  );
}

/// Per-box amount for splitting [totalNano] into [count] equal boxes after
/// [feesNano], adjusted so any leftover change is either nothing or at least
/// a whole minimum box. Null when the boxes would be below the minimum.
int? equalSplitAmount({
  required int totalNano,
  required int count,
  required int feesNano,
}) {
  if (count <= 0) return null;
  final available = totalNano - feesNano;
  if (available <= 0) return null;
  var per = available ~/ count;
  final leftover = available - per * count;
  if (leftover > 0 && leftover < minBoxNano) {
    // Shave enough off each box to make the change a real box.
    per -= ((minBoxNano - leftover) / count).ceil();
  }
  return per < minBoxNano ? null : per;
}

/// Splits [boxIds] into consolidation batches of at most [maxInputs]. A
/// final batch of one box is merged into the previous one, since a single
/// input cannot be consolidated. Fewer than two boxes yields nothing.
List<List<String>> consolidationChunks(
  List<String> boxIds, {
  int maxInputs = consolidationMaxInputs,
}) {
  if (boxIds.length < 2) return const [];
  final chunks = <List<String>>[];
  for (var i = 0; i < boxIds.length; i += maxInputs) {
    chunks.add(
      boxIds.sublist(
        i,
        i + maxInputs > boxIds.length ? boxIds.length : i + maxInputs,
      ),
    );
  }
  if (chunks.length > 1 && chunks.last.length == 1) {
    final last = chunks.removeLast();
    chunks.last.addAll(last);
  }
  return chunks;
}

class UtxoHealth {
  const UtxoHealth(this.label, this.color, this.hint);
  final String label;
  final Color color;
  final String hint;
}

UtxoHealth utxoHealth(int boxCount) {
  if (boxCount <= 20) {
    return const UtxoHealth(
      'Tidy',
      moss,
      'Few boxes: sends select inputs quickly and pay the least.',
    );
  }
  if (boxCount <= 80) {
    return const UtxoHealth(
      'Moderate',
      iris,
      'Sends may need several inputs; consolidating dust keeps fees down.',
    );
  }
  return const UtxoHealth(
    'Fragmented',
    rust,
    'Many small boxes make every send pick more inputs. Sweep dust or consolidate.',
  );
}
