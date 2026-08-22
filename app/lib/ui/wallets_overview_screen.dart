import 'package:flutter/material.dart';

import '../format.dart';
import '../services/network_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await walletService.init();
    try {
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
      final results = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        for (final (w, bal) in results) {
          _balances[w.walletId] = bal;
        }
      });
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Returns the balance to show for [w]. `null` means "unknown".
  Future<int?> _walletBalance(WalletInfo w) {
    final isActiveUnlocked = w.walletId == walletService.activeWalletId &&
        w.walletId == widget.selectedWalletId &&
        walletService.isUnlocked;
    if (isActiveUnlocked) {
      return Future.value(widget.activeBalanceNano);
    }
    final addr = w.address0;
    if (addr == null || addr.isEmpty) return Future.value(null);
    return walletService
        .getBalanceNano(addr, nodeUrl: networkController.activeUrl)
        .then<int?>((n) => n)
        .catchError((Object _) => null);
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
              child: _wallets.isEmpty
                  ? ListView(
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(
                            child: Text(
                              'No wallets stored yet. Create or restore one.',
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                      children: [
                        _summaryCard(context),
                        const SizedBox(height: 8),
                        ..._wallets.map(_walletTile),
                        const SizedBox(height: 20),
                        Text(
                          'Balances shown for locked wallets come from each '
                          'wallet\u2019s first address. Full balances require '
                          'unlocking that wallet.',
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
            '${_wallets.length} ${_wallets.length == 1 ? 'wallet' : 'wallets'}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            known == 0
                ? 'Total balance unavailable'
                : 'Visible total  ${formatErg(total)}',
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
    final bal = _balance(w);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: selected
              ? iris
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
                color: selected ? iris : Theme.of(context).colorScheme.primary,
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
                              color: iris.withValues(alpha: 0.15),
                              border: Border.all(color: iris),
                            ),
                            child: Text(
                              w.isUnlocked ? 'Active' : 'Selected',
                              style: const TextStyle(
                                color: iris,
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
                      w.address0 != null
                          ? shorten(w.address0!, head: 12, tail: 10)
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
                        ? (w.address0 != null
                            ? 'Unavailable'
                            : 'Unlock to view')
                        : 'ERG',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}