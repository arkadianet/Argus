import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/network_controller.dart';
import '../services/secure_storage.dart';
import '../services/session_lock.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'create_wallet_screen.dart';
import 'pin_fields.dart';
import 'restore_wallet_screen.dart';
import 'settings_screen.dart';
import 'transaction_detail_screen.dart';

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
  int _utxoCount = 0;
  bool _organizeBusy = false;
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
      await networkController.load();
      networkController.probe();
      await _refreshUnlockMethods();
      _status = _hasSeed ? 'Wallet found. Unlock to continue.' : 'No wallet. Create or restore one.';
    } on ArgusException catch (e) {
      _status = '${e.code}: ${e.message}';
    } catch (e) {
      _status = 'Error: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshUnlockMethods() async {
    _hasSeed = await SecureStorageService.hasEncryptedSeed();
    _hasPin = await SecureStorageService.hasPinWrap();
    _canBiometric = await SecureStorageService.hasBiometric() &&
        await SecureStorageService.hasWrapKey();
  }

  Future<void> _afterUnlock() async {
    if (!mounted) return;
    if (!walletService.isUnlocked) {
      setState(_resetLocked);
      return;
    }
    try {
      final receive = await walletService.deriveAddress(0);
      if (!mounted) return;
      if (!walletService.isUnlocked) {
        setState(_resetLocked);
        return;
      }
      setState(() {
        _walletUnlocked = true;
        _receiveAddress = receive;
        _changeAddress = receive;
        _senderAddress = receive;
        _status = 'Looking up addresses';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _walletUnlocked = walletService.isUnlocked;
        _receiveAddress = null;
        _changeAddress = null;
        _senderAddress = null;
        _status = walletService.isUnlocked
            ? 'Unlocked, but no address could be derived'
            : 'Locked';
      });
      return;
    }
    try {
      final raw = await walletService.discoverAddresses();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final used = (map['addresses'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final next = (map['next_unused_index'] as num?)?.toInt() ?? 0;
      final receive = next == 0
          ? (_receiveAddress ?? await walletService.deriveAddress(0))
          : await walletService.deriveAddress(next);
      if (!mounted) return;
      if (!walletService.isUnlocked) {
        setState(_resetLocked);
        return;
      }
      setState(() {
        _usedAddresses = used;
        _receiveAddress = receive;
        _changeAddress = receive;
        _senderAddress = _bestSender(receive);
        _status = 'Unlocked';
      });
      await _refresh();
    } catch (_) {
      if (!mounted) return;
      if (!walletService.isUnlocked) {
        setState(_resetLocked);
        return;
      }
      setState(() => _status = 'Unlocked (discovery unavailable)');
      await _refresh();
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
    try {
      final blocked = await SecureStorageService.pinBlockedMessage();
      if (blocked != null) {
        _snack(blocked);
        return false;
      }
      return true;
    } on SecureStorageException {
      _snack('Could not check PIN lockout');
      return false;
    }
  }

  Future<void> _pinFailed() async {
    await SecureStorageService.recordPinFailure();
  }

  Future<void> _pinSucceeded() async {
    await SecureStorageService.clearPinGate();
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
        try {
          await _pinSucceeded();
        } catch (_) {}
        _pinCtrl.clear();
        HapticFeedback.lightImpact();
        await _afterUnlock();
      } on ArgusException catch (e) {
        try {
          await _pinFailed();
        } catch (_) {}
        _snack('${e.code}: ${e.message}');
      } on SecureStorageException catch (e) {
        _snack(e.message);
      }
    });
  }

  Future<void> _unlockBiometric() async {
    await _runUnlock(() async {
      try {
        final wrapKey = await sessionLock.run(SecureStorageService.authenticateBiometric);
        if (wrapKey == null) {
          if (!await SecureStorageService.hasWrapKey()) {
            _snack('Biometric unlock is not set up. Enable it in Settings after unlocking with PIN.');
          }
          return;
        }
        final json = await SecureStorageService.loadEncryptedSeed();
        if (json == null) {
          _snack('Biometric unlock is not set up');
          return;
        }
        await walletService.restoreWallet(json, wrapKey: wrapKey);
        HapticFeedback.lightImpact();
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
      await _refreshUnlockMethods();
      await _afterUnlock();
    }
  }

  Future<void> _openRestore() async {
    final ok = await Navigator.push<bool>(
      context,
      fadeRoute(const RestoreWalletScreen()),
    );
    if (ok == true) {
      await _refreshUnlockMethods();
      await _afterUnlock();
    }
  }

  Future<void> _refresh() async {
    networkController.probe();
    setState(() => _status = 'Syncing addresses…');
    try {
      final raw = await walletService.discoverAddresses();
      if (!mounted) return;
      if (!walletService.isUnlocked) {
        setState(_resetLocked);
        return;
      }
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final used = (map['addresses'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final next = (map['next_unused_index'] as num?)?.toInt() ?? 0;
      final receive = next == 0
          ? (_receiveAddress ?? await walletService.deriveAddress(0))
          : await walletService.deriveAddress(next);
      if (!mounted) return;
      if (!walletService.isUnlocked) {
        setState(_resetLocked);
        return;
      }
      setState(() {
        _usedAddresses = used;
        _receiveAddress = receive;
        _changeAddress = receive;
        _senderAddress = _bestSender(receive);
      });
    } catch (_) {
      // Discovery failed — fall through to balance refresh with known addresses.
    }
    final addresses = _historyAddresses();
    if (addresses.isEmpty) {
      if (mounted) setState(() => _status = 'Could not find any addresses');
      return;
    }
    try {
      setState(() => _status = 'Refreshing balances…');
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
      if (!walletService.isUnlocked) {
        setState(_resetLocked);
        return;
      }
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
    _refreshUtxos();
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

  Future<void> _refreshUtxos() async {
    final addr = _historyAddresses();
    if (addr.isEmpty || _senderAddress == null) return;
    try {
      final boxes = await walletService.listUnspentBoxes(addr,
          nodeUrl: networkController.activeUrl);
      if (!mounted) return;
      setState(() => _utxoCount = boxes.length);
    } catch (_) {
      // UTXO count is best-effort; don't disrupt the dashboard
    }
  }

  Future<void> _organize() async {
    if (_organizeBusy) return;
    setState(() => _organizeBusy = true);
    try {
      final txIds = await walletService.consolidateErg(
        addresses: _historyAddresses(),
        changeAddress: _senderAddress ?? _receiveAddress ?? '',
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      if (txIds.isNotEmpty) {
        _snack('Consolidated in ${txIds.length} tx(s): '
            '${txIds.map((id) => shorten(id, head: 6, tail: 6)).join(', ')}');
        await _refresh();
      } else {
        _snack('Fragmentation is low — no consolidation needed');
      }
    } catch (_) {
      if (mounted) _snack('Could not consolidate UTXOs');
    } finally {
      if (mounted) setState(() => _organizeBusy = false);
    }
  }

  Future<void> _lock() async {
    await walletService.lock();
    setState(_resetLocked);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  WalletRouteArgs _args({Map<String, dynamic>? transaction}) {
    return WalletRouteArgs(
      senderAddress: _senderAddress ?? _receiveAddress ?? '',
      receiveAddress: _receiveAddress ?? '',
      changeAddress: _changeAddress ?? _receiveAddress ?? '',
      historyAddresses: _historyAddresses(),
      tokens: _tokens,
      spendableNano: _balanceNano,
      transaction: transaction,
    );
  }

  void _go(String route) {
    if (!walletService.isUnlocked || !_walletUnlocked) {
      _snack('Unlock the wallet first');
      return;
    }
    if (_receiveAddress == null) {
      _snack('Address is still loading');
      return;
    }
    Navigator.pushNamed(context, route, arguments: _args());
  }

  void _openTx(Map<String, dynamic> tx) {
    Navigator.push(
      context,
      fadeRoute(const TransactionDetailScreen(), settings: RouteSettings(arguments: _args(transaction: tx))),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, fadeRoute(const SettingsScreen()));
    if (!mounted) return;
    try {
      await _refreshUnlockMethods();
    } catch (_) {}
    if (mounted) setState(() {});
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
          PinFields(
            pin: _pinCtrl,
            label: 'PIN',
            onSubmitted: (_) {
              if (!_unlockBusy) _unlockWithPin();
            },
          ),
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
          ListenableBuilder(
            listenable: networkController,
            builder: (context, _) {
              final usd = networkController.usdPerErg;
              final nano = _balanceNano;
              final fiat = usd != null && nano != null
                  ? '≈ \$${(nano / 1e9 * usd).toStringAsFixed(2)}'
                  : null;
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  [
                    if (fiat != null) fiat,
                    networkController.statusLabel,
                  ].join('  ·  '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            },
          ),
          if (_stale) ...[
            const SizedBox(height: 10),
            Text(_status, style: const TextStyle(color: rust, fontSize: 12)),
          ] else if (_status.contains('Syncing') || _status.contains('Refreshing') || _status.contains('Looking up addresses')) ...[
            const SizedBox(height: 10),
            Text(_status, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12)),
          ],
          if (_utxoCount > 80) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.folder_open, size: 14,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  '$_utxoCount UTXOs',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _organizeBusy ? null : _organize,
                  icon: _organizeBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.compress, size: 16),
                  label: Text(_organizeBusy ? 'Organizing…' : 'Organize'),
                ),
              ],
            ),
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
              child: Text(
                'No activity yet. Receive to the address above.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          else
            ..._groupedActivity(_recentTxs),
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

  List<Widget> _groupedActivity(List<Map<String, dynamic>> txs) {
    final out = <Widget>[];
    String? lastDay;
    for (final tx in txs) {
      final day = dayKey((tx['timestamp'] as num?)?.toInt());
      if (day != lastDay) {
        lastDay = day;
        out.add(Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(day, style: Theme.of(context).textTheme.bodySmall),
        ));
      }
      final nano = (tx['value_nano_erg'] as num?)?.toInt();
      final txId = tx['tx_id']?.toString() ?? '';
      final height = (tx['height'] as num?)?.toInt();
      out.add(_line(
        title: formatErg(nano),
        subtitle: shorten(txId, head: 10, tail: 8),
        trailing: formatHeight(height),
        onTap: () => _openTx(tx),
      ));
    }
    return out;
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
