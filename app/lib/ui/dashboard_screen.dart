import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/address_label_service.dart';
import '../services/deep_link_controller.dart';
import '../services/ergopay_service.dart';
import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/secure_storage.dart';
import '../services/session_lock.dart';
import '../services/watch_only_service.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import '../theme/argus_theme.dart';
import 'assets_screen.dart';
import 'create_wallet_screen.dart';
import 'ergopay_screen.dart';
import 'offline_banner.dart';
import 'pin_fields.dart';
import 'restore_wallet_screen.dart';
import 'scan_screen.dart';
import 'send_screen.dart';
import 'settings_screen.dart';
import 'swap_hub_screen.dart';
import 'transaction_detail_screen.dart';
import 'transactions_screen.dart';
import 'wallets_overview_screen.dart';
import 'widgets/activity_tile.dart';
import 'widgets/asset_tile.dart';
import 'widgets/soft_card.dart';
import 'widgets/token_detail_sheet.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  bool _loading = true;

  /// Gate-screen message (locked / no wallet / unlock errors). The synced
  /// ledger reads its state from [_sync] instead.
  String _status = 'Initializing...';
  final _sync = walletSyncController;
  bool _walletUnlocked = false;
  bool _hasSeed = false;
  bool _hasPin = false;
  bool _canBiometric = false;
  bool _unlockBusy = false;
  int _watchOnlyTotal = 0;
  bool _watchOnlyLoading = false;
  int _watchOnlyGeneration = 0;
  final _pinCtrl = TextEditingController();
  List<WalletInfo> _wallets = [];
  String? _walletId;

  /// Home tabs: 0 wallet, 1 activity, 2 swap, 3 settings. Tabs are built on
  /// first visit so unlocking doesn't fan out into every protocol screen's
  /// network calls at once.
  int _tab = 0;
  final Set<int> _visitedTabs = {0};
  SwapVenue _swapVenue = SwapVenue.dexy;
  static const _tabTitles = ['Argus', 'Activity', 'Swap', 'Settings'];

  /// Poll for mempool changes (pending activity, balance, spendable UTXOs)
  /// while the dashboard is open. A tick is a light refresh on the known
  /// addresses; discovery and node probing only run on unlock and pull to
  /// refresh, plus the slower probe timer. Paused while backgrounded; a
  /// tick is skipped if the previous refresh is still in flight.
  Timer? _pollTimer;
  Timer? _probeTimer;
  bool _pollBackgrounded = false;

  static const _pollInterval = Duration(seconds: 20);
  static const _probeInterval = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    walletService.unlocked.addListener(_syncLock);
    watchOnlyService.addListener(_onWatchOnlyChanged);
    _sync.addListener(_onSyncChanged);
    deepLinkController.addListener(_onDeepLink);
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollTick());
    _probeTimer = Timer.periodic(_probeInterval, (_) => _probeTick());
    _init();
  }

  void _onSyncChanged() {
    if (mounted) setState(() {});
    _openPendingDeepLink();
  }

  void _onDeepLink() {
    if (!_openPendingDeepLink() && mounted) {
      // Parked until the wallet unlocks; tell the user why nothing happened.
      if (!_walletUnlocked && deepLinkController.pending != null) {
        setState(() => _status = 'Unlock to continue with the ErgoPay request.');
      }
    }
  }

  bool _ergoPayOpen = false;

  /// Opens a parked ErgoPay link once the wallet is unlocked and has an
  /// address. Returns false when it had to stay parked.
  bool _openPendingDeepLink() {
    if (!mounted || _ergoPayOpen) return false;
    final link = deepLinkController.pending;
    if (link == null) return false;
    if (!_walletUnlocked || !walletService.isUnlocked || _sync.receiveAddress == null) {
      return false;
    }
    deepLinkController.take();
    if (!isErgoPayLink(link)) return true;
    _openErgoPay(link);
    return true;
  }

  Future<void> _openErgoPay(String link) async {
    _ergoPayOpen = true;
    try {
      final txId = await Navigator.push<String?>(
        context,
        fadeRoute(ErgoPayScreen(link: link), settings: RouteSettings(arguments: _args())),
      );
      if (txId != null && mounted) _sync.refresh(discover: false);
    } finally {
      _ergoPayOpen = false;
    }
  }

  /// Home scan: ErgoPay links open the signing flow; `ergo:` payment URIs
  /// open Send prefilled.
  Future<void> _scan() async {
    if (!_guardUnlocked()) return;
    final raw = await Navigator.push<String>(context, fadeRoute(const ScanScreen()));
    if (!mounted || raw == null) return;
    if (isErgoPayLink(raw)) {
      _openErgoPay(raw);
      return;
    }
    final pay = parseErgoUri(raw);
    if (pay == null) {
      _snack('Not an Ergo address or ErgoPay link');
      return;
    }
    Navigator.push(
      context,
      fadeRoute(
        SendScreen(initialRecipient: pay.address, initialAmountErg: pay.amountErg),
        settings: RouteSettings(arguments: _args()),
      ),
    );
  }

  void _pollTick() {
    if (!mounted || _pollBackgrounded || !_walletUnlocked || _sync.busy) {
      return;
    }
    _sync.refresh(discover: false);
  }

  void _probeTick() {
    if (!mounted || _pollBackgrounded) return;
    networkController.probe();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _probeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    walletService.unlocked.removeListener(_syncLock);
    watchOnlyService.removeListener(_onWatchOnlyChanged);
    _sync.removeListener(_onSyncChanged);
    deepLinkController.removeListener(_onDeepLink);
    _pinCtrl.dispose();
    super.dispose();
  }

  void _onWatchOnlyChanged() {
    _refreshWatchOnly();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause mempool polling while backgrounded; resume on return.
    _pollBackgrounded =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (state != AppLifecycleState.resumed) return;
    // Re-prompt biometrics when the session lock fired while backgrounded.
    // If the user returned within the grace window the wallet is still
    // unlocked and this is a no-op.
    if (!_unlockBusy &&
        !walletService.isUnlocked &&
        _canBiometric &&
        _walletId != null) {
      _unlockBiometric();
    }
  }

  void _syncLock() {
    if (!walletService.unlocked.value && _walletUnlocked && mounted) {
      setState(_resetLocked);
    }
  }

  void _resetLocked() {
    _walletUnlocked = false;
    _tab = 0;
    _visitedTabs
      ..clear()
      ..add(0);
    _sync.reset();
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
      // Clear stale flags so a no-wallet gate rendered right after this
      // doesn't still offer unlock options for a deleted wallet.
      await _refreshUnlockMethods();
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
    // 1. Derive the main address locally and paint from the cache (instant).
    final ok = await _sync.hydrateAfterUnlock();
    if (!mounted) return;
    if (!walletService.isUnlocked) {
      setState(_resetLocked);
      return;
    }
    if (!ok) {
      debugPrint('argus: address derivation failed after unlock');
      setState(() {
        _walletUnlocked = true;
        _status = 'Unlocked, but no address could be derived';
      });
      return;
    }
    setState(() {
      _walletUnlocked = true;
      _status = 'Unlocked';
    });
    // 2. Full sync (discovery + balances + activity) in the background.
    await _sync.refresh(discover: true);
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
        // Loading another wallet's wrap key must be user-authenticated. On
        // Android the stored key has no biometric ACL of its own, so a silent
        // load here would let anyone holding the device bypass the lock
        // screen; iOS enforces this inside the Keychain read itself.
        final wrapKey = await sessionLock.run(
          () => SecureStorageService.authenticateBiometric(walletId: walletId),
        );
        if (!mounted) return;
        if (wrapKey == null) {
          setState(() {
            _resetLocked();
            _status = 'Authentication cancelled. Unlock with PIN.';
          });
          return;
        }
        final json = await SecureStorageService.loadEncryptedSeed(
          walletId: walletId,
        );
        if (!mounted) return;
        if (json == null) {
          setState(_resetLocked);
          _snack('Wallet data not found');
          return;
        }
        await walletService.restoreWallet(json, wrapKey: wrapKey, walletId: walletId);
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
          activeBalanceNano: _walletUnlocked ? _sync.balanceNano : null,
        ),
      ),
    );
    if (!mounted) return;
    // A wallet may have been removed inside the overview — capture the
    // pre-reload selection so removal (and its replacement) is detectable
    // after the list reload reassigns _walletId.
    final previousId = _walletId;
    await _loadWallets();
    if (previousId != null &&
        !_wallets.any((w) => w.walletId == previousId)) {
      // The wallet this screen was showing was removed.
      if (_wallets.isEmpty) {
        if (walletService.isUnlocked) await walletService.lock();
        setState(_resetLocked);
        return;
      }
      // Land on the replacement the reload selected, regardless of what the
      // overview popped with.
      if (_walletId != null) {
        await _switchWallet(_walletId!);
        return;
      }
    }
    if (picked != null && picked.isNotEmpty && picked != previousId) {
      await _switchWallet(picked);
      return;
    }
    if (mounted) setState(() {});
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
    final receive = _sync.receiveAddress ?? '';
    return WalletRouteArgs(
      senderAddress: _sync.senderAddress ?? receive,
      receiveAddress: receive,
      changeAddress: _sync.changeAddress ?? receive,
      historyAddresses: _sync.historyAddresses,
      tokens: _sync.tokens,
      spendableNano: _sync.balanceNano,
      transaction: transaction,
    );
  }

  bool _guardUnlocked() {
    if (!walletService.isUnlocked || !_walletUnlocked) {
      _snack('Unlock the wallet first');
      return false;
    }
    if (_sync.receiveAddress == null) {
      _snack('Address is still loading');
      return false;
    }
    return true;
  }

  void _go(String route) {
    if (!_guardUnlocked()) return;
    Navigator.pushNamed(context, route, arguments: _args());
  }

  void _selectTab(int index) {
    if (index == _tab) return;
    if (index != 0 && !_guardUnlocked()) return;
    final leavingSettings = _tab == 3;
    setState(() {
      _tab = index;
      _visitedTabs.add(index);
    });
    if (leavingSettings) {
      // PIN / biometric setup may have changed on the settings tab.
      _refreshUnlockMethods().then((_) {
        if (mounted) setState(() {});
      }).catchError((_) {});
    }
  }

  /// Switches to the swap tab on [venue]; embedded screens read balances
  /// from the enclosing [WalletArgsScope].
  void _goHub(SwapVenue venue) {
    if (_swapVenue != venue) setState(() => _swapVenue = venue);
    _selectTab(2);
  }

  void _openTx(Map<String, dynamic> tx) {
    Navigator.push(
      context,
      fadeRoute(const TransactionDetailScreen(), settings: RouteSettings(arguments: _args(transaction: tx))),
    );
  }

  void _openToken(TokenBalance t) {
    showTokenDetailSheet(
      context,
      token: t,
      explorerUrl: networkController.explorerToken(t.id),
      onSend: (token) {
        if (!_guardUnlocked()) return;
        Navigator.push(
          context,
          fadeRoute(
            SendScreen(initialAssetId: token.id),
            settings: RouteSettings(arguments: _args()),
          ),
        );
      },
    );
  }

  void _openSettings() => _selectTab(3);

  /// The settings tab renamed, deleted or picked another wallet. An empty id
  /// means the wallet this screen pointed at is gone.
  Future<void> _onSettingsWalletChanged(String switchedTo) async {
    if (!mounted) return;
    await _loadWallets();
    if (!mounted) return;
    if (switchedTo.isEmpty) {
      setState(_resetLocked);
      return;
    }
    if (switchedTo != _walletId) {
      _selectTab(0);
      await _switchWallet(switchedTo);
      return;
    }
    if (mounted) setState(() {});
  }

  String get _activeWalletName {
    for (final w in _wallets) {
      if (w.walletId == _walletId) return w.name;
    }
    return 'Wallet';
  }

  bool get _balanceHidden => privacyService.hideBalances;

  @override
  Widget build(BuildContext context) {
    if (_loading) return _splash();

    final showTabs = _walletUnlocked;
    return PopScope(
      canPop: !showTabs || _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _selectTab(0);
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(
          showTabs ? _tabTitles[_tab] : 'Argus',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        actions: [
          if (_walletUnlocked)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan',
              onPressed: _scan,
            ),
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
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([addressLabelService, privacyService]),
        builder: (context, _) => Column(
          children: [
            const WarningStrip(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: showTabs ? _tabs() : _gate(),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: showTabs
          ? NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _selectTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.account_balance_wallet_outlined),
                  selectedIcon: Icon(Icons.account_balance_wallet),
                  label: 'Wallet',
                ),
                NavigationDestination(
                  icon: Icon(Icons.schedule_outlined),
                  selectedIcon: Icon(Icons.schedule),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.swap_horiz_outlined),
                  selectedIcon: Icon(Icons.swap_horiz),
                  label: 'Swap',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            )
          : null,
      ),
    );
  }

  /// Cold-start splash while the wallet core initialises: same branding as
  /// the gate so the app doesn't open on a bare spinner.
  Widget _splash() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IrisMark(size: 72),
            const SizedBox(height: 20),
            Text('Argus', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const SizedBox(width: 48, child: Hairline(gold: true)),
            const SizedBox(height: 28),
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }

  /// The unlocked home: tabs share one [WalletArgsScope] so embedded screens
  /// see the same live balances a pushed route would get as arguments.
  Widget _tabs() {
    final args = _args();
    Widget lazy(int i, Widget Function() build) =>
        _visitedTabs.contains(i) ? build() : const SizedBox.shrink();
    return WalletArgsScope(
      key: const ValueKey('tabs'),
      args: args,
      child: IndexedStack(
        index: _tab,
        children: [
          _ledger(),
          lazy(
            1,
            () => TransactionsScreen(
              key: ValueKey('activity-${_sync.receiveAddress}'),
              embedded: true,
              args: args,
            ),
          ),
          lazy(
            2,
            () => SwapHubScreen(
              embedded: true,
              venue: _swapVenue,
              onVenueChanged: (v) => _swapVenue = v,
            ),
          ),
          lazy(
            3,
            () => SettingsScreen(
              key: ValueKey('settings-$_walletId'),
              embedded: true,
              walletId: _walletId,
              onWalletSwitched: _onSettingsWalletChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gate() {
    return ListView(
      key: const ValueKey('gate'),
      padding: EdgeInsets.fromLTRB(
          28, 36, 28, 40 + MediaQuery.paddingOf(context).bottom),
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
          Text(_status,
              textAlign: TextAlign.center,
              style: TextStyle(color: rustFor(context))),
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

  // ── Ledger (unlocked home) ─────────────────────────────────────────────

  static const _assetCap = 4;

  Widget _ledger() {
    return ListenableBuilder(
      listenable: networkController,
      builder: (context, _) {
        final fungible = _sync.tokens.where((t) => !t.isNft).toList();
        final nfts = _sync.tokens.where((t) => t.isNft).toList();
        final fragmented = _sync.utxoCount > utxoFragmentationThreshold;
        Widget tokenTile(TokenBalance t) => AssetTile.token(
              t,
              hidden: _balanceHidden,
              onTap: () => _openToken(t),
            );
        final assets = <Widget>[
          AssetTile.erg(
            balanceNano: _sync.balanceNano,
            fiatText: networkController.fiatText(_sync.balanceNano),
            hidden: _balanceHidden,
            onTap: () => Navigator.push(
                context, fadeRoute(AssetsScreen(args: _args()))),
          ),
          ...fungible.map(tokenTile),
          ...nfts.map(tokenTile),
        ];
        final visibleAssets = assets.take(_assetCap).toList();
        final hiddenAssets = assets.length - visibleAssets.length;

        return RefreshIndicator(
          onRefresh: () => _sync.refresh(discover: true),
          child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            const OfflineBanner(),
            _walletCard(fragmented),
            const SizedBox(height: 28),
            _sectionHeader('Assets',
                action: hiddenAssets > 0
                    ? 'View all (${assets.length})'
                    : 'View all',
                onTap: () => Navigator.push(context,
                    fadeRoute(AssetsScreen(args: _args())))),
            const SizedBox(height: 10),
            SoftCard(
              padding: EdgeInsets.zero,
              child: DividedColumn(children: visibleAssets),
            ),
            const SizedBox(height: 28),
            _sectionHeader('Recent activity',
                action: _sync.recentTxs.isNotEmpty ? 'View all' : null,
                onTap: () => _selectTab(1)),
            const SizedBox(height: 10),
            _sync.recentTxs.isEmpty
                ? SoftCard(
                    child: Text(
                      'No activity yet. Receive to your address to get started.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : SoftCard(
                    padding: EdgeInsets.zero,
                    child: DividedColumn(
                      children: [
                        for (final tx in _sync.recentTxs)
                          ActivityTile(
                            tx: tx,
                            hidden: _balanceHidden,
                            onTap: () => _openTx(tx),
                          ),
                      ],
                    ),
                  ),
            const SizedBox(height: 28),
            _sectionHeader('Discover',
                action: 'Explore all', onTap: () => _goHub(SwapVenue.dexy)),
            const SizedBox(height: 10),
            SizedBox(
              height: 168,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _discoverCard(
                    title: 'Dexy',
                    subtitle: 'Trade, provide liquidity, and mint on Ergo.',
                    icon: Icons.all_inclusive,
                    onTap: () => _goHub(SwapVenue.dexy),
                  ),
                  _discoverCard(
                    title: 'AgeUSD',
                    subtitle: 'The decentralized stablecoin on Ergo.',
                    icon: Icons.attach_money,
                    onTap: () => _goHub(SwapVenue.ageusd),
                  ),
                  _discoverCard(
                    title: 'DEX',
                    subtitle: 'Permissionless token swaps on Ergo.',
                    icon: Icons.swap_horiz,
                    onTap: () => _goHub(SwapVenue.spectrum),
                  ),
                ],
              ),
            ),
            if (_sync.usedAddresses.isNotEmpty) ...[
              const SizedBox(height: 28),
              _sectionHeader('Addresses'),
              const SizedBox(height: 10),
              SoftCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < _sync.usedAddresses.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: 16),
                      _addressTile(_sync.usedAddresses[i]),
                    ],
                  ],
                ),
              ),
            ],
          ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(String title, {String? action, VoidCallback? onTap}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Newsreader',
              fontWeight: FontWeight.w600,
              fontSize: 20,
            ),
          ),
        ),
        if (action != null)
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(action,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: iris)),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right, size: 18, color: iris),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _walletCard(bool fragmented) {
    final muted = ArgusColors.of(context).muted;
    final online = networkController.activeUrl != null;
    final stale = _sync.isStale;
    final syncing = _sync.isSyncing;
    final synced = !stale && !syncing && online;
    final syncAge = formatSyncAge(_sync.lastSyncedAt);

    return SoftCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: _openWalletOverview,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _activeWalletName,
                        style: const TextStyle(
                          fontFamily: 'Newsreader',
                          fontWeight: FontWeight.w600,
                          fontSize: 17,
                        ),
                      ),
                      Icon(Icons.keyboard_arrow_down, size: 20, color: muted),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              _iconCircle(
                _balanceHidden
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                onTap: () =>
                    privacyService.setHideBalances(!_balanceHidden),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: _sync.balanceNano == null && _sync.isSyncing
                    ? Container(
                        width: 150,
                        height: 34,
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: muted.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      )
                    : Text(
                        _balanceHidden
                            ? '••••••'
                            : formatErg(_sync.balanceNano, unit: false, maxFrac: 4),
                        style: Theme.of(context)
                            .textTheme
                            .displayLarge
                            ?.copyWith(fontSize: 44),
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'ERG',
                  style: TextStyle(
                    fontFamily: 'Newsreader',
                    fontSize: 18,
                    color: muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ListenableBuilder(
            listenable: networkController,
            builder: (context, _) {
              if (_balanceHidden) {
                return Text(
                    '≈ ${networkController.fiatSymbol}•••• ${networkController.fiatCode.toUpperCase()}',
                    style: TextStyle(fontSize: 14, color: muted));
              }
              return Text(
                networkController.fiatText(_sync.balanceNano) ?? '',
                style: TextStyle(fontSize: 14, color: muted),
              );
            },
          ),
          const SizedBox(height: 14),
          if (_sync.pinIssue != null) ...[
            InkWell(
              onTap: _openSettings,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.push_pin_outlined, size: 14, color: rust),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _sync.pinIssue!,
                        style: TextStyle(fontSize: 12.5, color: rust),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: ArgusColors.of(context).inset,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 0,
              runSpacing: 4,
              children: [
                InkWell(
                  onTap: () => _go('/utxos'),
                  borderRadius: BorderRadius.circular(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle,
                          size: 8,
                          color: synced ? moss : (stale ? rust : iris)),
                      const SizedBox(width: 6),
                      Text(
                        synced
                            ? 'Synced'
                            : (stale
                                ? 'Out of sync'
                                : (syncing ? 'Syncing…' : 'Offline')),
                        style: TextStyle(
                            fontSize: 12.5,
                            color: muted,
                            fontWeight: FontWeight.w500),
                      ),
                      _dotSep(muted),
                      Icon(Icons.inventory_2_outlined,
                          size: 13, color: muted),
                      const SizedBox(width: 4),
                      Text(
                        networkController.height == null
                            ? 'Block —'
                            : 'Block ${formatWithCommas(networkController.height!)}',
                        style: TextStyle(fontSize: 12.5, color: muted),
                      ),
                      _dotSep(muted),
                      Text(
                        '${_sync.utxoCount} UTXOs${fragmented ? ' · Fragmented' : ''}',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: fragmented ? rust : muted,
                          fontWeight:
                              fragmented ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (!syncing && syncAge.isNotEmpty) ...[
                        _dotSep(muted),
                        Text(
                          syncAge,
                          style: TextStyle(fontSize: 12.5, color: muted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _openSettings,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Network',
                            style:
                                TextStyle(fontSize: 12.5, color: muted)),
                        Icon(Icons.chevron_right, size: 16, color: muted),
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
                child: _actionButton(
                    icon: Icons.north_east, label: 'Send', onTap: () => _go('/send')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _actionButton(
                    icon: Icons.south_west,
                    label: 'Receive',
                    onTap: () => _go('/receive')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _actionButton(
                    icon: Icons.swap_horiz,
                    label: 'Swap',
                    onTap: () => _goHub(SwapVenue.spectrum)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dotSep(Color muted) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Text('·',
            style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
      );

  Widget _iconCircle(IconData icon, {VoidCallback? onTap}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: dark ? watchfulSurface : bannerTint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon,
            size: 19,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
      ),
    );
  }

  Widget _actionButton(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(
          fontFamily: 'Karla',
          fontWeight: FontWeight.w500,
          fontSize: 14.5,
        ),
      ),
    );
  }

  Widget _discoverCard({
    required String title,
    required String subtitle,
    required IconData icon,
    VoidCallback? onTap,
    bool comingSoon = false,
  }) {
    final muted = ArgusColors.of(context).muted;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 168,
      margin: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: comingSoon ? null : onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: ArgusColors.of(context).cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: dark ? watchfulSurface : bannerTint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 19, color: iris),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'Newsreader',
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 3),
              Expanded(
                child: Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, height: 1.3, color: muted),
                ),
              ),
              if (comingSoon)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: dark ? watchfulSurface : bannerTint,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Coming soon',
                    style: TextStyle(fontSize: 10.5, color: muted),
                  ),
                )
              else
                const Icon(Icons.arrow_forward, size: 16, color: iris),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addressTile(Map<String, dynamic> a) {
    final muted = ArgusColors.of(context).muted;
    final addr = a['address']?.toString() ?? '';
    final nano = (a['balance_nano_erg'] as num?)?.toInt();
    final label = addressLabelService.labelFor(addr);
    return InkWell(
      onTap: () => _labelAddress(addr),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shorten(addr, head: 10, tail: 8),
                    style: monoStyle(context, size: 12.5),
                  ),
                  if (label != null && label.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(label,
                        style: TextStyle(fontSize: 12, color: muted)),
                  ],
                ],
              ),
            ),
            Text(
              _balanceHidden ? '••••' : formatErg(nano, maxFrac: 4),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
