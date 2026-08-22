import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/address_label_service.dart';
import '../services/network_controller.dart';
import '../services/secure_storage.dart';
import '../services/session_lock.dart';
import '../services/watch_only_service.dart';
import '../services/wallet_database_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'create_wallet_screen.dart';
import 'pin_fields.dart';
import 'restore_wallet_screen.dart';
import 'settings_screen.dart';
import 'transaction_detail_screen.dart';
import 'wallets_overview_screen.dart';

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
  DateTime? _lastSynced;
  int _watchOnlyTotal = 0;
  bool _watchOnlyLoading = false;
  int _watchOnlyGeneration = 0;
  final _pinCtrl = TextEditingController();
  List<WalletInfo> _wallets = [];
  String? _walletId;

  @override
  void initState() {
    super.initState();
    walletService.unlocked.addListener(_syncLock);
    watchOnlyService.addListener(_onWatchOnlyChanged);
    _init();
  }

  @override
  void dispose() {
    walletService.unlocked.removeListener(_syncLock);
    watchOnlyService.removeListener(_onWatchOnlyChanged);
    _pinCtrl.dispose();
    super.dispose();
  }

  void _onWatchOnlyChanged() {
    _refreshWatchOnly();
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
    _utxoCount = 0;
    _status = _hasSeed ? 'Locked' : (_wallets.isNotEmpty ? 'Wallet found. Unlock to continue.' : 'No wallet. Create or restore one.');
  }

  Future<void> _refreshWatchOnly() async {
    final generation = ++_watchOnlyGeneration;
    final addrs = watchOnlyService.addresses;
    if (addrs.isEmpty) {
      if (mounted) setState(() {
        _watchOnlyTotal = 0;
        _watchOnlyLoading = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _watchOnlyLoading = true);
    final futures = addrs.map((addr) async {
      try {
        final bal = await walletService.getBalance(addr, nodeUrl: networkController.activeUrl);
        return (bal['balance_nano_erg'] as num?)?.toInt() ?? 0;
      } catch (_) {
        return 0;
      }
    }).toList();
    final results = await Future.wait(futures);
    if (generation != _watchOnlyGeneration) return;
    final total = results.fold<int>(0, (sum, bal) => sum + bal);
    if (mounted) setState(() {
      _watchOnlyTotal = total;
      _watchOnlyLoading = false;
    });
  }

  Future<void> _init() async {
    try {
      await walletService.init();
      await networkController.load();
      networkController.probe();
       await _loadWallets();
      await _refreshUnlockMethods();
      _status = _wallets.isEmpty
          ? 'No wallet. Create or restore one.'
          : 'Wallet found. Unlock to continue.';
      // Auto-trigger biometric unlock when available so the user isn't
      // forced to press a button just to open the wallet on launch.
      if (_canBiometric && _walletId != null) {
        _unlockBiometric();
      }
    } on ArgusException catch (e) {
      _status = '${e.code}: ${e.message}';
    } catch (e) {
      _status = 'Error: $e';
    }
    _refreshWatchOnly();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadWallets() async {
    _wallets = await walletService.listWallets();
    if (_wallets.isNotEmpty) {
      if (_walletId == null || !_wallets.any((w) => w.walletId == _walletId)) {
        _walletId = _wallets.first.walletId;
      }
    } else {
      _walletId = null;
    }
  }

  Future<void> _refreshUnlockMethods() async {
    if (_walletId == null) {
      _hasSeed = false;
      _hasPin = false;
      _canBiometric = false;
      return;
    }
    _hasSeed = await SecureStorageService.hasEncryptedSeed(walletId: _walletId);
    _hasPin = await SecureStorageService.hasPinWrap(walletId: _walletId);
    _canBiometric = await SecureStorageService.hasBiometric() &&
        await SecureStorageService.hasWrapKey(walletId: _walletId);
  }

  Future<void> _afterUnlock() async {
    if (!mounted) return;
    if (!walletService.isUnlocked) {
      setState(_resetLocked);
      return;
    }

    // 1. Derive address (pinned index or 0) locally (instant, deterministic)
    final int addressIndex = await walletService.getPinnedAddressIndex();
    final String receive;
    try {
      receive = await walletService.deriveAddress(addressIndex);
      if (!mounted) return;
      if (!walletService.isUnlocked) {
        setState(_resetLocked);
        return;
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('argus: address derivation failed after unlock: $e');
      setState(() {
        _walletUnlocked = walletService.isUnlocked;
        _status = walletService.isUnlocked
            ? 'Unlocked, but no address could be derived'
            : 'Locked';
      });
      return;
    }

    // 2. Instant 0ms hydration from local mini-db cache validated by wallet identifier
    final cached = await WalletDatabaseService.loadCachedState(expectedWalletId: receive);
    if (cached != null && mounted) {
      final used = (cached['used_addresses'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final balance = cached['balance_nano_erg'] as int?;
      final txs = (cached['transactions'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final rawTokens = (cached['tokens'] as List? ?? []);
      final tokenList = <TokenBalance>[];
      for (final t in rawTokens) {
        if (t is Map) {
          tokenList.add(TokenBalance(
            id: t['id']?.toString() ?? '',
            amount: (t['amount'] as num?)?.toInt() ?? 0,
            name: t['name']?.toString(),
            decimals: (t['decimals'] as num?)?.toInt() ?? 0,
          ));
        }
      }

      setState(() {
        _walletUnlocked = true;
        _receiveAddress ??= receive;
        _changeAddress ??= receive;
        _senderAddress ??= _bestSender(receive);
        _usedAddresses = used;
        _balanceNano = balance;
        _tokens = tokenList;
        _recentTxs = txs;
        _utxoCount = (cached['utxo_count'] as num?)?.toInt() ?? 0;
        _status = 'Unlocked';
      });
    } else {
      setState(() {
        _walletUnlocked = true;
        _receiveAddress ??= receive;
        _changeAddress ??= receive;
        _senderAddress ??= receive;
        _status = 'Unlocked';
      });
    }

    // 3. Fast sync in background
    await _refresh();
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
      // Keep the auto-lock from destroying the handle mid-unlock (the
      // biometric sheet, or any backgrounding, otherwise re-arms the
      // grace timer while restore/derive is still in flight).
      await sessionLock.run(work);
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
        final json = await SecureStorageService.loadEncryptedSeed(walletId: _walletId);
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: _walletId);
        if (json == null || pinWrap == null) {
          if (mounted) setState(() => _status = 'No PIN-protected wallet found.');
          return;
        }
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, _pinCtrl.text);
        await walletService.restoreWallet(json, wrapKey: wrapKey, walletId: _walletId);
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
        final wrapKey = await sessionLock.run(() => SecureStorageService.authenticateBiometric(walletId: _walletId));
        if (wrapKey == null) {
          if (!await SecureStorageService.hasWrapKey(walletId: _walletId)) {
            _snack('Biometric unlock is not set up. Enable it in Settings after unlocking with PIN.');
          } else if (mounted && !_walletUnlocked) {
            setState(() => _status = 'Biometric cancelled. Enter PIN or tap below.');
          }
          return;
        }
        final json = await SecureStorageService.loadEncryptedSeed(walletId: _walletId);
        if (json == null) {
          _snack('Biometric unlock is not set up');
          return;
        }
        await walletService.restoreWallet(json, wrapKey: wrapKey, walletId: _walletId);
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
        final json = await SecureStorageService.loadEncryptedSeed(walletId: _walletId);
        final wrapKey = await SecureStorageService.loadWrapKey(walletId: _walletId);
        if (json == null || wrapKey == null) {
          if (mounted) setState(() => _status = 'No wallet found. Create or restore.');
          return;
        }
        await walletService.restoreWallet(json, wrapKey: wrapKey, walletId: _walletId);
        if (!mounted) return;
        final pin = await _askNewPin();
        if (pin != null) {
          final pinWrap = await walletService.wrapKeyWithPin(wrapKey, pin);
          await SecureStorageService.savePinWrap(pinWrap, walletId: _walletId);
          await SecureStorageService.deleteWrapKey(walletId: _walletId);
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
    final walletId = await Navigator.push<String?>(
      context,
      fadeRoute(const CreateWalletScreen()),
    );
    if (walletId != null) {
      _walletId = walletId;
      await sessionLock.run(() async {
        await _loadWallets();
        await _refreshUnlockMethods();
        await _afterUnlock();
      });
    }
  }

  Future<void> _openRestore() async {
    final walletId = await Navigator.push<String?>(
      context,
      fadeRoute(const RestoreWalletScreen()),
    );
    if (walletId != null) {
      _walletId = walletId;
      await sessionLock.run(() async {
        await _loadWallets();
        await _refreshUnlockMethods();
        await _afterUnlock();
      });
    }
  }

  Future<void> _switchWallet(String walletId) async {
    if (!mounted) return;
    if (walletId == _walletId && walletService.isUnlocked) return;
    setState(() => _status = 'Switching wallet…');
    try {
      if (walletService.isUnlocked && walletService.activeWalletId != walletId) {
        await walletService.lock();
      }
      _walletId = walletId;
      await _refreshUnlockMethods();
      if (!mounted) return;

      // A wallet that still has a stored wrap key (biometric mode) can be
      // switched into directly. A PIN-only wallet has no raw wrap key, so the
      // best UX is to land on its unlock gate and let the user unlock as usual.
      final wrapKeyAvailable = await SecureStorageService.hasWrapKey(
        walletId: walletId,
      );
      setState(() {
        _resetLocked();
        _status = _hasSeed
            ? '$_activeWalletName locked. Enter its PIN below.'
            : 'Wallet found. Unlock to continue.';
      });
      if (wrapKeyAvailable) {
        await walletService.switchWallet(walletId);
        if (!mounted) return;
        setState(_resetLocked);
        if (walletService.isUnlocked) {
          await _afterUnlock();
        }
      }
    } on ArgusException catch (e) {
      if (!mounted) return;
      setState(_resetLocked);
      _snack('${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(_resetLocked);
      _snack('Could not switch wallet: $e');
    }
  }

  Future<void> _openWalletOverview() async {
    final picked = await Navigator.push<String>(
      context,
      fadeRoute(
        WalletOverviewScreen(
          selectedWalletId: _walletId,
          activeBalanceNano: _walletUnlocked ? _balanceNano : null,
        ),
      ),
    );
    if (!mounted || picked == null) return;
    if (picked == _walletId) return;
    await _switchWallet(picked);
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
      final pinnedIndex = await walletService.getPinnedAddressIndex();
      final receive = next == 0
          ? (_receiveAddress ?? await walletService.deriveAddress(pinnedIndex))
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
      final balanceSucceeded = failed < addresses.length && addresses.isNotEmpty;
      setState(() {
        if (balanceSucceeded) {
          _balanceNano = erg;
          _tokens = tokens.values.toList();
        }
        if (txs.isNotEmpty) {
          _recentTxs = txs.take(5).toList();
        }
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
    await _refreshUtxos();
    _lastSynced = DateTime.now();

    // Persist latest state to local mini-db cache for instant load next time
    if (_receiveAddress != null) {
      await WalletDatabaseService.saveCachedState(
        walletId: _receiveAddress!,
        primaryAddress: _receiveAddress,
        usedAddresses: _usedAddresses,
        balanceNano: _balanceNano ?? 0,
        tokens: _tokens
            .map((t) => {
                  'id': t.id,
                  'amount': t.amount,
                  'name': t.name,
                  'decimals': t.decimals,
                })
            .toList(),
        transactions: _recentTxs,
        utxoCount: _utxoCount,
      );
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

  Future<void> _refreshUtxos() async {
    final addr = _historyAddresses();
    if (addr.isEmpty) return;
    try {
      final boxes = await walletService.listUnspentBoxes(addr,
          nodeUrl: networkController.activeUrl);
      if (!mounted) return;
      setState(() => _utxoCount = boxes.length);
    } catch (_) {
      // UTXO count is best-effort; don't disrupt the dashboard
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

  Future<void> _labelAddress(String address) async {
    final existing = addressLabelService.labelFor(address) ?? '';
    final ctrl = TextEditingController(text: existing);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Address label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              shorten(address, head: 10, tail: 8),
              style: monoStyle(ctx, size: 11),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'Label (optional)'),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final label = ctrl.text;
    ctrl.dispose();
    if (ok != true) return;
    await addressLabelService.setLabel(address, label);
    if (mounted) setState(() {});
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
    final switchedTo = await Navigator.push<String?>(
      context,
      fadeRoute(SettingsScreen(walletId: _walletId)),
    );
    if (!mounted) return;
    if (switchedTo != null && switchedTo != _walletId) {
      await _switchWallet(switchedTo);
    }
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

  String get _activeWalletName {
    for (final w in _wallets) {
      if (w.walletId == _walletId) return w.name;
    }
    return 'Wallet';
  }

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
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: 'Wallets',
            onPressed: _openWalletOverview,
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: addressLabelService,
        builder: (context, _) => Column(
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
        if (_wallets.isNotEmpty) ...[
          const SizedBox(height: 16),
          Center(
            child: InkWell(
              onTap: _openWalletOverview,
              borderRadius: BorderRadius.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.account_balance_wallet_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _activeWalletName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (_status.startsWith('Error') || _status.contains(':')) ...[
          const SizedBox(height: 12),
          Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: rust)),
        ],
        if (watchOnlyService.addresses.isNotEmpty) ...[
          const SizedBox(height: 24),
          ListenableBuilder(
            listenable: watchOnlyService,
            builder: (context, _) => _watchOnlyLoading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : Column(
                    children: [
                      Text(
                        'Watch-only balance',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        formatErg(_watchOnlyTotal),
                        style: const TextStyle(
                          fontFamily: 'Newsreader',
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${watchOnlyService.addresses.length} addresses',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
          ),
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
    final fragmented = _utxoCount > utxoFragmentationThreshold;

    return RefreshIndicator(
      key: const ValueKey('ledger'),
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
           const SizedBox(height: 28),
           Material(
             color: Colors.transparent,
             child: InkWell(
               onTap: _openWalletOverview,
               child: Padding(
                 padding: const EdgeInsets.only(bottom: 12),
                 child: Row(
                   children: [
                     Icon(
                       Icons.account_balance_wallet_outlined,
                       size: 18,
                       color: Theme.of(context).colorScheme.primary,
                     ),
                     const SizedBox(width: 8),
                     Flexible(
                       child: Text(
                         _activeWalletName,
                         maxLines: 1,
                         overflow: TextOverflow.ellipsis,
                         style: Theme.of(context).textTheme.titleMedium,
                       ),
                     ),
                     const SizedBox(width: 2),
                     Icon(
                       Icons.chevron_right,
                       size: 18,
                       color: Theme.of(context).colorScheme.primary,
                     ),
                   ],
                 ),
               ),
             ),
           ),
           if (networkController.activeUrl == null && !networkController.probing)
             Padding(
               padding: const EdgeInsets.only(bottom: 12),
               child: Material(
                 color: rust.withValues(alpha: 0.12),
                 borderRadius: BorderRadius.circular(8),
                 child: Padding(
                   padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                   child: Row(
                     children: [
                       const Icon(Icons.wifi_off_outlined, color: rust, size: 16),
                       const SizedBox(width: 8),
                       const Expanded(
                         child: Text(
                           'No reachable nodes. Tap Retry to check.',
                           style: TextStyle(color: rust, fontSize: 12),
                         ),
                       ),
                       TextButton(
                         onPressed: networkController.probing ? null : networkController.probe,
                         child: const Text('Retry'),
                       ),
                     ],
                   ),
                 ),
               ),
             ),
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
          if (!_stale && !_status.contains('Syncing') && _lastSynced != null && (networkController.activeUrl != null)) ...[
            const SizedBox(height: 10),
            Text(
              'Synced ${formatRelativeTime(_lastSynced!)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          ],
          const SizedBox(height: 10),
          InkWell(
            onTap: () => _go('/utxos'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.layers_outlined,
                    size: 14,
                    color: fragmented
                        ? rust
                        : Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$_utxoCount UTXOs${fragmented ? ' (Fragmented)' : ''}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: fragmented ? rust : null,
                          fontWeight: fragmented
                              ? FontWeight.w600
                              : null,
                        ),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fragmented ? 'Organize' : 'Manage',
                        style: TextStyle(
                          fontSize: 12,
                          color: fragmented
                              ? rust
                              : Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right,
                        size: 14,
                        color: fragmented
                            ? rust
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
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
          const SizedBox(height: 28),
          const SectionLabel('Protocols'),
          const SizedBox(height: 8),
          _protocolTile(
            context,
            title: 'Dexy',
            subtitle: 'Oracle-pegged assets · mint, swap, liquidity',
            icon: Icons.all_inclusive,
            onTap: () => _go('/dexy'),
          ),
          _protocolTile(
            context,
            title: 'AgeUSD',
            subtitle: 'Coming soon',
            icon: Icons.paid_outlined,
            enabled: false,
          ),
          _protocolTile(
            context,
            title: 'DEX',
            subtitle: 'Coming soon',
            icon: Icons.sync_alt,
            enabled: false,
          ),
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
              final label = addressLabelService.labelFor(addr);
              return _line(
                title: shorten(addr, head: 10, tail: 8),
                subtitle: label,
                trailing: formatErg(nano),
                monoTitle: true,
                onTap: () => _labelAddress(addr),
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

  Widget _protocolTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    VoidCallback? onTap,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: enabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Icon(
              enabled ? Icons.chevron_right : Icons.lock_clock_outlined,
              size: 18,
              color: enabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
