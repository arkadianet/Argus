import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/address_label_service.dart';
import '../services/deep_link_controller.dart';
import '../services/duckpools_service.dart';
import '../services/ergopay_service.dart';
import '../services/incoming_payment_watcher.dart';
import '../services/mix_service.dart';
import '../services/network_controller.dart';
import '../services/notification_service.dart';
import '../services/privacy_service.dart';
import '../services/public_wallet_sync.dart';
import '../services/secure_storage.dart';
import '../services/session_lock.dart';
import '../services/sigmafi_service.dart';
import '../services/stealth_service.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import '../services/watch_account_service.dart';
import '../services/watch_only_service.dart';
import '../theme/argus_theme.dart';
import 'assets_screen.dart';
import 'create_wallet_screen.dart';
import 'ergopay_screen.dart';
import 'home/erg_price_feed.dart';
import 'home/home_data.dart' show isPendingTx;
import 'home/home_models.dart';
import 'home/overview_model.dart';
import 'home/unlock_gate.dart';
import 'home/wallet_ledger.dart';
import 'home/wallet_nav_bar.dart';
import 'home/wallet_page.dart';
import 'home/watched_wallet.dart';
import 'pin_fields.dart';
import 'restore_wallet_screen.dart';
import 'scan_screen.dart';
import 'send_screen.dart';
import 'settings/network_settings_page.dart';
import 'settings_screen.dart';
import 'swap_hub_screen.dart';
import 'transaction_detail_screen.dart';
import 'transactions_screen.dart';
import 'wallets_overview_screen.dart';
import 'widgets/discover_sheet.dart';
import 'widgets/entry_dialogs.dart';
import 'widgets/error_sheet.dart';
import 'widgets/token_detail_sheet.dart';
import 'widgets/wallet_view_boundary.dart';
import 'widgets/watch_account_list.dart';

/// The app's home: the overview of every wallet, and the page of the one
/// that is open.
///
/// The app always opens on the overview ([WalletsOverviewScreen]), with no
/// unlock and no prompt. Tapping a wallet opens its page in place; back
/// returns to the overview, which is how the user switches wallets. A seed
/// wallet asks for its key once, when it is opened. A cancelled biometric
/// prompt leaves its locked page ([UnlockGate]) with Unlock and Use PIN,
/// and nothing asks again by itself. Watched addresses and accounts open
/// the same page with key-only actions swapped for their watch-only
/// equivalent ([WatchedWalletPage]).
///
/// An unlocked seed wallet's page has four tabs: Wallet ([WalletLedger]),
/// Activity, Discover (every protocol and tool, which replaced the Swap
/// tab: Swap is one of the wallet's actions) and Settings.
///
/// This state also owns what must run whichever page shows: the poll of
/// the unlocked wallet, the overview's public refresh, the ERG price
/// history the home screens chart, deep links and incoming-payment
/// notifications.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.initializeWalletService});

  final Future<void> Function()? initializeWalletService;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  final _sync = walletSyncController;
  final _overview = WalletsOverviewModel();
  final _price = ErgPriceFeed();

  /// The wallet whose page is showing; null shows the overview.
  WalletRef? _open;

  /// Shown on the overview: a startup error, or why a parked link waits.
  String? _notice;
  bool _noticeIsError = false;

  /// The seed wallet being unlocked or unlocked: the one the gate and the
  /// ledger belong to. Null until a seed wallet is opened.
  String? _walletId;
  bool _walletUnlocked = false;

  /// Unlock methods of [_methodsFor]; stale until it equals [_walletId].
  String? _methodsFor;
  bool _hasSeed = false;
  bool _hasPin = false;
  bool _canBiometric = false;
  bool _unlockBusy = false;

  /// The gate shows the PIN field although biometrics are set up.
  bool _usePin = false;

  /// Why the open wallet is still locked, for the gate.
  String? _gateStatus;
  bool _gateStatusIsError = false;
  final _pinCtrl = TextEditingController();

  /// Wallet page tabs: 0 wallet, 1 activity, 2 discover, 3 settings. Tabs
  /// are built on first visit so unlocking doesn't fan out into every
  /// screen's network calls at once.
  int _tab = 0;
  final Set<int> _visitedTabs = {0};
  static const _tabOrder = [WalletTab.wallet, WalletTab.activity, WalletTab.discover, WalletTab.settings];

  /// Poll for mempool changes (pending activity, balance, spendable UTXOs)
  /// while a wallet is unlocked. A tick is a light refresh on the known
  /// addresses; discovery also runs when its freshness interval expires.
  /// Manual refresh forces discovery; the probe timer remains separate.
  /// Paused while backgrounded; a tick is skipped if the previous refresh is
  /// still in flight. The same timer drives the overview's own refresh,
  /// locked or not, on its five-minute floor.
  Timer? _pollTimer;
  Timer? _probeTimer;
  bool _pollBackgrounded = false;

  /// The timer ticks every [_fastPollInterval]; a tick polls when something
  /// is unconfirmed, or when [_pollInterval] has passed since the last poll.
  static const _pollInterval = Duration(seconds: 20);
  static const _fastPollInterval = Duration(seconds: 5);
  static const _probeInterval = Duration(minutes: 2);
  DateTime _lastPollAt = DateTime.now();

  /// Polling keeps going this long after the app leaves the foreground so an
  /// incoming payment can still be announced; Android may stop it sooner.
  static const _backgroundPollWindow = Duration(minutes: 10);
  DateTime? _backgroundedAt;
  final _incoming = IncomingPaymentWatcher();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    walletService.unlocked.addListener(_syncLock);
    _overview.attach();
    _price.attach();
    watchOnlyService.addListener(_onWatchedListChanged);
    watchAccountService.addListener(_onWatchedListChanged);
    _sync.addListener(_onSyncChanged);
    mixService.addListener(_onSyncChanged);
    duckpoolsService.addListener(_onDuckpoolsChanged);
    // The SigmaFi card reads its subtitle from the service, so it has to
    // hear about a loan posted or repaid the way the Duckpools card does.
    sigmafiService.addListener(_onDuckpoolsChanged);
    deepLinkController.addListener(_onDeepLink);
    _pollTimer = Timer.periodic(_fastPollInterval, (_) => _pollTick());
    _probeTimer = Timer.periodic(_probeInterval, (_) => _probeTick());
    _init();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _probeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    walletService.unlocked.removeListener(_syncLock);
    watchOnlyService.removeListener(_onWatchedListChanged);
    watchAccountService.removeListener(_onWatchedListChanged);
    _sync.removeListener(_onSyncChanged);
    mixService.removeListener(_onSyncChanged);
    duckpoolsService.removeListener(_onDuckpoolsChanged);
    sigmafiService.removeListener(_onDuckpoolsChanged);
    deepLinkController.removeListener(_onDeepLink);
    _overview.dispose();
    _price.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await (widget.initializeWalletService ?? walletService.init)();
      await networkController.load();
      networkController.probe();
      await _overview.loadWallets();
    } on ArgusException catch (e) {
      _notice = '${e.code}: ${e.message}';
      _noticeIsError = true;
    } catch (e) {
      _notice = 'Error: $e';
      _noticeIsError = true;
    }
    // No unlock and no biometric prompt here: the app opens on the overview,
    // and a wallet asks for its key when the user opens it.
    if (!mounted) return;
    setState(() => _loading = false);
    unawaited(_overview.refreshOnLaunch());
  }

  // ── Listeners ─────────────────────────────────────────────────────────

  void _onSyncChanged() {
    if (mounted) setState(() {});
    _openPendingDeepLink();
    _announceIncoming();
    _refreshDuckpoolsIfDue();
  }

  void _onDuckpoolsChanged() {
    if (mounted) setState(() {});
  }

  /// A watched wallet that stopped being watched cannot stay open.
  void _onWatchedListChanged() {
    final open = _open;
    if (open == null || !open.watched || !mounted) return;
    final exists = open.kind == WalletKind.watchedAddress
        ? watchOnlyService.addresses.contains(open.id)
        : watchAccountService.accounts.any((a) => a.key == open.id);
    if (!exists) _closeWallet();
  }

  void _syncLock() {
    if (!mounted) return;
    setState(() {
      if (!walletService.unlocked.value && _walletUnlocked) _resetLocked();
    });
  }

  /// Value the wallet's lend tokens once per sync, at most every few
  /// minutes: the pools change slowly and the read is eight requests.
  void _refreshDuckpoolsIfDue() {
    if (!_walletUnlocked || _sync.isSyncing) return;
    final last = duckpoolsService.lastRefreshedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 5)) return;
    final holdings = {for (final t in _sync.tokens) t.id: t.amount};
    unawaited(duckpoolsService.refresh(holdings));
    // Loans are read less often: a borrowing pool is five requests, and
    // the read also announces any loan that crossed a line.
    unawaited(duckpoolsService.refreshLoansIfDue(_sync.historyAddresses));
  }

  /// Announces payments that appeared since the last refresh. Only fires
  /// while the app is not in front, so the home screen itself stays quiet.
  void _announceIncoming() {
    if (!_walletUnlocked) return;
    // The merged list, so a stealth receipt is announced too: it never
    // appears in the address history the node returns.
    final fresh = _incoming.observe(_sync.displayActivity);
    if (fresh.isEmpty || !_pollBackgrounded) return;
    for (final tx in fresh) {
      notificationService.incomingPayment(
        nanoErg: (tx['value_nano_erg'] as num?)?.toInt() ?? 0,
        walletName: _walletName(_walletId),
        pending: ((tx['height'] as num?)?.toInt() ?? 0) == 0,
        stealth: tx['stealth'] == true,
      );
    }
  }

  // ── Deep links ────────────────────────────────────────────────────────

  void _onDeepLink() {
    if (!_openPendingDeepLink() && mounted) {
      // Parked until a wallet unlocks; tell the user why nothing happened.
      final link = deepLinkController.pending;
      if (!_walletUnlocked && link != null) {
        setState(() {
          _notice = isErgoPayLink(link)
              ? 'Unlock a wallet to continue with the ErgoPay request.'
              : 'Unlock a wallet to open what the notification is about.';
          _noticeIsError = false;
        });
      }
    }
  }

  bool _ergoPayOpen = false;

  /// Opens a parked link once a wallet is unlocked and has an address.
  /// Returns false when it had to stay parked.
  bool _openPendingDeepLink() {
    if (!mounted || _ergoPayOpen) return false;
    final link = deepLinkController.pending;
    if (link == null) return false;
    final walletId = _walletId;
    if (walletId == null ||
        !_walletUnlocked ||
        !walletService.isUnlocked ||
        _sync.receiveAddress == null) {
      return false;
    }
    deepLinkController.take();
    if (_notice != null && !_noticeIsError) setState(() => _notice = null);
    if (isErgoPayLink(link)) {
      _openErgoPay(link);
      return true;
    }
    final route = argusLinkRoute(link);
    if (route == null) return true;
    // A notification tap lands on the screen it names, over the unlocked
    // wallet's page and nothing else.
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (_open != WalletRef.seed(walletId)) _showSeedPage(walletId);
    if (route == '/transactions') {
      _selectTab(1);
    } else {
      _go(route);
    }
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

  // ── Polling and lifecycle ─────────────────────────────────────────────

  void _pollTick() {
    if (!mounted) return;
    if (_pollBackgrounded) {
      final since = _backgroundedAt;
      if (since == null || DateTime.now().difference(since) > _backgroundPollWindow) {
        return;
      }
    } else {
      // Locked wallets and watched addresses, each on its own five-minute
      // floor. This needs no unlock: the overview shows them before one.
      unawaited(_overview.refreshIfDue());
    }
    if (!_walletUnlocked || _sync.busy) return;
    final now = DateTime.now();
    if (!shouldPoll(
      now: now,
      lastPollAt: _lastPollAt,
      hasPending: _sync.hasPending,
      pollInterval: _pollInterval,
      fastPollInterval: _fastPollInterval,
    )) {
      return;
    }
    _lastPollAt = now;
    // Routine poll: refresh without flipping the strip to "Syncing…".
    _sync.refresh(discover: false, quiet: true);
    // Mixes move on the same cadence; the service drops a tick that
    // arrives while one is running.
    unawaited(mixService.tick());
    unawaited(duckpoolsService.tickOrders());
  }

  void _probeTick() {
    if (!mounted || _pollBackgrounded) return;
    networkController.probe();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    publicWalletSync.setForeground(state == AppLifecycleState.resumed);
    // Pause mempool polling while backgrounded; resume on return.
    final backgrounded =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (backgrounded && !_pollBackgrounded) _backgroundedAt = DateTime.now();
    _pollBackgrounded = backgrounded;
    if (backgrounded) unawaited(mixService.setForeground(false));
    if (state != AppLifecycleState.resumed) return;
    _backgroundedAt = null;
    unawaited(mixService.setForeground(true));
    // Whatever happened while away shows now, not at the next tick.
    if (_walletUnlocked && !_sync.busy) {
      _lastPollAt = DateTime.now();
      unawaited(_sync.refresh(discover: false, quiet: true));
    }
    // Deliberately no unlock here. A biometric sheet pauses and resumes the
    // activity itself, so prompting on resume reopened the sheet the moment
    // the user cancelled it, over and over (1.0.0-beta.1). After an
    // auto-lock the wallet's page shows its gate; unlocking is the user's
    // tap.
  }

  // ── Opening and closing wallets ───────────────────────────────────────

  Future<void> _openWallet(WalletRef ref) async {
    if (ref.watched) {
      setState(() {
        _open = ref;
        _tab = 0;
        _visitedTabs
          ..clear()
          ..add(0);
      });
      return;
    }
    await _openSeed(ref.id);
  }

  /// Shows [walletId]'s page without touching its lock state.
  void _showSeedPage(String walletId) {
    setState(() {
      if (_open != WalletRef.seed(walletId)) {
        _tab = 0;
        _visitedTabs
          ..clear()
          ..add(0);
      }
      _open = WalletRef.seed(walletId);
      _gateStatus = null;
      _usePin = false;
    });
  }

  /// Opens a seed wallet: straight in when it is the unlocked one, else its
  /// gate, with biometrics asked once when they are set up.
  Future<void> _openSeed(String walletId) async {
    _pinCtrl.clear();
    _showSeedPage(walletId);
    if (walletService.isUnlocked && walletService.activeWalletId == walletId) {
      if (_walletId == walletId && _walletUnlocked) return;
      _walletId = walletId;
      await sessionLock.run(() async {
        await _refreshUnlockMethods();
        await _afterUnlock();
      });
      return;
    }
    await _switchWallet(walletId);
  }

  /// Makes [walletId] the wallet to unlock, and asks for biometrics once
  /// when they are set up. A cancel leaves the gate with Unlock and Use
  /// PIN; nothing asks again by itself.
  ///
  /// A wallet unlocked before stays unlocked until this one's key is in
  /// hand ([_lockOtherWallet]): backing out of the gate returns to the
  /// overview with it still open. Its view and services are left as they
  /// are; it just stops being polled while it is not the selected wallet.
  Future<void> _switchWallet(String walletId) async {
    try {
      _walletId = walletId;
      setState(() {
        _walletUnlocked = false;
        _incoming.reset();
        _tab = 0;
        _visitedTabs
          ..clear()
          ..add(0);
        _usePin = false;
      });
      await _refreshUnlockMethods();
      if (!mounted || _walletId != walletId) return;
      setState(() {});
      if (_open == WalletRef.seed(walletId) && _canBiometric && _hasPin) {
        await _unlockBiometric();
      }
    } on ArgusException catch (e) {
      if (!mounted) return;
      showErrorSheet(context, code: e.code, message: e.message);
    } catch (e) {
      if (!mounted) return;
      _snack('Could not open wallet: $e');
    }
  }

  /// Back to the overview. An unlocked wallet stays unlocked, so opening it
  /// again asks for nothing; the session lock still locks it in the
  /// background.
  void _closeWallet() {
    if (_open == null) return;
    setState(() {
      _open = null;
      _tab = 0;
      _visitedTabs
        ..clear()
        ..add(0);
      _gateStatus = null;
      _usePin = false;
    });
    _pinCtrl.clear();
    unawaited(_overview.loadWallets());
  }

  /// System back on a wallet page: first to its Wallet tab, then out.
  void _back() {
    if (_tab != 0) {
      _selectTab(0);
    } else {
      _closeWallet();
    }
  }

  /// Renamed or re-pinned in its settings: the page title and the address
  /// it is shown as come from the wallet list.
  Future<void> _onWalletEdited() async {
    await _overview.loadWallets();
    if (mounted) setState(() {});
  }

  Future<void> _onWalletRemoved(String walletId) async {
    if (!mounted) return;
    final name = _walletName(walletId);
    if (_open?.id == walletId) _closeWallet();
    if (_walletId == walletId) {
      setState(() {
        _resetLocked();
        _walletId = null;
        _methodsFor = null;
      });
    }
    await _overview.loadWallets();
    _snack('"$name" removed');
  }

  void _onWatchedRemoved() {
    _closeWallet();
    _snack('Stopped watching');
  }

  Future<void> _openCreate() =>
      _adopt(Navigator.push<String?>(context, fadeRoute(const CreateWalletScreen())));

  Future<void> _openRestore() =>
      _adopt(Navigator.push<String?>(context, fadeRoute(const RestoreWalletScreen())));

  /// A created or restored wallet comes back unlocked: open it without a
  /// second prompt.
  Future<void> _adopt(Future<String?> pushed) async {
    final walletId = await pushed;
    if (walletId == null || !mounted) return;
    _walletId = walletId;
    _showSeedPage(walletId);
    await sessionLock.run(() async {
      await _overview.loadWallets();
      await _refreshUnlockMethods();
      await _afterUnlock();
    });
  }

  // ── Unlocking ─────────────────────────────────────────────────────────

  void _resetLocked() {
    _walletUnlocked = false;
    _incoming.reset();
    _tab = 0;
    _visitedTabs
      ..clear()
      ..add(0);
    _sync.deactivate();
    stealthService.reset();
    mixService.reset();
    duckpoolsService.reset();
    sigmafiService.clearIfForeign();
    _usePin = false;
  }

  Future<void> _refreshUnlockMethods() async {
    final id = _walletId;
    if (id == null) {
      _hasSeed = false;
      _hasPin = false;
      _canBiometric = false;
      _methodsFor = null;
      return;
    }
    final hasSeed = await SecureStorageService.hasEncryptedSeed(walletId: id);
    final hasPin = await SecureStorageService.hasPinWrap(walletId: id);
    final canBiometric = await SecureStorageService.hasBiometric() &&
        await SecureStorageService.hasWrapKey(walletId: id);
    if (_walletId != id) return;
    _hasSeed = hasSeed;
    _hasPin = hasPin;
    _canBiometric = canBiometric;
    _methodsFor = id;
  }

  UnlockMethod get _unlockMethod {
    if (!_hasSeed) return UnlockMethod.none;
    if (!_hasPin) return UnlockMethod.legacy;
    return _canBiometric ? UnlockMethod.biometric : UnlockMethod.pin;
  }

  void _setGateStatus(String? message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _gateStatus = message;
      _gateStatusIsError = error;
    });
  }

  Future<void> _afterUnlock() async {
    if (!mounted) return;
    if (!walletService.isUnlocked) {
      setState(_resetLocked);
      return;
    }
    final walletId = walletService.activeWalletId;
    if (walletId == null || walletId != _walletId) return;
    _incoming.reset();
    stealthService.reset();
    mixService.reset();
    duckpoolsService.reset();
    sigmafiService.clearIfForeign();
    _sync.activateWallet(walletId);
    if (_sync.receiveAddress != null) {
      setState(() {
        _walletUnlocked = true;
        _gateStatus = null;
      });
    }
    // Record the pinned address if only its index was ever stored, so the
    // wallet list shows the pinned address rather than index 0 once this
    // wallet is locked again.
    await walletService.backfillPinnedAddress().catchError((_) {});
    // 1. Derive the main address locally and paint from the cache (instant).
    if (walletService.activeWalletId != walletId || _walletId != walletId) return;
    final ok = await _sync.hydrateAfterUnlock();
    if (!mounted ||
        walletService.activeWalletId != walletId ||
        _walletId != walletId) {
      return;
    }
    if (!walletService.isUnlocked) {
      setState(_resetLocked);
      return;
    }
    await _overview.loadWallets();
    if (!mounted ||
        walletService.activeWalletId != walletId ||
        _walletId != walletId) {
      return;
    }
    setState(() {
      _walletUnlocked = true;
      _gateStatus = null;
      _usePin = false;
    });
    if (!ok) {
      debugPrint('argus: address derivation failed after unlock');
      _snack('Unlocked, but no address could be derived');
      return;
    }
    // The published stealth string comes straight from the seed, so it can
    // be shown before any network call. Restoring a wallet lands here too,
    // and the refresh below runs the first stealth scan.
    unawaited(stealthService.loadAddress());
    // Reads the persisted identity list and tells the handle about it, so
    // the refresh below scans with every identity the user has published.
    unawaited(stealthService.loadIdentities());
    unawaited(mixService.load());
    unawaited(duckpoolsService.load());
    notificationService.requestPermission();
    // 2. Refresh known addresses; rescan only when discovery is due.
    await _sync.refresh(discover: true, forceDiscovery: false);
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

  /// The wallet unlocked before is locked only once this one's key is in
  /// hand, so an abandoned gate does not cost the user their open wallet.
  Future<void> _lockOtherWallet(String walletId) async {
    if (walletService.isUnlocked && walletService.activeWalletId != walletId) {
      await walletService.lockForSwitch();
    }
  }

  Future<void> _unlockWithPin() async {
    final walletId = _walletId;
    if (walletId == null) return;
    final err = validatePin(_pinCtrl.text);
    if (err != null) {
      _snack(err);
      return;
    }
    await _runUnlock(() async {
      if (!await _pinAllowed()) return;
      try {
        final json = await SecureStorageService.loadEncryptedSeed(walletId: walletId);
        final pinWrap = await SecureStorageService.loadPinWrap(walletId: walletId);
        if (json == null || pinWrap == null) {
          _setGateStatus('No PIN-protected wallet found.', error: true);
          return;
        }
        final wrapKey = await walletService.unwrapKeyWithPin(pinWrap, _pinCtrl.text);
        if (_walletId != walletId) return;
        await _lockOtherWallet(walletId);
        await walletService.restoreWallet(json, wrapKey: wrapKey, walletId: walletId);
        try {
          await SecureStorageService.clearPinGate();
        } catch (_) {}
        _pinCtrl.clear();
        HapticFeedback.lightImpact();
        await _afterUnlock();
      } on ArgusException catch (e) {
        try {
          await SecureStorageService.recordPinFailure();
        } catch (_) {}
        if (mounted) showErrorSheet(context, code: e.code, message: e.message);
      } on SecureStorageException catch (e) {
        if (mounted) showErrorSheet(context, message: e.message);
      }
    });
  }

  /// One biometric prompt. Called when a wallet is opened and when the user
  /// taps Unlock on its gate; never from a lifecycle event or a rebuild.
  Future<void> _unlockBiometric() async {
    final walletId = _walletId;
    if (walletId == null) return;
    await _runUnlock(() async {
      try {
        final wrapKey = await sessionLock.run(
          () => SecureStorageService.authenticateBiometric(walletId: walletId),
        );
        if (!mounted || _walletId != walletId) return;
        if (wrapKey == null) {
          if (!await SecureStorageService.hasWrapKey(walletId: walletId)) {
            _canBiometric = false;
            _setGateStatus('Biometric unlock is not set up for this wallet. Use its PIN.');
          } else {
            _setGateStatus('Biometric unlock cancelled. Tap Unlock to try again, or use your PIN.');
          }
          return;
        }
        final json = await SecureStorageService.loadEncryptedSeed(walletId: walletId);
        if (json == null) {
          _setGateStatus('Wallet data not found on this device.', error: true);
          return;
        }
        await _lockOtherWallet(walletId);
        await walletService.restoreWallet(json, wrapKey: wrapKey, walletId: walletId);
        HapticFeedback.lightImpact();
        await _afterUnlock();
      } on ArgusException catch (e) {
        if (mounted) showErrorSheet(context, code: e.code, message: e.message);
      } on SecureStorageException catch (e) {
        if (mounted) showErrorSheet(context, message: e.message);
      }
    });
  }

  Future<void> _unlockLegacyThenPin() async {
    final walletId = _walletId;
    if (walletId == null) return;
    await _runUnlock(() async {
      try {
        final json = await SecureStorageService.loadEncryptedSeed(walletId: walletId);
        final wrapKey = await SecureStorageService.loadWrapKey(walletId: walletId);
        if (json == null || wrapKey == null) {
          _setGateStatus('No wallet found. Create or restore.', error: true);
          return;
        }
        await _lockOtherWallet(walletId);
        await walletService.restoreWallet(json, wrapKey: wrapKey, walletId: walletId);
        if (!mounted) return;
        final pin = await _askNewPin();
        if (pin != null) {
          final pinWrap = await walletService.wrapKeyWithPin(wrapKey, pin);
          await SecureStorageService.savePinWrap(pinWrap, walletId: walletId);
          await SecureStorageService.deleteWrapKey(walletId: walletId);
          _hasPin = true;
          _canBiometric = false;
        }
        await _afterUnlock();
      } on ArgusException catch (e) {
        if (mounted) showErrorSheet(context, code: e.code, message: e.message);
      } on SecureStorageException catch (e) {
        if (mounted) showErrorSheet(context, message: e.message);
      }
    });
  }

  Future<String?> _askNewPin() async {
    final entry = await showDialog<PinEntry>(
      context: context,
      builder: (_) => const PinEntryDialog(
        title: 'Set a PIN',
        askConfirm: true,
        cancelLabel: 'Later',
        confirmLabel: 'Save',
      ),
    );
    if (entry == null) return null;
    final err = pinError(entry.pin, entry.confirm);
    if (err != null) {
      _snack(err);
      return null;
    }
    return entry.pin;
  }

  Future<void> _lock() async {
    await walletService.lock();
    if (mounted) setState(_resetLocked);
  }

  // ── Wallet page actions ───────────────────────────────────────────────

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _labelAddress(String address) async {
    final label = await showAddressLabelDialog(
      context,
      address: address,
      existing: addressLabelService.labelFor(address) ?? '',
    );
    if (label == null) return;
    await addressLabelService.setLabel(address, label);
    if (mounted) setState(() {});
  }

  /// Route args for read-only asset views: totals include stealth holdings.
  /// Send, Swap and the UTXO tools keep [_args], whose amounts are spendable.
  WalletRouteArgs _displayArgs() {
    final a = _args();
    return WalletRouteArgs(
      senderAddress: a.senderAddress,
      receiveAddress: a.receiveAddress,
      changeAddress: a.changeAddress,
      historyAddresses: a.historyAddresses,
      tokens: _sync.displayTokens,
      spendableNano: _sync.totalNanoWithStealth,
    );
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

  /// The swap screen on [venue]: the DEX from the Swap action, AgeUSD and
  /// Dexy from their Discover rows. It reads live balances from the app's
  /// wallet scope, as every pushed screen does.
  void _openSwap(SwapVenue venue) {
    if (!_guardUnlocked()) return;
    Navigator.push(
      context,
      fadeRoute(SwapHubScreen(initialTab: coerceVenue(venue)), settings: RouteSettings(arguments: _args())),
    );
  }

  void _openTx(Map<String, dynamic> tx) {
    Navigator.push(
      context,
      fadeRoute(
        const TransactionDetailScreen(),
        settings: RouteSettings(arguments: _args(transaction: tx)),
      ),
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

  /// Where a feature lives: a venue of the swap screen, or a route.
  void _openFeature(DiscoverFeature feature) {
    final e = discoverExplainers[feature]!;
    if (e.venue != null) {
      _openSwap(e.venue!);
    } else {
      _go(e.route!);
    }
  }

  /// A Discover row: the feature's explainer, whose button opens it.
  void _openDiscover(DiscoverFeature feature) {
    showDiscoverSheet(context, feature: feature, onGo: () => _openFeature(feature));
  }

  String _walletName(String? walletId) =>
      (walletId == null ? null : _overview.wallet(walletId)?.name) ?? 'Wallet';

  String _watchedName(WalletRef ref) {
    if (ref.kind == WalletKind.watchedAddress) {
      return addressLabelService.labelFor(ref.id) ?? 'Watched address';
    }
    for (final a in watchAccountService.accounts) {
      if (a.key == ref.id) return a.label ?? 'Watched account';
    }
    return 'Watched account';
  }

  bool get _balanceHidden => privacyService.hideBalances;

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return _splash();
    final open = _open;
    if (open == null) return _overviewScreen();
    if (open.kind == WalletKind.seed) return _seedPage(open.id);
    return _watchedPage(open);
  }

  /// Cold-start splash while the wallet core initialises: same branding as
  /// the overview so the app doesn't open on a bare spinner.
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

  Widget _overviewScreen() {
    return WalletsOverviewScreen(
      model: _overview,
      priceFeed: _price,
      onOpen: _openWallet,
      onCreate: _openCreate,
      onRestore: _openRestore,
      onWatchAddress: () => addWatchAddress(context),
      onWatchAccount: () => addWatchAccount(context),
      onSettings: () => Navigator.push(context, fadeRoute(const SettingsScreen())),
      onNetwork: () => Navigator.push(context, fadeRoute(const NetworkSettingsPage())),
      notice: _notice,
      noticeIsError: _noticeIsError,
    );
  }

  Widget _watchedPage(WalletRef ref) {
    return ListenableBuilder(
      listenable: Listenable.merge([addressLabelService, watchAccountService]),
      builder: (context, _) => WatchedWalletPage(
        key: ValueKey(ref),
        target: ref,
        name: _watchedName(ref),
        cached: ref.kind == WalletKind.watchedAddress
            ? _overview.watchedHoldings(ref.id)
            : null,
        priceFeed: _price,
        onClose: _closeWallet,
        onRemoved: _onWatchedRemoved,
      ),
    );
  }

  Widget _seedPage(String walletId) {
    final info = _overview.wallet(walletId);
    final name = info?.name ?? 'Wallet';
    final unlocked = _walletUnlocked && _walletId == walletId;
    final owns = unlocked && _sync.ownsWallet(walletId);
    final tab = _tabOrder[_tab];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: WalletPageScreen(
        title: owns && tab != WalletTab.wallet ? walletTabLook(tab).label : name,
        onBack: _closeWallet,
        actions: [
          if (owns && tab == WalletTab.wallet)
            IconButton(
              key: const Key('wallet-scan'),
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan a QR code',
              onPressed: _scan,
            ),
        ],
        body: ListenableBuilder(
          listenable: Listenable.merge([addressLabelService, privacyService]),
          builder: (context, _) => WalletViewBoundary(
            controller: _sync,
            walletId: walletId,
            unlocked: unlocked,
            ledger: (_) => _tabs(walletId),
            gate: (_) => _gate(walletId, info),
          ),
        ),
        navBar: owns
            ? ListenableBuilder(
                listenable: _sync,
                builder: (context, _) => WalletNavBar(
                  current: tab,
                  onSelect: (t) => _selectTab(_tabOrder.indexOf(t)),
                  pendingCount: _sync.displayActivity.where(isPendingTx).length,
                ),
              )
            : null,
      ),
    );
  }

  Widget _gate(String walletId, WalletInfo? info) {
    final known = _overview.lastKnown(walletId);
    final ready = _methodsFor == walletId && _walletId == walletId;
    return UnlockGate(
      name: info?.name ?? 'Wallet',
      address: info?.displayAddress,
      pinnedIndex: info?.pinnedAddressIndex,
      lastKnownNano: known == null ? null : known.balanceNano + known.stealthNano,
      lastKnownAge: known?.age,
      hidden: _balanceHidden,
      // Until this wallet's methods are read, offer nothing that would act
      // on the previous wallet's.
      method: ready ? _unlockMethod : UnlockMethod.biometric,
      pinController: _pinCtrl,
      busy: _unlockBusy || !ready,
      usePin: _usePin,
      onUnlock: _unlockBiometric,
      onUsePin: () => setState(() => _usePin = true),
      onUseBiometrics: () => setState(() => _usePin = false),
      onUnlockWithPin: _unlockWithPin,
      onUnlockLegacy: _unlockLegacyThenPin,
      status: _gateStatus ?? (_noticeIsError ? null : _notice),
      statusIsError: _gateStatus != null && _gateStatusIsError,
    );
  }

  /// The unlocked wallet's tabs share one [WalletArgsScope] so embedded
  /// screens see the same live balances a pushed route would get as
  /// arguments.
  Widget _tabs(String walletId) {
    final args = _args();
    Widget lazy(int i, Widget Function() build) =>
        _visitedTabs.contains(i) ? build() : const SizedBox.shrink();
    return WalletArgsScope(
      key: const ValueKey('tabs'),
      args: args,
      child: IndexedStack(
        index: _tab,
        children: [
          WalletLedger(
            sync: _sync,
            wallet: _overview.wallet(walletId),
            priceFeed: _price,
            actions: WalletLedgerActions(
              go: _go,
              swap: _openSwap,
              showActivity: () => _selectTab(1),
              showSettings: _openSettings,
              viewAssets: () => Navigator.push(
                context,
                fadeRoute(AssetsScreen(args: _displayArgs())),
              ),
              openTx: _openTx,
              openToken: _openToken,
              labelAddress: _labelAddress,
              lock: _lock,
            ),
          ),
          lazy(
            1,
            () => TransactionsScreen(
              key: ValueKey('activity-${_sync.receiveAddress}'),
              embedded: true,
              args: args,
            ),
          ),
          lazy(2, () => WalletDiscover(sync: _sync, onExplain: _openDiscover)),
          lazy(
            3,
            () => SettingsScreen(
              key: ValueKey('settings-$walletId'),
              embedded: true,
              walletId: walletId,
              onShowAllWallets: _closeWallet,
              onWalletChanged: _onWalletEdited,
              onWalletRemoved: _onWalletRemoved,
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether a poll tick should refresh: always once [pollInterval] has
/// passed, and every [fastPollInterval] while a transaction is unconfirmed,
/// so a Pending row flips to Confirmed within seconds of the block.
bool shouldPoll({
  required DateTime now,
  required DateTime lastPollAt,
  required bool hasPending,
  Duration pollInterval = const Duration(seconds: 20),
  Duration fastPollInterval = const Duration(seconds: 5),
}) {
  final since = now.difference(lastPollAt);
  if (since >= pollInterval) return true;
  return hasPending && since >= fastPollInterval;
}
