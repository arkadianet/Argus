import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/argus_theme.dart';
import 'app_fee.dart';
import 'storage_rent.dart';
import 'utxo_tools_controller.dart';
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

/// A one-transaction consolidation the UTXO screen proposes on its own.
///
/// Boxes come from one address only: they are already publicly tied to each
/// other, so the cleanup links nothing new (merging across addresses would).
/// Mixed boxes and boxes set aside for a pending mix never take part. Boxes
/// that rent puts at risk or that fall due within [rentSoonDays] go first,
/// then dust, then the oldest; moving a box into the new one also restarts
/// its four-year rent clock.
class CleanupSuggestion {
  const CleanupSuggestion({
    required this.address,
    required this.boxes,
    required this.atRiskCount,
    required this.dueSoonCount,
    required this.leftAtAddress,
    required this.forRent,
    this.feesNano = minerFeeNano + argusFeeNano,
  });

  final String address;

  /// Inputs, most urgent first; at most [consolidationMaxInputs].
  final List<InputBoxInput> boxes;

  /// Inputs whose value would not cover their rent.
  final int atRiskCount;

  /// Inputs due now or within [rentSoonDays] that are not also at risk.
  final int dueSoonCount;

  /// Eligible boxes at [address] this transaction leaves for a later one.
  final int leftAtAddress;

  /// True when rent, not box count alone, is the reason for the suggestion.
  final bool forRent;

  /// Miner fee plus Argus fee, as the consolidation builder charges them.
  final int feesNano;

  List<String> get boxIds => [for (final b in boxes) b.boxId];

  BigInt get totalNano =>
      boxes.fold(BigInt.zero, (sum, b) => sum + b.valueNanoErg);

  BigInt get afterFeesNano => totalNano - BigInt.from(feesNano);

  /// Inputs whose rent clock the move restarts for a reason worth naming.
  int get rentResetCount => atRiskCount + dueSoonCount;

  /// Every token the inputs hold, summed and ordered by id as the
  /// consolidation builder orders them.
  Map<String, BigInt> get tokens {
    final totals = <String, BigInt>{};
    for (final b in boxes) {
      for (final a in b.assets) {
        totals[a.tokenId] = (totals[a.tokenId] ?? BigInt.zero) + a.amount;
      }
    }
    final ids = totals.keys.toList()..sort();
    return {for (final id in ids) id: totals[id]!};
  }
}

/// The cleanup worth proposing for [boxes], or null when there is none.
///
/// An address qualifies when one of its boxes is flagged by [rent] (at risk
/// or due soon) or when the wallet as a whole is fragmented (more than
/// [fragmentedAbove] boxes, the home screen's threshold). A fragmented
/// wallet merges up to [maxInputs] boxes at the address; a tidy one only
/// moves its flagged boxes, plus the address's largest ERG-only box so the
/// new box can pay its own rent. The address with the most flagged boxes
/// wins, then the one with the most boxes. [exclude] removes boxes that must
/// not move (mixed, reserved for a mix, or already being spent).
CleanupSuggestion? suggestCleanup({
  required List<InputBoxInput> boxes,
  Map<String, BoxRent> rent = const {},
  Set<String> exclude = const {},
  int fragmentedAbove = utxoFragmentationThreshold,
  int maxInputs = consolidationMaxInputs,
  int feesNano = minerFeeNano + argusFeeNano,
}) {
  if (maxInputs < 2) return null;
  final fragmented = boxes.length > fragmentedAbove;
  final byAddress = <String, List<InputBoxInput>>{};
  for (final b in boxes) {
    final address = b.address;
    if (address == null || address.isEmpty || exclude.contains(b.boxId)) {
      continue;
    }
    byAddress.putIfAbsent(address, () => []).add(b);
  }

  bool flagged(InputBoxInput b) => rent[b.boxId]?.flagged ?? false;
  bool atRisk(InputBoxInput b) => rent[b.boxId]?.atRisk ?? false;
  int rank(InputBoxInput b) {
    if (flagged(b)) return 0;
    if (b.valueNanoErg < BigInt.from(dustThresholdNano)) return 1;
    return 2;
  }

  CleanupSuggestion? best;
  var bestScore = (-1, -1);
  final addresses = byAddress.keys.toList()..sort();
  for (final address in addresses) {
    final group = byAddress[address]!;
    if (group.length < 2) continue;
    final urgent = group.where(flagged).length;
    if (urgent == 0 && !fragmented) continue;

    final ordered = [...group]
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : compareUtxoAge(a, b);
      });
    final picks = fragmented
        ? ordered.take(maxInputs).toList()
        : ordered.where(flagged).take(maxInputs - 1).toList();
    // The address's largest ERG-only box joins in, so boxes rescued from
    // rent land in a box that can pay it.
    final funder = _largest(group.where((b) => b.assets.isEmpty));
    if (funder != null && !picks.contains(funder)) {
      if (picks.length >= maxInputs) picks.removeLast();
      picks.add(funder);
    }
    // A lone flagged box needs a partner to be moved at all.
    if (picks.length < 2) {
      final partner = _largest(group.where((b) => !picks.contains(b)));
      if (partner != null) picks.add(partner);
    }
    if (picks.length < 2) continue;
    final total = picks.fold(BigInt.zero, (sum, b) => sum + b.valueNanoErg);
    if (total < BigInt.from(feesNano + minBoxNano)) continue;

    final score = (urgent, group.length);
    if (score.$1 > bestScore.$1 ||
        (score.$1 == bestScore.$1 && score.$2 > bestScore.$2)) {
      bestScore = score;
      best = CleanupSuggestion(
        address: address,
        boxes: List.unmodifiable(picks),
        atRiskCount: picks.where(atRisk).length,
        dueSoonCount: picks
            .where((b) => !atRisk(b) && (rent[b.boxId]?.dueSoon ?? false))
            .length,
        leftAtAddress: group.length - picks.length,
        forRent: urgent > 0,
        feesNano: feesNano,
      );
    }
  }
  return best;
}

InputBoxInput? _largest(Iterable<InputBoxInput> boxes) {
  InputBoxInput? best;
  for (final b in boxes) {
    if (best == null) {
      best = b;
      continue;
    }
    final byValue = b.valueNanoErg.compareTo(best.valueNanoErg);
    if (byValue > 0 || (byValue == 0 && b.boxId.compareTo(best.boxId) < 0)) {
      best = b;
    }
  }
  return best;
}
