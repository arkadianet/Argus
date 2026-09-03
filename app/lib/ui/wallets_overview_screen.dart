import 'package:flutter/material.dart';

import '../format.dart';
import '../services/address_label_service.dart';
import '../services/network_controller.dart';
import '../services/wallet_database_service.dart';
import '../services/watch_only_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'wallet_dialogs.dart';
import 'widgets/empty_state.dart';
import 'widgets/soft_card.dart';

/// "2 wallets · 3 watch-only" headline for the overview summary card.
String overviewHeadline({required int wallets, required int watchOnly}) {
  if (wallets == 0) {
    return '$watchOnly watch-only ${watchOnly == 1 ? 'address' : 'addresses'}';
  }
  final w = '$wallets ${wallets == 1 ? 'wallet' : 'wallets'}';
  return watchOnly == 0 ? w : '$w · $watchOnly watch-only';
}

String overviewTotalLine({required int known, required int total}) =>
    known == 0 ? 'Total balance unavailable' : 'Visible total  ${formatErg(total)}';

/// Full-wallet overview with balances visible without unlocking.
///
/// For wallets other than the active one the balance is fetched from the node
/// using the wallet's first public address (the same as watch-only) — no seed
/// material is touched. The active unlocked wallet shows its live synced
/// balance instead. Selecting another wallet returns its id for a switch.
class WalletOverviewScreen extends StatefulWidget {
  const WalletOverviewScreen({
    super.key,
    this.selectedWalletId,
    this.activeBalanceNano,
  });

  /// The wallet currently selected on the dashboard (may be locked).
  final String? selectedWalletId;

  /// Live synced balance of the active wallet when unlocked.
  final int? activeBalanceNano;

  @override
  State<WalletOverviewScreen> createState() => _WalletOverviewScreenState();
}

class _WalletOverviewScreenState extends State<WalletOverviewScreen> {
  bool _loading = true;
  bool _refreshing = false;
  List<WalletInfo> _wallets = [];
  final Map<String, int?> _balances = {};
  final Map<String, int?> _watchBalances = {};

  @override
  void initState() {
    super.initState();
    watchOnlyService.addListener(_onWatchChanged);
    _load();
  }

  @override
  void dispose() {
    watchOnlyService.removeListener(_onWatchChanged);
    super.dispose();
  }

  void _onWatchChanged() {
    if (mounted) _refreshBalances();
  }

  Future<void> _load() async {
    try {
      await walletService.init();
      final wallets = await walletService.listWallets();
      if (!mounted) return;
      setState(() {
        _wallets = wallets;
        _loading = false;
      });
      await _refreshBalances();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load wallets: $e');
    }
  }

  Future<void> _refreshBalances() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final futures = _wallets.map((w) async => (w, await _walletBalance(w)));
      final watchAddrs = watchOnlyService.addresses;
      final watchFutures = watchAddrs.map((a) async => (a, await _addressBalance(a)));
      final results = await Future.wait(futures);
      final watchResults = await Future.wait(watchFutures);
      if (!mounted) return;
      setState(() {
        for (final (w, bal) in results) {
          _balances[w.walletId] = bal;
        }
        _watchBalances.removeWhere((k, _) => !watchAddrs.contains(k));
        for (final (a, bal) in watchResults) {
          _watchBalances[a] = bal;
        }
      });
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<int?> _addressBalance(String addr) => walletService
      .getBalanceNano(addr, nodeUrl: networkController.activeUrl)
      .then<int?>((n) => n)
      .catchError((Object _) => null);

  /// Returns the balance to show for [w]. `null` means "unknown".
  Future<int?> _walletBalance(WalletInfo w) {
    final isActiveUnlocked = w.walletId == walletService.activeWalletId &&
        w.walletId == widget.selectedWalletId &&
        walletService.isUnlocked;
    if (isActiveUnlocked) {
      return Future.value(widget.activeBalanceNano);
    }
    return WalletDatabaseService.lastKnownBalance(w.walletId).then((known) {
      if (known != null) return Future<int?>.value(known.balanceNano);
      final addr = w.displayAddress;
      if (addr == null || addr.isEmpty) return Future<int?>.value(null);
      return walletService
          .getBalanceNano(addr, nodeUrl: networkController.activeUrl)
          .then<int?>((n) => n)
          .catchError((Object _) => null);
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallets'),
        actions: [
          IconButton(
            icon: const Icon(Icons.visibility_outlined),
            tooltip: 'Watch an address',
            onPressed: _addWatchOnly,
          ),
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Refresh balances',
            onPressed: _refreshing ? null : _refreshBalances,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshBalances,
              child: _wallets.isEmpty && watchOnlyService.addresses.isEmpty
                  ? ListView(
                      children: const [
                        EmptyState(
                          icon: Icons.account_balance_wallet_outlined,
                          title: 'No wallets yet',
                          body: 'Create or restore a wallet from the home screen, or watch an address without its keys.',
                        ),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(20, 12, 20,
                          40 + MediaQuery.paddingOf(context).bottom),
                      children: [
                        _summaryCard(context),
                        const SizedBox(height: 8),
                        ..._wallets.map(_walletTile),
                        if (watchOnlyService.addresses.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          const SectionLabel('Watch-only', scope: 'App-wide'),
                          const SizedBox(height: 10),
                          SoftCard(
                            padding: EdgeInsets.zero,
                            child: DividedColumn(
                              indent: 16,
                              children: [
                                for (final a in watchOnlyService.addresses)
                                  _watchTile(a),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Text(
                          'Locked wallets show their last synced total, or the '
                          'balance of their primary address if they have never '
                          'been opened on this device.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
            ),
    );
  }

  Widget _summaryCard(BuildContext context) {
    var known = 0;
    var total = 0;
    for (final w in _wallets) {
      final bal = _balance(w);
      if (bal != null && bal >= 0) {
        known++;
        total += bal;
      }
    }
    for (final bal in _watchBalances.values) {
      if (bal != null && bal >= 0) {
        known++;
        total += bal;
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            overviewHeadline(
              wallets: _wallets.length,
              watchOnly: watchOnlyService.addresses.length,
            ),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            overviewTotalLine(known: known, total: total),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  int? _balance(WalletInfo w) {
    final bal = _balances[w.walletId];
    if (bal == null || bal < 0) return null;
    return bal;
  }

  Widget _walletTile(WalletInfo w) {
    final selected = w.walletId == widget.selectedWalletId;
    final isActiveUnlocked = w.walletId == walletService.activeWalletId &&
        w.walletId == widget.selectedWalletId &&
        walletService.isUnlocked;
    final bal = _balance(w);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected
              ? accentOf(context)
              : Theme.of(context).colorScheme.outline,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: () => Navigator.pop(context, w.walletId),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 22,
                color: selected ? accentOf(context) : Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            w.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: accentOf(context).withValues(alpha: 0.15),
                              border: Border.all(color: accentOf(context)),
                            ),
                            child: Text(
                              w.isUnlocked ? 'Active' : 'Selected',
                              style: TextStyle(
                                color: accentOf(context),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      w.displayAddress != null
                          ? shorten(w.displayAddress!, head: 12, tail: 10)
                          : 'wallet_id: ${w.walletId.length >= 8 ? w.walletId.substring(0, 8) : w.walletId}\u2026',
                      style: monoStyle(context, size: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (bal == null)
                    Text(
                      '—',
                      style: Theme.of(context).textTheme.bodyMedium,
                    )
                  else
                    Text(
                      formatErg(bal, unit: false),
                      style: const TextStyle(
                        fontFamily: 'Newsreader',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    bal == null
                        ? (isActiveUnlocked
                            ? 'Syncing'
                            : (w.displayAddress != null
                                ? 'Unavailable'
                                : 'Unlock to view'))
                        : 'ERG',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'Rename wallet',
                onPressed: () async {
                  if (await renameWalletDialog(context, w)) _load();
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Remove wallet',
                onPressed: () => _confirmDelete(w),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _watchTile(String address) {
    final colors = ArgusColors.of(context);
    final bal = _watchBalances[address];
    final label = addressLabelService.labelFor(address);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 20, color: colors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label != null && label.isNotEmpty ? label : 'Watch-only',
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(shorten(address, head: 12, tail: 10), style: monoStyle(context, size: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                bal == null ? '—' : formatErg(bal, unit: false),
                style: const TextStyle(
                  fontFamily: 'Newsreader',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(bal == null ? 'Unavailable' : 'ERG',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Stop watching',
            onPressed: () => _confirmUnwatch(address),
          ),
        ],
      ),
    );
  }

  Future<void> _addWatchOnly() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Watch an address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'See balance and activity for any Ergo address. No keys are '
              'stored, so it cannot spend.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: monoStyle(ctx, size: 13),
              decoration: const InputDecoration(labelText: 'Ergo address'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Watch')),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || text.isEmpty) return;
    final added = await watchOnlyService.add(text);
    if (!mounted) return;
    _snack(added ? 'Now watching ${shorten(text, head: 8, tail: 6)}' : 'Not a valid Ergo address, or already watched');
  }

  Future<void> _confirmUnwatch(String address) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop watching?'),
        content: Text(shorten(address, head: 12, tail: 10), style: monoStyle(ctx, size: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stop watching')),
        ],
      ),
    );
    if (ok == true) await watchOnlyService.remove(address);
  }

  Future<void> _confirmDelete(WalletInfo w) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove wallet?'),
        content: Text(
          '"${w.name}" will be removed from this device. Your recovery '
          'phrase is the only way back in — make sure the paper backup '
          'exists before removing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: rust,
              foregroundColor: bone,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await walletService.deleteWallet(w.walletId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${w.name}" removed')),
      );
      final remaining =
          _wallets.where((x) => x.walletId != w.walletId).toList();
      if (w.walletId == widget.selectedWalletId) {
        // The active wallet is gone: hand the dashboard the wallet to land
        // on, or an empty id when none remain.
        Navigator.pop(context, remaining.isEmpty ? '' : remaining.first.walletId);
        return;
      }
      _load();
    } catch (e) {
      if (!mounted) return;
      _snack('Could not remove wallet: $e');
    }
  }
}