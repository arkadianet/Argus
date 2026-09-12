import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/network_controller.dart';
import '../../theme/argus_theme.dart';

/// A receipt for a submitted transaction, not a claim of chain confirmation.
/// Callers own the wording and navigation; receipt actions stay shared.
class TxResultView extends StatelessWidget {
  const TxResultView({
    super.key,
    required this.txId,
    required this.headline,
    required this.onDismiss,
    this.note,
    this.warning,
    this.explorerLaunchMode = LaunchMode.platformDefault,
  });

  final String txId;
  final String headline;
  final String? note;
  final String? warning;
  final VoidCallback onDismiss;
  final LaunchMode explorerLaunchMode;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 64, color: Color(0xFF5B9E6D)),
          const SizedBox(height: 20),
          Text(
            headline,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(note!, textAlign: TextAlign.center),
          ],
          const SizedBox(height: 8),
          const SizedBox(width: 48, child: Hairline(gold: true)),
          const SizedBox(height: 16),
          const Text('Transaction ID'),
          const SizedBox(height: 8),
          SelectableText(txId, style: monoStyle(context, size: 12)),
          if (warning != null) ...[
            const SizedBox(height: 12),
            SelectableText(
              warning!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: rustFor(context)),
            ),
          ],
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: txId));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Transaction ID copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy id'),
          ),
          TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(networkController.explorerTx(txId)),
              mode: explorerLaunchMode,
            ),
            icon: const Icon(Icons.open_in_browser, size: 16),
            label: const Text('View on explorer'),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: onDismiss, child: const Text('Done')),
        ],
      ),
    );
  }
}

/// Stays until dismissed, while preserving the working screen underneath.
Future<void> showTxResultSheet(
  BuildContext context, {
  required String txId,
  required String headline,
  String? note,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
    ),
    builder: (ctx) => SafeArea(
      child: TxResultView(
        txId: txId,
        headline: headline,
        note: note,
        onDismiss: () => Navigator.pop(ctx),
      ),
    ),
  );
}
