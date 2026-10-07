import 'package:flutter/material.dart';

import '../services/secure_storage.dart';
import '../services/session_lock.dart';
import '../services/wallet_service.dart';
import 'home/name_dialog.dart';

/// Right after a wallet gets its PIN: offer biometric unlock while the PIN
/// is still in hand, so the user need not find it in Settings later. Does
/// nothing on a device without biometrics. Never throws.
Future<void> offerBiometricUnlock(
  BuildContext context, {
  required String walletId,
  required String pin,
}) async {
  bool possible;
  try {
    possible = await SecureStorageService.hasBiometric();
  } catch (_) {
    possible = false;
  }
  if (!possible || !context.mounted) return;
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Unlock with biometrics?'),
      content: const Text(
        'Use your fingerprint or face to unlock this wallet instead of typing '
        'the PIN each time. You can change this later under Settings › Security.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enable')),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;
  String message;
  try {
    final saved = await sessionLock.run(() async {
      final pinWrap = await SecureStorageService.loadPinWrap(walletId: walletId);
      if (pinWrap == null) return false;
      final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, pin);
      await SecureStorageService.saveWrapKey(wrapKey, walletId: walletId);
      await SecureStorageService.clearPinGate();
      return true;
    });
    message = saved ? 'Biometric unlock enabled' : 'Could not enable biometrics; try again under Settings › Security';
  } catch (_) {
    message = 'Could not enable biometrics; try again under Settings › Security';
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Rename dialog for a wallet's own settings. Returns true when the name
/// changed.
Future<bool> renameWalletDialog(BuildContext context, WalletInfo w) async {
  final name = await showNameDialog(
    context,
    title: 'Rename wallet',
    initial: w.name,
    confirm: 'Rename',
  );
  if (name == null || name.isEmpty || name == w.name) return false;
  await walletService.renameWallet(w.walletId, name);
  return true;
}
