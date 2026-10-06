import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/privacy_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../wallet_dialogs.dart';
import 'settings_shared.dart';

/// Settings scoped to one wallet: its name, primary address, change policy,
/// backup, and removing it from this device.
class WalletSettingsPage extends StatefulWidget {
  const WalletSettingsPage({
    super.key,
    this.walletId,
    required this.walletName,
    this.onChanged,
    this.onRemoved,
  });
  final String? walletId;
  final String walletName;

  /// The name or the pinned address changed.
  final VoidCallback? onChanged;

  /// The wallet was removed from this device; carries its id. Called even
  /// when this page is already gone: removing the unlocked wallet locks it,
  /// and the lock pops every route above the home screen.
  final ValueChanged<String>? onRemoved;

  @override
  State<WalletSettingsPage> createState() => _WalletSettingsPageState();
}

class _WalletSettingsPageState extends State<WalletSettingsPage> {
  late Future<int> _pinnedIndexFuture;
  late String _name = widget.walletName;

  String? get _walletId => widget.walletId ?? walletService.activeWalletId;

  @override
  void initState() {
    super.initState();
    _pinnedIndexFuture = walletService.getPinnedAddressIndex(walletId: _walletId);
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _pinnedIndexFuture = walletService.getPinnedAddressIndex(walletId: _walletId);
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<WalletInfo?> _info() async {
    final id = _walletId;
    if (id == null) return null;
    for (final w in await walletService.listWallets()) {
      if (w.walletId == id) return w;
    }
    return null;
  }

  Future<void> _rename() async {
    try {
      final w = await _info();
      if (w == null || !mounted) return;
      if (await renameWalletDialog(context, w)) {
        final renamed = await _info();
        if (mounted && renamed != null) setState(() => _name = renamed.name);
        widget.onChanged?.call();
      }
    } catch (_) {
      _snack('Could not rename wallet');
    }
  }

  Future<void> _remove() async {
    final id = _walletId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $_name?'),
        content: const Text(
          'This removes the wallet from this device. Argus does not keep a '
          'copy of the recovery phrase; the paper you wrote when creating '
          'this wallet is the only way back in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: rust, foregroundColor: bone),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final onRemoved = widget.onRemoved;
    try {
      await walletService.deleteWallet(id);
    } catch (_) {
      _snack('Could not remove wallet');
      return;
    }
    onRemoved?.call(id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pinAddressIndex() async {
    final indexCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pin address index'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Derive the address at this index and use it as the primary '
                'address for send and receive. Index 0 resets to the default. '
                'The balance still counts every address of the wallet.'),
            const SizedBox(height: 12),
            TextField(
              controller: indexCtrl,
              decoration: InputDecoration(
                labelText: 'Index',
                hintText: '0',
                helperText: '0–${WalletService.maxAddressIndex}',
              ),
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pin')),
        ],
      ),
    );
    final text = indexCtrl.text.trim();
    indexCtrl.dispose();
    if (ok != true) return;
    final index = int.tryParse(text);
    if (index == null || index < 0) {
      _snack('Invalid index');
      return;
    }
    if (index > WalletService.maxAddressIndex) {
      _snack("This wallet can't derive past index ${WalletService.maxAddressIndex}");
      return;
    }
    final wid = _walletId;
    if (wid == null) return;
    final addr = await walletService.tryDeriveAddress(index);
    if (!mounted) return;
    if (addr == null) {
      _snack("Wallet can't derive index $index");
      return;
    }
    await walletService.setPinnedAddressIndex(wid, index, address: addr);
    _refresh();
    widget.onChanged?.call();
    _snack('Pinned index $index · ${shorten(addr, head: 10, tail: 8)}');
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = walletService.isUnlocked;
    return ListenableBuilder(
      listenable: privacyService,
      builder: (context, _) => SettingsPage(
        title: _name,
        children: [
          SettingsGroup(
            title: 'Wallet',
            scope: 'This wallet',
            children: [
              SettingsRow(
                icon: Icons.edit_outlined,
                title: 'Name',
                subtitle: _name,
                onTap: _rename,
              ),
            ],
          ),
          SettingsGroup(
            title: 'Addresses',
            scope: 'This wallet',
            children: [
              FutureBuilder<int>(
                future: _pinnedIndexFuture,
                builder: (context, snapshot) {
                  final pinned = snapshot.data ?? 0;
                  final isPinned = pinned != 0;
                  final outOfRange = pinned > WalletService.maxAddressIndex;
                  return SettingsRow(
                    icon: Icons.push_pin_outlined,
                    danger: outOfRange,
                    title: outOfRange
                        ? "Pinned index #$pinned can't be derived"
                        : (isPinned ? 'Primary address: index #$pinned' : 'Primary address: index 0'),
                    subtitle: outOfRange
                        ? 'This wallet derives up to index ${WalletService.maxAddressIndex}. Unpin or choose a lower index.'
                        : 'Receive and change default to this address until it is used.',
                    trailing: isPinned
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: 'Unpin',
                            onPressed: () async {
                              final wid = _walletId;
                              if (wid == null) return;
                              await walletService.setPinnedAddressIndex(wid, 0);
                              _refresh();
                              widget.onChanged?.call();
                            },
                          )
                        : null,
                    onTap: unlocked ? _pinAddressIndex : null,
                  );
                },
              ),
              SettingsRow(
                icon: Icons.shuffle,
                title: 'Fresh addresses',
                subtitle: 'Receive and change on a new address each time, like Nautilus. Off: everything uses your pinned or first address.',
                trailing: Switch(
                  value: privacyService.useUnusedChangeAddress(_walletId),
                  onChanged: (v) async {
                    final wid = _walletId;
                    if (wid == null) {
                      _snack('Unlock a wallet to change this setting');
                      return;
                    }
                    try {
                      await privacyService.setUnusedChangeAddress(v, walletId: wid);
                    } catch (_) {
                      _snack('Could not update privacy setting');
                    }
                  },
                ),
              ),
            ],
          ),
          const SectionLabel('Backup'),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Argus does not keep a copy of the recovery phrase. The paper you wrote at create or restore is the only way back in.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 24),
          SettingsGroup(
            title: 'Remove',
            scope: 'This wallet',
            children: [
              SettingsRow(
                icon: Icons.delete_outline,
                title: 'Remove wallet',
                subtitle: 'From this device only. Keep the recovery phrase.',
                danger: true,
                onTap: _remove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
