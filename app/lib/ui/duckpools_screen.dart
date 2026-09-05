import 'package:flutter/material.dart';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../format.dart';
import '../services/network_controller.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/error_sheet.dart';
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

  /// Borrow from a token pool against ERG: collateral and loan sheet,
  /// quote, confirm, broadcast, record.
  Future<void> _borrow(DuckPoolState s) async {
    if (_working) return;
    final args = WalletRouteArgs.of(context);
    final market = duckpoolsService.marketFor(s.pool);
    if (market == null || !market.ready) return;
    final picked = await showModalBottomSheet<(int, int)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (_) => _BorrowSheet(state: s, market: market, spendableNano: args.spendableNano ?? 0),
    );
    if (picked == null || !mounted) return;
    final (collateralNano, loan) = picked;
    setState(() => _working = true);
    try {
      final prepared = await duckpoolsService.prepareOrder(
        poolKey: s.pool,
        kind: 'borrow',
        amount: loan,
        collateralNano: collateralNano,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
      );
      if (!mounted) return;
      final q = (prepared['quote'] as Map).cast<String, dynamic>();
      String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), s.decimals)} ${s.ticker}';
      await _post(prepared, title: 'Post a borrow order', rows: [
        ConfirmTxRow('Borrow', amt(q['loan'] as num), bold: true),
        ConfirmTxRow('Collateral', formatErg((q['collateral_nano'] as num).toInt()), bold: true),
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
    final args = WalletRouteArgs.of(context);
    final held = args.tokens
        .where((t) => t.id == duckpoolsService.pools.firstWhere((p) => p.key == l.pool).currencyId)
        .fold<int>(0, (a, t) => a + t.amount);
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
      final rows = partial
          ? [
              ConfirmTxRow('Repay', amt(q['repayment'] as num), bold: true),
              ConfirmTxRow('Owed now', amt(l.owed)),
              ConfirmTxRow('Owed after', amt(q['owed_after'] as num)),
              ConfirmTxRow('Collateral stays', formatErg(l.collateralNano)),
            ]
          : [
              ConfirmTxRow('Repay', amt(q['repayment'] as num), bold: true),
              ConfirmTxRow('Owed now', amt(q['owed_now'] as num)),
              ConfirmTxRow('Covers interest until filled', 'yes; the rest stays with the pool'),
              ConfirmTxRow('Collateral back', formatErg((q['collateral_nano'] as num).toInt()), bold: true),
            ];
      // The repayment rides as tokens, so the box's ERG is all fees.
      rows.add(ConfirmTxRow('Bot fee + fill fee', formatErg((q['box_value'] as num).toInt())));
      await _post(prepared, title: partial ? 'Post a partial repayment' : 'Post a repayment', rows: rows);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not post the order', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Lend into, or withdraw from, one pool: amount sheet, quote, confirm,
  /// broadcast, record.
  Future<void> _order(DuckPoolState s, String kind) async {
    if (_working) return;
    final args = WalletRouteArgs.of(context);
    final svc = duckpoolsService;
    final holdingTokens = s.walletLendTokens;
    final amount = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (_) => _OrderSheet(state: s, kind: kind, maxLendTokens: holdingTokens),
    );
    if (amount == null || !mounted) return;
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
                if (svc.loans.isNotEmpty) ...[
                  const SectionLabel('Your loans'),
                  const SizedBox(height: 8),
                  for (final l in svc.loans) ...[
                    _LoanCard(
                      loan: l,
                      onRepay: _working ? null : () => _repay(l, partial: false),
                      onRepayPart: _working ? null : () => _repay(l, partial: true),
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
  const _PoolCard({required this.state, required this.position, this.market, this.onLend, this.onWithdraw, this.onBorrow});

  final DuckPoolState state;
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
          if (market != null && market!.ready) ...[
            row('1 ERG collateral counts as', '${amt(market!.ergValue!)} ${s.ticker}'),
            row('Liquidation line', '${(market!.threshold! / 10).toStringAsFixed(0)}% · penalty ${(market!.penalty! / 10).toStringAsFixed(0)}%'),
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
          '${o.collateralNano != null ? ' against ${formatErg(o.collateralNano!)}' : ''}',
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


/// One loan: what it owes, what backs it, how close to the line it is.
class _LoanCard extends StatelessWidget {
  const _LoanCard({required this.loan, this.onRepay, this.onRepayPart});

  final DuckLoan loan;
  final VoidCallback? onRepay;
  final VoidCallback? onRepayPart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final l = loan;
    String amt(int units) => '${formatTokenAmountGrouped(units, l.decimals)} ${l.ticker}';
    final health = l.healthBps / 100;
    final healthColor = l.liquidatable || health < 110
        ? theme.colorScheme.error
        : health < 130
            ? Colors.orange
            : accentOf(context);
    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
              Text(value, style: monoStyle(context, size: 12.5).copyWith(color: color)),
            ],
          ),
        );
    final height = networkController.height;
    final blocksLeft = height == null ? null : (l.forcedLiquidationHeight - height).clamp(0, 1 << 30);
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
                l.liquidatable ? 'liquidatable' : '${health.toStringAsFixed(0)}% health',
                style: TextStyle(color: healthColor, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          row('Borrowed', amt(l.loan)),
          row('Collateral', formatErg(l.collateralNano)),
          row('Counts as', amt(l.collateralValue)),
          row('Liquidation below', amt(l.liquidationValue), color: healthColor),
          row('Collateral over debt', '${l.ratioPercent.toStringAsFixed(0)}% (line ${(l.threshold / 10).toStringAsFixed(0)}%)'),
          if (blocksLeft != null)
            row('Forced liquidation', blocksLeft == 0 ? 'now' : 'in ${formatBlocksAsDuration(blocksLeft)}'),
          const SizedBox(height: 4),
          Text('Loan ${shorten(l.boxId, head: 8, tail: 6)}', style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(onPressed: onRepay, child: const Text('Repay')),
              OutlinedButton(onPressed: onRepayPart, child: const Text('Repay part')),
            ],
          ),
        ],
      ),
    );
  }
}

/// "2 days" from a block count, two-minute blocks.
String formatBlocksAsDuration(int blocks) {
  final minutes = blocks * 2;
  if (minutes < 120) return '$minutes min';
  if (minutes < 60 * 48) return '${(minutes / 60).round()} h';
  return '${(minutes / 1440).round()} days';
}

/// Collateral and loan entry for a borrow, with the quote shown live.
class _BorrowSheet extends StatefulWidget {
  const _BorrowSheet({required this.state, required this.market, required this.spendableNano});
  final DuckPoolState state;
  final DuckMarket market;
  final int spendableNano;

  @override
  State<_BorrowSheet> createState() => _BorrowSheetState();
}

class _BorrowSheetState extends State<_BorrowSheet> {
  final _collateral = TextEditingController();
  final _loan = TextEditingController();
  Map<String, dynamic>? _quote;
  String? _error;

  int? _parse(TextEditingController c, int decimals) => parseDuckAmount(c.text, decimals);

  int? get _collateralNano => _parse(_collateral, 9);
  int? get _loanUnits => _parse(_loan, widget.state.decimals);

  void _requote() {
    final c = _collateralNano;
    final l = _loanUnits;
    setState(() {
      _quote = null;
      _error = null;
      if (c == null || l == null) return;
      try {
        _quote = duckpoolsService.loanQuote(poolKey: widget.state.pool, kind: 'borrow', amount: l, collateralNano: c);
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
    String amt(num units) => '${formatTokenAmountGrouped(units.toInt(), s.decimals)} ${s.ticker}';
    final q = _quote;
    final c = _collateralNano;
    // What this much collateral could borrow at most, before the quote
    // says so exactly.
    final roughMax = c == null || m.ergValue == null || m.threshold == null
        ? null
        : (c / 1000000000 * m.ergValue! * 1000 / m.threshold!).floor();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Borrow ${s.ticker} against ERG', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('duck-collateral'),
            controller: _collateral,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'ERG to lock as collateral',
              helperText: 'Spendable ${formatErg(widget.spendableNano)} · 1 ERG counts as ${amt(m.ergValue ?? 0)}',
            ),
            onChanged: (_) => _requote(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('duck-loan'),
            controller: _loan,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '${s.ticker} to borrow',
              helperText: roughMax == null
                  ? 'The pool holds ${amt(s.pooled)}'
                  : 'Up to about ${amt(roughMax)} at the ${(m.threshold! / 10).toStringAsFixed(0)}% line; less is safer',
            ),
            onChanged: (_) => _requote(),
          ),
          const SizedBox(height: 12),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          if (q != null) ...[
            Text(
              'Collateral counts as ${amt(q['collateral_value'] as num)} · health at open '
              '${((q['health_bps'] as num) / 100).toStringAsFixed(0)}% · liquidated below 100%',
              style: TextStyle(color: muted, fontSize: 12.5),
            ),
            const SizedBox(height: 4),
            Text('Interest compounds every 120 blocks at the pool\'s rate. The loan is called '
                'after about ${formatBlocksAsDuration(65520)} whatever the price does. '
                'Plus 0.002 ERG for the bot and the fill, the Argus fee and the miner fee.',
                style: TextStyle(color: muted, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('duck-borrow-continue'),
            onPressed: q == null ? null : () => Navigator.pop(context, (_collateralNano!, _loanUnits!)),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }
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
              'Plus 0.003 ERG for the bot and the fill, the Argus fee and the miner fee.',
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
