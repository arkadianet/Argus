import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../bridge/argus_error.dart';
import 'widgets/error_sheet.dart';
import '../services/dexy_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'dexy/dexy_confirm.dart';
import 'dexy/dexy_sheets.dart';
import 'offline_banner.dart';
import 'widgets/soft_card.dart';

/// Mint card and confirm-sheet title for a variant. Names the token (USE), not
/// the protocol implementation (DexyUSD).
String dexyMintTitle(DexyVariant variant) => 'Mint ${variant.shortName}';

/// Holdings header for a variant.
String dexyHoldingsTitle(DexyVariant variant) => 'Your ${variant.shortName}';

/// Mobile-first Dexy hub. Every action builds a transaction through the shared
/// confirm sheet ("Sign & broadcast") and submits via the cached-preparation
/// flow — the same guard rails as every other send in Argus.
class DexyScreen extends StatefulWidget {
  const DexyScreen({super.key, this.embedded = false});

  /// When true the screen renders without its own Scaffold/AppBar so it can
  /// live inside the swap hub's tab view.
  final bool embedded;

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
      WalletRouteArgs.of(context);

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

  // Mint outputs (tokens + ERG change) land on the change-policy address:
  // first derived by default, next unused when privacy mode is on.
  String get _recipient =>
      _args.changeAddress.isNotEmpty
          ? _args.changeAddress
          : _args.receiveAddress.isNotEmpty
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

  Future<void> _load({bool fresh = false}) async {
    setState(() {
      _loading = _state == null;
      _error = null;
    });
    try {
      final state = await dexService.state(_variant, fresh: fresh);
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
      final txId =
          await walletService.sendErg(preparationId: build.preparationId);
      if (!mounted) return;
      _snack('Broadcast! ${shorten(txId, head: 8, tail: 6)}');
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      await showTxFailureSheet(context, e);
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
      builder: (ctx) => DexyMintSheet(
        variant: _variant,
        state: _state!,
        spendableNano: _args.spendableNano,
        onBuild: (amount) => dexService.buildMint(
          variant: _variant,
          amount: amount,
          recipient: _recipient,
          changeAddress: _recipient,
          spendAddresses: _spendAddresses,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final build = result['build'] as DexyBuildResult;
    final c = dexyMintConfirm(build, _variant);
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: c.title,
      rows: c.rows,
      detail: c.detail,
      confirmLabel: c.confirmLabel,
    );
    if (confirmed) await _broadcast(build);
  }

  Future<void> _openSwap() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => DexySwapSheet(
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
          changeAddress: _recipient,
          spendAddresses: _spendAddresses,
        ),
      ),
    );
    if (result == null || !mounted) return;
    final build = result['final'] as DexyBuildResult;
    final c = dexySwapConfirm(build, _variant);
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: c.title,
      rows: c.rows,
      detail: c.detail,
      confirmLabel: c.confirmLabel,
    );
    if (confirmed) await _broadcast(build);
  }

  Future<void> _openLiquidity({String initialAction = 'deposit'}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => DexyLiquiditySheet(
        variant: _variant,
        state: _state!,
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
              changeAddress: _recipient,
              spendAddresses: _spendAddresses,
            );
          }
          return dexService.buildLpRedeem(
            variant: _variant,
            lpToBurn: lpAmt,
            recipient: _recipient,
            changeAddress: _recipient,
            spendAddresses: _spendAddresses,
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    final build = result['final'] as DexyBuildResult;
    final c = dexyLiquidityConfirm(build, _variant);
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: c.title,
      rows: c.rows,
      detail: c.detail,
      confirmLabel: c.confirmLabel,
    );
    if (confirmed) await _broadcast(build);
  }

  // ── Layout ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        const OfflineBanner(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(fresh: true),
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
        ),
      ],
    );
    if (widget.embedded) {
      return body;
    }
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
      body: body,
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
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: selected
                      ? accentOf(context).withValues(alpha: 0.14)
                      : Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected ? accentOf(context) : ArgusColors.of(context).cardBorder,
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
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(dexyHoldingsTitle(_variant),
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
    final lpPerToken = lpErgPerToken(st);
    final tokensPerErg = st.rates.tokensPerErg;
    final diff = st.rateDifferencePct;
    return SoftCard(
      padding: const EdgeInsets.all(16),
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
        borderRadius: BorderRadius.circular(12),
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
    return SoftCard(
      padding: const EdgeInsets.all(16),
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
              _stat('Free mint today',
                  '${formatTokenAmount(st.freeMintAvailable, _variant.decimals)} ${_variant.shortName}'),
              _stat('LP supply', _fmt(st.lpCirculating)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionsCard(BuildContext context) {
    return SoftCard(
      padding: const EdgeInsets.all(16),
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
    final colors = ArgusColors.of(context);
    return InkWell(
      onTap: _busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: colors.chip, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 19, color: accentOf(context)),
            ),
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
        borderRadius: BorderRadius.circular(8),
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
