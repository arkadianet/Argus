import 'package:flutter/material.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/address_label_service.dart';
import '../services/network_controller.dart';
import '../services/secure_storage.dart';
import '../services/session_lock.dart';
import '../services/watch_only_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import '../theme/theme_controller.dart';
import 'pin_fields.dart';

class SettingsScreen extends StatefulWidget {
  final String? walletId;
  const SettingsScreen({super.key, this.walletId});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _canBiometric = false;
  bool _hasPin = false;
  bool _unlockLoadFailed = false;
  bool _busy = false;
  int _graceKey = 0;
  final _nodeCtrl = TextEditingController();
  final _explorerCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _explorerCtrl.text = networkController.explorer;
    _load();
  }

  @override
  void dispose() {
    _nodeCtrl.dispose();
    _explorerCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final hasPin = await SecureStorageService.hasPinWrap(walletId: widget.walletId);
      final bio = hasPin &&
          await SecureStorageService.hasBiometric() &&
          await SecureStorageService.hasWrapKey(walletId: widget.walletId);
      if (!mounted) return;
      setState(() {
        _hasPin = hasPin;
        _canBiometric = bio;
        _unlockLoadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _unlockLoadFailed = true);
      _snack('Could not load unlock settings');
    }
  }

  Future<void> _disableBiometric() async {
    setState(() => _busy = true);
    try {
      await SecureStorageService.deleteWrapKey(walletId: widget.walletId);
      await _load();
    } catch (_) {
      _snack('Could not disable biometrics');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addNode() async {
    final err = await networkController.addNode(_nodeCtrl.text);
    if (err != null) {
      _snack(err);
      return;
    }
    if (!mounted) return;
    _nodeCtrl.clear();
  }

  Future<void> _enableBiometric() async {
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm PIN'),
        content: PinFields(pin: pin),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    final entered = pin.text;
    pin.dispose();
    if (ok != true) return;
    final pinErr = validatePin(entered);
    if (pinErr != null) {
      _snack(pinErr);
      return;
    }
    try {
      final blocked = await SecureStorageService.pinBlockedMessage();
      if (blocked != null) {
        _snack(blocked);
        return;
      }
    } on SecureStorageException {
      _snack('Could not check PIN lockout');
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = await sessionLock.run(() async {
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: widget.walletId);
        if (pinWrap == null) return false;
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, entered);
        await SecureStorageService.saveWrapKey(wrapKey, walletId: widget.walletId);
        await SecureStorageService.clearPinGate();
        return true;
      });
      if (!mounted) return;
      if (!saved) {
        _snack('No PIN-protected wallet found.');
        return;
      }
      setState(() => _canBiometric = true);
      _snack('Biometric unlock enabled');
    } on ArgusException catch (e) {
      if (isIncorrectPin(e)) {
        try {
          await SecureStorageService.recordPinFailure();
        } catch (_) {}
        _snack('Incorrect PIN');
      } else {
        _snack('Could not enable biometrics');
      }
    } catch (_) {
      _snack('Could not enable biometrics');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchWallet() async {
    final wallets = await walletService.listWallets();
    if (!mounted) return;
    final current = widget.walletId;
    final result = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Select wallet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          for (final w in wallets)
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: Text(w.name),
              subtitle: Text(w.address0 != null ? w.address0! : 'wallet_id: ${w.walletId.substring(0, 8)}…'),
              selected: w.walletId == current,
              trailing: w.isUnlocked ? const Icon(Icons.lock_open, size: 16) : null,
              onTap: () => Navigator.pop(ctx, w.walletId),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (result != null && result != current) {
      Navigator.pop(context, result);
    }
  }

  Future<void> _changePin() async {
    final oldPin = TextEditingController();
    final newPin = TextEditingController();
    final confirmPin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PinFields(pin: oldPin, label: 'Current PIN'),
            const SizedBox(height: 12),
            PinFields(pin: newPin, confirm: confirmPin, label: 'New PIN'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change')),
        ],
      ),
    );
    final old = oldPin.text;
    final next = newPin.text;
    final confirm = confirmPin.text;
    oldPin.dispose();
    newPin.dispose();
    confirmPin.dispose();
    if (ok != true) return;
    final pinErr = validatePin(next);
    if (pinErr != null) {
      _snack(pinErr);
      return;
    }
    if (next != confirm) {
      _snack('PINs do not match');
      return;
    }
    setState(() => _busy = true);
    try {
      var changed = false;
      await sessionLock.run(() async {
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: widget.walletId);
        if (pinWrap == null) {
          _snack('No PIN-protected wallet found');
          return;
        }
        final blocked = await SecureStorageService.pinBlockedMessage();
        if (blocked != null) {
          _snack(blocked);
          return;
        }
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, old);
        final newPinWrap = await walletService.wrapKeyWithPin(wrapKey, next);
        await SecureStorageService.savePinWrap(newPinWrap, walletId: widget.walletId);
        changed = true;
      });
      if (changed) {
        _snack('PIN changed');
        try {
          await SecureStorageService.clearPinGate();
        } catch (_) {
          _snack('PIN changed but lockout state could not be reset');
        }
      }
    } on ArgusException catch (e) {
      if (isIncorrectPin(e)) {
        try {
          await SecureStorageService.recordPinFailure();
        } catch (_) {}
        _snack('Incorrect PIN');
      } else {
        _snack('${e.code}: ${e.message}');
      }
    } catch (_) {
      _snack('Could not change PIN');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addWatchAddress() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add watch-only address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Ergo address',
                hintText: '9...',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    final addr = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || addr.isEmpty) return;
    if (!looksLikeErgoAddress(addr)) {
      _snack('Not a valid Ergo address');
      return;
    }
    await watchOnlyService.add(addr);
    _snack('Address added');
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
            const Text('Derive address at this index and pin it as the primary '
                'address for send/receive flows. Use index 0 to reset to default.'),
            const SizedBox(height: 12),
            TextField(
              controller: indexCtrl,
              decoration: const InputDecoration(
                labelText: 'Index',
                hintText: '0',
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
    if (ok != true) return;
    final text = indexCtrl.text.trim();
    indexCtrl.dispose();
    final index = int.tryParse(text);
    if (index == null || index < 0) {
      _snack('Invalid index');
      return;
    }
    await walletService.setPinnedAddressIndex(walletService.activeWalletId!, index);
    _snack('Pinned address index $index');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          themeController,
          networkController,
          walletService.unlocked,
          addressLabelService,
          watchOnlyService,
        ]),
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              const SectionLabel('Network'),
              const SizedBox(height: 8),
              Text(
                networkController.statusLabel,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: networkController.probing ? null : networkController.probe,
                  child: Text(networkController.probing ? 'Checking…' : 'Check nodes'),
                ),
              ),
              ...List.generate(networkController.nodes.length, (i) {
                final n = networkController.nodes[i];
                final active = n.url == networkController.activeUrl;
                final last = i == networkController.nodes.length - 1;
                final isLastEnabled = n.enabled && networkController.enabledUrls.length <= 1;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(Uri.tryParse(n.url)?.host ?? n.url,
                                style: Theme.of(context).textTheme.titleMedium),
                            Text(
                              describeNode(
                                n,
                                networkController.probes[n.url],
                                active: active,
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Up',
                        onPressed: i == 0 ? null : () => networkController.moveNode(i, -1),
                        icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                      ),
                      IconButton(
                        tooltip: 'Down',
                        onPressed: last ? null : () => networkController.moveNode(i, 1),
                        icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                      ),
                      IconButton(
                        tooltip: n.enabled ? 'Disable' : 'Enable',
                        onPressed: isLastEnabled ? null : () => networkController.toggleNode(i),
                        icon: Icon(n.enabled ? Icons.visibility : Icons.visibility_off, size: 20),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        onPressed: isLastEnabled ? null : () => networkController.removeNode(i),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                );
              }),
              TextField(
                controller: _nodeCtrl,
                decoration: InputDecoration(
                  labelText: 'Add node URL',
                  hintText: 'https://host  or  1.2.3.4:9053',
                  suffixIcon: IconButton(
                    tooltip: 'Add',
                    onPressed: _addNode,
                    icon: const Icon(Icons.add),
                  ),
                ),
                onSubmitted: (_) => _addNode(),
              ),
              const SizedBox(height: 8),
              Text(
                'Built-in nodes are HTTPS. You can add http://ip:port for a node you run or trust. That traffic is not encrypted.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _explorerCtrl,
                decoration: InputDecoration(
                  labelText: 'Explorer URL',
                  hintText: 'https://api.sigmaspace.io',
                  suffixIcon: IconButton(
                    tooltip: 'Save',
                    onPressed: () => networkController.setExplorer(_explorerCtrl.text),
                    icon: const Icon(Icons.check),
                  ),
                ),
                onSubmitted: networkController.setExplorer,
              ),
              const SizedBox(height: 8),
              Text(
                'Token names and decimals come from extraIndex nodes first, then this explorer API as a fallback. The URL is also used for Open in explorer.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 28),
              const SectionLabel('Appearance'),
              const SizedBox(height: 12),
              ...ArgusPalette.values.map((p) {
                final label = switch (p) {
                  ArgusPalette.system => 'System',
                  ArgusPalette.watchful => 'Watchful',
                  ArgusPalette.ledger => 'Ledger',
                };
                final hint = switch (p) {
                  ArgusPalette.system => 'Dark → Watchful, light → Ledger',
                  ArgusPalette.watchful => 'Ink ground, bone type',
                  ArgusPalette.ledger => 'Warm paper, dark ink',
                };
                final selected = themeController.palette == p;
                return Semantics(
                  selected: selected,
                  button: true,
                  label: label,
                  child: InkWell(
                  onTap: () => themeController.setPalette(p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text(hint, style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: selected ? iris : Colors.transparent,
                            border: Border.all(color: iris, width: 1.2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                );
              }),
              const SizedBox(height: 28),
              const SectionLabel('Auto-lock'),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: ValueKey(_graceKey),
                initialValue: sessionLock.grace.inSeconds,
                decoration: const InputDecoration(
                  labelText: 'Lock when backgrounded',
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Immediately')),
                  DropdownMenuItem(value: 2, child: Text('After 2 seconds')),
                  DropdownMenuItem(value: 30, child: Text('After 30 seconds')),
                  DropdownMenuItem(value: 60, child: Text('After 1 minute')),
                  DropdownMenuItem(value: 300, child: Text('After 5 minutes')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  try {
                    await sessionLock.setGrace(Duration(seconds: v));
                  } catch (_) {
                    if (mounted) setState(() => _graceKey++);
                    _snack('Could not update auto-lock');
                  }
                },
              ),
              const SizedBox(height: 28),
              const SectionLabel('Unlock'),
              const SizedBox(height: 12),
              if (!walletService.isUnlocked)
                Text(
                  'Unlock the wallet to change biometric settings.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else if (_unlockLoadFailed)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy ? null : _load,
                    child: const Text('Retry unlock settings'),
                  ),
                )
              else if (_canBiometric) ...[
                Text(
                  'Biometric unlock is on. The PIN still unwraps the key.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy ? null : _disableBiometric,
                    child: const Text('Disable biometric unlock'),
                  ),
                ),
              ]
              else if (_hasPin)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy ? null : _enableBiometric,
                    child: const Text('Enable biometric unlock'),
                  ),
                )
              else
                Text(
                  'Set a PIN when you create or restore a wallet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (_hasPin && walletService.isUnlocked) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _busy ? null : _changePin,
                    icon: const Icon(Icons.lock_reset),
                    label: const Text('Change PIN'),
                  ),
                ),
              ],
              if (walletService.isUnlocked) ...[
                const SizedBox(height: 28),
                const SectionLabel('Wallets'),
                const SizedBox(height: 12),
                FutureBuilder(
                  future: walletService.listWallets(),
                  builder: (context, snapshot) {
                    final wallets = snapshot.data ?? [];
                    if (wallets.length < 2) {
                      return Text(
                        wallets.isEmpty
                            ? 'No wallets stored.'
                            : '1 wallet stored. Create or restore another to switch.',
                        style: Theme.of(context).textTheme.bodySmall,
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${wallets.length} wallets stored',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _busy ? null : _switchWallet,
                          icon: const Icon(Icons.swap_horiz),
                          label: const Text('Switch wallet'),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 28),
                const SectionLabel('Advanced Tools'),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.pushNamed(context, '/utxos'),
                    icon: const Icon(Icons.layers_outlined),
                    label: const Text('UTXO Management & Restructuring'),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              const SectionLabel('Watch-only addresses'),
              const SizedBox(height: 12),
              if (watchOnlyService.addresses.isEmpty)
                Text(
                  'Monitor balances for addresses without a seed. Add addresses to track them on the dashboard.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      children: watchOnlyService.addresses.map((addr) {
                        return Chip(
                          label: Text(
                            shorten(addr, head: 6, tail: 4),
                            style: monoStyle(context, size: 10),
                          ),
                          onDeleted: () => watchOnlyService.remove(addr),
                          visualDensity: VisualDensity.compact,
                        );
                      }).toList(),
                    ),
                    TextButton(
                      onPressed: () => _addWatchAddress(),
                      child: const Text('Add address'),
                    ),
                  ],
                ),
              if (watchOnlyService.addresses.isEmpty)
                TextButton(
                  onPressed: () => _addWatchAddress(),
                  child: const Text('Add watch-only address'),
                ),
              const SizedBox(height: 28),
              const SectionLabel('Primary address'),
              const SizedBox(height: 12),
              FutureBuilder(
                future: walletService.getPinnedAddressIndex(),
                builder: (context, snapshot) {
                  final pinned = snapshot.data ?? 0;
                  final isPinned = pinned != 0;
                  return ListTile(
                    leading: const Icon(Icons.push_pin_outlined),
                    title: Text(isPinned
                        ? 'Address index #$pinned is pinned as primary'
                        : 'Primary address (index 0)'),
                    trailing: isPinned
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: 'Unpin',
                            onPressed: () async {
                              await walletService.setPinnedAddressIndex(
                                walletService.activeWalletId!,
                                0,
                              );
                              setState(() {});
                            },
                          )
                        : null,
                  );
                },
              ),
              TextButton.icon(
                onPressed: walletService.isUnlocked
                    ? _pinAddressIndex
                    : null,
                icon: const Icon(Icons.search),
                label: const Text('Find & pin an address index'),
              ),
              const SizedBox(height: 28),
              const SectionLabel('Address labels'),
              const SizedBox(height: 12),
              if (addressLabelService.labels.isEmpty)
                Text(
                  'Tap any address on the dashboard or receive screen to label it.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: addressLabelService.labels.entries.map((e) => Chip(
                    label: Text(
                      '${e.value}: ${shorten(e.key, head: 6, tail: 4)}',
                      style: monoStyle(context, size: 10),
                    ),
                    onDeleted: () => addressLabelService.removeLabel(e.key),
                    visualDensity: VisualDensity.compact,
                  )).toList(),
                ),
              const SizedBox(height: 28),
              const SectionLabel('Backup'),
              const SizedBox(height: 12),
              Text(
                'Argus does not keep a copy of the recovery phrase. The paper you wrote at create or restore is the only way back in.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
        },
      ),
    );
  }
}
