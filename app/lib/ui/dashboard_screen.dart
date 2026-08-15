import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'create_wallet_screen.dart';
import 'pin_fields.dart';
import 'restore_wallet_screen.dart';
import 'settings_screen.dart';

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
  bool _unlockBusy = false;
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
    if (!mounted) return;
    setState(() {
      _walletUnlocked = true;
      _status = 'Looking up addresses';
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
      if (!mounted) return;
      setState(() {
        _usedAddresses = used;
        _receiveAddress = receive;
        _changeAddress = receive;
        _senderAddress = _bestSender(receive);
        _status = 'Unlocked';
      });
      await _refresh();
    } catch (_) {
      try {
        final fallback = await walletService.deriveAddress(0);
        if (!mounted) return;
        setState(() {
          _receiveAddress = fallback;
          _changeAddress = fallback;
          _senderAddress = fallback;
          _status = 'Unlocked (discovery unavailable)';
        });
        await _refresh();
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _walletUnlocked = walletService.isUnlocked;
          _receiveAddress = null;
          _changeAddress = null;
          _senderAddress = null;
          _status = 'Unlocked, but no address could be derived';
        });
      }
    }
  }

  String _bestSender(String receive) {
    var best = receive;
    var bestNano = -1;
    for (final used in _usedAddresses) {
      final addr = used['address']?.toString();
      final nano = (used['balance_nano_erg'] as num?)?.toInt() ?? 0;
      if (addr != null && addr.isNotEmpty && nano >= bestNano) {
        best = addr;
        bestNano = nano;
      }
    }
    return best;
  }

  Future<bool> _pinAllowed() async {
    final gate = await SecureStorageService.loadPinGate();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (gate.until > now) {
      final wait = ((gate.until - now) / 1000).ceil();
      _snack('Too many attempts. Try again in ${wait}s');
      return false;
    }
    return true;
  }

  Future<void> _pinFailed() async {
    final gate = await SecureStorageService.loadPinGate();
    final count = gate.count + 1;
    final delaySec = 1 << (count > 6 ? 5 : count - 1);
    await SecureStorageService.savePinGate(
      count: count,
      until: DateTime.now().millisecondsSinceEpoch + delaySec * 1000,
    );
  }

  Future<void> _pinSucceeded() async {
    await SecureStorageService.savePinGate(count: 0, until: 0);
  }

  Future<void> _runUnlock(Future<void> Function() work) async {
    if (_unlockBusy) return;
    setState(() => _unlockBusy = true);
    try {
      await work();
    } finally {
      if (mounted) setState(() => _unlockBusy = false);
    }
  }

  Future<void> _unlockWithPin() async {
    final err = validatePin(_pinCtrl.text);
    if (err != null) {
      _snack(err);
      return;
    }
    await _runUnlock(() async {
      if (!await _pinAllowed()) return;
      try {
        final json = await SecureStorageService.loadEncryptedSeed();
        final pinWrap = await SecureStorageService.loadPinWrap();
        if (json == null || pinWrap == null) {
          if (mounted) setState(() => _status = 'No PIN-protected wallet found.');
          return;
        }
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, _pinCtrl.text);
        await walletService.restoreWallet(json, wrapKey: wrapKey);
        await _pinSucceeded();
        _pinCtrl.clear();
        await _afterUnlock();
      } on ArgusException catch (e) {
        await _pinFailed();
        _snack('${e.code}: ${e.message}');
      } on SecureStorageException catch (e) {
        _snack(e.message);
      }
    });
  }

  Future<void> _unlockBiometric() async {
    await _runUnlock(() async {
      try {
        final wrapKey = await SecureStorageService.authenticateBiometric();
        if (wrapKey == null) return;
        final json = await SecureStorageService.loadEncryptedSeed();
        if (json == null) {
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
    });
  }

  Future<void> _unlockLegacyThenPin() async {
    await _runUnlock(() async {
      try {
        final json = await SecureStorageService.loadEncryptedSeed();
        final wrapKey = await SecureStorageService.loadWrapKey();
        if (json == null || wrapKey == null) {
          if (mounted) setState(() => _status = 'No wallet found. Create or restore.');
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
          _canBiometric = false;
        }
        await _afterUnlock();
      } on ArgusException catch (e) {
        _snack('${e.code}: ${e.message}');
      } on SecureStorageException catch (e) {
        _snack(e.message);
      }
    });
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

  Future<void> _openCreate() async {
    final ok = await Navigator.push<bool>(
      context,
      fadeRoute(const CreateWalletScreen()),
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
      fadeRoute(const RestoreWalletScreen()),
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
      final maps = await Future.wait(
        addresses.map((address) async {
          try {
            return await walletService.getBalance(address);
          } catch (_) {
            return null;
          }
        }),
      );
      var erg = 0;
      var failed = 0;
      final tokens = <String, TokenBalance>{};
      for (final map in maps) {
        if (map == null) {
          failed++;
          continue;
        }
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
      final txs = await walletService.loadHistory(addresses, limit: 20);
      if (!mounted) return;
      setState(() {
        _balanceNano = erg;
        _tokens = tokens.values.toList();
        _recentTxs = txs.take(5).toList();
        if (failed == addresses.length) {
          _status = 'Could not refresh balances';
        } else if (failed > 0) {
          _status = 'Unlocked (balances may be stale)';
        } else {
          _status = 'Unlocked';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Could not refresh balances');
    }
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

  void _openSettings() {
    Navigator.push(context, fadeRoute(const SettingsScreen()));
  }

  bool get _stale =>
      _status.contains('stale') ||
      _status.contains('unavailable') ||
      _status.contains('Could not') ||
      _status.contains('no address');

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Argus')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Argus'),
        actions: [
          if (_walletUnlocked)
            IconButton(
              icon: const Icon(Icons.lock_open_outlined),
              tooltip: 'Lock wallet',
              onPressed: _lock,
            ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          const WarningStrip(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _walletUnlocked ? _ledger() : _gate(),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _walletUnlocked
          ? NavigationBar(
              selectedIndex: 0,
              onDestinationSelected: (i) {
                if (i == 1) _go('/send');
                if (i == 2) _go('/receive');
                if (i == 3) _go('/transactions');
              },
              destinations: const [
                NavigationDestination(icon: Icon(Icons.menu_book_outlined), label: 'Wallet'),
                NavigationDestination(icon: Icon(Icons.north_east), label: 'Send'),
                NavigationDestination(icon: Icon(Icons.south_west), label: 'Receive'),
                NavigationDestination(icon: Icon(Icons.history), label: 'History'),
              ],
            )
          : null,
    );
  }

  Widget _gate() {
    return ListView(
      key: const ValueKey('gate'),
      padding: const EdgeInsets.fromLTRB(28, 36, 28, 40),
      children: [
        const SizedBox(height: 56),
        const Center(child: IrisMark(size: 72)),
        const SizedBox(height: 20),
        Text(
          'Argus',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Center(child: SizedBox(width: 48, child: Hairline(gold: true))),
        const SizedBox(height: 12),
        Text(
          _hasSeed
              ? 'Enter your PIN to open the ledger.'
              : 'Create a wallet, or restore one you already have.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (_status.startsWith('Error') || _status.contains(':')) ...[
          const SizedBox(height: 12),
          Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: rust)),
        ],
        const SizedBox(height: 36),
        if (_hasSeed && _hasPin) ...[
          PinFields(pin: _pinCtrl, label: 'PIN'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _unlockBusy ? null : _unlockWithPin,
            child: _unlockBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Unlock'),
          ),
          if (_canBiometric)
            TextButton(
              onPressed: _unlockBusy ? null : _unlockBiometric,
              child: const Text('Unlock with biometrics'),
            ),
        ] else if (_hasSeed)
          FilledButton(
            onPressed: _unlockBusy ? null : _unlockLegacyThenPin,
            child: _unlockBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Unlock and set PIN'),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _openCreate,
                child: const Text('Create'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: _openRestore,
                child: const Text('Restore'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ledger() {
    final fungible = _tokens.where((t) => !t.isNft).toList();
    final nfts = _tokens.where((t) => t.isNft).toList();

    return RefreshIndicator(
      key: const ValueKey('ledger'),
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          const SizedBox(height: 28),
          Text(
            formatErg(_balanceNano, unit: false),
            style: Theme.of(context).textTheme.displayLarge,
          ),
          const SizedBox(height: 6),
          const SectionLabel('ERG'),
          if (_stale) ...[
            const SizedBox(height: 10),
            Text(_status, style: const TextStyle(color: rust, fontSize: 12)),
          ],
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _go('/send'),
                  child: const Text('Send'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _go('/receive'),
                  child: const Text('Receive'),
                ),
              ),
            ],
          ),
          if (_receiveAddress != null) ...[
            const SizedBox(height: 28),
            const SectionLabel('Receive'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => _go('/receive'),
              child: Text(_receiveAddress!, style: monoStyle(context, size: 12)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: _receiveAddress!)),
                child: const Text('Copy address'),
              ),
            ),
          ],
          if (fungible.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Hairline(),
            const SizedBox(height: 20),
            const SectionLabel('Tokens'),
            const SizedBox(height: 8),
            ...fungible.map(
              (t) => _line(
                title: t.label,
                trailing: formatTokenAmount(t.amount, t.decimals),
                subtitle: shorten(t.id, head: 10, tail: 6),
              ),
            ),
          ],
          if (nfts.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Hairline(),
            const SizedBox(height: 20),
            const SectionLabel('NFTs'),
            const SizedBox(height: 8),
            ...nfts.map(
              (t) => _line(title: t.label, subtitle: shorten(t.id, head: 10, tail: 6)),
            ),
          ],
          const SizedBox(height: 16),
          const Hairline(),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(child: SectionLabel('Activity')),
              if (_recentTxs.isNotEmpty)
                TextButton(
                  onPressed: () => _go('/transactions'),
                  child: const Text('All'),
                ),
            ],
          ),
          if (_recentTxs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text('Nothing yet.', style: Theme.of(context).textTheme.bodyMedium),
            )
          else
            ..._recentTxs.map((tx) {
              final nano = (tx['value_nano_erg'] as num?)?.toInt();
              final txId = tx['tx_id']?.toString() ?? '';
              return _line(
                title: formatErg(nano),
                subtitle: shorten(txId, head: 10, tail: 8),
                trailing: '#${tx['height'] ?? '?'}',
                onTap: () => _go('/transactions'),
              );
            }),
          if (_usedAddresses.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Hairline(),
            const SizedBox(height: 20),
            const SectionLabel('Used addresses'),
            const SizedBox(height: 8),
            ..._usedAddresses.map((a) {
              final addr = a['address']?.toString() ?? '';
              final nano = (a['balance_nano_erg'] as num?)?.toInt();
              return _line(
                title: shorten(addr, head: 10, tail: 8),
                trailing: formatErg(nano),
                monoTitle: true,
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _line({
    required String title,
    String? subtitle,
    String? trailing,
    bool monoTitle = false,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: monoTitle
                        ? monoStyle(context, size: 13)
                        : Theme.of(context).textTheme.titleMedium,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle, style: monoStyle(context, size: 11)),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              Text(trailing, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
