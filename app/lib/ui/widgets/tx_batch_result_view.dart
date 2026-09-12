import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/argus_theme.dart';
import 'tx_explorer_link.dart';

/// A receipt of acknowledged submissions, not a claim of chain confirmation.
class TxBatchResultView extends StatelessWidget {
  const TxBatchResultView({
    super.key,
    required this.txIds,
    required this.plannedCount,
    required this.onDismiss,
    this.failure,
  });

  final List<String> txIds;
  final int plannedCount;
  final String? failure;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Consolidation result',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text('${txIds.length} of $plannedCount transactions submitted'),
        if (txIds.length < plannedCount)
          Text(
            'Stopped early after ${txIds.length} of $plannedCount. No further batches were attempted.',
          ),
        if (failure != null) ...[
          const SizedBox(height: 12),
          SelectableText(failure!, style: TextStyle(color: rustFor(context))),
        ],
        for (var i = 0; i < txIds.length; i++) ...[
          const Divider(height: 24),
          Text('Transaction ${i + 1}'),
          SelectableText(txIds[i], style: monoStyle(context, size: 12)),
          TextButton.icon(
            key: ValueKey('copy-${txIds[i]}'),
            onPressed: () => Clipboard.setData(ClipboardData(text: txIds[i])),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy id'),
          ),
          TxExplorerLink(
            key: ValueKey('explorer-${txIds[i]}'),
            txId: txIds[i],
            label: 'View on explorer',
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(onPressed: onDismiss, child: const Text('Done')),
      ],
    ),
  );
}

Future<void> showTxBatchResultSheet(
  BuildContext context, {
  required List<String> txIds,
  required int plannedCount,
  String? failure,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Theme.of(context).colorScheme.surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
  ),
  builder: (ctx) => SafeArea(
    child: TxBatchResultView(
      txIds: List.unmodifiable(txIds),
      plannedCount: plannedCount,
      failure: failure,
      onDismiss: () => Navigator.pop(ctx),
    ),
  ),
);
