import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../bridge/argus_error.dart';
import '../services/dexy_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';

/// Mobile-first Dexy hub. Every action builds a transaction through the shared
/// confirm sheet ("Sign & broadcast") and submits via the cached-preparation
/// flow — the same guard rails as every other send in Argus.
class DexyScreen extends StatefulWidget {
  const DexyScreen({super.key});

  @override
  State<DexyScreen> createState() => _DexyScreenState();
}

class _DexyScreenState extends State<DexyScreen> {
  DexyVariant _variant = DexyVariant.gold;
  DexyState? _state;
  bool _loading = true;
  String? _error;
  bool _busy = false;

  WalletRouteArgs get _args =>
      WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);

  int? get _tokenBalance {
    for (final t in _args.tokens) {
      if (t.id == _variant.tokenId) return t.amount;
    }
    return null;
  }

  int? get _lpBalance {
    for (final t in _args.tokens) {
      if (t.id == _variant.lpTokenId) return t.amount;
    }
    return null;
  }

  String get _recipient => _args.receiveAddress.isNotEmpty
      ? _args.receiveAddress
      : _args.senderAddress;

  List<String> get _spendAddresses {
    final args = _args;
    return args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await dexService.state(_variant);
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } on ArgusException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _switchVariant(DexyVariant v) {
    if (v == _variant) return;
    setState(() => _variant = v);
    _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _broadcast(DexyBuildResult build) async {
    setState(() => _busy = true);
    try {
      final raw =
          await walletService.sendErg(preparationId: build.preparationId);
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final txId = map['tx_id']?.toString() ?? raw;
      if (!mounted) return;
      _snack('Broadcast! ${shorten(txId, head: 8, tail: 6)}');
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      _snack('Broadcast may have failed. Check activity before retrying. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(2)}M';
    if (n >= 1000) return '${(n / 1e3).toStringAsFixed(1)}K';
    return '$n';
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<void> _openMint() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _DexyMintSheet(
        variant: _variant,
        state: _state!,
        spendableNano: _args.spendableNano,
        onBuild: (amount) => dexService.buildMint(
          variant: _variant,
          amount: amount,
          recipient: _recipient,
          spendAddresses: _spendAddresses,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final build = result['build'] as DexyBuildResult;
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: 'Mint ${_variant.name}',
      rows: [
        ConfirmTxRow(
            'Received',
            '${formatTokenAmount(build.tokenAmount, _variant.decimals)} '
            '${_variant.shortName}'),
        ConfirmTxRow('ERG cost', formatErg(build.ergCostNano)),
        ConfirmTxRow('Miner fee', formatErg(build.minerFee)),
      ],
      detail: 'Minted from the Dexy bank at the oracle rate.',
      confirmLabel: 'Sign & broadcast mint',
    );
    if (confirmed) await _broadcast(build);
  }

  Future<void> _openSwap() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _DexySwapSheet(
        variant: _variant,
        state: _state!,
        tokenBalance: _tokenBalance,
        spendableNano: _args.spendableNano,
        onBuild: (direction, amount, minOutput) => dexService.buildSwap(
          variant: _variant,
          direction: direction,
          amount: amount,
          minOutput: minOutput,
          recipient: _recipient,
          spendAddresses: _spendAddresses,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final build = result['final'] as DexyBuildResult;
    final isErgInput = build.direction == 'erg_to_dexy';
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: 'Swap ERG ↔ ${_variant.shortName}',
      rows: [
        ConfirmTxRow(
          'Pay',
          isErgInput
              ? formatErg(build.inputAmount)
              : '${formatTokenAmount(build.inputAmount, _variant.decimals)} ${_variant.shortName}',
        ),
        ConfirmTxRow(
          'Receive',
          isErgInput
              ? '${formatTokenAmount(build.outputAmount, _variant.decimals)} ${_variant.shortName}'
              : formatErg(build.outputAmount),
        ),
        ConfirmTxRow(
            'Price impact', '${build.priceImpactPct.toStringAsFixed(2)}%'),
        ConfirmTxRow('Miner fee', formatErg(build.minerFee)),
      ],
      detail:
          'Rate set by the ${_variant.shortName} LP pool (${build.feePct.toStringAsFixed(1)}% fee).',
      confirmLabel: 'Sign & broadcast swap',
    );
    if (confirmed) await _broadcast(build);
  }

  Future<void> _openLiquidity({String initialAction = 'deposit'}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _DexyLiquiditySheet(
        variant: _variant,
        initialAction: initialAction,
        tokenBalance: _tokenBalance,
        lpBalance: _lpBalance,
        spendableBalance: _args.spendableNano,
        onBuild: (action, ergAmt, dexyAmt, lpAmt) {
          if (action == 'deposit') {
            return dexService.buildLpDeposit(
              variant: _variant,
              depositErg: ergAmt,
              depositDexy: dexyAmt,
              recipient: _recipient,
              spendAddresses: _spendAddresses,
            );
          }
          return dexService.buildLpRedeem(
            variant: _variant,
            lpToBurn: lpAmt,
            recipient: _recipient,
            spendAddresses: _spendAddresses,
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    final build = result['final'] as DexyBuildResult;
    final isDeposit = build.action == 'deposit';
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: isDeposit ? 'Add liquidity' : 'Remove liquidity',
      rows: isDeposit
          ? [
              ConfirmTxRow('Deposit ERG', formatErg(build.ergAmount)),
              ConfirmTxRow(
                  'Deposit ${_variant.shortName}',
                  '${formatTokenAmount(build.dexyAmount, _variant.decimals)} '
                  '${_variant.shortName}'),
              ConfirmTxRow('Miner fee', formatErg(build.minerFee)),
            ]
          : [
              ConfirmTxRow('LP tokens burned', '${build.lpTokens}'),
              ConfirmTxRow(
                  'Receive',
                  '${formatErg(build.ergAmount)} + '
                  '${formatTokenAmount(build.dexyAmount, _variant.decimals)} '
                  '${_variant.shortName}'),
              ConfirmTxRow('Miner fee', formatErg(build.minerFee)),
            ],
      detail: isDeposit
          ? 'Receives ${formatTokenAmount(build.lpTokens, 0)} LP tokens.'
          : '2% redemption fee applies.',
      confirmLabel: isDeposit
          ? 'Sign & broadcast deposit'
          : 'Sign & broadcast redeem',
    );
    if (confirmed) await _broadcast(build);
  }

  // ── Layout ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dexy'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh rates',
            onPressed: _loading || _busy ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            _variantSwitcher(context),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 90),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _errorView(context)
            else if (_state != null) ...[
              _balanceCard(context),
              const SizedBox(height: 14),
              _ratesCard(context),
              const SizedBox(height: 14),
              _statsCard(context),
              const SizedBox(height: 22),
              _actionsCard(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _variantSwitcher(BuildContext context) {
    return Row(
      children: DexyVariant.values.map((v) {
        final selected = v == _variant;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: InkWell(
              onTap: () => _switchVariant(v),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: selected
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.14)
                      : Theme.of(context).colorScheme.surface,
                  border: Border.all(
                    color: selected
                        ? iris
                        : Theme.of(context).colorScheme.outline,
                    width: selected ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  children: [
                    Text(v.shortName,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(v.name, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _errorView(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const Icon(Icons.cloud_off, size: 40, color: rust),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: _load, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _balanceCard(BuildContext context) {
    final bal = _tokenBalance;
    final st = _state!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Your ${_variant.name}',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              _tag(st.canMint ? 'Mint open' : 'Mint paused',
                  st.canMint ? const Color(0xFF5B9E6D) : rust),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            bal != null
                ? '${formatTokenAmount(bal, _variant.decimals)} ${_variant.shortName}'
                : '0 ${_variant.shortName}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            _lpBalance != null && _lpBalance! > 0
                ? '${_fmt(_lpBalance!)} LP tokens'
                : 'No LP position yet',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _ratesCard(BuildContext context) {
    final st = _state!;
    final lpPerToken = st.lpDexyReserves > 0
        ? st.lpErgReserves / st.lpDexyReserves / 1e9
        : 0.0;
    final tokensPerErg = st.rates.tokensPerErg;
    final diff = st.rateDifferencePct;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Rates'),
          const SizedBox(height: 12),
          _twoCol('Oracle',
              '${st.rates.ergPerToken.toStringAsFixed(6)} ERG / ${_variant.shortName}'),
          const SizedBox(height: 8),
          _twoCol('LP pool',
              '${lpPerToken.toStringAsFixed(6)} ERG / ${_variant.shortName}'),
          const SizedBox(height: 8),
          _twoCol(
              'Token per ERG', '${tokensPerErg.toStringAsFixed(6)} ${_variant.shortName}'),
          const SizedBox(height: 8),
          _twoCol('Oracle vs LP', '${diff.toStringAsFixed(2)}% apart'),
          const SizedBox(height: 12),
          _bestPathBlock(context, st),
        ],
      ),
    );
  }

  Widget _bestPathBlock(BuildContext context, DexyState st) {
    final best = st.bestPath;
    final col = best.available
        ? const Color(0xFF6BA5A0)
        : Theme.of(context).colorScheme.outline;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: col.withValues(alpha: 0.08),
        border: Border.all(color: col.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Best mint rate',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: col)),
          const SizedBox(height: 4),
          Text(
            best.available
                ? '${best.name}: ${best.effectiveRate?.toStringAsFixed(4)} ERG per ${_variant.shortName}'
                : '${best.name} — ${best.reason ?? 'unavailable'}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _statsCard(BuildContext context) {
    final st = _state!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Protocol'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _stat('Bank reserves', formatErg(st.bankErgNano)),
              _stat('Circulating',
                  '${formatTokenAmount(st.dexyCirculating, _variant.decimals)} ${_variant.shortName}'),
              _stat('Pooled',
                  '${formatTokenAmount(st.lpDexyReserves, _variant.decimals)} ${_variant.shortName}'),
              _stat('Free mint today', _fmt(st.freeMintAvailable)),
              _stat('LP supply', _fmt(st.lpCirculating)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionsCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('Actions'),
          const SizedBox(height: 8),
          _actionTile(context, Icons.outbond, 'Mint',
              'Buy ${_variant.shortName} at the oracle rate', _openMint),
          _actionTile(context, Icons.swap_horiz, 'Swap',
              'Trade ERG and ${_variant.shortName}', _openSwap),
          _actionTile(context, Icons.add_circle_outline, 'Add liquidity',
              'Earn pool LP tokens on ERG + ${_variant.shortName}',
              () => _openLiquidity(initialAction: 'deposit')),
          _actionTile(context, Icons.remove_circle_outline, 'Remove liquidity',
              'Redeem LP tokens for ERG + ${_variant.shortName}',
              () => _openLiquidity(initialAction: 'redeem')),
        ],
      ),
    );
  }

  Widget _actionTile(BuildContext context, IconData icon, String title,
      String subtitle, VoidCallback onTap) {
    return InkWell(
      onTap: _busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 3),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }

  Widget _twoCol(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        Text(
          value,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _tag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Action sheets
// ─────────────────────────────────────────────────────────────────────────────

/// Mint flow: enter an amount, see the live cost, then review.
class _DexyMintSheet extends StatefulWidget {
  const _DexyMintSheet({
    required this.variant,
    required this.state,
    this.spendableNano,
    required this.onBuild,
  });

  final DexyVariant variant;
  final DexyState state;
  final int? spendableNano;
  final Future<DexyBuildResult> Function(int amount) onBuild;

  @override
  State<_DexyMintSheet> createState() => _DexyMintSheetState();
}

class _DexyMintSheetState extends State<_DexyMintSheet> {
  final _ergCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  Timer? _debounce;
  DexyMintPreview? _preview;
  bool _previewing = false;
  String? _previewError;
  bool _building = false;

  double get _effectiveRate => widget.state.rates.ergPerToken;

  @override
  void dispose() {
    _debounce?.cancel();
    _ergCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _onErgChanged() {
    final parsed = double.tryParse(_ergCtrl.text.trim());
    if (parsed != null && parsed > 0 && _effectiveRate > 0) {
      final decimals = widget.variant.decimals;
      final tokenVal = parsed / _effectiveRate;
      var scale = 1;
      for (var i = 0; i < decimals; i++) {
        scale *= 10;
      }
      final baseUnits = (tokenVal * scale).floor();
      _tokenCtrl.text = formatScaled(baseUnits, decimals);
    } else {
      _tokenCtrl.clear();
    }
    _triggerPreview();
  }

  void _onTokenChanged() {
    final parsed = double.tryParse(_tokenCtrl.text.trim());
    if (parsed != null && parsed > 0 && _effectiveRate > 0) {
      final ergVal = parsed * _effectiveRate;
      _ergCtrl.text = ergVal.toStringAsFixed(4);
    } else {
      _ergCtrl.clear();
    }
    _triggerPreview();
  }

  void _applyMax() {
    final spendable = widget.spendableNano;
    if (spendable == null || _effectiveRate <= 0) return;
    final maxNano = spendable - minerFeeNano - minBoxNano;
    if (maxNano > 0) {
      _ergCtrl.text = formatErg(maxNano, unit: false, maxFrac: 4);
      _onErgChanged();
    }
  }

  void _triggerPreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _refresh);
  }

  Future<void> _refresh() async {
    final raw = parseDecimalToBase(_tokenCtrl.text.trim(), widget.variant.decimals);
    if (raw == null || raw <= 0) {
      setState(() {
        _preview = null;
        _previewError = null;
      });
      return;
    }
    setState(() => _previewing = true);
    try {
      final p = await dexService.previewMint(widget.variant, raw);
      if (!mounted) return;
      setState(() {
        _preview = p;
        _previewError = p.error;
        _previewing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _previewError = '$e';
        _previewing = false;
      });
    }
  }

  Future<void> _review() async {
    final raw = parseDecimalToBase(_tokenCtrl.text.trim(), widget.variant.decimals);
    if (raw == null || raw <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter an amount')));
      return;
    }
    setState(() => _building = true);
    try {
      final build = await widget.onBuild(raw);
      if (!mounted) return;
      Navigator.pop(context, {'build': build});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not prepare: $e')));
      setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = widget.variant;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Mint ${variant.name}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(variant.peg, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 18),
          TextField(
            controller: _ergCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _onErgChanged(),
            decoration: InputDecoration(
              labelText: 'You pay (ERG)',
              suffixIcon: TextButton(
                onPressed: _applyMax,
                child: const Text('MAX'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _onTokenChanged(),
            decoration: InputDecoration(
              labelText: 'You receive (${variant.shortName})',
              helperText: 'Fixed oracle rate: ${_effectiveRate.toStringAsFixed(4)} ERG / ${variant.shortName}',
            ),
          ),
          const SizedBox(height: 12),
          if (_previewing)
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Estimating…'),
              ],
            )
          else if (_preview != null && _preview!.canExecute) ...[
            _sheetRow('ERG cost', formatErg(_preview!.totalCostNano)),
            _sheetRow('Miner fee', formatErg(_preview!.txFeeNano, unit: false)),
          ] else if (_previewError != null)
            Text(_previewError!,
                style: TextStyle(color: rust, fontSize: 12)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _building || _previewing ? null : _review,
              child: _building
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Review'),
            ),
          ),
        ],
      ),
    );
  }
}


/// Swap sheet with live quotes in both directions.
class _DexySwapSheet extends StatefulWidget {
  const _DexySwapSheet({
    required this.variant,
    required this.state,
    required this.onBuild,
    this.tokenBalance,
    this.spendableNano,
  });

  final DexyVariant variant;
  final DexyState state;
  final Future<DexyBuildResult> Function(String direction, int amount, int minOutput)
      onBuild;
  final int? tokenBalance;
  final int? spendableNano;

  @override
  State<_DexySwapSheet> createState() => _DexySwapSheetState();
}

class _DexySwapSheetState extends State<_DexySwapSheet> {
  final _amountCtrl = TextEditingController();
  Timer? _debounce;
  String _direction = 'erg_to_dexy';
  DexySwapPreview? _quote;
  bool _quoting = false;
  String? _quoteError;
  bool _building = false;

  bool get _ergInput => _direction == 'erg_to_dexy';

  @override
  void dispose() {
    _debounce?.cancel();
    _amountCtrl.dispose();
    super.dispose();
  }

  int? get _rawAmount {
    final text = _amountCtrl.text.trim();
    if (text.isEmpty) return null;
    return _ergInput
        ? parseErgToNano(text)
        : parseDecimalToBase(text, widget.variant.decimals);
  }

  int get _outDecimals => _ergInput ? widget.variant.decimals : 9;

  void _setDirection(String d) {
    if (d == _direction) return;
    setState(() {
      _direction = d;
      _amountCtrl.clear();
      _quote = null;
      _quoteError = null;
    });
    _onChanged();
  }

  void _applyMax() {
    if (_ergInput) {
      final spendable = widget.spendableNano;
      if (spendable == null) return;
      final max = spendable - minerFeeNano - minBoxNano;
      if (max < minBoxNano) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not enough ERG for fee and change')),
        );
        return;
      }
      setState(() => _amountCtrl.text = formatErg(max, unit: false));
    } else {
      final maxRaw = widget.tokenBalance;
      if (maxRaw == null) return;
      setState(
          () => _amountCtrl.text = formatTokenAmount(maxRaw, widget.variant.decimals));
    }
    _onChanged();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _quoteNow);
  }

  Future<void> _quoteNow() async {
    final raw = _rawAmount;
    if (raw == null || raw <= 0) {
      setState(() {
        _quote = null;
        _quoteError = null;
      });
      return;
    }
    setState(() => _quoting = true);
    try {
      final q = await dexService.previewSwap(
          widget.variant, _direction, raw,
          slippagePct: 0.5);
      if (!mounted) return;
      setState(() {
        _quote = q;
        _quoteError = q.error;
        _quoting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _quote = null;
        _quoteError = '$e';
        _quoting = false;
      });
    }
  }

  Future<void> _review() async {
    final raw = _rawAmount;
    if (raw == null || raw <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter an amount')));
      return;
    }
    final quote = _quote;
    if (quote == null || !quote.canExecute) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(quote?.error ?? 'No quote available')));
      return;
    }
    setState(() => _building = true);
    try {
      final build = await widget.onBuild(_direction, raw, quote.minOutput);
      if (!mounted) return;
      Navigator.of(context).pop({'final': build});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not prepare: $e')));
      setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = widget.variant;
    final inputName = _ergInput ? 'ERG' : variant.shortName;
    final outputName = _ergInput ? variant.shortName : 'ERG';
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Swap ERG ↔ ${variant.shortName}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Row(
            children: [
              ChoiceChip(
                label: const Text('ERG →'),
                selected: _ergInput,
                onSelected: (_) => _setDirection('erg_to_dexy'),
                selectedColor: iris,
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text('← ${variant.shortName}'),
                selected: !_ergInput,
                onSelected: (_) => _setDirection('dexy_to_erg'),
                selectedColor: iris,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amountCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _onChanged(),
            decoration: InputDecoration(
              labelText: 'You pay ($inputName)',
              suffixIcon: TextButton(
                onPressed: _applyMax,
                child: const Text('MAX'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'AMM pool rate (differs from oracle mint rate)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 8),
          if (_quoting)
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Quoting…'),
              ],
            )
          else if (_quote != null && _quote!.canExecute) ...[
            _sheetRow(
                'You receive',
                '${formatTokenAmount(_quote!.outputAmount, _outDecimals)} $outputName'),
            _sheetRow(
                'Minimum after slippage',
                '${formatTokenAmount(_quote!.minOutput, _outDecimals)} $outputName'),
            _sheetRow('Price impact',
                '${_quote!.priceImpactPct.toStringAsFixed(2)}%'),
            _sheetRow('LP fee', '${_quote!.feePct.toStringAsFixed(2)}%'),
          ] else if (_quoteError != null)
            Text(_quoteError!, style: TextStyle(color: rust, fontSize: 12)),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _building || _quoting ? null : _review,
              child: _building
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Review'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Add / remove liquidity sheet.
class _DexyLiquiditySheet extends StatefulWidget {
  const _DexyLiquiditySheet({
    required this.variant,
    required this.onBuild,
    this.initialAction = 'deposit',
    this.tokenBalance,
    this.lpBalance,
    this.spendableBalance,
  });

  final DexyVariant variant;
  final Future<DexyBuildResult> Function(
      String action, int ergAmt, int dexyAmt, int lpAmt) onBuild;
  final String initialAction;
  final int? tokenBalance;
  final int? lpBalance;
  final int? spendableBalance;

  @override
  State<_DexyLiquiditySheet> createState() => _DexyLiquiditySheetState();
}

class _DexyLiquiditySheetState extends State<_DexyLiquiditySheet> {
  final _ergCtrl = TextEditingController();
  final _dexyCtrl = TextEditingController();
  final _lpCtrl = TextEditingController();
  Timer? _debounce;
  late String _action;
  DexyLpPreview? _preview;
  bool _previewing = false;
  String? _previewError;
  bool _building = false;

  @override
  void initState() {
    super.initState();
    _action = widget.initialAction;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ergCtrl.dispose();
    _dexyCtrl.dispose();
    _lpCtrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _refresh);
  }

  Future<void> _refresh() async {
    final variant = widget.variant;
    final isDeposit = _action == 'deposit';
    final erg = isDeposit ? parseErgToNano(_ergCtrl.text) : 0;
    final dexy =
        isDeposit ? parseDecimalToBase(_dexyCtrl.text, variant.decimals) : 0;
    final lp = !isDeposit ? parseDecimalToBase(_lpCtrl.text, 0) : 0;

    if ((isDeposit && (erg == null || erg <= 0 || dexy == null || dexy <= 0)) ||
        (!isDeposit && (lp == null || lp <= 0))) {
      setState(() {
        _preview = null;
        _previewError = null;
      });
      return;
    }
    setState(() => _previewing = true);
    try {
      final p = await dexService.previewLp(
        variant,
        _action,
        ergAmount: erg ?? 0,
        dexyAmount: dexy ?? 0,
        lpAmount: lp ?? 0,
      );
      if (!mounted) return;
      setState(() {
        _preview = p;
        _previewError = p.error;
        _previewing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _previewError = '$e';
        _previewing = false;
      });
    }
  }

  Future<void> _review() async {
    final variant = widget.variant;
    final int erg;
    final int dexy;
    final int lp;
    if (_action == 'deposit') {
      final e = parseErgToNano(_ergCtrl.text);
      final d = parseDecimalToBase(_dexyCtrl.text, variant.decimals);
      if (e == null || e <= 0 || d == null || d <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter both ERG and token amounts')));
        return;
      }
      erg = e;
      dexy = d;
      lp = 0;
    } else {
      final l = parseDecimalToBase(_lpCtrl.text, 0);
      if (l == null || l <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter an LP amount')));
        return;
      }
      erg = 0;
      dexy = 0;
      lp = l;
    }
    setState(() => _building = true);
    try {
      final build = await widget.onBuild(_action, erg, dexy, lp);
      if (!mounted) return;
      Navigator.of(context).pop({'final': build});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not prepare: $e')));
      setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = widget.variant;
    final isDeposit = _action == 'deposit';
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(isDeposit
              ? 'Add ${variant.shortName} liquidity'
              : 'Remove ${variant.shortName} liquidity',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          Row(
            children: [
              ChoiceChip(
                label: const Text('Deposit'),
                selected: isDeposit,
                onSelected: (_) => setState(() {
                  _action = 'deposit';
                  _preview = null;
                  _previewError = null;
                }),
                selectedColor: iris,
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Redeem'),
                selected: !isDeposit,
                onSelected: (_) => setState(() {
                  _action = 'redeem';
                  _preview = null;
                  _previewError = null;
                }),
                selectedColor: iris,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isDeposit) ...[
            TextField(
              controller: _ergCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _onChanged(),
              decoration: InputDecoration(
                labelText: 'ERG to deposit',
                suffixIcon: TextButton(
                  onPressed: () {
                    final b = widget.spendableBalance;
                    if (b != null) {
                      final max = b - minerFeeNano - minBoxNano;
                      if (max < minBoxNano) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Not enough ERG for fee and change'),
                          ),
                        );
                      } else {
                        _ergCtrl.text = formatErg(max, unit: false);
                      }
                    }
                    _onChanged();
                  },
                  child: const Text('MAX'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dexyCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _onChanged(),
              decoration: InputDecoration(
                labelText: '${variant.shortName} to deposit',
                suffixIcon: TextButton(
                  onPressed: () {
                    final b = widget.tokenBalance;
                    if (b != null)
                      _dexyCtrl.text = formatTokenAmount(b, variant.decimals);
                    _onChanged();
                  },
                  child: const Text('MAX'),
                ),
              ),
            ),
          ] else
            TextField(
              controller: _lpCtrl,
              keyboardType: const TextInputType.numberWithOptions(),
              onChanged: (_) => _onChanged(),
              decoration: InputDecoration(
                labelText: 'LP tokens to redeem',
                suffixIcon: TextButton(
                  onPressed: () {
                    final b = widget.lpBalance;
                    if (b != null) _lpCtrl.text = formatTokenAmount(b, 0);
                    _onChanged();
                  },
                  child: const Text('MAX'),
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (_previewing)
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Estimating…'),
              ],
            )
          else if (_preview != null && _preview!.canExecute) ...[
            if (isDeposit) ...[
              _sheetRow('LP tokens received',
                  '${formatTokenAmount(_preview!.lpTokens, 0)}'),
              _sheetRow('Consumed',
                  '${formatErg(_preview!.consumedErg)} + ${formatTokenAmount(_preview!.consumedDexy, variant.decimals)} ${variant.shortName}'),
            ] else ...[
              _sheetRow('Receive ERG', formatErg(_preview!.ergOut)),
              _sheetRow('Receive ${variant.shortName}',
                  '${formatTokenAmount(_preview!.dexyOut, variant.decimals)}'),
              _sheetRow(
                  'Redemption fee', '${_preview!.redemptionFeePct}%'),
            ],
          ] else if (_previewError != null)
            Text(_previewError!,
                style: TextStyle(color: rust, fontSize: 12)),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _building || _previewing ? null : _review,
              child: _building
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isDeposit ? 'Review deposit' : 'Review redeem'),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _sheetRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13)),
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    ),
  );
}