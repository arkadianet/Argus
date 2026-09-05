import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/privacy_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import 'settings_shared.dart';

/// Settings scoped to one wallet: primary address, change policy, tools.
class WalletSettingsPage extends StatefulWidget {
  const WalletSettingsPage({super.key, this.walletId, required this.walletName});
  final String? walletId;
  final String walletName;

  @override
  State<WalletSettingsPage> createState() => _WalletSettingsPageState();
}

class _WalletSettingsPageState extends State<WalletSettingsPage> {
  late Future<int> _pinnedIndexFuture;

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
                'address for send and receive. Index 0 resets to the default.'),
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
    _snack('Pinned index $index · ${shorten(addr, head: 10, tail: 8)}');
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = walletService.isUnlocked;
    return ListenableBuilder(
      listenable: privacyService,
      builder: (context, _) => SettingsPage(
        title: widget.walletName,
        children: [
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
          SettingsGroup(
            title: 'Tools',
            scope: 'This wallet',
            children: [
              SettingsRow(
                icon: Icons.layers_outlined,
                title: 'UTXO management',
                subtitle: 'Consolidate, split and restructure boxes.',
                onTap: unlocked ? () => Navigator.pushNamed(context, '/utxos') : null,
              ),
              SettingsRow(
                icon: Icons.blender_outlined,
                title: 'Mix',
                subtitle: 'Move ERG through the ErgoMixer pool so it cannot be traced back.',
                onTap: unlocked ? () => Navigator.pushNamed(context, '/mix') : null,
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
        ],
      ),
    );
  }
}
