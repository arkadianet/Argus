import 'widgets/error_sheet.dart';
import '../services/app_fee.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/sigmausd_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'offline_banner.dart';
import 'widgets/soft_card.dart';

/// AgeUSD (SigmaUSD) hub. Mint and redeem SigUSD / SigRSV against the bank at
/// the live oracle rate. Every action builds through the shared confirm sheet
/// ("Sign & broadcast") and submits via the cached-preparation flow.
class AgeUsdScreen extends StatefulWidget {
  const AgeUsdScreen({super.key, this.embedded = false});

  /// When true the screen renders without its own Scaffold/AppBar so it can
  /// live inside the swap hub's tab view.
  final bool embedded;

  @override
  State<AgeUsdScreen> createState() => _AgeUsdScreenState();
}

class _AgeUsdScreenState extends State<AgeUsdScreen> {
  SigmaUsdAction _action = SigmaUsdAction.mintSigUsd;
  SigmaUsdStateData? _state;
  bool _loading = true;
  String? _error;
  bool _busy = false;

  final _amountCtrl = TextEditingController();
  Timer? _previewDebounce;
  int _previewGeneration = 0;
  SigmaUsdPreview? _preview;
  String? _previewError;

  WalletRouteArgs get _args =>
      WalletRouteArgs.of(context);

  int? get _sigUsdBalance {
    for (final t in _args.tokens) {
      if (t.id == SigmaUsdTokens.sigUsd) return t.amount;
    }
    return null;
  }

  int? get _sigRsvBalance {
    for (final t in _args.tokens) {
      if (t.id == SigmaUsdTokens.sigRsv) return t.amount;
    }
    return null;
  }

  int? get _selectedBalance => switch (_action.tokenName) {
        'SigUSD' => _sigUsdBalance,
        'SigRSV' => _sigRsvBalance,
        _ => null,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool fresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await sigmaUsdService.state(fresh: fresh);
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
      _schedulePreview();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  List<String> get _spendAddresses {
    final args = _args;
    return args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
  }

  String get _recipient {
    final args = _args;
    if (args.changeAddress.isNotEmpty) return args.changeAddress;
    if (args.receiveAddress.isNotEmpty) return args.receiveAddress;
    return args.senderAddress;
  }

  void _schedulePreview() {
    _previewDebounce?.cancel();
    _previewDebounce =
        Timer(const Duration(milliseconds: 300), _refreshPreview);
  }

  Future<void> _refreshPreview() async {
    final gen = ++_previewGeneration;
    final amount =
        parseDecimalToBase(_amountCtrl.text, _action.decimals);
    if (amount == null || amount <= 0) {
      if (mounted && gen == _previewGeneration) {
        setState(() {
          _preview = null;
          _previewError = null;
        });
      }
      return;
    }
    try {
      final preview = await sigmaUsdService.preview(_action, amount);
      if (!mounted || gen != _previewGeneration) return;
      setState(() {
        _preview = preview;
        _previewError = null;
      });
    } catch (e) {
      if (mounted && gen == _previewGeneration) {
        setState(() {
          _preview = null;
          _previewError = 'Could not fetch quote: $e';
        });
      }
    }
  }

  void _switchAction(SigmaUsdAction action) {
    if (action == _action) return;
    setState(() {
      _action = action;
      _amountCtrl.clear();
      _preview = null;
      _previewError = null;
    });
    _schedulePreview();
  }

  void _applyMax() {
    final st = _state;
    if (st == null) return;
    final maxBase =
        _action.isRedeem ? (_selectedBalance ?? 0) : st.maxFor(_action);
    if (maxBase <= 0) {
      _snack('Nothing available for this action');
      return;
    }
    _amountCtrl.text = formatTokenAmount(maxBase, _action.decimals);
    _schedulePreview();
  }

  Future<void> _review() async {
    final st = _state;
    if (st == null) return;
    final amount = parseDecimalToBase(_amountCtrl.text, _action.decimals);
    if (amount == null || amount <= 0) {
      _snack('Enter an amount');
      return;
    }
    final spend = _spendAddresses;
    if (spend.isEmpty) {
      _snack('No spendable addresses');
      return;
    }

    setState(() => _busy = true);
    SigmaUsdBuildResult build;
    try {
      build = await sigmaUsdService.build(
        action: _action,
        amount: amount,
        recipient: _recipient,
        changeAddress: _args.changeAddress.isNotEmpty
            ? _args.changeAddress
            : _args.senderAddress,
        spendAddresses: spend,
      );
    } on ArgusException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showErrorSheet(context, code: e.code, message: e.message);
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not build transaction: $e');
      return;
    }
    if (!mounted) return;

    final isMint = !(_action.isRedeem);
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: '${_action.verb} ${_action.tokenName}',
      rows: [
        ConfirmTxRow(
          isMint ? 'You receive' : 'You redeem',
          '${formatTokenAmount(build.tokenAmount, _action.decimals)} '
          '${_action.tokenName}',
        ),
        if (isMint)
          ConfirmTxRow('ERG cost', formatErg(build.ergAmountNano))
        else
          ConfirmTxRow('ERG back', formatErg(build.ergAmountNano)),
        ConfirmTxRow('Miner fee', formatErg(build.minerFee)),
        argusFeeRow(),
      ],
      detail: isMint
          ? 'Minted against the bank at the oracle rate.'
          : 'Redeemed against the bank at the oracle rate.',
      confirmLabel:
          'Sign & broadcast ${_action.verb.toLowerCase()}',
    );
    if (!confirmed) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    try {
      final txId =
          await walletService.sendErg(preparationId: build.preparationId);
      if (!mounted) return;
      _snack('Broadcast! ${shorten(txId, head: 8, tail: 6)}');
      HapticFeedback.mediumImpact();
      _amountCtrl.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      await showTxFailureSheet(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _state;
    final body = Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              TextButton(
                                  onPressed: _load, child: const Text('Retry')),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _load(fresh: true),
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        children: [
                          if (st != null) ...[
                            _protocolHeader(st),
                            const SizedBox(height: 20),
                            _balances(),
                            const SizedBox(height: 20),
                            const SectionLabel('Action'),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final a in SigmaUsdAction.values)
                                  ChoiceChip(
                                    label: Text('${a.verb} ${a.tokenName}'),
                                    selected: a == _action,
                                    onSelected: st.can(a)
                                        ? (_) => _switchAction(a)
                                        : null,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _amountCtrl,
                              decoration: InputDecoration(
                                labelText:
                                    'Amount (${_action.tokenName})',
                                suffixIcon: TextButton(
                                  onPressed: _applyMax,
                                  child: const Text('MAX'),
                                ),
                                helperText: _helperFor(st),
                              ),
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              onChanged: (_) => _schedulePreview(),
                            ),
                            const SizedBox(height: 12),
                            _previewPanel(),
                            const SizedBox(height: 24),
                            FilledButton(
                              onPressed: _busy || !st.can(_action)
                                  ? null
                                  : _review,
                              child: _busy
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : Text('${_action.verb} '
                                      '${_action.tokenName}'),
                            ),
                          ],
                        ],
                      ),
                  ),
            ),
        ],
      );
    if (widget.embedded) {
      return body;
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('AgeUSD'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: body,
    );
  }

  String _helperFor(SigmaUsdStateData st) {
    if (!st.can(_action)) {
      return 'Disabled at the current reserve ratio.';
    }
    if (!_action.isRedeem) {
      final max = st.maxFor(_action);
      return 'Max ${formatTokenAmount(max, _action.decimals)} '
          '${_action.tokenName} at this ratio.';
    }
    final bal = _selectedBalance;
    if (bal == null) return 'You hold no ${_action.tokenName}.';
    return 'You hold ${formatTokenAmount(bal, _action.decimals)} '
        '${_action.tokenName}.';
  }

  Widget _protocolHeader(SigmaUsdStateData st) {
    final ergUsd = st.oracleNanoErgPerUsd > 0
        ? 1e9 / st.oracleNanoErgPerUsd
        : 0.0;
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Reserve ratio',
                  style: Theme.of(context).textTheme.bodySmall),
              Text(
                '${st.reserveRatioPct.toStringAsFixed(1)}%',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (st.reserveRatioPct / 1000).clamp(0.0, 1.0),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 10),
          _kvRow('ERG / USD', '\$${ergUsd.toStringAsFixed(4)}'),
          _kvRow('Liabilities', formatErg(st.liabilitiesNano)),
          _kvRow('Equity', formatErg(st.equityNano)),
        ],
      ),
    );
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(value, style: monoStyle(context, size: 12)),
        ],
      ),
    );
  }

  Widget _balances() {
    return Row(
      children: [
        Expanded(
          child: _balanceCard('SigUSD', _sigUsdBalance,
              SigmaUsdAction.mintSigUsd.decimals),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _balanceCard('SigRSV', _sigRsvBalance,
              SigmaUsdAction.mintSigRsv.decimals),
        ),
      ],
    );
  }

  Widget _balanceCard(String name, int? amount, int decimals) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ArgusColors.of(context).inset,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            amount == null
                ? '—'
                : formatTokenAmount(amount, decimals),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _previewPanel() {
    if (_previewError != null) {
      return Text(
        _previewError!,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: rustFor(context)),
      );
    }
    final p = _preview;
    if (p == null) {
      return Text(
        'Enter an amount to see the quote.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    if (!p.canExecute) {
      return Text(
        p.error ?? 'This action is not available right now.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: rustFor(context)),
      );
    }
    final isMint = !_action.isRedeem;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ArgusColors.of(context).inset,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kvRow(isMint ? 'ERG cost' : 'ERG back',
              formatErg(isMint ? p.ergCostNano : p.ergOutNano)),
          _kvRow('Protocol fee', formatErg(p.protocolFeeNano)),
          _kvRow('Miner fee', formatErg(p.txFeeNano)),
        ],
      ),
    );
  }
}
