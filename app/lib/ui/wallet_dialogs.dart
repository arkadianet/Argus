import 'package:flutter/material.dart';

import '../services/wallet_service.dart';

/// Rename dialog shared by the home list, the overview and Settings.
/// Returns true when the name changed.
Future<bool> renameWalletDialog(BuildContext context, WalletInfo w) async {
  final ctrl = TextEditingController(text: w.name);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename wallet'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (_) => Navigator.pop(ctx, true),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rename')),
      ],
    ),
  );
  final name = ctrl.text.trim();
  ctrl.dispose();
  if (ok != true || name.isEmpty || name == w.name) return false;
  await walletService.renameWallet(w.walletId, name);
  return true;
}
