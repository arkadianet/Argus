import 'dart:async';

import 'network_controller.dart';
import 'token_metadata.dart';
import 'wallet_service.dart';
import 'watch_account_service.dart';
import 'watch_only_service.dart';

/// Names and scales for what watched addresses and watched accounts hold,
/// resolved automatically as a seed wallet's are.
///
/// A watched wallet is a first-class wallet: its page, its activity and
/// its prices read the one token lookup, so its holdings need descriptors
/// of their own. They are resolved under the seed wallets' rule (alpha.59):
/// only from the node that served the wallet's balances, never the
/// explorer or another node, and only about ids that node just served
/// ([WalletService.resolveWatchedHoldings]). They are stored per watched
/// wallet, never in a table shared across wallets, and dropped when the
/// wallet stops being watched. The public pool-token catalog stays apart.
///
/// Triggers: a watched address's balance read (the overview's and its
/// page's go through [WalletService.getBalance]) that shows a token nothing
/// can scale yet, and a watched account's finished scan that does.
class WatchedTokenMeta {
  WatchedTokenMeta({
    WalletService? wallet,
    WatchOnlyService? addresses,
    WatchAccountService? accounts,
    NetworkController? network,
  }) : _wallet = wallet ?? walletService,
       _addresses = addresses ?? watchOnlyService,
       _accounts = accounts ?? watchAccountService,
       _network = network ?? networkController;

  final WalletService _wallet;
  final WatchOnlyService _addresses;
  final WatchAccountService _accounts;
  final NetworkController _network;

  bool _attached = false;
  Set<String> _keys = {};

  /// The last scan seen per account, so each finished scan is looked at
  /// once.
  final Map<String, WatchAccountSnapshot> _seenScans = {};

  void attach() {
    if (_attached) return;
    _attached = true;
    _wallet.onBalanceRead = _onBalance;
    _addresses.addListener(_onWatchedChanged);
    _accounts.addListener(_onWatchedChanged);
    _onWatchedChanged();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    if (_wallet.onBalanceRead == _onBalance) _wallet.onBalanceRead = null;
    _addresses.removeListener(_onWatchedChanged);
    _accounts.removeListener(_onWatchedChanged);
    _keys = {};
    _seenScans.clear();
  }

  Set<String> _currentKeys() => {
    for (final a in _addresses.addresses) WalletService.watchedAddressKey(a),
    for (final a in _accounts.accounts) WalletService.watchedAccountKey(a.key),
  };

  void _onWatchedChanged() {
    final now = _currentKeys();
    for (final gone in _keys.difference(now)) {
      unawaited(_wallet.forgetWatchedTokenTable(gone));
    }
    for (final added in now.difference(_keys)) {
      unawaited(_wallet.loadWatchedTokenTable(added));
    }
    _keys = now;
    for (final account in _accounts.accounts) {
      final scan = account.snapshot;
      if (scan == null || identical(_seenScans[account.key], scan)) continue;
      _seenScans[account.key] = scan;
      final key = WalletService.watchedAccountKey(account.key);
      if (!_worthAPass(key, scan.tokens.keys)) continue;
      unawaited(
        _wallet.resolveWatchedHoldings(
          key,
          scan.tokenAddresses,
          nodeUrl: _network.activeUrl,
        ),
      );
    }
    final present = {for (final a in _accounts.accounts) a.key};
    _seenScans.removeWhere((key, _) => !present.contains(key));
  }

  void _onBalance(
    String address,
    Map<String, dynamic> balance,
    String? nodeUrl,
  ) {
    if (!_addresses.addresses.contains(address)) return;
    final ids = [
      for (final t in (balance['tokens'] as List? ?? const []))
        if (t is Map && t['id'] is String) t['id'] as String,
    ];
    final key = WalletService.watchedAddressKey(address);
    if (!_worthAPass(key, ids)) return;
    unawaited(
      _wallet.resolveWatchedHoldings(key, [address], nodeUrl: nodeUrl),
    );
  }

  /// A token nothing can scale yet that no node has already said does not
  /// exist and this wallet has not already read in full (a malformed R6
  /// stays unscaled, and asking again would only say so again): without
  /// one, a pass would read the balances again for nothing at every
  /// refresh.
  bool _worthAPass(String key, Iterable<String> ids) => ids.any(
    (id) =>
        tokenDecimals(id) == null &&
        !_wallet.watchedMissed(key, id) &&
        !_wallet.watchedSettled(key, id),
  );
}

final watchedTokenMeta = WatchedTokenMeta();
