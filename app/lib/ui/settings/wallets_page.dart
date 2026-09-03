import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../widgets/soft_card.dart';
import 'settings_shared.dart';

/// Every stored wallet: switch, rename, delete, create, restore.
class WalletsPage extends StatefulWidget {
  const WalletsPage({super.key, this.walletId, this.onWalletSwitched});

  final String? walletId;

  /// Reports a switch or a deletion of the current wallet (empty id = the
  /// wallet this page was opened for is gone).
  final ValueChanged<String>? onWalletSwitched;

  @override
  State<WalletsPage> createState() => _WalletsPageState();
}

class _WalletsPageState extends State<WalletsPage> {
  late Future<List<WalletInfo>> _walletsFuture = walletService.listWallets();

  String? get _walletId => widget.walletId ?? walletService.activeWalletId;

  void _refresh() {
    if (!mounted) return;
    setState(() => _walletsFuture = walletService.listWallets());
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _handOff(String id) {
    final cb = widget.onWalletSwitched;
    Navigator.pop(context);
    if (cb != null) cb(id);
  }

  Future<void> _rename(WalletInfo w) async {
    final ctrl = TextEditingController(text: w.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename wallet'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rename')),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || name == w.name) return;
    try {
      await walletService.renameWallet(w.walletId, name);
      _refresh();
    } catch (_) {
      _snack('Could not rename wallet');
    }
  }

  Future<void> _delete(WalletInfo w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${w.name}?'),
        content: const Text(
          'This removes the wallet from this device. Argus does not keep a copy of the recovery phrase; the paper you wrote when creating this wallet is the only way back in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: rust, foregroundColor: bone),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await walletService.deleteWallet(w.walletId);
      final remaining = await walletService.listWallets();
      if (!mounted) return;
      if (w.walletId == _walletId) {
        _handOff(remaining.isNotEmpty ? remaining.first.walletId : '');
        return;
      }
      _refresh();
      _snack('Wallet deleted');
    } catch (_) {
      _snack('Could not delete wallet');
    }
  }

  Future<void> _openCreateOrRestore(String route) async {
    await Navigator.pushNamed(context, route);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    return SettingsPage(
      title: 'Wallets',
      children: [
        FutureBuilder<List<WalletInfo>>(
          future: _walletsFuture,
          builder: (context, snapshot) {
            final wallets = snapshot.data ?? const <WalletInfo>[];
            final currentId = _walletId;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Stored on this device', scope: 'App-wide'),
                const SizedBox(height: 10),
                SoftCard(
                  padding: EdgeInsets.zero,
                  child: DividedColumn(
                    indent: 16,
                    children: [
                      if (wallets.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('No wallets stored.', style: Theme.of(context).textTheme.bodySmall),
                        ),
                      for (final w in wallets)
                        InkWell(
                          onTap: w.walletId == currentId ? null : () => _handOff(w.walletId),
                          borderRadius: BorderRadius.circular(cardRadius),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.account_balance_wallet_outlined,
                                  size: 22,
                                  color: w.walletId == currentId ? iris : colors.muted,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                          ),
                                          if (w.walletId == currentId) ...[
                                            const SizedBox(width: 8),
                                            Text(
                                              w.isUnlocked ? 'ACTIVE' : 'SELECTED',
                                              style: TextStyle(fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w600,
                                                  color: w.isUnlocked ? moss : colors.muted),
                                            ),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        w.address0 != null ? shorten(w.address0!, head: 10, tail: 8) : 'id ${shorten(w.walletId, head: 8, tail: 0)}',
                                        style: monoStyle(context, size: 11).copyWith(color: colors.muted),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Rename',
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  onPressed: () => _rename(w),
                                ),
                                IconButton(
                                  tooltip: 'Delete',
                                  icon: Icon(Icons.delete_outline, size: 18, color: rustFor(context)),
                                  onPressed: () => _delete(w),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _openCreateOrRestore('/create'),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Create'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _openCreateOrRestore('/restore'),
                        icon: const Icon(Icons.restore, size: 18),
                        label: const Text('Restore'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const SettingsNote('Tap a wallet to switch to it. Each wallet has its own PIN and its own settings.'),
              ],
            );
          },
        ),
      ],
    );
  }
}
