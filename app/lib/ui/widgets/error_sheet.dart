import 'package:flutter/material.dart';

import '../../bridge/argus_error.dart';
import 'package:flutter/services.dart';

import '../../theme/argus_theme.dart';

/// An error the user can read at their own pace and copy: stays until
/// dismissed, unlike a snackbar.
Future<void> showErrorSheet(
  BuildContext context, {
  required String message,
  String? code,
  String title = 'Something went wrong',
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
    builder: (ctx) {
      final colors = ArgusColors.of(ctx);
      final full = code == null || code.isEmpty ? message : '$code: $message';
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.error_outline, color: rust, size: 22),
                  const SizedBox(width: 10),
                  Expanded(child: Text(title, style: Theme.of(ctx).textTheme.titleLarge)),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: colors.inset, borderRadius: BorderRadius.circular(12)),
                child: SingleChildScrollView(
                  child: SelectableText(full, style: monoStyle(ctx, size: 12)),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: full));
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Error copied')));
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                  const Spacer(),
                  FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// How a failed sign-and-broadcast should be reported.
class TxFailure {
  const TxFailure({required this.title, required this.message, this.code});
  final String title;
  final String message;
  final String? code;
}

/// Classifies an error from signing or broadcasting. Reduction, signing
/// and build failures happen before anything reaches the network, so the
/// user can retry freely; a node error after signing may or may not have
/// broadcast, so the user is told to check activity first.
TxFailure classifyTxFailure(Object error) {
  final raw = error is ArgusException ? error : ArgusException.fromJson('$error');
  final code = raw.code;
  final msg = raw.message;
  final lower = '$code $msg'.toLowerCase();
  final beforeNetwork = code == 'TX_REDUCTION_FAILED' ||
      code == 'SIGNING_FAILED' ||
      code == 'TX_BUILD_FAILED' ||
      code == 'WALLET_LOCKED' ||
      lower.contains('reduced to false') ||
      lower.contains('prover');
  if (beforeNetwork) {
    final why = lower.contains('reduced to false')
        ? 'A contract rejected this transaction, so it was not signed. Nothing was sent.'
        : 'Nothing was sent.';
    return TxFailure(title: 'Signing failed', message: '$why\n\n$msg', code: code == 'GENERIC' ? null : code);
  }
  return TxFailure(
    title: 'Broadcast may have failed',
    message: 'Check Activity before retrying; the transaction may already be in the mempool.\n\n$msg',
    code: code == 'GENERIC' ? null : code,
  );
}

Future<void> showTxFailureSheet(BuildContext context, Object error) {
  final f = classifyTxFailure(error);
  return showErrorSheet(context, title: f.title, message: f.message, code: f.code);
}
