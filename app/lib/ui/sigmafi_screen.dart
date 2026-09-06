import 'package:flutter/material.dart';

import '../format.dart';
import '../services/duckpools_service.dart' show parseDuckAmount;
import '../services/sigmafi_math.dart';
import '../services/sigmafi_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/empty_state.dart';
import 'widgets/error_sheet.dart';
import 'widgets/soft_card.dart';

/// SigmaFi bonds: lend against other people's requests, post a request
/// of your own, and settle what is yours.
class SigmaFiScreen extends StatefulWidget {
  const SigmaFiScreen({super.key});

  @override
  State<SigmaFiScreen> createState() => _SigmaFiScreenState();
}

class _SigmaFiScreenState extends State<SigmaFiScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  bool _working = false;

  @override
  void initState() {
    super.initState();
    sigmafiService.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    sigmafiService.removeListener(_changed);
    _tabs.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final args = WalletRouteArgs.of(context);
    sigmafiService.clearIfForeign();
    await sigmafiService.refresh({...args.historyAddresses, args.receiveAddress, args.changeAddress});
  }

  /// Wallet token names and decimals, for collateral lines.
  Map<String, TokenBalance> _wallet(BuildContext context) {
    final args = WalletRouteArgs.of(context);
    return {for (final t in args.tokens) t.id: t};
  }

  String _amount(String assetId, int units) {
    final a = sigmafiService.asset(assetId);
    if (a == null) return '$units ${shorten(assetId)}';
    return a.isErg ? formatErg(units) : '${formatTokenAmountGrouped(units, a.decimals)} ${a.name}';
  }

  String _collateral(int erg, List<SigmaFiToken> tokens, Map<String, TokenBalance> wallet) {
    final parts = <String>[];
    // A token-only order carries the minimum ERG, which is not collateral.
    if (erg > 1000000 || tokens.isEmpty) parts.add(formatErg(erg));
    for (final t in tokens) {
      final w = wallet[t.id];
      parts.add(w == null ? '${t.amount} ${shorten(t.id)}' : '${formatTokenAmountGrouped(t.amount, w.decimals)} ${w.name ?? shorten(t.id)}');
    }
    return parts.join(' + ');
  }

  String _term(int blocks) {
    final days = daysForBlocks(blocks);
    return days >= 2 ? '${days.toStringAsFixed(days == days.roundToDouble() ? 0 : 1)} days' : '$blocks blocks';
  }

  Future<void> _spend(String action, Map<String, dynamic> box, List<ConfirmTxRow> Function(Map<String, dynamic> p) rows,
      {required String title, required String detail, required String confirmLabel, required String done}) async {
    if (_working) return;
    final svc = sigmafiService;
    final args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await svc.prepareSpend(
        action: action,
        box: box,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
      );
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        title: title,
        detail: detail,
        confirmLabel: confirmLabel,
        rows: [...rows(prepared), ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt()))],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      if (!svc.canCommit(prepared)) throw StateError('The wallet changed while the transaction was being prepared; nothing was sent');
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$done: ${shorten(txId)}')));
      }
      await _refresh();
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not ${confirmLabel.toLowerCase()}', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _lend(SigmaFiOrder o) => _spend(
        'close',
        o.box,
        (p) => [
          ConfirmTxRow('You lend', _amount(o.loanAsset, o.principal), bold: true),
          ConfirmTxRow('SigmaFi fee (0.5%)', _amount(o.loanAsset, o.devFee)),
          ConfirmTxRow('Argus fee (0.4%)', _amount(o.loanAsset, o.uiFee)),
          ConfirmTxRow('Total out', _amount(o.loanAsset, o.lenderCost), bold: true),
          ConfirmTxRow('Repaid to you', _amount(o.loanAsset, o.repayment)),
          ConfirmTxRow('By block', '${p['maturity_height']} (${_term(o.termBlocks)})'),
          ConfirmTxRow('Collateral held', _collateral(o.collateralErg, o.collateralTokens, _wallet(context))),
        ],
        title: 'Lend against this request',
        detail: 'The collateral moves into a bond. The borrower repays you before maturity, '
            'or you may take the collateral after it. SigmaFi and Argus each take a small fee of the loan.',
        confirmLabel: 'Lend',
        done: 'Loan sent',
      );

  Future<void> _cancel(SigmaFiOrder o) => _spend(
        'cancel',
        o.box,
        (p) => [ConfirmTxRow('Back to you', _collateral(o.collateralErg, o.collateralTokens, _wallet(context)), bold: true)],
        title: 'Withdraw the request',
        detail: 'Nobody has lent against it; the collateral comes back.',
        confirmLabel: 'Withdraw',
        done: 'Request withdrawn',
      );

  Future<void> _repay(SigmaFiBond b) => _spend(
        'repay',
        b.box,
        (p) => [
          ConfirmTxRow('You repay', _amount(b.loanAsset, b.repayment), bold: true),
          ConfirmTxRow('Collateral back', _collateral(b.collateralErg, b.collateralTokens, _wallet(context))),
          ConfirmTxRow('Blocks left', '${b.blocksRemaining}'),
        ],
        title: 'Repay the bond',
        detail: 'The repayment goes to the lender and the collateral returns to you.',
        confirmLabel: 'Repay',
        done: 'Repaid',
      );

  Future<void> _liquidate(SigmaFiBond b) => _spend(
        'liquidate',
        b.box,
        (p) => [
          ConfirmTxRow('You take', _collateral(b.collateralErg, b.collateralTokens, _wallet(context)), bold: true),
          ConfirmTxRow('Blocks overdue', '${-b.blocksRemaining}'),
        ],
        title: 'Take the collateral',
        detail: 'The bond matured without repayment; the collateral is yours.',
        confirmLabel: 'Liquidate',
        done: 'Collateral taken',
      );

  Future<void> _post(_Request r) async {
    if (_working) return;
    final svc = sigmafiService;
    final args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await svc.prepareOpen(
        loanAsset: r.asset.id,
        principal: r.principal,
        repayment: r.repayment,
        termBlocks: r.termBlocks,
        collateralErg: r.collateralErg,
        collateralTokens: r.collateralTokens,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
      );
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Post the request',
        detail: 'The collateral is locked until a lender fills the request or you withdraw it. '
            'A lender pays the SigmaFi and Argus fees on top of the loan.',
        confirmLabel: 'Post',
        rows: [
          ConfirmTxRow('You ask for', _amount(r.asset.id, r.principal), bold: true),
          ConfirmTxRow('You repay', _amount(r.asset.id, r.repayment)),
          ConfirmTxRow('Interest', '${interestPercent(r.principal, r.repayment).toStringAsFixed(2)}% '
              '(${aprPercent(interestPercent(r.principal, r.repayment), r.termBlocks).toStringAsFixed(1)}% APR)'),
          ConfirmTxRow('Term', '${_term(r.termBlocks)} from the fill'),
          ConfirmTxRow('Collateral locked', _collateral(r.collateralErg, r.collateralTokens, _wallet(context)), bold: true),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      if (!svc.canCommit(prepared)) throw StateError('The wallet changed while the request was being prepared; nothing was sent');
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Request posted: ${shorten(txId)}')));
        _tabs.animateTo(1);
      }
      await _refresh();
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not post the request', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = sigmafiService;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SigmaFi bonds'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: svc.busy ? null : _refresh,
            icon: svc.busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Market'), Tab(text: 'Mine'), Tab(text: 'Request')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _market(context),
          _mine(context),
          _RequestTab(enabled: !_working, onPost: _post, wallet: _wallet(context)),
        ],
      ),
    );
  }

  Widget _status(BuildContext context) {
    final svc = sigmafiService;
    final muted = ArgusColors.of(context).muted;
    final lines = <Widget>[];
    if (svc.lastError != null) {
      lines.add(SelectableText(svc.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error)));
    }
    if (svc.skipped.isNotEmpty) {
      lines.add(Text('${svc.skipped.length} ${svc.skipped.length == 1 ? 'box' : 'boxes'} under the contracts could not be read.',
          style: TextStyle(color: muted, fontSize: 12)));
    }
    if (svc.lastRefreshedAt != null) {
      lines.add(Text('Read ${formatRelativeTime(svc.lastRefreshedAt)} at block ${formatHeight(svc.lastHeight)}',
          style: TextStyle(color: muted, fontSize: 12)));
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
    );
  }

  Widget _market(BuildContext context) {
    final svc = sigmafiService;
    final wallet = _wallet(context);
    final orders = svc.openOrders;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _status(context),
          if (orders.isEmpty && !svc.busy)
            EmptyState(
              icon: Icons.handshake_outlined,
              title: svc.lastRefreshedAt == null ? 'Reading the market' : 'No open requests',
              body: svc.lastRefreshedAt == null
                  ? 'Open loan requests appear here once the contracts have been read.'
                  : 'Nobody is asking for a loan right now. Post a request of your own.',
              tone: svc.lastError != null && svc.lastRefreshedAt == null ? EmptyStateTone.error : EmptyStateTone.neutral,
            ),
          for (final o in orders)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Wants ${_amount(o.loanAsset, o.principal)}',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                        ),
                        Text('${o.aprPercent.toStringAsFixed(1)}% APR',
                            style: TextStyle(color: ArgusColors.of(context).accent, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _line(context, 'Repays', '${_amount(o.loanAsset, o.repayment)} (${o.interestPercent.toStringAsFixed(2)}%)'),
                    _line(context, 'Term', _term(o.termBlocks)),
                    _line(context, 'Collateral', _collateral(o.collateralErg, o.collateralTokens, wallet)),
                    _line(context, 'Borrower', shorten(o.borrowerAddress)),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(onPressed: _working ? null : () => _lend(o), child: const Text('Lend')),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mine(BuildContext context) {
    final svc = sigmafiService;
    final wallet = _wallet(context);
    final mine = svc.myOrders;
    final borrows = svc.myBorrows;
    final lends = svc.myLends;
    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(t, style: Theme.of(context).textTheme.titleMedium),
        );
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _status(context),
          if (mine.isEmpty && borrows.isEmpty && lends.isEmpty)
            const EmptyState(
              icon: Icons.account_balance_outlined,
              title: 'Nothing of yours in the market',
              body: 'Requests you post, loans you take and loans you give show up here.',
            ),
          if (mine.isNotEmpty) header('Your requests'),
          for (final o in mine)
            _card(context, [
              _line(context, 'Asking', _amount(o.loanAsset, o.principal), bold: true),
              _line(context, 'Repays', '${_amount(o.loanAsset, o.repayment)} over ${_term(o.termBlocks)}'),
              _line(context, 'Collateral', _collateral(o.collateralErg, o.collateralTokens, wallet)),
              if (!o.onClose) _line(context, 'Note', 'Fixed-height order; Argus cannot fill this kind'),
            ], action: OutlinedButton(onPressed: _working ? null : () => _cancel(o), child: const Text('Withdraw'))),
          if (borrows.isNotEmpty) header('You borrowed'),
          for (final b in borrows)
            _card(context, [
              _line(context, 'Repay', _amount(b.loanAsset, b.repayment), bold: true),
              _line(context, b.matured ? 'Matured' : 'Matures', b.matured
                  ? '${-b.blocksRemaining} blocks ago; the lender may take the collateral'
                  : 'in ${b.blocksRemaining} blocks (block ${formatWithCommas(b.maturityHeight)})'),
              _line(context, 'Collateral', _collateral(b.collateralErg, b.collateralTokens, wallet)),
              _line(context, 'Lender', shorten(b.lenderAddress)),
            ], action: b.repayable ? FilledButton(onPressed: _working ? null : () => _repay(b), child: const Text('Repay')) : null),
          if (lends.isNotEmpty) header('You lent'),
          for (final b in lends)
            _card(context, [
              _line(context, 'Owed to you', _amount(b.loanAsset, b.repayment), bold: true),
              _line(context, b.matured ? 'Matured' : 'Matures', b.matured
                  ? '${-b.blocksRemaining} blocks ago without repayment'
                  : 'in ${b.blocksRemaining} blocks (block ${formatWithCommas(b.maturityHeight)})'),
              _line(context, 'Collateral', _collateral(b.collateralErg, b.collateralTokens, wallet)),
              _line(context, 'Borrower', shorten(b.borrowerAddress)),
            ], action: b.liquidatable ? FilledButton(onPressed: _working ? null : () => _liquidate(b), child: const Text('Take collateral')) : null),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, List<Widget> lines, {Widget? action}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...lines,
              if (action != null) ...[const SizedBox(height: 8), Align(alignment: Alignment.centerRight, child: action)],
            ],
          ),
        ),
      );

  Widget _line(BuildContext context, String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 96, child: Text(label, style: TextStyle(color: ArgusColors.of(context).muted))),
            Expanded(child: Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w600 : null))),
          ],
        ),
      );
}

/// A request as the form has it, checked.
class _Request {
  const _Request({
    required this.asset,
    required this.principal,
    required this.repayment,
    required this.termBlocks,
    required this.collateralErg,
    required this.collateralTokens,
  });
  final SigmaFiAsset asset;
  final int principal;
  final int repayment;
  final int termBlocks;
  final int collateralErg;
  final List<SigmaFiToken> collateralTokens;
}

class _RequestTab extends StatefulWidget {
  const _RequestTab({required this.enabled, required this.onPost, required this.wallet});
  final bool enabled;
  final ValueChanged<_Request> onPost;
  final Map<String, TokenBalance> wallet;

  @override
  State<_RequestTab> createState() => _RequestTabState();
}

class _RequestTabState extends State<_RequestTab> {
  SigmaFiAsset? _asset;
  final _principal = TextEditingController();
  final _interest = TextEditingController(text: '5');
  final _days = TextEditingController(text: '30');
  final _erg = TextEditingController();
  final _tokens = <_TokenRow>[];

  @override
  void dispose() {
    for (final c in [_principal, _interest, _days, _erg]) {
      c.dispose();
    }
    for (final t in _tokens) {
      t.amount.dispose();
    }
    super.dispose();
  }

  SigmaFiAsset get asset => _asset ?? sigmafiService.assets.first;

  int? get _principalUnits => parseDuckAmount(_principal.text, asset.decimals);
  int? get _interestBps {
    final t = _interest.text.trim();
    if (!RegExp(r'^\d{1,3}(\.\d{0,2})?$').hasMatch(t)) return null;
    final parts = t.split('.');
    final frac = (parts.length > 1 ? parts[1] : '').padRight(2, '0');
    return int.parse(parts[0]) * 100 + int.parse(frac);
  }

  int? get _termBlocks {
    final d = int.tryParse(_days.text.trim());
    return d == null ? null : blocksForDays(d);
  }

  int get _collateralErg => _erg.text.trim().isEmpty ? 0 : (parseDuckAmount(_erg.text, 9) ?? -1);

  String? get _problem {
    final p = _principalUnits;
    if (p == null) return 'Enter the amount to borrow';
    final bps = _interestBps;
    if (bps == null) return 'Enter the interest as a percentage, up to two decimals';
    final term = _termBlocks;
    if (term == null) return 'Enter the term in days';
    final termProblem = termError(term);
    if (termProblem != null) return termProblem;
    if (_collateralErg < 0) return 'The ERG collateral is not a valid amount';
    if (_collateralErg > 0 && _collateralErg < 1000000) return 'ERG collateral must be at least 0.001 ERG';
    for (final t in _tokens) {
      if (t.token == null) return 'Pick a token for each collateral row';
      final n = parseDuckAmount(t.amount.text, t.token!.decimals);
      if (n == null) return 'Enter an amount of ${t.token!.name ?? shorten(t.token!.id)}';
      if (n > t.token!.amount) return 'Not enough ${t.token!.name ?? shorten(t.token!.id)}';
    }
    if (_tokens.map((t) => t.token?.id).toSet().length != _tokens.length) return 'Each token once';
    if (_collateralErg == 0 && _tokens.isEmpty) return 'Add collateral: ERG, tokens, or both';
    return null;
  }

  void _post() {
    final p = _principalUnits!;
    widget.onPost(_Request(
      asset: asset,
      principal: p,
      repayment: repaymentFor(p, _interestBps!),
      termBlocks: _termBlocks!,
      collateralErg: _collateralErg,
      collateralTokens: [for (final t in _tokens) (id: t.token!.id, amount: parseDuckAmount(t.amount.text, t.token!.decimals)!)],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final assets = sigmafiService.assets;
    final p = _principalUnits;
    final bps = _interestBps;
    final term = _termBlocks;
    final problem = _problem;
    final preview = p != null && bps != null && term != null && termError(term) == null
        ? 'Repay ${asset.isErg ? formatErg(repaymentFor(p, bps)) : '${formatTokenAmountGrouped(repaymentFor(p, bps), asset.decimals)} ${asset.name}'} '
            'after ${_days.text.trim()} days; ${aprPercent(interestPercent(p, repaymentFor(p, bps)), term).toStringAsFixed(1)}% APR for the lender'
        : null;
    final tokensHeld = widget.wallet.values.where((t) => t.amount > 0).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('Ask the market for a loan. Lock collateral now; a lender sends the loan and holds the collateral until you repay.',
            style: TextStyle(color: muted)),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: asset.id,
          decoration: const InputDecoration(labelText: 'Borrow'),
          items: [for (final a in assets) DropdownMenuItem(value: a.id, child: Text(a.name))],
          onChanged: widget.enabled ? (v) => setState(() => _asset = sigmafiService.asset(v ?? 'ERG')) : null,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _principal,
          enabled: widget.enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Amount', suffixText: asset.name),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _interest,
                enabled: widget.enabled,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Interest', suffixText: '%'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _days,
                enabled: widget.enabled,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Term', suffixText: 'days'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        if (preview != null) ...[
          const SizedBox(height: 8),
          Text(preview, style: TextStyle(color: muted, fontSize: 12)),
        ],
        const SizedBox(height: 20),
        Text('Collateral', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _erg,
          enabled: widget.enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'ERG (optional with tokens)', suffixText: 'ERG'),
          onChanged: (_) => setState(() {}),
        ),
        for (final t in _tokens) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  initialValue: t.token?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Token'),
                  items: [
                    for (final w in tokensHeld)
                      DropdownMenuItem(value: w.id, child: Text(w.name ?? shorten(w.id), overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: widget.enabled ? (v) => setState(() => t.token = widget.wallet[v]) : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: t.amount,
                  enabled: widget.enabled,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                onPressed: widget.enabled
                    ? () => setState(() {
                          _tokens.remove(t);
                          t.amount.dispose();
                        })
                    : null,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.enabled && tokensHeld.isNotEmpty ? () => setState(() => _tokens.add(_TokenRow())) : null,
            icon: const Icon(Icons.add),
            label: Text(tokensHeld.isEmpty ? 'No tokens to lock' : 'Add token collateral'),
          ),
        ),
        const SizedBox(height: 16),
        if (problem != null) Text(problem, style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: widget.enabled && problem == null ? _post : null,
          child: const Text('Post the request'),
        ),
        const SizedBox(height: 8),
        Text('The contract insists on a term above 30 blocks and below the storage rent period (~4 years). '
            'A lender pays 0.5% of the loan to SigmaFi and 0.4% to Argus on top of what you receive.',
            style: TextStyle(color: muted, fontSize: 12)),
      ],
    );
  }
}

class _TokenRow {
  TokenBalance? token;
  final amount = TextEditingController();
}
