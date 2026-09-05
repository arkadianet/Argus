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

/// Duckpools lending: the pools as they are, and what this wallet lends.
/// Read-only for now; lending and withdrawing are the next step.
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
    await duckpoolsService.refresh(_holdings(context));
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
                  'Borrowers lock ERG as collateral. Argus reads the pools and values '
                  'the lend tokens you already hold; lending from here is the next step.',
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
                      onLend: _working ? null : () => _order(s, 'lend'),
                      onWithdraw: s.hasPosition && !_working ? () => _order(s, 'withdraw') : null,
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
  const _PoolCard({required this.state, required this.position, this.onLend, this.onWithdraw});

  final DuckPoolState state;
  final bool position;
  final VoidCallback? onLend;
  final VoidCallback? onWithdraw;

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
      'filled' => o.kind == 'lend'
          ? 'Filled: ${o.received == null ? 'lend tokens received' : '${formatTokenAmountGrouped(o.received!, o.decimals)} lend tokens received'}'
          : 'Filled: ${o.received == null ? 'paid out' : '${formatErg(o.received!)} paid out'}',
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
    final what = o.kind == 'lend'
        ? 'Lend ${formatTokenAmountGrouped(o.amount, o.decimals)} ${o.ticker}'
        : 'Withdraw ${formatTokenAmountGrouped(o.amount, o.decimals)} lend tokens (${o.ticker})';
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
