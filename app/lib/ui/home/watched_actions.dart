import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/address_label_service.dart';
import '../../services/watch_account_service.dart';
import '../../services/watch_only_service.dart';
import '../../theme/argus_theme.dart';
import 'name_dialog.dart';
import 'overview_model.dart';

/// Renaming a watched wallet and no longer watching it: one flow, reached
/// from the wallet's Settings tab, from the ⋮ menu in its page's header,
/// and from a swipe on its row in the overview (or that row's
/// accessibility action), so it is never more than a step from where the
/// wallet is seen.

/// The watched account [ref] names, if it is one still on this device.
WatchAccount? watchedAccountFor(WalletRef ref) {
  for (final a in watchAccountService.accounts) {
    if (a.key == ref.id) return a;
  }
  return null;
}

/// The name a watched wallet goes by now.
String watchedNameOf(WalletRef ref) => ref.kind == WalletKind.watchedAccount
    ? (watchedAccountFor(ref)?.label ?? '')
    : (addressLabelService.labelFor(ref.id) ?? '');

/// Asks for a new name for [ref] and saves it. True when saved; a failure
/// is said in a snack bar and returns false.
Future<bool> renameWatched(BuildContext context, WalletRef ref) async {
  final account = watchedAccountFor(ref);
  final name = await showNameDialog(context, title: 'Name', label: 'Name (optional)', initial: watchedNameOf(ref));
  if (name == null) return false;
  try {
    if (ref.kind == WalletKind.watchedAccount) {
      if (account == null) return false;
      await watchAccountService.setLabel(account, name);
    } else {
      await addressLabelService.setLabel(ref.id, name);
    }
    return true;
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not save the name: $e');
    return false;
  }
}

/// Asks once whether to stop watching [ref]. Nothing changes on chain; an
/// account's extended key leaves this device.
Future<bool> confirmStopWatching(BuildContext context, WalletRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Stop watching?'),
      content: Text(
        ref.kind == WalletKind.watchedAccount
            ? 'The extended key is removed from this device. Re-import it to watch the account again.'
            : shorten(ref.id, head: 12, tail: 10),
        style: ref.kind == WalletKind.watchedAccount ? null : monoStyle(ctx, size: 12),
      ),
      actions: [
        TextButton(
          key: const Key('stop-watching-cancel'),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('stop-watching-confirm'),
          style: FilledButton.styleFrom(backgroundColor: rust, foregroundColor: bone),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Stop watching'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Confirms, then stops watching [ref]. True when it is gone from this
/// device; a cancel returns false, a failure says so and returns false.
Future<bool> stopWatching(BuildContext context, WalletRef ref) async {
  if (!await confirmStopWatching(context, ref)) return false;
  try {
    if (ref.kind == WalletKind.watchedAccount) {
      final account = watchedAccountFor(ref);
      if (account != null) await watchAccountService.remove(account);
    } else {
      await watchOnlyService.remove(ref.id);
    }
    return true;
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not stop watching: $e');
    return false;
  }
}

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
