import 'package:flutter/material.dart';

import '../theme/argus_theme.dart';

/// A single summary line shown inside the confirmation sheet.
class ConfirmTxRow {
  const ConfirmTxRow(this.label, this.value, {this.bold = false});

  final String label;
  final String value;
  final bool bold;
}

/// What the user chose on the confirmation sheet.
enum ConfirmChoice { cancel, signOnly, broadcast }

/// Unmistakable last gate before any transaction is signed and broadcast.
///
/// Every path that submits to the network should funnel through this sheet so
/// the user always sees a clear warning and an explicit "Sign & broadcast"
/// action rather than a generic confirm.
class ConfirmTransactionSheet extends StatefulWidget {
  const ConfirmTransactionSheet({
    super.key,
    required this.title,
    required this.rows,
    this.confirmLabel = 'Sign & broadcast',
    this.detail,
    this.recipientAddress,
    this.allowSignOnly = false,
    this.expandableTitle,
    this.expandable,
  });

  final String title;
  final List<ConfirmTxRow> rows;
  final String confirmLabel;
  final String? detail;

  /// Shown in full, selectable, so the user can verify every character.
  final String? recipientAddress;

  /// Offers a secondary "Sign only" action that resolves to
  /// [ConfirmChoice.signOnly].
  final bool allowSignOnly;

  /// Optional collapsed section (e.g. the selected input boxes).
  final String? expandableTitle;
  final Widget? expandable;

  @override
  State<ConfirmTransactionSheet> createState() =>
      _ConfirmTransactionSheetState();
}

class _ConfirmTransactionSheetState extends State<ConfirmTransactionSheet> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.brightness == Brightness.dark
        ? watchfulMuted
        : ledgerMuted;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: rust.withValues(alpha: 0.1),
                border: Border.all(color: rust.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(10),
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
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: rustFor(context)),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.recipientAddress != null) ...[
              const SizedBox(height: 18),
              Text(
                'TO',
                style: theme.textTheme.titleSmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark ? ink : paper,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  widget.recipientAddress!,
                  style: monoStyle(context, size: 12),
                ),
              ),
            ],
            const SizedBox(height: 18),
            for (final row in widget.rows) _row(context, row),
            if (widget.detail != null) ...[
              const SizedBox(height: 10),
              Text(
                widget.detail!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
            if (widget.expandable != null) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: muted,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.expandableTitle ?? 'Details',
                        style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded) widget.expandable!,
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        Navigator.pop(context, ConfirmChoice.cancel),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: rust,
                      foregroundColor: bone,
                    ),
                    onPressed: () =>
                        Navigator.pop(context, ConfirmChoice.broadcast),
                    child: Text(widget.confirmLabel),
                  ),
                ),
              ],
            ),
            if (widget.allowSignOnly) ...[
              const SizedBox(height: 4),
              Center(
                child: TextButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, ConfirmChoice.signOnly),
                  icon: const Icon(Icons.draw_outlined, size: 16),
                  label: const Text('Sign only'),
                ),
              ),
            ],
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
          Flexible(
            child: Text(row.value, textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }
}

/// Shows the confirmation sheet and reports which action the user took.
/// Dismissing the sheet counts as [ConfirmChoice.cancel].
Future<ConfirmChoice> showConfirmTransactionChoice(
  BuildContext context, {
  required String title,
  required List<ConfirmTxRow> rows,
  String confirmLabel = 'Sign & broadcast',
  String? detail,
  String? recipientAddress,
  bool allowSignOnly = false,
  String? expandableTitle,
  Widget? expandable,
}) async {
  final result = await showModalBottomSheet<ConfirmChoice>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
    ),
    builder: (ctx) => ConfirmTransactionSheet(
      title: title,
      rows: rows,
      confirmLabel: confirmLabel,
      detail: detail,
      recipientAddress: recipientAddress,
      allowSignOnly: allowSignOnly,
      expandableTitle: expandableTitle,
      expandable: expandable,
    ),
  );
  return result ?? ConfirmChoice.cancel;
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
  final choice = await showConfirmTransactionChoice(
    context,
    title: title,
    rows: rows,
    confirmLabel: confirmLabel,
    detail: detail,
  );
  return choice == ConfirmChoice.broadcast;
}
