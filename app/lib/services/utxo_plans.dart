import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';
import 'wallet_service.dart';

export 'utxo_tools_controller.dart' show dustThresholdNano;

/// Inputs per consolidation transaction. Ergo allows far more, but this
/// keeps each transaction well inside block cost limits and node timeouts.
const consolidationMaxInputs = 100;

/// Per-box amount for splitting [totalNano] into [count] equal boxes after
/// [feesNano], adjusted so any leftover change is either nothing or at least
/// a whole minimum box. Null when the boxes would be below the minimum.
int? equalSplitAmount({required int totalNano, required int count, required int feesNano}) {
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
List<List<String>> consolidationChunks(List<String> boxIds, {int maxInputs = consolidationMaxInputs}) {
  if (boxIds.length < 2) return const [];
  final chunks = <List<String>>[];
  for (var i = 0; i < boxIds.length; i += maxInputs) {
    chunks.add(boxIds.sublist(i, i + maxInputs > boxIds.length ? boxIds.length : i + maxInputs));
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
    return const UtxoHealth('Tidy', moss, 'Few boxes: sends select inputs quickly and pay the least.');
  }
  if (boxCount <= 80) {
    return const UtxoHealth('Moderate', iris, 'Sends may need several inputs; consolidating dust keeps fees down.');
  }
  return const UtxoHealth('Fragmented', rust, 'Many small boxes make every send pick more inputs. Sweep dust or consolidate.');
}
