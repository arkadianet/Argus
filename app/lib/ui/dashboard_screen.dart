import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import 'create_wallet_screen.dart';
import 'pin_fields.dart';
import 'restore_wallet_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _loading = true;
  String _status = 'Initializing...';
  String? _receiveAddress;
  String? _changeAddress;
  String? _senderAddress;
  int? _balanceNano;
  List<Map<String, dynamic>> _recentTxs = [];
  List<Map<String, dynamic>> _usedAddresses = [];
  List<TokenBalance> _tokens = [];
  bool _walletUnlocked = false;
  bool _hasSeed = false;
  bool _hasPin = false;
  bool _canBiometric = false;
  final _pinCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    walletService.unlocked.addListener(_syncLock);
    _init();
  }

  @override
  void dispose() {
    walletService.unlocked.removeListener(_syncLock);
    _pinCtrl.dispose();
    super.dispose();
  }

  void _syncLock() {
    if (!walletService.unlocked.value && _walletUnlocked && mounted) {
      setState(_resetLocked);
    }
  }

  void _resetLocked() {
    _walletUnlocked = false;
    _receiveAddress = null;
    _changeAddress = null;
    _senderAddress = null;
    _balanceNano = null;
    _recentTxs = [];
    _usedAddresses = [];
    _tokens = [];
    _status = _hasSeed ? 'Locked' : 'No wallet. Create or restore one.';
  }

  Future<void> _init() async {
    try {
      await walletService.init();
      _hasSeed = await SecureStorageService.hasEncryptedSeed();
      _hasPin = await SecureStorageService.hasPinWrap();
      _canBiometric = await SecureStorageService.hasBiometric() &&
          await SecureStorageService.hasWrapKey();
      _status = _hasSeed ? 'Wallet found. Unlock to continue.' : 'No wallet. Create or restore one.';
    } on ArgusException catch (e) {
      _status = '${e.code}: ${e.message}';
    } catch (e) {
      _status = 'Error: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _afterUnlock() async {
    setState(() {
      _walletUnlocked = true;
      _status = 'Discovering addresses…';
    });
    try {
      final raw = await walletService.discoverAddresses();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final used = (map['addresses'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final next = (map['next_unused_index'] as num?)?.toInt() ?? 0;
      final receive = await walletService.deriveAddress(next);
      final sender = used.isNotEmpty
          ? used.last['address']?.toString() ?? receive
          : receive;
      setState(() {
        _usedAddresses = used;
        _receiveAddress = receive;
        _changeAddress = receive;
        _senderAddress = sender;
        _status = 'Unlocked';
      });
      await _refresh();
    } catch (e) {
      final fallback = await walletService.deriveAddress(0);
      setState(() {
        _receiveAddress = fallback;
        _changeAddress = fallback;
        _senderAddress = fallback;
        _status = 'Unlocked (discovery unavailable)';
      });
      await _refresh();
    }
  }

  Future<void> _unlockWithPin() async {
    final err = validatePin(_pinCtrl.text);
    if (err != null) {
      _snack(err);
      return;
    }
    try {
      final json = await SecureStorageService.loadEncryptedSeed();
      final pinWrap = await SecureStorageService.loadPinWrap();
      if (json == null || pinWrap == null) {
        setState(() => _status = 'No PIN-protected wallet found.');
        return;
      }
      final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, _pinCtrl.text);
      await walletService.restoreWallet(json, wrapKey: wrapKey);
      _pinCtrl.clear();
      await _afterUnlock();
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } on SecureStorageException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _unlockBiometric() async {
    try {
      if (!await SecureStorageService.authenticateBiometric()) return;
      final json = await SecureStorageService.loadEncryptedSeed();
      final wrapKey = await SecureStorageService.loadWrapKey();
      if (json == null || wrapKey == null) {
        _snack('Biometric unlock is not set up');
        return;
      }
      await walletService.restoreWallet(json, wrapKey: wrapKey);
      await _afterUnlock();
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } on SecureStorageException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _unlockLegacyThenPin() async {
    try {
      final json = await SecureStorageService.loadEncryptedSeed();
      final wrapKey = await SecureStorageService.loadWrapKey();
      if (json == null || wrapKey == null) {
        setState(() => _status = 'No wallet found. Create or restore.');
        return;
      }
      await walletService.restoreWallet(json, wrapKey: wrapKey);
      if (!mounted) return;
      final pin = await _askNewPin();
      if (pin != null) {
        final pinWrap = await walletService.wrapKeyWithPin(wrapKey, pin);
        await SecureStorageService.savePinWrap(pinWrap);
        await SecureStorageService.deleteWrapKey();
        _hasPin = true;
      }
      await _afterUnlock();
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } on SecureStorageException catch (e) {
      _snack(e.message);
    }
  }

  Future<String?> _askNewPin() async {
    final pin = TextEditingController();
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set a PIN'),
        content: PinFields(pin: pin, confirm: confirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final value = pin.text;
    final confirmValue = confirm.text;
    pin.dispose();
    confirm.dispose();
    if (ok != true) return null;
    final err = pinError(value, confirmValue);
    if (err != null) {
      _snack(err);
      return null;
    }
    return value;
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
      final pinWrap = await SecureStorageService.loadPinWrap();
      if (pinWrap == null) return;
      if (!await SecureStorageService.authenticateBiometric()) return;
      final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, entered);
      await SecureStorageService.saveWrapKey(wrapKey);
      setState(() => _canBiometric = true);
      _snack('Biometric unlock enabled');
    } catch (e) {
      _snack('Could not enable biometrics: $e');
    }
  }

  Future<void> _openCreate() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CreateWalletScreen()),
    );
    if (ok == true) {
      _hasSeed = true;
      _hasPin = true;
      await _afterUnlock();
    }
  }

  Future<void> _openRestore() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const RestoreWalletScreen()),
    );
    if (ok == true) {
      _hasSeed = true;
      _hasPin = true;
      await _afterUnlock();
    }
  }

  Future<void> _refresh() async {
    final addresses = _historyAddresses();
    if (addresses.isEmpty) return;
    try {
      var erg = 0;
      final tokens = <String, TokenBalance>{};
      for (final address in addresses) {
        final map = await walletService.getBalance(address);
        erg += (map['balance_nano_erg'] as num?)?.toInt() ?? 0;
        for (final t in await walletService.hydrateTokens(map['tokens'])) {
          final prev = tokens[t.id];
          tokens[t.id] = TokenBalance(
            id: t.id,
            amount: (prev?.amount ?? 0) + t.amount,
            name: t.name,
            decimals: t.decimals,
            emissionAmount: t.emissionAmount,
            iconUrl: t.iconUrl,
          );
        }
      }
      final txs = await _loadHistory(addresses);
      if (!mounted) return;
      setState(() {
        _balanceNano = erg;
        _tokens = tokens.values.toList();
        _recentTxs = txs.take(5).toList();
      });
    } catch (_) {}
  }

  List<String> _historyAddresses() {
    final out = <String>[];
    for (final used in _usedAddresses) {
      final a = used['address']?.toString();
      if (a != null && a.isNotEmpty) out.add(a);
    }
    if (_receiveAddress != null && !out.contains(_receiveAddress)) {
      out.add(_receiveAddress!);
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _loadHistory(List<String> addresses) async {
    final all = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final address in addresses.take(8)) {
      final raw = await walletService.getTransactionHistory(address, limit: 20);
      for (final tx in jsonDecode(raw) as List) {
        if (tx is! Map) continue;
        final map = Map<String, dynamic>.from(tx);
        final id = map['tx_id']?.toString() ?? '';
        if (id.isEmpty || !seen.add(id)) continue;
        all.add(map);
      }
    }
    all.sort((a, b) {
      final tb = (b['timestamp'] as num?)?.toInt() ?? 0;
      final ta = (a['timestamp'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return all;
  }

  Future<void> _lock() async {
    await walletService.lock();
    setState(_resetLocked);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  WalletRouteArgs _args() {
    return WalletRouteArgs(
      senderAddress: _senderAddress ?? _receiveAddress ?? '',
      receiveAddress: _receiveAddress ?? '',
      changeAddress: _changeAddress ?? _receiveAddress ?? '',
      historyAddresses: _historyAddresses(),
      tokens: _tokens,
    );
  }

  void _go(String route) {
    if (!_walletUnlocked || _receiveAddress == null) {
      _snack('Unlock the wallet first');
      return;
    }
    Navigator.pushNamed(context, route, arguments: _args());
  }

  String _erg(int? nano) {
    if (nano == null) return '—';
    return '${(nano / 1e9).toStringAsFixed(4)} ERG';
  }

  String _tokenAmt(TokenBalance t) {
    if (t.decimals <= 0) return '${t.amount}';
    var scale = 1;
    for (var i = 0; i < t.decimals; i++) {
      scale *= 10;
    }
    final whole = t.amount ~/ scale;
    final frac = (t.amount % scale).toString().padLeft(t.decimals, '0');
    return '$whole.$frac';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Argus')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final fungible = _tokens.where((t) => !t.isNft).toList();
    final nfts = _tokens.where((t) => t.isNft).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Argus'),
        actions: [
          if (_walletUnlocked)
            IconButton(
              icon: const Icon(Icons.lock_open),
              tooltip: 'Lock wallet',
              onPressed: _lock,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Unaudited prototype. Use only funds you can afford to lose.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_status, style: theme.textTheme.titleMedium),
                    if (_receiveAddress != null) ...[
                      const SizedBox(height: 8),
                      Text('Receive address', style: theme.textTheme.labelSmall),
                      SelectableText(
                        _receiveAddress!,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Text(_erg(_balanceNano), style: theme.textTheme.headlineSmall),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () =>
                                Clipboard.setData(ClipboardData(text: _receiveAddress!)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.qr_code, size: 18),
                            onPressed: () => _go('/receive'),
                          ),
                        ],
                      ),
                    ],
                    if (!_walletUnlocked) ...[
                      const SizedBox(height: 12),
                      if (_hasSeed && _hasPin) ...[
                        PinFields(pin: _pinCtrl, label: 'Unlock PIN'),
                        const SizedBox(height: 8),
                        FilledButton(onPressed: _unlockWithPin, child: const Text('Unlock')),
                        if (_canBiometric)
                          TextButton(
                            onPressed: _unlockBiometric,
                            child: const Text('Unlock with biometrics'),
                          ),
                      ] else if (_hasSeed)
                        FilledButton(
                          onPressed: _unlockLegacyThenPin,
                          child: const Text('Unlock and set PIN'),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonal(
                              onPressed: _openCreate,
                              child: const Text('Create'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonal(
                              onPressed: _openRestore,
                              child: const Text('Restore'),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_walletUnlocked && _hasPin && !_canBiometric) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _enableBiometric,
                        child: const Text('Enable biometric unlock'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_walletUnlocked) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _go('/send'),
                      icon: const Icon(Icons.send),
                      label: const Text('Send'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => _go('/receive'),
                      icon: const Icon(Icons.qr_code),
                      label: const Text('Receive'),
                    ),
                  ),
                ],
              ),
              if (_usedAddresses.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Used addresses', style: theme.textTheme.titleSmall),
                ..._usedAddresses.map((a) {
                  final addr = a['address']?.toString() ?? '';
                  final nano = (a['balance_nano_erg'] as num?)?.toInt();
                  return ListTile(
                    dense: true,
                    title: Text(
                      addr.length > 18 ? '${addr.substring(0, 18)}…' : addr,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                    trailing: Text(_erg(nano)),
                  );
                }),
              ],
              if (fungible.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Tokens', style: theme.textTheme.titleSmall),
                ...fungible.map(
                  (t) => ListTile(
                    dense: true,
                    title: Text(t.label),
                    subtitle: Text(
                      t.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                    trailing: Text(_tokenAmt(t)),
                  ),
                ),
              ],
              if (nfts.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('NFTs', style: theme.textTheme.titleSmall),
                ...nfts.map(
                  (t) => ListTile(
                    dense: true,
                    title: Text(t.label),
                    subtitle: Text(
                      t.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            Text('Recent Transactions', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_recentTxs.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No transactions yet')),
                ),
              )
            else
              ..._recentTxs.map((tx) {
                final nano = (tx['value_nano_erg'] as num?)?.toInt();
                final txId = tx['tx_id']?.toString() ?? '';
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: Text(_erg(nano), style: const TextStyle(fontFamily: 'monospace')),
                    subtitle: Text(
                      txId.length > 16 ? txId.substring(0, 16) : txId,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: Text('#${tx['height'] ?? '?'}'),
                    onTap: () => _go('/transactions'),
                  ),
                );
              }),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (i) {
          if (i == 1) _go('/send');
          if (i == 2) _go('/receive');
          if (i == 3) _go('/transactions');
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Wallet'),
          NavigationDestination(icon: Icon(Icons.send), label: 'Send'),
          NavigationDestination(icon: Icon(Icons.qr_code), label: 'Receive'),
          NavigationDestination(icon: Icon(Icons.list), label: 'History'),
        ],
      ),
    );
  }
}
