import 'package:flutter/material.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/address_label_service.dart';
import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/secure_storage.dart';
import '../services/session_lock.dart';
import '../services/watch_only_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import '../theme/theme_controller.dart';
import 'pin_fields.dart';

class SettingsScreen extends StatefulWidget {
  final String? walletId;
  const SettingsScreen({
    super.key,
    this.walletId,
    this.embedded = false,
    this.onWalletSwitched,
  });

  /// Hosted as a home tab: no app bar, and wallet switches are reported via
  /// [onWalletSwitched] instead of popping the route. An empty id means the
  /// wallet this screen showed was deleted.
  final bool embedded;
  final ValueChanged<String>? onWalletSwitched;

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
  late Future<List<WalletInfo>> _walletsFuture;
  late Future<int> _pinnedIndexFuture;

  /// The wallet these wallet-scoped settings apply to. Falls back to the
  /// active wallet when the screen was opened without an explicit id.
  String? get _walletId => widget.walletId ?? walletService.activeWalletId;

  @override
  void initState() {
    super.initState();
    _explorerCtrl.text = networkController.explorer;
    _walletsFuture = walletService.listWallets();
    _pinnedIndexFuture = walletService.getPinnedAddressIndex(walletId: _walletId);
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
      final hasPin = await SecureStorageService.hasPinWrap(walletId: _walletId);
      final bio = hasPin &&
          await SecureStorageService.hasBiometric() &&
          await SecureStorageService.hasWrapKey(walletId: _walletId);
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
      await SecureStorageService.deleteWrapKey(walletId: _walletId);
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
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: _walletId);
        if (pinWrap == null) return false;
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, entered);
        await SecureStorageService.saveWrapKey(wrapKey, walletId: _walletId);
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

  void _refreshWallets() {
    // Callers invoke this after awaits (rename/delete/pin dialogs); a
    // disposed state must not call setState.
    if (!mounted) return;
    setState(() {
      _walletsFuture = walletService.listWallets();
      _pinnedIndexFuture = walletService.getPinnedAddressIndex(walletId: _walletId);
    });
  }

  Future<void> _renameWallet(WalletInfo w) async {
    final ctrl = TextEditingController(text: w.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename wallet'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
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
      _refreshWallets();
    } catch (_) {
      _snack('Could not rename wallet');
    }
  }

  Future<void> _deleteWallet(WalletInfo w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${w.name}?'),
        content: const Text(
          'This removes the wallet from this device. Argus does not keep a '
          'copy of the recovery phrase — the paper you wrote when creating '
          'this wallet is the only way back in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.onError,
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
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
        // The wallet this screen was opened for is gone — pop so the
        // dashboard re-loads onto the first remaining wallet (or none).
        _handOff(remaining.isNotEmpty ? remaining.first.walletId : '');
        return;
      }
      _refreshWallets();
      _snack('Wallet deleted');
    } catch (_) {
      _snack('Could not delete wallet');
    }
  }

  Future<void> _openCreateOrRestore(String route) async {
    await Navigator.pushNamed(context, route);
    _refreshWallets();
  }

  Future<void> _pickFiatCurrency() async {
    final current = networkController.fiatCode;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Display currency'),
        children: [
          for (final entry in NetworkController.fiatOptions.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, entry.key),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${entry.key.toUpperCase()} (${entry.value})'),
                  ),
                  if (entry.key == current)
                    const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    await networkController.setFiatCurrency(picked);
    if (mounted) setState(() {});
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
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: _walletId);
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
        await SecureStorageService.savePinWrap(newPinWrap, walletId: _walletId);
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
    final saved = await watchOnlyService.add(addr);
    _snack(saved ? 'Address added' : 'Not a valid Ergo address');
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
              decoration: InputDecoration(
                labelText: 'Index',
                hintText: '0',
                helperText:
                    '0–${WalletService.maxAddressIndex}',
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
    // Verify the wallet can actually derive the index before persisting.
    final addr = await walletService.tryDeriveAddress(index);
    if (!mounted) return;
    if (addr == null) {
      _snack("Wallet can't derive index $index");
      return;
    }
    await walletService.setPinnedAddressIndex(wid, index);
    _refreshWallets();
    _snack('Pinned index $index · ${shorten(addr, head: 10, tail: 8)}');
  }

  void _handOff(String walletId) {
    final cb = widget.onWalletSwitched;
    if (cb != null) {
      cb(walletId);
    } else {
      Navigator.pop(context, walletId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Settings')),
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
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              const SectionLabel('Network', scope: 'App-wide'),
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
              const SectionLabel('Appearance', scope: 'App-wide'),
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
              const SectionLabel('Currency', scope: 'App-wide'),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: networkController,
                builder: (context, _) => InkWell(
                  onTap: _pickFiatCurrency,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      border: Border(
                          bottom:
                              BorderSide(color: Theme.of(context).dividerColor)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Display currency',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 2),
                              Text(
                                'ERG price shown in '
                                '${networkController.fiatCode.toUpperCase()}',
                                style:
                                    Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        Text(
                          networkController.fiatSymbol,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.arrow_drop_down, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const SectionLabel('Auto-lock', scope: 'App-wide'),
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
              const SectionLabel('Privacy', scope: 'This wallet'),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fresh change addresses'),
                subtitle: Text(
                  'Send transaction change to unused addresses instead of your first address.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
                    if (mounted) _snack('Could not update privacy setting');
                  }
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 28),
              const SectionLabel('Unlock', scope: 'This wallet'),
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
              const SizedBox(height: 28),
              const SectionLabel('Wallets', scope: 'App-wide'),
              const SizedBox(height: 12),
              FutureBuilder(
                future: _walletsFuture,
                builder: (context, snapshot) {
                  final wallets = snapshot.data ?? [];
                  if (wallets.isEmpty) {
                    return Text(
                      'No wallets stored.',
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  }
                  final currentId = _walletId;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final w in wallets)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.account_balance_wallet_outlined,
                            size: 22,
                            color: w.walletId == currentId
                                ? iris
                                : Theme.of(context).colorScheme.primary,
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(w.name,
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                              if (w.isUnlocked) ...[
                                const SizedBox(width: 6),
                                Text('UNLOCKED',
                                    style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary)),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            w.address0 != null
                                ? shorten(w.address0!, head: 10, tail: 8)
                                : 'wallet_id: ${w.walletId.length >= 8 ? w.walletId.substring(0, 8) : w.walletId}…',
                            style: monoStyle(context, size: 11),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Rename',
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                onPressed: () => _renameWallet(w),
                              ),
                              IconButton(
                                tooltip: 'Delete',
                                icon: Icon(Icons.delete_outline,
                                    size: 18,
                                    color: Theme.of(context).colorScheme.error),
                                onPressed: () => _deleteWallet(w),
                              ),
                            ],
                          ),
                          onTap: () {
                            // Tapping another wallet switches to it: pop with
                            // its id so the dashboard runs the switch flow.
                            if (w.walletId != currentId) {
                              _handOff(w.walletId);
                            }
                          },
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () => _openCreateOrRestore('/create'),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Create new'),
                          ),
                          TextButton.icon(
                            onPressed: () => _openCreateOrRestore('/restore'),
                            icon: const Icon(Icons.restore, size: 18),
                            label: const Text('Restore'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              if (walletService.isUnlocked) ...[
                const SizedBox(height: 28),
                const SectionLabel('Advanced Tools', scope: 'This wallet'),
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
              const SectionLabel('Watch-only addresses', scope: 'App-wide'),
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
              const SectionLabel('Primary address', scope: 'This wallet'),
              const SizedBox(height: 12),
              FutureBuilder(
                future: _pinnedIndexFuture,
                builder: (context, snapshot) {
                  final pinned = snapshot.data ?? 0;
                  final isPinned = pinned != 0;
                  final outOfRange = pinned > WalletService.maxAddressIndex;
                  return ListTile(
                    leading: Icon(
                      Icons.push_pin_outlined,
                      color: outOfRange ? Theme.of(context).colorScheme.error : null,
                    ),
                    title: Text(outOfRange
                        ? "Pinned index #$pinned can't be derived"
                        : isPinned
                            ? 'Address index #$pinned is pinned as primary'
                            : 'Primary address (index 0)'),
                    subtitle: outOfRange
                        ? Text(
                            'This wallet derives up to index '
                            '${WalletService.maxAddressIndex}. Unpin or choose a lower index — the dashboard is falling back to index 0.',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.error),
                          )
                        : (isPinned && walletService.isUnlocked
                            ? FutureBuilder<String?>(
                                future: walletService.tryDeriveAddress(pinned),
                                builder: (context, snap) {
                                  final addr = snap.data;
                                  if (addr == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return Text(
                                    shorten(addr, head: 10, tail: 8),
                                    style: monoStyle(context, size: 11),
                                  );
                                },
                              )
                            : null),
                    trailing: isPinned
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: 'Unpin',
                             onPressed: () async {
     final wid = _walletId;
                                if (wid == null) return;
                                await walletService.setPinnedAddressIndex(wid, 0);
                                _refreshWallets();
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
              const SectionLabel('Address labels', scope: 'App-wide'),
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
