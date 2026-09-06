import 'package:flutter/material.dart';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../format.dart';
import '../services/network_controller.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/error_sheet.dart';
import '../services/duckpools_math.dart';
import '../services/duckpools_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'widgets/empty_state.dart';
import 'widgets/soft_card.dart';

/// Duckpools lending: the pools as they are, what this wallet lends and
/// owes, and the orders that move it.
class DuckpoolsScreen extends StatefulWidget {
  const DuckpoolsScreen({super.key});

  @override
  State<DuckpoolsScreen> createState() => _DuckpoolsScreenState();
}

class _DuckpoolsScreenState extends State<DuckpoolsScreen> {
  bool _working = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      duckpoolsService.tickOrders();
    });
  }

  /// Confirm, broadcast and record a prepared order of any kind.
  Future<void> _post(Map<String, dynamic> prepared, {required String title, required List<ConfirmTxRow> rows}) async {
    rows.addAll([
      ConfirmTxRow('Argus fee', formatErg((prepared['app_fee_nano'] as num?)?.toInt() ?? 0)),
      ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
      ConfirmTxRow('Refundable after block', '${prepared['refund_height']}'),
    ]);
    final ok = await showConfirmTransactionSheet(
      context,
      title: title,
      detail: 'An off-chain bot fills the order against the pool, usually within '
          'minutes. If none does by the refund block, Argus can take it back.',
      rows: rows,
      preparationId: (prepared['preparation_id'] as num).toInt(),
    );
    if (!ok || !mounted) return;
    if (!duckpoolsService.canCommit(prepared)) {
      throw StateError('The wallet changed while the order was being prepared; nothing was sent');
    }
    final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
    await duckpoolsService.commitOrder(prepared, txId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order posted: ${shorten(txId)}')));
    }
  }

  /// Whether the wallet is still the one a sheet was opened for; says so
  /// and returns false otherwise.
  bool _sameWallet(String? before) {
    if (duckpoolsService.activeWalletId == before) return true;
    showErrorSheet(context, title: 'Could not post the order', message: 'The wallet changed while the sheet was open.');
    return false;
  }

  /// Borrow from a token pool against ERG: collateral and loan sheet,
  /// quote, confirm, broadcast, record.
  Future<void> _borrow(DuckPoolState s) async {
    if (_working) return;
    final walletBefore = duckpoolsService.activeWalletId;
    var args = WalletRouteArgs.of(context);
    final market = duckpoolsService.marketFor(s.pool);
    if (market == null || !market.ready) return;
    final pool = duckpoolsService.pools.firstWhere((p) => p.key == s.pool);
    final held = {for (final t in args.tokens) t.id: t.amount};
    final picked = await showModalBottomSheet<(String, int, int)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (_) => _BorrowSheet(state: s, market: market, spendableNano: args.spendableNano ?? 0, held: held),
    );
    if (picked == null || !mounted) return;
    if (!_sameWallet(walletBefore)) return;
    args = WalletRouteArgs.of(context);
    final (asset, collateralAmount, loan) = picked;
    setState(() => _working = true);
    try {
      final prepared = await duckpoolsService.prepareOrder(
        poolKey: s.pool,
        kind: 'borrow',
        amount: loan,
        collateralAsset: asset.isEmpty ? null : asset,
        collateralAmount: collateralAmount,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
      );
      if (!mounted) return;
      final q = (prepared['quote'] as Map).cast<String, dynamic>();
      String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), s.decimals)} ${s.ticker}';
      final (cTicker, cDecimals) = pool.collateralUnit(q['collateral_asset'] as String?);
      await _post(prepared, title: 'Post a borrow order', rows: [
        ConfirmTxRow('Borrow', amt(q['loan'] as num), bold: true),
        ConfirmTxRow('Collateral', '${formatTokenAmountGrouped((q['collateral_amount'] as num).toInt(), cDecimals)} $cTicker', bold: true),
        ConfirmTxRow('Collateral counts as', amt(q['collateral_value'] as num)),
        ConfirmTxRow('Liquidation line', '${((q['threshold'] as num) / 10).toStringAsFixed(0)}% of the debt'),
        ConfirmTxRow('Health at open', '${((q['health_bps'] as num) / 100).toStringAsFixed(0)}%'),
        // What the proxy carries beyond the collateral itself.
        ConfirmTxRow('Bot fee + fill fee', formatErg((q['box_value'] as num).toInt() - (q['collateral_nano'] as num).toInt())),
      ]);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not post the order', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Repay a loan in full, or part of it.
  Future<void> _repay(DuckLoan l, {required bool partial}) async {
    if (_working) return;
    final walletBefore = duckpoolsService.activeWalletId;
    var args = WalletRouteArgs.of(context);
    // What the wallet holds of the loan's asset: the pool's token, or
    // spendable ERG for the ERG pool.
    final currencyId = duckpoolsService.pools.firstWhere((p) => p.key == l.pool).currencyId;
    final held = currencyId == null
        ? (args.spendableNano ?? 0)
        : args.tokens.where((t) => t.id == currencyId).fold<int>(0, (a, t) => a + t.amount);
    int? amount;
    if (partial) {
      amount = await showModalBottomSheet<int>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
        builder: (_) => _PartialRepaySheet(loan: l, held: held),
      );
      if (amount == null || !mounted) return;
      if (!_sameWallet(walletBefore)) return;
      args = WalletRouteArgs.of(context);
    }
    setState(() => _working = true);
    try {
      final prepared = await duckpoolsService.prepareOrder(
        poolKey: l.pool,
        kind: partial ? 'partial_repay' : 'repay',
        amount: amount ?? 0,
        collateralBoxId: l.boxId,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
      );
      if (!mounted) return;
      final q = (prepared['quote'] as Map).cast<String, dynamic>();
      String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), l.decimals)} ${l.ticker}';
      final pool = duckpoolsService.pools.firstWhere((p) => p.key == l.pool);
      final (cTicker, cDecimals) = pool.collateralUnit(l.collateralAsset);
      final collateral = '${formatTokenAmountGrouped(l.collateralAmount, cDecimals)} $cTicker';
      final rows = partial
          ? [
              ConfirmTxRow('Repay', amt(q['repayment'] as num), bold: true),
              ConfirmTxRow('Owed now', amt(l.owed)),
              ConfirmTxRow('Owed after', amt(q['owed_after'] as num)),
              ConfirmTxRow('Collateral stays', collateral),
            ]
          : [
              ConfirmTxRow('Repay', amt(q['repayment'] as num), bold: true),
              ConfirmTxRow('Owed now', amt(q['owed_now'] as num)),
              ConfirmTxRow('Covers interest until filled', 'yes; the rest stays with the pool'),
              ConfirmTxRow('Collateral back', collateral, bold: true),
            ];
      // A token pool's repayment rides as tokens, so the box's ERG is all
      // fees. The ERG pool's box is the repayment alone: the bot's fee and
      // the fill fee come out of the collateral box's own carry.
      final carried = (q['box_value'] as num).toInt() - (l.collateralAsset == null ? 0 : (q['repayment'] as num).toInt());
      rows.add(ConfirmTxRow('Bot fee + fill fee', carried > 0 ? formatErg(carried) : 'paid from the collateral box\'s 0.002 ERG carry'));
      await _post(prepared, title: partial ? 'Post a partial repayment' : 'Post a repayment', rows: rows);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not post the order', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Add collateral to a loan, or take some out: the borrower's own spend
  /// of the collateral box, no bot.
  Future<void> _adjust(DuckLoan l) async {
    if (_working) return;
    final walletBefore = duckpoolsService.activeWalletId;
    var args = WalletRouteArgs.of(context);
    final pool = duckpoolsService.pools.firstWhere((p) => p.key == l.pool);
    final (cTicker, cDecimals) = pool.collateralUnit(l.collateralAsset);
    final held = l.collateralAsset == null
        ? (args.spendableNano ?? 0)
        : args.tokens.where((t) => t.id == l.collateralAsset).fold<int>(0, (a, t) => a + t.amount);
    final newAmount = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (_) => _AdjustSheet(loan: l, ticker: cTicker, decimals: cDecimals, held: held),
    );
    if (newAmount == null || !mounted) return;
    if (!_sameWallet(walletBefore)) return;
    args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await duckpoolsService.prepareAdjust(
        poolKey: l.pool,
        collateralBoxId: l.boxId,
        newAmount: newAmount,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
      );
      if (!mounted) return;
      final q = (prepared['quote'] as Map).cast<String, dynamic>();
      String c(num units) => '${formatTokenAmountGrouped(units.toInt(), cDecimals)} $cTicker';
      final delta = (q['delta'] as num).toInt();
      final ok = await showConfirmTransactionSheet(
        context,
        title: delta > 0 ? 'Add collateral' : 'Take collateral out',
        confirmLabel: delta > 0 ? 'Add' : 'Take out',
        detail: 'This rebuilds your collateral box directly; nothing waits for a bot. '
            'The loan, its interest and its liquidation date stay as they are.',
        rows: [
          ConfirmTxRow(delta > 0 ? 'Add' : 'Take out', c(delta.abs()), bold: true),
          ConfirmTxRow('Collateral now', c(q['current_amount'] as num)),
          ConfirmTxRow('Collateral after', c(q['new_amount'] as num), bold: true),
          ConfirmTxRow('Health after', '${((q['health_after_bps'] as num) / 100).toStringAsFixed(0)}%'),
          ConfirmTxRow('Least allowed now', c(q['min_amount'] as num)),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Collateral adjusted: ${shorten(txId)}')));
      }
      await duckpoolsService.refreshLoans(args.historyAddresses);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not adjust the collateral', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Lend into, or withdraw from, one pool: amount sheet, quote, confirm,
  /// broadcast, record.
  Future<void> _order(DuckPoolState s, String kind) async {
    if (_working) return;
    final svc = duckpoolsService;
    final walletBefore = svc.activeWalletId;
    final holdingTokens = s.walletLendTokens;
    final amount = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (_) => _OrderSheet(state: s, kind: kind, maxLendTokens: holdingTokens),
    );
    if (amount == null || !mounted) return;
    // The addresses and the wallet id must come from the same wallet: read
    // the route again after the sheet, and stop if the wallet changed
    // while it was open.
    if (!_sameWallet(walletBefore)) return;
    final args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await svc.prepareOrder(
        poolKey: s.pool,
        kind: kind,
        amount: amount,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
      );
      if (!mounted) return;
      final q = (prepared['quote'] as Map).cast<String, dynamic>();
      String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), s.decimals)} ${s.ticker}';
      final rows = kind == 'lend'
          ? [
              ConfirmTxRow('Lend', amt(q['amount'] as num), bold: true),
              ConfirmTxRow('Service fee', amt(q['service_fee'] as num)),
              ConfirmTxRow('Reaches the pool', amt(q['to_pool'] as num)),
              ConfirmTxRow('Lend tokens expected', formatTokenAmountGrouped((q['lend_tokens_expected'] as num).toInt(), s.decimals)),
              ConfirmTxRow('At least', formatTokenAmountGrouped((q['min_lend_tokens'] as num).toInt(), s.decimals)),
            ]
          : [
              ConfirmTxRow('Lend tokens in', formatTokenAmountGrouped((q['lend_tokens'] as num).toInt(), s.decimals), bold: true),
              ConfirmTxRow('Worth today', amt(q['entitled'] as num)),
              ConfirmTxRow('Service fee', amt(q['service_fee'] as num)),
              ConfirmTxRow('You receive', amt(q['out'] as num), bold: true),
              ConfirmTxRow('At least', amt(q['min_out'] as num)),
            ];
      // What the proxy box carries beyond the deposit itself: the bot's
      // fee and the fill's fee, as the Rust side sized them.
      final carried = (q['box_value'] as num).toInt() - (kind == 'lend' && s.pool == 'erg' ? (q['amount'] as num).toInt() : 0);
      rows.addAll([
        ConfirmTxRow('Bot fee + fill fee', formatErg(carried)),
        ConfirmTxRow('Argus fee', formatErg((prepared['app_fee_nano'] as num?)?.toInt() ?? 0)),
        ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ConfirmTxRow('Refundable after block', '${prepared['refund_height']}'),
      ]);
      final ok = await showConfirmTransactionSheet(
        context,
        title: kind == 'lend' ? 'Post a lend order' : 'Post a withdraw order',
        detail: 'An off-chain bot fills the order against the pool, usually within '
            'minutes. If none does by the refund block, Argus can take it back.',
        rows: rows,
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      if (!svc.canCommit(prepared)) throw StateError('The wallet changed while the order was being prepared; nothing was sent');
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      await svc.commitOrder(prepared, txId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Order posted: ${shorten(txId)}')));
      }
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not post the order', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _refund(DuckOrder o) async {
    if (_working) return;
    final args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await duckpoolsService.prepareRefund(o, userAddress: args.receiveAddress);
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Take the order back',
        confirmLabel: 'Refund',
        detail: 'Nobody filled this order by its refund block. Everything in it '
            'comes back less the contract\'s one fee.',
        rows: [
          ConfirmTxRow('Back to you', formatErg((prepared['value_nano_erg'] as num).toInt()), bold: true),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      await duckpoolsService.markRefundSent(o, txId);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not refund the order', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Map<String, int> _holdings(BuildContext context) {
    final args = WalletRouteArgs.of(context);
    return {for (final t in args.tokens) t.id: t.amount};
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final addresses = WalletRouteArgs.of(context).historyAddresses;
    await Future.wait([
      duckpoolsService.refresh(_holdings(context)),
      duckpoolsService.refreshLoans(addresses),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duckpools'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: duckpoolsService.busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: duckpoolsService,
        builder: (context, _) {
          final svc = duckpoolsService;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(
                  'Pool lending on Ergo. Lenders put an asset into a pool and hold '
                  'lend tokens that are worth more of it as borrowers pay interest. '
                  'Borrowers lock ERG as collateral and can be liquidated if it falls '
                  'below the pool\'s line. Every action here is an order a bot fills.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  svc.lastRefreshedAt == null
                      ? (svc.busy ? 'Reading the pools…' : 'Not read yet')
                      : 'Read ${formatSyncAge(svc.lastRefreshedAt)}',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                if (svc.lastError != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SelectableText(
                          'Could not read the pools: ${svc.lastError}',
                          style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy error',
                        iconSize: 18,
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: svc.lastError!));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error copied')));
                        },
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (svc.orders.isNotEmpty) ...[
                  const SectionLabel('Your orders'),
                  const SizedBox(height: 8),
                  for (final o in svc.orders) ...[
                    _OrderCard(
                      order: o,
                      working: _working,
                      onRefund: () => _refund(o),
                      onRemove: () => svc.removeOrder(o),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 12),
                ],
                if (svc.loansError != null) ...[
                  SelectableText(
                    'Could not read the loans: ${svc.loansError}',
                    style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                ],
                if (svc.loans.isEmpty && svc.loansRefreshedAt != null && svc.loansError == null) ...[
                  Text(
                    'No loans on this wallet\'s addresses. Borrow from a pool above to open one.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                ],
                if (svc.loans.isNotEmpty) ...[
                  const SectionLabel('Your loans'),
                  const SizedBox(height: 8),
                  for (final l in svc.loans) ...[
                    _LoanCard(
                      loan: l,
                      pool: svc.states.where((st) => st.pool == l.pool).firstOrNull,
                      onRepay: _working ? null : () => _repay(l, partial: false),
                      onRepayPart: _working ? null : () => _repay(l, partial: true),
                      onAdjust: _working ? null : () => _adjust(l),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 12),
                ],
                if (svc.positions.isNotEmpty) ...[
                  const SectionLabel('Your positions'),
                  const SizedBox(height: 8),
                  for (final s in svc.positions) ...[
                    _PoolCard(
                      state: s,
                      position: true,
                      onLend: _working ? null : () => _order(s, 'lend'),
                      onWithdraw: _working ? null : () => _order(s, 'withdraw'),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 12),
                ],
                const SectionLabel('Pools'),
                const SizedBox(height: 8),
                if (svc.states.isEmpty && !svc.busy)
                  const EmptyState(
                    icon: Icons.water_outlined,
                    title: 'No pool data yet',
                    body: 'Pull down to read the eight pools from the chain.',
                    compact: true,
                  )
                else
                  for (final s in svc.states) ...[
                    _PoolCard(
                      state: s,
                      position: false,
                      market: svc.marketFor(s.pool),
                      lends: svc.pools.any((p) => p.key == s.pool && p.lends),
                      loansBusy: svc.loansBusy,
                      onLend: _working ? null : () => _order(s, 'lend'),
                      onWithdraw: s.hasPosition && !_working ? () => _order(s, 'withdraw') : null,
                      onBorrow: (svc.marketFor(s.pool)?.ready ?? false) && !_working ? () => _borrow(s) : null,
                    ),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// "27.5%" from basis points.
String utilisationText(int bps) => '${(bps / 100).toStringAsFixed(bps % 100 == 0 ? 0 : 1)}%';

class _PoolCard extends StatelessWidget {
  const _PoolCard({
    this.lends = false,
    this.loansBusy = false,required this.state, required this.position, this.market, this.onLend, this.onWithdraw, this.onBorrow});

  final DuckPoolState state;

  /// Whether the pool lends at all, and whether its terms are being read.
  final bool lends;
  final bool loansBusy;
  final bool position;
  final DuckMarket? market;
  final VoidCallback? onLend;
  final VoidCallback? onWithdraw;
  final VoidCallback? onBorrow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final s = state;
    String amt(int units) => formatTokenAmountGrouped(units, s.decimals);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
              Text(value, style: monoStyle(context, size: 12.5)),
            ],
          ),
        );
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  position ? '${amt(s.walletValue)} ${s.ticker}' : '${s.ticker} pool',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                s.utilisationBps == 0 ? 'nothing borrowed' : '${utilisationText(s.utilisationBps)} lent out',
                style: TextStyle(color: s.utilisationBps == 0 ? muted : accentOf(context), fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (position) ...[
            row('Lend tokens', formatTokenAmountGrouped(s.walletLendTokens, s.decimals)),
            row('Worth today', '${amt(s.walletValue)} ${s.ticker}'),
          ],
          row('In the pool', '${amt(s.pooled)} ${s.ticker}'),
          row('Out on loan', '${amt(s.borrowed)} ${s.ticker}'),
          row('Per lend token', '${s.lendTokenPrice.toStringAsFixed(4)} ${s.ticker}'),
          if (s.lendAprBps != null) row('Lenders earn', '${(s.lendAprBps! / 100).toStringAsFixed(2)}% a year'),
          if (s.borrowAprBps != null) row('Borrowers pay', '${(s.borrowAprBps! / 100).toStringAsFixed(2)}% a year'),
          if (market != null && market!.ready && market!.ergValue != null) ...[
            row('1 ERG collateral counts as', '${amt(market!.ergValue!)} ${s.ticker}'),
            row('Liquidation threshold', '${(market!.threshold! / 10).toStringAsFixed(0)}% collateral ratio'),
            row('Liquidation penalty', '${(market!.penalty! / 10).toStringAsFixed(0)}%, as Duckpools states it'),
            row('Borrow up to', '${maxLoanToValuePercent(market!.threshold!).toStringAsFixed(0)}% of the collateral\'s value'),
          ],
          if (market != null)
            for (final c in market!.collaterals.where((c) => c.ready))
              row('1 ${c.ticker} collateral', '${formatErg(c.unitValueNano!)} · threshold ${(c.threshold! / 10).toStringAsFixed(0)}%'),
          if (market != null && !market!.ready) ...[
            const SizedBox(height: 6),
            SelectableText(
              'Borrowing unavailable: ${market!.unavailableReason}. Refresh to try again.',
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
          ] else if (market == null && lends) ...[
            const SizedBox(height: 6),
            Text(
              loansBusy ? 'Reading the borrowing terms…' : 'The borrowing terms have not been read yet. Refresh to read them.',
              style: TextStyle(color: muted, fontSize: 11.5),
            ),
          ],
          if (market != null && market!.unpriced > 0) ...[
            const SizedBox(height: 6),
            SelectableText(
              '${market!.unpriced} of your loans here could not be priced, so ${market!.unpriced == 1 ? 'it is' : 'they are'} '
              'not listed below. Refresh once the price boxes are readable again.',
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
          ],
          if (s.utilisationBps == 0) ...[
            const SizedBox(height: 6),
            Text(
              'With nothing borrowed, lenders earn nothing until a borrower appears.',
              style: TextStyle(color: muted, fontSize: 11.5),
            ),
          ],
          if (onLend != null || onWithdraw != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                if (onLend != null) FilledButton.tonal(onPressed: onLend, child: const Text('Lend')),
                if (onWithdraw != null) OutlinedButton(onPressed: onWithdraw, child: const Text('Withdraw')),
                if (onBorrow != null) OutlinedButton(onPressed: onBorrow, child: const Text('Borrow')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// What an order is doing, in words.
String orderStatusText(DuckOrder o, {int? height}) => switch (o.status) {
      'pending' => 'Waiting for a bot to fill it'
          '${height != null ? ' · refundable in ${(o.refundHeight - height).clamp(0, 1 << 30)} blocks' : ''}',
      'refundable' => 'Nobody filled it. You can take it back.',
      'refund_sent' => 'Refund sent, waiting for a block',
      'filled' => switch (o.kind) {
          'lend' => 'Filled: ${o.received == null ? 'lend tokens received' : '${formatTokenAmountGrouped(o.received!, o.decimals)} lend tokens received'}',
          'borrow' => 'Filled: ${o.received == null ? 'loan received' : '${formatTokenAmountGrouped(o.received!, o.decimals)} ${o.ticker} received'}',
          'repay' => 'Filled: ${o.received == null ? 'collateral returned' : '${formatErg(o.received!)} collateral returned'}',
          'partial_repay' => 'Filled: the loan is smaller',
          _ => 'Filled: ${o.received == null ? 'paid out' : '${formatErg(o.received!)} paid out'}',
        },
      'refunded' => 'Refunded',
      _ => o.status,
    };

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.working, required this.onRefund, required this.onRemove});

  final DuckOrder order;
  final bool working;
  final VoidCallback onRefund;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final what = switch (o.kind) {
      'lend' => 'Lend ${formatTokenAmountGrouped(o.amount, o.decimals)} ${o.ticker}',
      'borrow' => 'Borrow ${formatTokenAmountGrouped(o.amount, o.decimals)} ${o.ticker}'
          '${o.collateralNano != null ? ' against ${_collateralText(o.pool, o.collateralAsset, o.collateralNano!)}' : ''}',
      'repay' => 'Repay ${formatTokenAmountGrouped(o.amount, o.decimals)} ${o.ticker}',
      'partial_repay' => 'Repay ${formatTokenAmountGrouped(o.amount, o.decimals)} ${o.ticker} of a loan',
      _ => 'Withdraw ${formatTokenAmountGrouped(o.amount, o.decimals)} lend tokens (${o.ticker})',
    };
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(what, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(orderStatusText(o, height: networkController.height), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text('Order ${shorten(o.proxyBoxId, head: 8, tail: 6)} · posted ${formatSyncAge(o.createdAt)}',
              style: TextStyle(color: muted, fontSize: 12)),
          if (o.lastError != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: SelectableText(o.lastError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12))),
                IconButton(
                  iconSize: 18,
                  tooltip: 'Copy error',
                  onPressed: () => Clipboard.setData(ClipboardData(text: o.lastError!)),
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (o.status == 'refundable') FilledButton.tonal(onPressed: working ? null : onRefund, child: const Text('Refund')),
              if (!o.open) TextButton(onPressed: onRemove, child: const Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Amount entry for an order, with the quote shown as it is typed.
class _OrderSheet extends StatefulWidget {
  const _OrderSheet({required this.state, required this.kind, required this.maxLendTokens});
  final DuckPoolState state;
  final String kind;
  final int maxLendTokens;

  @override
  State<_OrderSheet> createState() => _OrderSheetState();
}

class _OrderSheetState extends State<_OrderSheet> {
  final _ctl = TextEditingController();
  Map<String, dynamic>? _quote;
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  int? get _units => parseDuckAmount(_ctl.text, widget.state.decimals);

  void _requote() {
    final units = _units;
    setState(() {
      _quote = null;
      _error = null;
      if (units == null) {
        if (_ctl.text.trim().isNotEmpty) _error = 'Use at most ${widget.state.decimals} decimal places.';
        return;
      }
      try {
        _quote = duckpoolsService.quote(poolKey: widget.state.pool, kind: widget.kind, amount: units);
      } catch (e) {
        _error = e.toString().replaceFirst('Bad state: ', '');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final lend = widget.kind == 'lend';
    final muted = ArgusColors.of(context).muted;
    String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), s.decimals)} ${s.ticker}';
    final q = _quote;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(lend ? 'Lend ${s.ticker}' : 'Withdraw from the ${s.ticker} pool', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('duck-amount'),
            controller: _ctl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: lend ? 'Amount of ${s.ticker} to lend' : 'Lend tokens to hand in',
              helperText: lend
                  ? 'The service fee comes out of this amount.'
                  : 'You hold ${formatTokenAmountGrouped(widget.maxLendTokens, s.decimals)}',
              suffixIcon: lend
                  ? null
                  : TextButton(
                      onPressed: () {
                        _ctl.text = formatTokenAmount(widget.maxLendTokens, s.decimals);
                        _requote();
                      },
                      child: const Text('MAX'),
                    ),
            ),
            onChanged: (_) => _requote(),
          ),
          const SizedBox(height: 12),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          if (q != null) ...[
            Text(
              lend
                  ? 'Service fee ${amt(q['service_fee'] as num)} · about ${formatTokenAmountGrouped((q['lend_tokens_expected'] as num).toInt(), s.decimals)} lend tokens'
                  : 'Worth ${amt(q['entitled'] as num)} · service fee ${amt(q['service_fee'] as num)} · you receive about ${amt(q['out'] as num)}',
              style: TextStyle(color: muted, fontSize: 12.5),
            ),
            const SizedBox(height: 4),
            Text('Plus ${formatErg((q['box_value'] as num).toInt() - (lend && s.pool == 'erg' ? (q['amount'] as num).toInt() : 0))} '
                'for the bot and the fill, the Argus fee and the miner fee. '
                'The order accepts up to 1% less than quoted if the pool moves.',
                style: TextStyle(color: muted, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('duck-continue'),
            onPressed: q == null ? null : () => Navigator.pop(context, _units),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}


/// "2.5 ERG" or "1,000 SigUSD": a collateral amount in its own unit.
String _collateralText(String poolKey, String? asset, int amount) {
  final pool = duckpoolsService.pools.where((p) => p.key == poolKey).firstOrNull;
  final (ticker, decimals) = pool?.collateralUnit(asset) ?? ('ERG', 9);
  return '${formatTokenAmountGrouped(amount, decimals)} $ticker';
}

/// One loan: what it owes, what backs it, how close to the line it is.
class _LoanCard extends StatefulWidget {
  const _LoanCard({required this.loan, this.pool, this.onRepay, this.onRepayPart, this.onAdjust});

  final DuckLoan loan;

  /// The pool's current rates, for the interest the loan is costing.
  final DuckPoolState? pool;
  final VoidCallback? onRepay;
  final VoidCallback? onRepayPart;
  final VoidCallback? onAdjust;

  @override
  State<_LoanCard> createState() => _LoanCardState();
}

class _LoanCardState extends State<_LoanCard> {
  /// The "what if the price moves" slider, percent.
  double _priceMove = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final l = widget.loan;
    String amt(int units) => '${formatTokenAmountGrouped(units, l.decimals)} ${l.ticker}';
    final ratio = l.ratioPercent;
    final thresholdPct = l.threshold / 10;
    final healthColor = healthColorFor(context, l.healthBps, liquidatable: l.liquidatable);
    Widget row(String label, String value, {Color? color, String? note}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(value, style: monoStyle(context, size: 12.5).copyWith(color: color)),
                  if (note != null) Text(note, style: TextStyle(color: muted, fontSize: 11)),
                ],
              ),
            ],
          ),
        );
    final collateralDecimals = _collateralDecimals(l.pool, l.collateralAsset);
    final collateralTicker = _collateralTicker(l.pool, l.collateralAsset);
    final priceNow = collateralUnitPrice(collateralValue: l.collateralValue, collateralAmount: l.collateralAmount, collateralDecimals: collateralDecimals);
    final liqPrice = liquidationUnitPrice(liquidationValue: l.liquidationValue, collateralAmount: l.collateralAmount, collateralDecimals: collateralDecimals);
    final drop = dropToLiquidationPercent(collateralValue: l.collateralValue, liquidationValue: l.liquidationValue);
    String price(double units) => '${formatTokenAmountGrouped(units.round(), l.decimals)} ${l.ticker}';
    final interest = l.owed - l.loan;
    final apr = widget.pool?.borrowAprBps;
    final height = networkController.height;
    final blocksLeft = height == null ? null : (l.forcedLiquidationHeight - height).clamp(0, 1 << 30);
    final whatIf = healthAfterPriceChange(l.healthBps, _priceMove);
    final whatIfColor = healthColorFor(context, whatIf, liquidatable: whatIf <= 10000);
    final toSafe = extraCollateralForHealth(
      owed: l.owed,
      threshold: l.threshold,
      targetHealthBps: 15000,
      collateralValue: l.collateralValue,
      collateralAmount: l.collateralAmount,
    );
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Owe ${amt(l.owed)}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text(
                l.liquidatable ? 'liquidatable' : '${ratio.isFinite ? ratio.toStringAsFixed(0) : '∞'}% collateral',
                style: TextStyle(color: healthColor, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          RatioBar(ratioPercent: ratio, thresholdPercent: thresholdPct, liquidatable: l.liquidatable),
          const SizedBox(height: 10),
          row('Collateral ratio', '${ratio.isFinite ? ratio.toStringAsFixed(0) : '∞'}%', color: healthColor,
              note: 'liquidation opens under ${thresholdPct.toStringAsFixed(0)}%'),
          row('Borrowed', amt(l.loan), note: interest > 0 ? '+ ${amt(interest)} interest so far' : null),
          if (apr != null)
            row('Costing', '${(apr / 100).toStringAsFixed(2)}% a year',
                note: 'about ${_smallAmount(interestOver(owed: l.owed, aprBps: apr, days: 30), l.decimals, l.ticker)} a month at today\'s rate'),
          row('Collateral', _collateralText(l.pool, l.collateralAsset, l.collateralAmount),
              note: 'counts as ${amt(l.collateralValue)} · 1 $collateralTicker = ${price(priceNow)}'),
          row(
            'Liquidation price',
            '1 $collateralTicker = ${price(liqPrice)}',
            color: healthColor,
            note: l.liquidatable ? 'the price is below the line now' : 'a ${drop.toStringAsFixed(0)}% fall in $collateralTicker',
          ),
          row('Liquidation penalty', '${(l.penalty / 10).toStringAsFixed(0)}%',
              note: 'the liquidator\'s bonus on the debt, as Duckpools states it'),
          if (blocksLeft != null)
            row(
              'Called whatever the price',
              blocksLeft == 0 ? 'now' : 'in ${formatBlocksAsDuration(blocksLeft)}',
              note: blocksLeft == 0 ? null : 'about ${formatCalendarDate(blockDate(blocksLeft, DateTime.now()))}; repay or refinance before then',
            ),
          if (toSafe > 0)
            row('To reach ${(thresholdPct * 1.5).toStringAsFixed(0)}% collateral', 'add ${formatTokenAmountGrouped(toSafe, collateralDecimals)} $collateralTicker',
                note: 'at today\'s price, through Collateral below'),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('If $collateralTicker moves', style: TextStyle(color: muted, fontSize: 12)),
              Expanded(
                child: Slider(
                  key: Key('duck-whatif-${l.boxId}'),
                  value: _priceMove,
                  min: -60,
                  max: 30,
                  divisions: 18,
                  label: '${_priceMove >= 0 ? '+' : ''}${_priceMove.toStringAsFixed(0)}%',
                  onChanged: (v) => setState(() => _priceMove = v),
                ),
              ),
              Text(
                '${_priceMove >= 0 ? '+' : ''}${_priceMove.toStringAsFixed(0)}% → ${whatIf <= 10000 ? 'liquidatable' : '${ratioFromHealth(healthBps: whatIf, threshold: l.threshold).toStringAsFixed(0)}%'}',
                style: monoStyle(context, size: 12).copyWith(color: whatIfColor),
              ),
            ],
          ),
          Text('Loan ${shorten(l.boxId, head: 8, tail: 6)}', style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(onPressed: widget.onRepay, child: const Text('Repay')),
              OutlinedButton(onPressed: widget.onRepayPart, child: const Text('Repay part')),
              OutlinedButton(onPressed: widget.onAdjust, child: const Text('Collateral')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Green well above the line, orange near it, red at it: the same scale
/// the alerts use (130% watch, 115% danger).
Color healthColorFor(BuildContext context, int healthBps, {required bool liquidatable}) {
  final theme = Theme.of(context);
  if (liquidatable || healthBps < 11500) return theme.colorScheme.error;
  if (healthBps < 13000) return Colors.orange;
  return accentOf(context);
}

/// A loan's collateral ratio on a bar from the pool's threshold to
/// three times it, with the threshold and the alert ratios marked in
/// the same terms the site shows.
class RatioBar extends StatelessWidget {
  const RatioBar({super.key, required this.ratioPercent, required this.thresholdPercent, required this.liquidatable});
  final double ratioPercent;
  final double thresholdPercent;
  final bool liquidatable;

  double _pos(double ratio) => thresholdPercent <= 0 ? 0 : ((ratio - thresholdPercent) / (thresholdPercent * 2)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final healthBps = thresholdPercent <= 0 || !ratioPercent.isFinite ? 30000 : (ratioPercent / thresholdPercent * 10000).round();
    final color = healthColorFor(context, healthBps, liquidatable: liquidatable);
    final muted = ArgusColors.of(context).muted;
    final marks = [
      ('${thresholdPercent.toStringAsFixed(0)}%', thresholdPercent),
      ('${(thresholdPercent * 1.3).toStringAsFixed(0)}%', thresholdPercent * 1.3),
      ('${(thresholdPercent * 2).toStringAsFixed(0)}%', thresholdPercent * 2),
      ('${(thresholdPercent * 3).toStringAsFixed(0)}%', thresholdPercent * 3),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        return SizedBox(
          height: 24,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 4,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: LinearGradient(colors: [Theme.of(context).colorScheme.error, Colors.orange, accentOf(context)], stops: const [0, 0.15, 0.4]),
                  ),
                ),
              ),
              for (final (label, ratio) in marks)
                Positioned(
                  left: (w * _pos(ratio) - 16).clamp(0.0, w - 32),
                  top: 12,
                  child: SizedBox(width: 32, child: Text(label, textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 9))),
                ),
              Positioned(
                left: (w * _pos(ratioPercent.isFinite ? ratioPercent : thresholdPercent * 3) - 6).clamp(0.0, w - 12),
                top: 1,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: color, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// An amount that may round to nothing: "under 0.01 SigUSD" rather than
/// "0 SigUSD" for a small monthly interest.
String _smallAmount(int units, int decimals, String ticker) {
  if (units > 0) return '${formatTokenAmountGrouped(units, decimals)} $ticker';
  final unit = decimals == 0 ? '1' : '0.${'0' * (decimals - 1)}1';
  return 'under $unit $ticker';
}

/// "6 Dec" or "6 Dec 2027" for a date in another year.
String formatCalendarDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final now = DateTime.now();
  return '${d.day} ${months[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}';
}

int _collateralDecimals(String pool, String? asset) {
  if (asset == null) return 9;
  final c = duckpoolsService.marketFor(pool)?.collaterals.where((c) => c.asset == asset).firstOrNull;
  return c?.decimals ?? 0;
}

String _collateralTicker(String pool, String? asset) {
  if (asset == null) return 'ERG';
  final c = duckpoolsService.marketFor(pool)?.collaterals.where((c) => c.asset == asset).firstOrNull;
  return c?.ticker ?? shorten(asset);
}

/// "2 days" from a block count, two-minute blocks.
String formatBlocksAsDuration(int blocks) {
  final minutes = blocks * 2;
  if (minutes < 120) return '$minutes min';
  if (minutes < 60 * 48) return '${(minutes / 60).round()} h';
  return '${(minutes / 1440).round()} days';
}

/// Borrowing the way Duckpools' site frames it: how much to borrow, at
/// what collateral ratio, and the collateral that takes. The collateral
/// stays editable, and the ratio follows it.
class _BorrowSheet extends StatefulWidget {
  const _BorrowSheet({required this.state, required this.market, required this.spendableNano, required this.held});
  final DuckPoolState state;
  final DuckMarket market;
  final int spendableNano;

  /// Token id to amount held, for the ERG pool's collateral choice.
  final Map<String, int> held;

  @override
  State<_BorrowSheet> createState() => _BorrowSheetState();
}

class _BorrowSheetState extends State<_BorrowSheet> {
  final _loan = TextEditingController();
  final _collateral = TextEditingController();
  final _ratio = TextEditingController(text: '200');
  Map<String, dynamic>? _quote;
  String? _error;

  /// The chosen token collateral (ERG pool), or null for ERG.
  DuckMarketCollateral? _asset;

  bool get _ergPool => widget.state.pool == 'erg';
  List<DuckMarketCollateral> get _choices => widget.market.collaterals.where((c) => c.ready).toList();

  @override
  void initState() {
    super.initState();
    if (_ergPool) {
      final choices = _choices;
      _asset = choices.where((c) => (widget.held[c.asset] ?? 0) > 0).firstOrNull ?? choices.firstOrNull;
    }
  }

  @override
  void dispose() {
    _loan.dispose();
    _collateral.dispose();
    _ratio.dispose();
    super.dispose();
  }

  int get _collateralDecimals => _asset?.decimals ?? 9;
  String get _collateralTicker => _asset?.ticker ?? 'ERG';
  int? get _thresholdRaw => _asset?.threshold ?? widget.market.threshold;

  /// Loan-asset units one whole unit of collateral counts for.
  double? get _unitPrice {
    final unitValue = _asset == null ? widget.market.ergValue : _asset!.unitValueNano;
    if (unitValue == null) return null;
    // The market quotes 1 ERG in the loan asset, or 1 token in nanoERG.
    return unitValue.toDouble();
  }

  int? get _loanUnits => parseDuckAmount(_loan.text, widget.state.decimals);
  int? get _collateralUnits => parseDuckAmount(_collateral.text, _collateralDecimals);
  /// The typed ratio when it is a usable number: finite and positive.
  double? get _ratioPercent {
    final r = double.tryParse(_ratio.text.trim());
    return r != null && r.isFinite && r > 0 ? r : null;
  }

  /// What the wallet can lock: spendable ERG less room for the fees, or
  /// the token held.
  int get _available => _asset == null ? (widget.spendableNano - 10000000).clamp(0, 1 << 62) : (widget.held[_asset!.asset] ?? 0);

  void _setCollateralFromRatio() {
    final loan = _loanUnits;
    final ratio = _ratioPercent;
    final price = _unitPrice;
    if (loan == null || ratio == null || price == null) return;
    final units = collateralForRatio(loan: loan, ratioPercent: ratio, unitPrice: price, collateralDecimals: _collateralDecimals);
    _collateral.text = formatTokenAmount(units, _collateralDecimals).replaceAll(',', '');
  }

  void _setRatioFromCollateral() {
    final loan = _loanUnits;
    final c = _collateralUnits;
    final price = _unitPrice;
    if (loan == null || loan == 0 || c == null || price == null) return;
    final value = c / _pow10(_collateralDecimals) * price;
    _ratio.text = (value / loan * 100).toStringAsFixed(0);
  }

  void _pickRatio(double ratio) {
    _ratio.text = ratio.toStringAsFixed(0);
    _setCollateralFromRatio();
    _requote();
  }

  void _requote() {
    final c = _collateralUnits;
    final l = _loanUnits;
    setState(() {
      _quote = null;
      _error = null;
      if (c == null || l == null) return;
      final min = _thresholdRaw == null ? null : minimumRatioPercent(_thresholdRaw!);
      if (c > _available) {
        _error = _asset == null
            ? 'That needs ${formatErg(c)} of collateral; ${formatErg(_available)} is spendable after fees.'
            : 'That needs ${formatTokenAmountGrouped(c, _collateralDecimals)} $_collateralTicker; you hold ${formatTokenAmountGrouped(_available, _collateralDecimals)}.';
        return;
      }
      try {
        final q = duckpoolsService.loanQuote(
          poolKey: widget.state.pool,
          kind: 'borrow',
          amount: l,
          collateralAsset: _asset?.asset ?? '',
          collateralAmount: c,
        );
        // The ratio the quote would really open at (fees and price impact
        // in), not what the field says or the linear estimate.
        final opensAt = collateralRatioPercent(collateralValue: (q['collateral_value'] as num).toInt(), owed: l);
        if (min != null && opensAt < min) {
          _error = 'This opens at ${opensAt.toStringAsFixed(0)}%; open at ${min.toStringAsFixed(0)}% or more, since the threshold is '
              '${(_thresholdRaw! / 10).toStringAsFixed(0)}% and the price can move before the fill.';
          return;
        }
        _quote = q;
      } catch (e) {
        _error = e.toString().replaceFirst('Bad state: ', '');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final m = widget.market;
    final muted = ArgusColors.of(context).muted;
    final threshold = _thresholdRaw;
    final thresholdPct = threshold == null ? null : threshold / 10;
    final minRatio = threshold == null ? null : minimumRatioPercent(threshold);
    final price = _unitPrice;
    final q = _quote;
    final ratio = _ratioPercent;
    // The most the available collateral could borrow at the chosen ratio:
    // the rounding that sizes the collateral must not tip it past what is
    // available, so the candidate steps down until it fits.
    int? maxLoan;
    if (price != null && ratio != null) {
      var candidate = (_available / _pow10(_collateralDecimals) * price / (ratio / 100)).floor();
      for (var i = 0; i < 4 && candidate > 0; i++) {
        if (collateralForRatio(loan: candidate, ratioPercent: ratio, unitPrice: price, collateralDecimals: _collateralDecimals) <= _available) break;
        candidate -= 1;
      }
      maxLoan = candidate > 0 ? candidate : null;
    }
    String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), s.decimals)} ${s.ticker}';
    final priceText = _asset == null
        ? '1 ERG counts as ${amt(m.ergValue ?? 0)}'
        : '1 ${_asset!.ticker} counts as ${formatErg(_asset!.unitValueNano ?? 0)}';
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_ergPool ? 'Borrow ERG against a token' : 'Borrow ${s.ticker} against ERG', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Liquidation opens when the collateral is worth less than ${thresholdPct?.toStringAsFixed(0) ?? '?'}% of the debt · '
              'penalty ${((_asset?.penalty ?? m.penalty ?? 0) / 10).toStringAsFixed(0)}% · $priceText',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (_ergPool) ...[
              DropdownButtonFormField<String>(
                key: const Key('duck-collateral-asset'),
                initialValue: _asset?.asset,
                decoration: const InputDecoration(labelText: 'Collateral'),
                items: [
                  for (final ch in _choices)
                    DropdownMenuItem(
                      value: ch.asset,
                      child: Text('${ch.ticker} · threshold ${(ch.threshold! / 10).toStringAsFixed(0)}%'),
                    ),
                ],
                onChanged: (v) {
                  setState(() => _asset = _choices.firstWhere((ch) => ch.asset == v));
                  _setCollateralFromRatio();
                  _requote();
                },
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('duck-loan'),
              controller: _loan,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '${s.ticker} to borrow',
                helperText: maxLoan == null
                    ? 'The pool holds ${amt(s.pooled)}${_ergPool ? ' · at least 0.05 ERG' : ''}'
                    : 'Up to ${amt(maxLoan)} with what you can lock at ${ratio!.toStringAsFixed(0)}% · pool holds ${amt(s.pooled)}',
                suffixIcon: maxLoan == null || maxLoan <= 0
                    ? null
                    : TextButton(
                        onPressed: () {
                          _loan.text = formatTokenAmount(maxLoan!, s.decimals).replaceAll(',', '');
                          _setCollateralFromRatio();
                          _requote();
                        },
                        child: const Text('Max'),
                      ),
              ),
              onChanged: (_) {
                _setCollateralFromRatio();
                _requote();
              },
            ),
            const SizedBox(height: 12),
            Text('Collateral ratio', style: TextStyle(color: muted, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final r in [if (minRatio != null) minRatio, 200.0, 300.0])
                  ChoiceChip(
                    label: Text(r == minRatio ? 'Minimum ${r.toStringAsFixed(0)}%' : '${r.toStringAsFixed(0)}%'),
                    selected: ratio == r,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => _pickRatio(r),
                  ),
                SizedBox(
                  width: 96,
                  child: TextField(
                    key: const Key('duck-ratio'),
                    controller: _ratio,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true, suffixText: '%', labelText: 'Custom'),
                    onChanged: (_) {
                      _setCollateralFromRatio();
                      _requote();
                    },
                  ),
                ),
              ],
            ),
            if (thresholdPct != null && ratio != null && ratio > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'At ${ratio.toStringAsFixed(0)}% the price can fall ${((1 - thresholdPct / ratio) * 100).clamp(0, 100).toStringAsFixed(0)}% before liquidation.',
                  style: TextStyle(color: muted, fontSize: 11.5),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('duck-collateral'),
              controller: _collateral,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '$_collateralTicker to lock',
                helperText: _asset == null
                    ? 'Spendable ${formatErg(widget.spendableNano)} · about 0.01 ERG stays for fees'
                    : 'You hold ${formatTokenAmountGrouped(widget.held[_asset!.asset] ?? 0, _asset!.decimals)} ${_asset!.ticker}',
              ),
              onChanged: (_) {
                _setRatioFromCollateral();
                _requote();
              },
            ),
            const SizedBox(height: 12),
            if (_error != null) SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            if (q != null) _BorrowFigures(quote: q, state: s, collateralTicker: _collateralTicker, collateralDecimals: _collateralDecimals, ergPool: _ergPool),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('duck-borrow-continue'),
              onPressed: q == null ? null : () => Navigator.pop(context, (_asset?.asset ?? '', _collateralUnits!, _loanUnits!)),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the quote means to the borrower: health, the liquidation price,
/// the fall that reaches it, the interest, and the clock.
class _BorrowFigures extends StatelessWidget {
  const _BorrowFigures({required this.quote, required this.state, required this.collateralTicker, required this.collateralDecimals, required this.ergPool});
  final Map<String, dynamic> quote;
  final DuckPoolState state;
  final String collateralTicker;
  final int collateralDecimals;
  final bool ergPool;

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final q = quote;
    final s = state;
    String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), s.decimals)} ${s.ticker}';
    final healthBps = (q['health_bps'] as num).toInt();
    final loan = (q['loan'] as num).toInt();
    final collateralValue = (q['collateral_value'] as num).toInt();
    final collateralAmount = (q['collateral_amount'] as num).toInt();
    final threshold = (q['threshold'] as num).toInt();
    final penalty = (q['penalty'] as num).toInt();
    final liquidationValue = (loan * threshold / 1000).ceil();
    final liqPrice = liquidationUnitPrice(liquidationValue: liquidationValue, collateralAmount: collateralAmount, collateralDecimals: collateralDecimals);
    final priceNow = collateralUnitPrice(collateralValue: collateralValue, collateralAmount: collateralAmount, collateralDecimals: collateralDecimals);
    final drop = dropToLiquidationPercent(collateralValue: collateralValue, liquidationValue: liquidationValue);
    final apr = s.borrowAprBps;
    final color = healthColorFor(context, healthBps, liquidatable: healthBps <= 10000);
    Widget row(String label, String value, {Color? valueColor}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
              Text(value, style: monoStyle(context, size: 12.5).copyWith(color: valueColor)),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RatioBar(ratioPercent: collateralRatioPercent(collateralValue: collateralValue, owed: loan), thresholdPercent: threshold / 10, liquidatable: healthBps <= 10000),
        const SizedBox(height: 6),
        row('Collateral ratio at open', '${collateralRatioPercent(collateralValue: collateralValue, owed: loan).toStringAsFixed(0)}%', valueColor: color),
        row('Liquidation threshold', '${(threshold / 10).toStringAsFixed(0)}%'),
        row('Collateral counts as', amt(collateralValue)),
        row('1 $collateralTicker now', amt(priceNow.round())),
        row('Liquidation price', amt(liqPrice.round()), valueColor: color),
        row('Room before liquidation', 'a ${drop.toStringAsFixed(0)}% fall in $collateralTicker', valueColor: color),
        row('Liquidation penalty', '${(penalty / 10).toStringAsFixed(0)}%, as Duckpools states it'),
        if (apr != null) ...[
          row('Interest at today\'s rate', '${(apr / 100).toStringAsFixed(2)}% a year'),
          row('About', '${_smallAmount(interestOver(owed: loan, aprBps: apr, days: 30), s.decimals, s.ticker)} a month · ${_smallAmount(interestOver(owed: loan, aprBps: apr, days: 365), s.decimals, s.ticker)} a year'),
        ],
        row('Called whatever the price', 'about ${formatCalendarDate(blockDate(forcedLiquidationBlocks, DateTime.now()))}'),
        const SizedBox(height: 4),
        Text(
          'Interest compounds every 120 blocks at the pool\'s rate, which moves with utilisation. '
          'Plus ${ergPool ? '0.006' : '0.002'} ERG for the collateral box, the bot and the fill, the Argus fee and the miner fee.',
          style: TextStyle(color: muted, fontSize: 11.5),
        ),
      ],
    );
  }
}

int _pow10(int n) {
  var v = 1;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

/// Amount entry for a partial repayment.
class _PartialRepaySheet extends StatefulWidget {
  const _PartialRepaySheet({required this.loan, required this.held});
  final DuckLoan loan;
  final int held;

  @override
  State<_PartialRepaySheet> createState() => _PartialRepaySheetState();
}

class _PartialRepaySheetState extends State<_PartialRepaySheet> {
  final _ctl = TextEditingController();
  Map<String, dynamic>? _quote;
  String? _error;

  int? get _units => parseDuckAmount(_ctl.text, widget.loan.decimals);

  void _requote() {
    final units = _units;
    setState(() {
      _quote = null;
      _error = null;
      if (units == null) return;
      try {
        _quote = duckpoolsService.loanQuote(
          poolKey: widget.loan.pool,
          kind: 'partial_repay',
          amount: units,
          collateralBoxId: widget.loan.boxId,
        );
      } catch (e) {
        _error = e.toString().replaceFirst('Bad state: ', '');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.loan;
    final muted = ArgusColors.of(context).muted;
    String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), l.decimals)} ${l.ticker}';
    final q = _quote;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Repay part of the loan', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('duck-repay-amount'),
            controller: _ctl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '${l.ticker} to repay',
              helperText: 'Owed ${amt(l.owed)} · you hold ${amt(widget.held)}. To clear it all, use Repay.',
            ),
            onChanged: (_) => _requote(),
          ),
          const SizedBox(height: 12),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          if (q != null)
            Text(
              'Owed after: about ${amt(q['owed_after'] as num)}. The collateral stays where it is. '
              'Plus ${l.collateralAsset == null ? '0.003 ERG for the bot and the fill' : '0.002 ERG on top of the repayment for the bot and the fill'}, the Argus fee and the miner fee.',
              style: TextStyle(color: muted, fontSize: 12.5),
            ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('duck-repay-continue'),
            onPressed: q == null ? null : () => Navigator.pop(context, _units),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}

/// New collateral amount for a loan, with the health it would give.
class _AdjustSheet extends StatefulWidget {
  const _AdjustSheet({required this.loan, required this.ticker, required this.decimals, required this.held});
  final DuckLoan loan;
  final String ticker;
  final int decimals;

  /// What the wallet holds of the collateral asset, for adding.
  final int held;

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  late final TextEditingController _ctl;
  Map<String, dynamic>? _quote;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: formatTokenAmount(widget.loan.collateralAmount, widget.decimals));
  }

  int? get _units => parseDuckAmount(_ctl.text, widget.decimals);

  void _requote() {
    final units = _units;
    setState(() {
      _quote = null;
      _error = null;
      if (units == null) return;
      try {
        _quote = duckpoolsService.adjustQuote(poolKey: widget.loan.pool, collateralBoxId: widget.loan.boxId, newAmount: units);
      } catch (e) {
        _error = e.toString().replaceFirst('Bad state: ', '');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.loan;
    final muted = ArgusColors.of(context).muted;
    String c(num units) => '${formatTokenAmountGrouped(units.toInt(), widget.decimals)} ${widget.ticker}';
    final q = _quote;
    final delta = q == null ? 0 : (q['delta'] as num).toInt();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Change the collateral', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Now ${c(l.collateralAmount)} backs ${formatTokenAmountGrouped(l.owed, l.decimals)} ${l.ticker} '
              'at ${(l.healthBps / 100).toStringAsFixed(0)}% health. You hold ${c(widget.held)} to add.',
              style: TextStyle(color: muted, fontSize: 12.5)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('duck-adjust-amount'),
            controller: _ctl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '${widget.ticker} to keep as collateral',
              helperText: 'More makes the loan safer; less comes back to the wallet.',
            ),
            onChanged: (_) => _requote(),
          ),
          const SizedBox(height: 12),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          if (q != null)
            Text(
              '${delta > 0 ? 'Add ${c(delta)}' : 'Take out ${c(-delta)}'} · health after '
              '${((q['health_after_bps'] as num) / 100).toStringAsFixed(0)}% · the least allowed right now is ${c(q['min_amount'] as num)}. '
              'Plus the miner fee; no bot fee.',
              style: TextStyle(color: muted, fontSize: 12.5),
            ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('duck-adjust-continue'),
            onPressed: q == null ? null : () => Navigator.pop(context, _units),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}
