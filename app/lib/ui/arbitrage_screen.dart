import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/amm_service.dart';
import '../services/arbitrage_service.dart';
import '../services/verified_tokens.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/empty_state.dart';
import 'widgets/error_sheet.dart';
import 'widgets/soft_card.dart';
import 'widgets/tx_result_view.dart';

/// Circular arbitrage across Spectrum pools. Opt-in: it only scans while
/// this screen is open and in front, and signs nothing without a review of
/// the whole chain.
class ArbitrageScreen extends StatefulWidget {
  const ArbitrageScreen({super.key, this.service, this.names});

  /// Injected by tests; the app uses [arbitrageService].
  final ArbitrageService? service;

  /// Token names and decimals; the app reads the cached pool set.
  final AmmPoolSet? names;

  @override
  State<ArbitrageScreen> createState() => _ArbitrageScreenState();
}

/// What the user reads instead of an error code.
String arbErrorText(Object e) {
  final ex = e is ArgusException ? e : (e is String ? ArgusException.fromJson(e) : null);
  final msg = ex?.message ?? e.toString();
  if (msg.contains('NOT_PROFITABLE')) {
    return 'The gap closed: at current prices this route no longer clears your minimum profit.';
  }
  if (msg.contains('POOL_BUSY')) {
    return 'Someone is already trading a pool on this route; their transaction is in the mempool. Try again after the next block.';
  }
  if (msg.contains('POOL_MOVED')) return 'A pool on this route has changed since the scan. Scan again.';
  if (msg.contains('NOT_ENOUGH_ERG')) {
    return 'This wallet does not hold enough ERG for the whole chain: every leg pays its own fees on top of the amount traded.';
  }
  if (msg.contains('EXTRA_INDEX_REQUIRED')) {
    return 'Your node has no extra index, so Spectrum pools cannot be read. Choose a node with extraIndex enabled in settings.';
  }
  if (msg.contains('REVIEW_EXPIRED')) return 'That review is more than five minutes old. Review the trade again.';
  if (msg.contains('NO_EXIT')) return 'No ERG pool buys this token right now. Try the Swap screen later.';
  if (msg.contains('WALLET_LOCKED') || ex?.isWalletLocked == true) return 'Unlock the wallet to sign.';
  return msg;
}

class _ArbitrageScreenState extends State<ArbitrageScreen> with WidgetsBindingObserver, TxReceiptOwner {
  late final ArbitrageService _service = widget.service ?? arbitrageService;
  late final ArbitrageScanner _scanner = ArbitrageScanner(scan: _scan);
  int _minProfitNano = arbDefaultMinProfitNano;
  bool _includeUntrusted = false;
  AmmPoolSet? _names;
  bool _ready = false;

  WalletRouteArgs get _args => WalletRouteArgs.of(context);

  List<String> get _spendAddresses {
    final args = _args;
    return args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
  }

  String get _changeAddress => _args.changeAddress.isNotEmpty ? _args.changeAddress : _args.receiveAddress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _names = widget.names;
    _load();
  }

  Future<void> _load() async {
    final minProfit = await _service.loadMinProfit();
    final names = _names ?? await ammService.cachedPools().catchError((_) => null);
    if (!mounted) return;
    setState(() {
      _minProfitNano = minProfit;
      _names = names;
      _ready = true;
    });
    _scanner.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never scan behind the user's back: only while this screen is in front.
    if (state == AppLifecycleState.resumed) {
      if (_ready) _scanner.start();
    } else {
      _scanner.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanner.dispose();
    super.dispose();
  }

  Future<ArbScanResult> _scan() => _service.scan(
        minProfitNano: _minProfitNano,
        includeUntrusted: _includeUntrusted,
        availableNano: _args.spendableNano,
      );

  String _symbol(String? id) {
    if (id == null) return 'ERG';
    return knownToken(id)?.ticker ?? _names?.tokens[id]?.name ?? '${id.substring(0, 8)}…';
  }

  int _decimals(String? id) {
    if (id == null) return 9;
    return knownToken(id)?.decimals ?? _names?.tokens[id]?.decimals ?? 0;
  }

  String _amount(int amount, String? id) =>
      '${id == null ? formatErg(amount, maxFrac: 4, unit: false) : formatTokenAmountGrouped(amount, _decimals(id))} ${_symbol(id)}';

  String _route(ArbOpportunity o) =>
      [_symbol(o.legs.first.fromTokenId), for (final l in o.legs) _symbol(l.toTokenId)].join(' → ');

  Future<void> _editMinProfit() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => _MinProfitDialog(initialNano: _minProfitNano),
    );
    if (picked == null || picked < 0 || !mounted) return;
    setState(() => _minProfitNano = picked);
    await _service.saveMinProfit(picked);
    _scanner.refresh();
  }

  void _setIncludeUntrusted(bool v) {
    setState(() => _includeUntrusted = v);
    _scanner.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Arbitrage')),
      body: ListenableBuilder(
        listenable: _scanner,
        builder: (context, _) => RefreshIndicator(
          onRefresh: _scanner.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              _intro(context),
              const SizedBox(height: 16),
              _settings(context),
              const SizedBox(height: 12),
              _statusLine(context),
              const SizedBox(height: 12),
              ..._results(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final colors = ArgusColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pools sometimes disagree on a price. This finds round trips from ERG through them that '
          'pay back more ERG than they cost: pool fees, plus a miner fee and the Argus fee for every leg. '
          'Scans run only while this screen is open.',
          style: TextStyle(color: colors.muted, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 12),
        Container(
          key: const Key('arb-warning'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: rust.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: rust.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.bolt, size: 18, color: rustFor(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Bots trade these gaps around the clock and usually get there first. A quote here is '
                  'seconds old, and every leg is its own transaction: if someone trades one of these pools '
                  'before your next leg lands, that leg fails and you keep the token instead of ERG.',
                  style: TextStyle(fontSize: 13, height: 1.4, color: rustFor(context)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settings(BuildContext context) {
    final colors = ArgusColors.of(context);
    return SoftCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            ListTile(
              key: const Key('arb-min-profit-row'),
              title: const Text('Minimum profit'),
              subtitle: Text('After pool, miner and Argus fees', style: TextStyle(color: colors.muted, fontSize: 12.5)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatErg(_minProfitNano, maxFrac: 4), style: const TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(width: 4),
                  const Icon(Icons.edit_outlined, size: 16),
                ],
              ),
              onTap: _editMinProfit,
            ),
            const Divider(height: 1, indent: 16),
            SwitchListTile(
              key: const Key('arb-untrusted'),
              value: _includeUntrusted,
              onChanged: _setIncludeUntrusted,
              title: const Text('Include unverified tokens'),
              subtitle: Text(
                _includeUntrusted
                    ? 'A failed leg can leave you with a token nobody will buy back.'
                    : 'Routes only through tokens on the verified list.',
                style: TextStyle(color: _includeUntrusted ? rustFor(context) : colors.muted, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine(BuildContext context) {
    final colors = ArgusColors.of(context);
    final r = _scanner.result;
    final parts = <String>[
      if (r != null) '${r.poolsInGraph} of ${r.poolCount} pools deep enough',
      if (r != null) '${r.cyclesChecked} routes checked',
      if (r != null) 'scanned ${formatRelativeTime(r.scannedAt).toLowerCase()}',
      if (r == null && _scanner.scanning) 'Reading every pool from your node…',
    ];
    return Row(
      children: [
        Expanded(
          child: Text(
            parts.join(' · '),
            key: const Key('arb-status'),
            style: TextStyle(color: colors.muted, fontSize: 12.5),
          ),
        ),
        if (_scanner.scanning)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else
          IconButton(
            key: const Key('arb-rescan'),
            tooltip: 'Scan again',
            icon: const Icon(Icons.refresh),
            onPressed: _scanner.refresh,
          ),
      ],
    );
  }

  List<Widget> _results(BuildContext context) {
    final r = _scanner.result;
    final error = _scanner.error;
    if (error != null && r == null) {
      return [
        EmptyState(
          compact: true,
          tone: EmptyStateTone.error,
          icon: Icons.cloud_off_outlined,
          title: 'Could not read the pools',
          body: arbErrorText(error),
          actionLabel: 'Try again',
          onAction: _scanner.refresh,
        ),
      ];
    }
    if (r == null) return const [];
    final notes = <String>[
      if (r.skippedBusy > 0)
        '${r.skippedBusy} left out: a pool on the route is already being traded in the mempool.',
      if (r.skippedUntrusted > 0)
        '${r.skippedUntrusted} left out: they pass through unverified tokens.',
      if (!r.mempoolChecked) 'The mempool could not be read, so pools already being traded are not ruled out.',
      if (r.truncated) 'Your node returned the most pools it will list; some may be missing.',
    ];
    final muted = ArgusColors.of(context).muted;
    return [
      if (r.opportunities.isEmpty)
        SoftCard(
          child: EmptyState(
            compact: true,
            icon: Icons.balance_outlined,
            title: 'No gap worth taking',
            body: 'No route clears ${formatErg(_minProfitNano, maxFrac: 4)} after fees right now. '
                'Prices across these pools agree to within their fees, which is usual: bots close gaps within a block.',
          ),
        )
      else
        for (final o in r.opportunities) ...[
          _OpportunityCard(
            key: Key('arb-opp-${o.key}'),
            route: _route(o),
            opportunity: o,
            amount: _amount,
            onTap: () => _review(o),
          ),
          const SizedBox(height: 10),
        ],
      for (final n in notes)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(n, style: TextStyle(color: muted, fontSize: 12.5, height: 1.35)),
        ),
    ];
  }

  Future<void> _review(ArbOpportunity o) async {
    // No scans while the user reads and signs: the chain re-reads its own
    // pools, and the node has enough to do.
    _scanner.pause();
    final outcome = await showModalBottomSheet<(int, ArbExecution)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (ctx) => _ReviewSheet(
        prepare: () => _service.prepare(
          o,
          minProfitNano: _minProfitNano,
          availableNano: _args.spendableNano,
          spendAddresses: _spendAddresses,
          changeAddress: _changeAddress,
        ),
        execute: _service.execute,
        discard: _service.discard,
        watchOnly: _args.watchOnly,
        route: _route(o),
        symbol: _symbol,
        amount: _amount,
      ),
    );
    if (!mounted) return;
    if (outcome == null) {
      _scanner.start();
      return;
    }
    final (chainId, result) = outcome;
    switch (result.status) {
      case ArbExecutionStatus.moved:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A pool moved before signing; nothing was signed. Here are the fresh numbers.')),
        );
        await _review(o);
      case ArbExecutionStatus.rejected:
        await showErrorSheet(
          context,
          title: 'Nothing changed',
          message: 'The first leg was rejected, so no transaction went out.\n\n${result.error ?? ''}',
        );
        if (mounted) _scanner.start();
      case ArbExecutionStatus.submitted:
      case ArbExecutionStatus.stranded:
        await _track(chainId, o, result);
        if (mounted) _scanner.start();
    }
  }

  Future<void> _track(int chainId, ArbOpportunity o, ArbExecution execution) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (ctx) => _ChainSheet(
        chainId: chainId,
        legs: o.legs.length,
        execution: execution,
        status: _service.status,
        symbol: _symbol,
        amount: _amount,
        unwind: (holding) => _unwind(chainId, holding),
      ),
    );
  }

  Future<void> _unwind(int chainId, ArbHolding holding) async {
    try {
      final u = await _service.prepareUnwind(chainId);
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        preparationId: u.preparationId,
        title: 'Sell ${_symbol(u.tokenId)} back to ERG',
        rows: [
          ConfirmTxRow('You sell', _amount(u.inputAmount, u.tokenId)),
          ConfirmTxRow('You receive', formatErg(u.outputNano, maxFrac: 6), bold: true),
          ConfirmTxRow('Price impact', '${u.priceImpactPct.toStringAsFixed(2)}%'),
          ConfirmTxRow('Miner fee', formatErg(u.minerFeeNano)),
          ConfirmTxRow('Argus fee', formatErg(u.appFeeNano)),
        ],
        detail: 'Quoted against the pool as it is now. A direct Spectrum swap: it fills at exactly this amount or not at all.',
        confirmLabel: 'Sign & broadcast sale',
      );
      if (!ok) return;
      final txId = await walletService.sendErg(preparationId: u.preparationId);
      showTxResultSheet(receiptContext, txId: txId, headline: 'Sale submitted');
    } catch (e) {
      if (!mounted) return;
      showErrorSheet(context, title: 'Could not prepare the sale', message: arbErrorText(e));
    }
  }
}

/// Owns its text controller, so the dialog's closing animation never
/// rebuilds a field whose controller is already gone.
class _MinProfitDialog extends StatefulWidget {
  const _MinProfitDialog({required this.initialNano});

  final int initialNano;

  @override
  State<_MinProfitDialog> createState() => _MinProfitDialogState();
}

class _MinProfitDialogState extends State<_MinProfitDialog> {
  late final _controller = TextEditingController(text: formatErg(widget.initialNano, unit: false));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Minimum profit'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Only routes that clear this after every fee are shown, and a trade is refused if it no longer does when you sign.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('arb-min-profit'),
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(suffixText: 'ERG'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, parseDecimalToBase(_controller.text, 9)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _OpportunityCard extends StatelessWidget {
  const _OpportunityCard({super.key, required this.route, required this.opportunity, required this.amount, required this.onTap});

  final String route;
  final ArbOpportunity opportunity;
  final String Function(int amount, String? tokenId) amount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final o = opportunity;
    final colors = ArgusColors.of(context);
    final fees = o.minerFeesNano + o.appFeesNano;
    final chips = <(String, bool)>[
      if (!o.trusted) ('Unverified token', true),
      if (o.sizedToBalance) ('Sized to your balance', false),
      if (!o.affordable) ('Needs ${formatErg(o.capitalNano, maxFrac: 2)}', true),
    ];
    return SoftCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(cardRadius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(route, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '+${formatErg(o.netProfitNano, maxFrac: 4)}',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: o.netProfitNano > 0 ? moss : null),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${o.legs.length} legs · put in ${amount(o.inputNano, null)} · back ${amount(o.outputNano, null)}',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  'Fees ${formatErg(fees, maxFrac: 4)} (${o.legs.length} × miner + Argus) · '
                  'needs ${formatErg(o.capitalNano, maxFrac: 2)}',
                  style: TextStyle(color: colors.muted, fontSize: 12.5),
                ),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (label, warn) in chips)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: warn ? rust.withValues(alpha: 0.12) : colors.chip,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(label, style: TextStyle(fontSize: 12, color: warn ? rustFor(context) : null)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A label and a value that wrap onto two lines when text is large.
class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.bold = false, this.valueColor});

  final String label;
  final String value;
  final bool bold;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontWeight: bold ? FontWeight.w600 : FontWeight.w400, color: valueColor);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(child: Text(label, style: TextStyle(color: ArgusColors.of(context).muted))),
          const SizedBox(width: 12),
          Flexible(child: Text(value, textAlign: TextAlign.end, style: style)),
        ],
      ),
    );
  }
}

/// Builds the chain against fresh pools and shows all of it before
/// anything is signed.
class _ReviewSheet extends StatefulWidget {
  const _ReviewSheet({
    required this.prepare,
    required this.execute,
    required this.discard,
    required this.watchOnly,
    required this.route,
    required this.symbol,
    required this.amount,
  });

  final Future<ArbChainReview> Function() prepare;
  final Future<ArbExecution> Function(int chainId) execute;
  final void Function(int chainId) discard;
  final bool watchOnly;
  final String route;
  final String Function(String? tokenId) symbol;
  final String Function(int amount, String? tokenId) amount;

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  ArbChainReview? _review;
  Object? _error;
  bool _signing = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    widget.prepare().then((r) {
      if (!mounted) {
        widget.discard(r.chainId);
        return;
      }
      setState(() => _review = r);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    final r = _review;
    if (r != null && !_done) widget.discard(r.chainId);
    super.dispose();
  }

  Future<void> _sign() async {
    final r = _review;
    if (r == null || _signing) return;
    setState(() => _signing = true);
    try {
      final result = await widget.execute(r.chainId);
      _done = true;
      if (mounted) Navigator.pop(context, (r.chainId, result));
    } catch (e) {
      if (mounted) {
        setState(() {
          _signing = false;
          _error = e;
          _review = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final r = _review;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Review arbitrage', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(widget.route, style: TextStyle(color: colors.muted)),
            const SizedBox(height: 16),
            if (_error != null)
              EmptyState(
                compact: true,
                tone: EmptyStateTone.error,
                icon: Icons.report_outlined,
                title: 'Not signed',
                body: arbErrorText(_error!),
              )
            else if (r == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Row(
                  children: [
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Reading the pools again and building every leg…', style: TextStyle(color: colors.muted)),
                    ),
                  ],
                ),
              )
            else
              ..._chain(context, r),
          ],
        ),
      ),
    );
  }

  List<Widget> _chain(BuildContext context, ArbChainReview review) {
    final o = review.opportunity;
    final colors = ArgusColors.of(context);
    final n = o.legs.length;
    final bought = o.legs.first.toTokenId;
    return [
      for (final (i, l) in o.legs.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: colors.chip, shape: BoxShape.circle),
                child: Text('${i + 1}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${widget.amount(l.amountIn, l.fromTokenId)} → ${widget.amount(l.amountOut, l.toTokenId)}'),
                    Text(
                      'Pool ${l.poolId.substring(0, 8)}… · impact ${l.priceImpactPct.toStringAsFixed(2)}%',
                      style: TextStyle(color: colors.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      const Divider(height: 20),
      _Line('You put in', formatErg(o.inputNano, maxFrac: 6)),
      _Line('You get back', formatErg(o.outputNano, maxFrac: 6)),
      _Line('Miner fees ($n legs)', formatErg(o.minerFeesNano)),
      _Line('Argus fees ($n legs)', formatErg(o.appFeesNano)),
      _Line('Box minimum in transit', '${formatErg(o.boxMinInTransitNano)}, returned'),
      _Line('Expected net profit', '+${formatErg(o.netProfitNano, maxFrac: 6)}', bold: true, valueColor: moss),
      _Line('Needs in this wallet', formatErg(o.capitalNano, maxFrac: 4)),
      const SizedBox(height: 12),
      Container(
        key: const Key('arb-risk'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: rust.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'These $n transactions go out back to back. Bots compete for this gap: if one of these pools '
          'is traded before your next leg lands, that leg fails and you keep the ${widget.symbol(bought)} '
          'the leg before it bought. Argus will then offer to sell it back to ERG'
          '${o.unwindLossNano == null ? '' : ', which would cost about ${formatErg(o.unwindLossNano, maxFrac: 4)} at current prices'}. '
          'If a pool moves before you sign, nothing is signed and you see the new numbers first.',
          style: TextStyle(fontSize: 13, height: 1.4, color: rustFor(context)),
        ),
      ),
      const SizedBox(height: 18),
      if (widget.watchOnly)
        Text('This is a watch-only wallet: Argus can show the trade but cannot sign it.',
            style: TextStyle(color: colors.muted))
      else
        FilledButton(
          key: const Key('arb-sign'),
          onPressed: _signing ? null : _sign,
          child: Text(_signing ? 'Signing and broadcasting…' : 'Sign & broadcast $n legs'),
        ),
      TextButton(onPressed: _signing ? null : () => Navigator.pop(context), child: const Text('Cancel')),
    ];
  }
}

/// Follows a broadcast chain while it is open, and offers the way back to
/// ERG when a later leg did not land.
class _ChainSheet extends StatefulWidget {
  const _ChainSheet({
    required this.chainId,
    required this.legs,
    required this.execution,
    required this.status,
    required this.symbol,
    required this.amount,
    required this.unwind,
  });

  final int chainId;
  final int legs;
  final ArbExecution execution;
  final Future<ArbChainStatus> Function(int chainId) status;
  final String Function(String? tokenId) symbol;
  final String Function(int amount, String? tokenId) amount;
  final Future<void> Function(ArbHolding holding) unwind;

  @override
  State<_ChainSheet> createState() => _ChainSheetState();
}

class _ChainSheetState extends State<_ChainSheet> {
  ArbChainStatus? _status;
  Timer? _timer;
  bool _unwinding = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(arbStatusInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final s = await widget.status(widget.chainId);
      if (!mounted) return;
      setState(() => _status = s);
      if (s.state == ArbChainState.complete || s.state == ArbChainState.nothingHappened) _timer?.cancel();
    } catch (_) {
      // A slow node is not a failed chain; the next poll asks again.
    }
  }

  ArbHolding? get _holding => _status?.holding ?? widget.execution.holding;

  bool get _stranded =>
      _status?.state == ArbChainState.stranded ||
      (_status == null && widget.execution.status == ArbExecutionStatus.stranded);

  String _legLine(int i) {
    final s = _status;
    if (s == null || i >= s.legs.length) {
      return i < widget.execution.txIds.length ? 'broadcast' : 'not broadcast';
    }
    return switch (s.legs[i]) {
      ArbLegStatus.confirmed => 'in a block',
      ArbLegStatus.pending => 'waiting in the mempool',
      ArbLegStatus.missing => 'did not land',
      ArbLegStatus.notSubmitted => 'not broadcast',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final holding = _holding;
    final state = _status?.state;
    final title = switch (state) {
      ArbChainState.complete => 'Arbitrage complete',
      ArbChainState.nothingHappened => 'Nothing changed',
      _ when _stranded => 'A leg did not land',
      _ => 'Arbitrage broadcast',
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, key: const Key('arb-chain-title'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (var i = 0; i < widget.legs; i++)
              _Line('Leg ${i + 1}', _legLine(i)),
            const SizedBox(height: 12),
            if (state == ArbChainState.nothingHappened)
              Text('No leg landed, so your wallet is as it was.', style: TextStyle(color: colors.muted))
            else if (_stranded && holding != null) ...[
              Text(
                'Leg ${holding.afterLeg + 1} did not land, most likely because someone traded its pool first. You now hold '
                '${widget.amount(holding.amount, holding.tokenId)}, bought by leg ${holding.afterLeg}, instead of ERG.',
                key: const Key('arb-holding'),
                style: const TextStyle(height: 1.4),
              ),
              if (widget.execution.error != null) ...[
                const SizedBox(height: 6),
                Text(widget.execution.error!, style: TextStyle(color: colors.muted, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('arb-unwind'),
                onPressed: _unwinding
                    ? null
                    : () async {
                        setState(() => _unwinding = true);
                        await widget.unwind(holding);
                        if (mounted) setState(() => _unwinding = false);
                      },
                child: Text('Sell ${widget.symbol(holding.tokenId)} back to ERG'),
              ),
              const SizedBox(height: 6),
              Text(
                'You will see the fresh quote before anything is signed.',
                style: TextStyle(color: colors.muted, fontSize: 12.5),
              ),
            ] else
              Text(
                state == ArbChainState.complete
                    ? 'Every leg is in a block.'
                    : 'Checking every ${arbStatusInterval.inSeconds} seconds while this is open.',
                style: TextStyle(color: colors.muted),
              ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      ),
    );
  }
}
