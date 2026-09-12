import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/network_controller.dart';
import '../../services/wallet_service.dart';
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
    final warnings = [
      warning,
      walletService.broadcastWarning(txId),
    ].whereType<String>().join('\n\n');
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
          if (warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(
              warnings,
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

/// Retains the root navigator before an asynchronous broadcast can outlive State.
mixin TxReceiptOwner<T extends StatefulWidget> on State<T> {
  late BuildContext receiptContext;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    receiptContext = Navigator.of(context, rootNavigator: true).context;
  }
}

/// Bookkeeping cannot undo a successful node acknowledgement.
Future<String?> txBookkeeping(Future<void> Function() update) async {
  try {
    await update();
    return null;
  } catch (e) {
    return 'Transaction submitted, but local tracking could not be updated: $e. '
        'Keep this transaction ID and check Activity before retrying.';
  }
}

final _receiptQueues = Expando<Future<void>>();

/// One presentation at a time per surviving navigator. Submission futures do
/// not await this queue; every queued ID remains available until dismissed.
Future<void> queueTxPresentation(
  BuildContext context,
  Future<void> Function(BuildContext) show,
) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final previous = _receiptQueues[navigator] ?? Future<void>.value();
  final next = previous.then((_) => show(navigator.context));
  _receiptQueues[navigator] = next;
  return next;
}

/// Stays until dismissed, even when the originating route has been popped.
Future<void> showTxResultSheet(
  BuildContext context, {
  required String txId,
  required String headline,
  String? note,
  String? warning,
}) => queueTxPresentation(
  context,
  (survivingContext) => showModalBottomSheet<void>(
    context: survivingContext,
    useRootNavigator: true,
    backgroundColor: Theme.of(survivingContext).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
    ),
    builder: (ctx) => SafeArea(
      child: TxResultView(
        txId: txId,
        headline: headline,
        note: note,
        warning: warning,
        onDismiss: () => Navigator.pop(ctx),
      ),
    ),
  ),
);
