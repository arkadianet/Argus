import 'package:flutter/material.dart';
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
