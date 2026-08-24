import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';

/// A single summary line shown inside the confirmation sheet.
class ConfirmTxRow {
  const ConfirmTxRow(this.label, this.value, {this.bold = false});

  final String label;
  final String value;
  final bool bold;
}

/// Unmistakable last gate before any transaction is signed and broadcast.
///
/// Every path that submits to the network should funnel through this sheet so
/// the user always sees a clear warning and an explicit "Sign & broadcast"
/// action rather than a generic confirm.
class ConfirmTransactionSheet extends StatelessWidget {
  const ConfirmTransactionSheet({
    super.key,
    required this.title,
    required this.rows,
    this.confirmLabel = 'Sign & broadcast',
    this.detail,
  });

  final String title;
  final List<ConfirmTxRow> rows;
  final String confirmLabel;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: rust.withValues(alpha: 0.1),
                border: Border.all(color: rust.withValues(alpha: 0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.gpp_bad_outlined, color: rust, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This will sign and broadcast a transaction to the '
                      'network. It cannot be undone once confirmed.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: rustFor(context)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            for (final row in rows) _row(context, row),
            if (detail != null) ...[
              const SizedBox(height: 10),
              Text(
                detail!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: rust,
                      foregroundColor: bone,
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(confirmLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ConfirmTxRow row) {
    final style = TextStyle(
      fontWeight: row.bold ? FontWeight.w600 : FontWeight.normal,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(child: Text(row.label, style: style)),
          const SizedBox(width: 12),
          Flexible(child: Text(row.value, textAlign: TextAlign.end, style: style)),
        ],
      ),
    );
  }
}

/// Shows the confirmation sheet and resolves `true` only when the user taps
/// the explicit broadcast action.
Future<bool> showConfirmTransactionSheet(
  BuildContext context, {
  required String title,
  required List<ConfirmTxRow> rows,
  String confirmLabel = 'Sign & broadcast',
  String? detail,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    builder: (ctx) => ConfirmTransactionSheet(
      title: title,
      rows: rows,
      confirmLabel: confirmLabel,
      detail: detail,
    ),
  );
  return result ?? false;
}