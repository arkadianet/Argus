import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../format.dart';
import '../services/amm_service.dart';
import '../services/liquidity_math.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/empty_state.dart';
import 'widgets/error_sheet.dart';
import 'widgets/soft_card.dart';

Future<bool> confirmForgetPool(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete saved pool progress?'),
        content: const Text('This removes the Finish the pool action. It does not cancel or refund the first transaction. Keep this progress if you still need to finish the pool.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep progress')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete progress')),
        ],
      ),
    ) ?? false;

class PoolCreationStore {
  PoolCreationStore(this.walletId);
  final String walletId;
  String get _key => 'argus_pool_creation_v1_$walletId';

  Future<Map<String, dynamic>?> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    return raw == null ? null : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<void> save(Map<String, dynamic>? record) async {
    final prefs = await SharedPreferences.getInstance();
    if (record == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, jsonEncode({...record, 'wallet_id': walletId}));
    }
  }

  Future<bool> hasLegacy() async =>
      (await SharedPreferences.getInstance()).containsKey('argus_pool_creation_v1');
}

/// A Spectrum pool as the Liquidity screen sees it.
class LiquidityPool {
  LiquidityPool(this.raw, this.tokens);
  final Map<String, dynamic> raw;
  final Map<String, AmmTokenMeta> tokens;

  String get id => raw['pool_id'] as String;
  bool get isN2T => raw['pool_type'] == 'N2T';
  String get lpTokenId => raw['lp_token_id'] as String;
  BigInt get lpCirculating => BigInt.parse('${raw['lp_circulating']}');

  /// X: ERG for an ERG pool, else the X token.
  String? get xTokenId => isN2T ? null : (raw['token_x'] as Map)['token_id'] as String;
  BigInt get xReserves => isN2T ? BigInt.parse('${raw['erg_reserves']}') : BigInt.parse('${(raw['token_x'] as Map)['amount']}');
  String get yTokenId => (raw['token_y'] as Map)['token_id'] as String;
  BigInt get yReserves => BigInt.parse('${(raw['token_y'] as Map)['amount']}');

  String name(String? tokenId) => tokenId == null ? 'ERG' : (tokens[tokenId]?.name ?? shorten(tokenId, head: 6, tail: 4));
  int decimals(String? tokenId) => tokenId == null ? 9 : (tokens[tokenId]?.decimals ?? 0);
  String get pairLabel => '${name(xTokenId)} / ${name(yTokenId)}';
  double get feePercent {
    final n = (raw['fee_num'] as num?)?.toInt() ?? 997;
    final d = (raw['fee_denom'] as num?)?.toInt() ?? 1000;
    return (1 - n / d) * 100;
  }
}

/// Spectrum liquidity: what you provide, adding and removing, and
/// creating a pool.
class LiquidityScreen extends StatefulWidget {
  const LiquidityScreen({super.key, this.readPools});
  final Future<AmmPoolSet> Function(bool force)? readPools;

  @override
  State<LiquidityScreen> createState() => _LiquidityScreenState();
}

class _LiquidityScreenState extends State<LiquidityScreen> {
  List<LiquidityPool> _pools = const [];
  bool _loading = true;
  bool _truncated = false;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _loadPools();
  }

  Future<void> _loadPools({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final set = await (widget.readPools?.call(force) ?? ammService.pools(forceRefresh: force));
      if (!mounted) return;
      setState(() {
        _pools = [for (final p in set.pools) LiquidityPool(p, set.tokens)];
        _truncated = set.truncated;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Pools whose LP token this wallet holds, with the amount.
  List<(LiquidityPool, int)> _positions(WalletRouteArgs args) {
    final held = {for (final t in args.tokens) t.id: t.amount};
    return [
      for (final p in _pools)
        if ((held[p.lpTokenId] ?? 0) > 0) (p, held[p.lpTokenId]!),
    ];
  }

  Future<void> _confirmAndSend(Map<String, dynamic> prepared, {required String title, required List<ConfirmTxRow> rows, String? detail, String confirmLabel = 'Sign & broadcast'}) async {
    final ok = await showConfirmTransactionSheet(
      context,
      title: title,
      confirmLabel: confirmLabel,
      detail: detail,
      rows: rows,
      preparationId: (prepared['preparation_id'] as num).toInt(),
    );
    if (!ok || !mounted) return;
    final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sent: ${shorten(txId)}')));
  }

  Future<void> _add(LiquidityPool pool) async {
    if (_working) return;
    final args = WalletRouteArgs.of(context);
    final picked = await showModalBottomSheet<(int, int)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (_) => _AddSheet(pool: pool, args: args),
    );
    if (picked == null || !mounted) return;
    setState(() => _working = true);
    try {
      final prepared = await ammService.buildLpDeposit(
        poolId: pool.id,
        xAmount: picked.$1,
        yAmount: picked.$2,
        recipient: args.receiveAddress,
        changeAddress: args.changeAddress,
        spendAddresses: args.historyAddresses,
      );
      if (!mounted) return;
      await _confirmAndSend(prepared, title: 'Add liquidity to ${pool.pairLabel}', rows: [
        ConfirmTxRow('Deposit ${pool.name(pool.xTokenId)}', _fmt(prepared['x_deposited'], pool.decimals(pool.xTokenId), pool.name(pool.xTokenId)), bold: true),
        ConfirmTxRow('Deposit ${pool.name(pool.yTokenId)}', _fmt(prepared['y_deposited'], pool.decimals(pool.yTokenId), pool.name(pool.yTokenId)), bold: true),
        ConfirmTxRow('LP tokens received', '${prepared['lp_reward']}'),
        ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
      ], detail: 'Spends the pool box directly with your boxes; no bot is involved. Your share earns the pool\'s ${pool.feePercent.toStringAsFixed(2)}% swap fee.');
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not add liquidity', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _remove(LiquidityPool pool, int held) async {
    if (_working) return;
    final args = WalletRouteArgs.of(context);
    final lp = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius))),
      builder: (_) => _RemoveSheet(pool: pool, held: held),
    );
    if (lp == null || !mounted) return;
    setState(() => _working = true);
    try {
      final prepared = await ammService.buildLpRedeem(
        poolId: pool.id,
        lpAmount: lp,
        recipient: args.receiveAddress,
        changeAddress: args.changeAddress,
        spendAddresses: args.historyAddresses,
      );
      if (!mounted) return;
      await _confirmAndSend(prepared, title: 'Remove liquidity from ${pool.pairLabel}', rows: [
        ConfirmTxRow('LP tokens returned', '${prepared['lp_redeemed']}', bold: true),
        ConfirmTxRow('You receive', _fmt(prepared['x_received'], pool.decimals(pool.xTokenId), pool.name(pool.xTokenId)), bold: true),
        ConfirmTxRow('And', _fmt(prepared['y_received'], pool.decimals(pool.yTokenId), pool.name(pool.yTokenId)), bold: true),
        ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
      ]);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not remove liquidity', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  static String _fmt(Object? units, int decimals, String name) => '${formatTokenAmountGrouped((units as num).toInt(), decimals)} $name';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final args = WalletRouteArgs.of(context);
    final positions = _positions(args);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Liquidity'),
          actions: [
            IconButton(tooltip: 'Refresh pools', onPressed: _loading ? null : () => _loadPools(force: true), icon: const Icon(Icons.refresh)),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Pools'), Tab(text: 'Create a pool')]),
        ),
        body: TabBarView(
          children: [
            RefreshIndicator(
              onRefresh: () => _loadPools(force: true),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  Text(
                    'Provide both sides of a Spectrum pool and hold LP tokens for your share; every swap '
                    'through the pool pays its fee to the providers. Adding and removing spend the pool '
                    'box directly, with no bot.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    SelectableText('Could not read the pools: $_error', style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                  if (positions.isNotEmpty) ...[
                    const SectionLabel('Your positions'),
                    const SizedBox(height: 8),
                    for (final (p, held) in positions) ...[
                      _PoolCard(
                        pool: p,
                        held: held,
                        onAdd: _working ? null : () => _add(p),
                        onRemove: _working ? null : () => _remove(p, held),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 12),
                  ],
                  const SectionLabel('Pools'),
                  const SizedBox(height: 8),
                  if (_loading && _pools.isEmpty)
                    const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                  else if (_pools.isEmpty)
                    const EmptyState(icon: Icons.water_drop_outlined, title: 'No pools read', body: 'Pull down to read the Spectrum pools.', compact: true)
                  else
                    for (final p in _pools.where((p) => !positions.any((x) => x.$1.id == p.id))) ...[
                      _PoolCard(pool: p, held: 0, onAdd: _working ? null : () => _add(p)),
                      const SizedBox(height: 10),
                    ],
                  const SizedBox(height: 8),
                  Text(_truncated
                      ? 'The pool search reached its limit. Some pools and your positions may be missing.'
                      : 'Pools are read from the network.', style: TextStyle(color: muted, fontSize: 12)),
                ],
              ),
            ),
            _CreateTab(key: ValueKey(walletService.activeWalletId), args: args, tokens: _pools.isEmpty ? const {} : _pools.first.tokens),
          ],
        ),
      ),
    );
  }
}

class _PoolCard extends StatelessWidget {
  const _PoolCard({required this.pool, required this.held, this.onAdd, this.onRemove});
  final LiquidityPool pool;
  final int held;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final p = pool;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
            Text(value, style: monoStyle(context, size: 12.5)),
          ]),
        );
    final shareBps = held > 0 ? poolShareBps(BigInt.from(held), p.lpCirculating) : 0;
    final (xo, yo) = held > 0 ? redeemShares(p.xReserves, p.yReserves, p.lpCirculating, BigInt.from(held)) : (BigInt.zero, BigInt.zero);
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(p.pairLabel, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
            Text('${p.feePercent.toStringAsFixed(2)}% fee', style: TextStyle(color: muted, fontSize: 12)),
          ]),
          const SizedBox(height: 8),
          if (held > 0) ...[
            row('Your share', '${(shareBps / 100).toStringAsFixed(2)}% · $held LP'),
            row('Worth', '${formatTokenAmountGrouped(xo.toInt(), p.decimals(p.xTokenId))} ${p.name(p.xTokenId)} + ${formatTokenAmountGrouped(yo.toInt(), p.decimals(p.yTokenId))} ${p.name(p.yTokenId)}'),
          ],
          row('Reserves', '${formatTokenAmountGrouped(p.xReserves.toInt(), p.decimals(p.xTokenId))} ${p.name(p.xTokenId)} · ${formatTokenAmountGrouped(p.yReserves.toInt(), p.decimals(p.yTokenId))} ${p.name(p.yTokenId)}'),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            FilledButton.tonal(style: inlineButtonStyle, onPressed: onAdd, child: const Text('Add')),
            if (held > 0) OutlinedButton(style: inlineButtonStyle, onPressed: onRemove, child: const Text('Remove')),
          ]),
        ],
      ),
    );
  }
}

/// Both sides of a deposit, the second following the first at the pool's ratio.
class _AddSheet extends StatefulWidget {
  const _AddSheet({required this.pool, required this.args});
  final LiquidityPool pool;
  final WalletRouteArgs args;

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _x = TextEditingController();
  final _y = TextEditingController();
  bool _editingX = true;

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  int _held(String? tokenId) => tokenId == null
      ? (widget.args.spendableNano ?? 0)
      : widget.args.tokens.where((t) => t.id == tokenId).fold(0, (a, t) => a + t.amount);

  (int?, int?) get _units {
    final p = widget.pool;
    final x = parseDecimalToBase(_x.text, p.decimals(p.xTokenId));
    final y = parseDecimalToBase(_y.text, p.decimals(p.yTokenId));
    return (x, y);
  }

  void _follow() {
    final p = widget.pool;
    setState(() {
      if (_editingX) {
        final x = parseDecimalToBase(_x.text, p.decimals(p.xTokenId));
        _y.text = x == null ? '' : formatTokenAmount(depositCounterpart(p.xReserves, p.yReserves, BigInt.from(x)).toInt(), p.decimals(p.yTokenId));
      } else {
        final y = parseDecimalToBase(_y.text, p.decimals(p.yTokenId));
        _x.text = y == null ? '' : formatTokenAmount(depositCounterpart(p.yReserves, p.xReserves, BigInt.from(y)).toInt(), p.decimals(p.xTokenId));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pool;
    final muted = ArgusColors.of(context).muted;
    final (x, y) = _units;
    final reward = x != null && y != null ? lpReward(p.xReserves, p.yReserves, p.lpCirculating, BigInt.from(x), BigInt.from(y)) : BigInt.zero;
    final tooMuch = (x != null && x > _held(p.xTokenId)) || (y != null && y > _held(p.yTokenId));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add to ${p.pairLabel}', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('lp-x'),
            controller: _x,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: p.name(p.xTokenId), helperText: 'You hold ${formatTokenAmountGrouped(_held(p.xTokenId), p.decimals(p.xTokenId))}'),
            onTap: () => _editingX = true,
            onChanged: (_) {
              _editingX = true;
              _follow();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('lp-y'),
            controller: _y,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: p.name(p.yTokenId), helperText: 'You hold ${formatTokenAmountGrouped(_held(p.yTokenId), p.decimals(p.yTokenId))}'),
            onTap: () => _editingX = false,
            onChanged: (_) {
              _editingX = false;
              _follow();
            },
          ),
          const SizedBox(height: 12),
          if (tooMuch) Text('More than you hold', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          if (reward > BigInt.zero)
            Text('About $reward LP tokens, ${(poolShareBps(reward, p.lpCirculating + reward) / 100).toStringAsFixed(3)}% of the pool. Both amounts follow the pool\'s ratio; the smaller side decides.',
                style: TextStyle(color: muted, fontSize: 12.5)),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('lp-add-continue'),
            onPressed: x == null || y == null || x <= 0 || y <= 0 || tooMuch || reward <= BigInt.zero ? null : () => Navigator.pop(context, (x, y)),
            child: const Text('Continue'),
          ),
        ],
      ),
    )));
  }
}

class _RemoveSheet extends StatefulWidget {
  const _RemoveSheet({required this.pool, required this.held});
  final LiquidityPool pool;
  final int held;

  @override
  State<_RemoveSheet> createState() => _RemoveSheetState();
}

class _RemoveSheetState extends State<_RemoveSheet> {
  double _fraction = 1;

  @override
  Widget build(BuildContext context) {
    final p = widget.pool;
    final muted = ArgusColors.of(context).muted;
    final lp = (widget.held * _fraction).floor();
    final (xo, yo) = redeemShares(p.xReserves, p.yReserves, p.lpCirculating, BigInt.from(lp));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Remove from ${p.pairLabel}', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('${(_fraction * 100).round()}% · $lp of ${widget.held} LP', style: TextStyle(color: muted)),
          Slider(key: const Key('lp-remove-slider'), value: _fraction, min: 0.01, max: 1, divisions: 99, onChanged: (v) => setState(() => _fraction = v)),
          Text('You receive about ${formatTokenAmountGrouped(xo.toInt(), p.decimals(p.xTokenId))} ${p.name(p.xTokenId)} and ${formatTokenAmountGrouped(yo.toInt(), p.decimals(p.yTokenId))} ${p.name(p.yTokenId)}.',
              style: TextStyle(color: muted, fontSize: 12.5)),
          const SizedBox(height: 16),
          FilledButton(key: const Key('lp-remove-continue'), onPressed: lp <= 0 ? null : () => Navigator.pop(context, lp), child: const Text('Continue')),
        ],
      ),
    );
  }
}

/// Create a pool in two transactions; the second waits for the first to
/// confirm, so what it needs is remembered on this device in between.
class _CreateTab extends StatefulWidget {
  const _CreateTab({super.key, required this.args, required this.tokens});
  final WalletRouteArgs args;
  final Map<String, AmmTokenMeta> tokens;

  @override
  State<_CreateTab> createState() => _CreateTabState();
}

class _CreateTabState extends State<_CreateTab> with AutomaticKeepAliveClientMixin {
  late final String? _walletId = walletService.activeWalletId;
  PoolCreationStore? get _store => _walletId == null ? null : PoolCreationStore(_walletId);
  bool _loadingPending = true;
  String? _progressError;
  String? _xTokenId; // null = ERG
  String? _yTokenId;
  final _x = TextEditingController();
  final _y = TextEditingController();
  double _feePercent = 0.3;
  bool _working = false;
  Map<String, dynamic>? _pending;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  Future<void> _loadPending() async {
    try {
      final pending = await _store?.load();
      final legacy = await _store?.hasLegacy() ?? false;
      if (!mounted) return;
      setState(() {
        _pending = pending;
        _progressError = legacy
            ? 'Saved pool progress from an older version has no wallet owner. It has been kept, but cannot safely be finished here.'
            : null;
      });
    } catch (e) {
      if (mounted) setState(() => _progressError = 'Could not read saved pool progress: $e');
    } finally {
      if (mounted) setState(() => _loadingPending = false);
    }
  }

  Future<void> _savePending(Map<String, dynamic>? p) async {
    await _store!.save(p);
    if (mounted) setState(() => _pending = p);
  }

  bool get _ownsWallet => _walletId != null && walletService.activeWalletId == _walletId;

  Future<void> _forget() async {
    try {
      if (await confirmForgetPool(context) && mounted) await _savePending(null);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not delete progress', message: '$e');
    }
  }

  int _decimals(String? id) => id == null ? 9 : (widget.tokens[id]?.decimals ?? widget.args.tokens.where((t) => t.id == id).firstOrNull?.decimals ?? 0);
  String _name(String? id) => id == null ? 'ERG' : (widget.args.tokens.where((t) => t.id == id).firstOrNull?.label ?? widget.tokens[id]?.name ?? shorten(id, head: 6, tail: 4));

  Future<void> _bootstrap() async {
    final y = _yTokenId;
    final xUnits = parseDecimalToBase(_x.text, _decimals(_xTokenId));
    final yUnits = parseDecimalToBase(_y.text, _decimals(y));
    if (!_ownsWallet || _loadingPending || y == null || xUnits == null || yUnits == null || xUnits <= 0 || yUnits <= 0 || _working) return;
    if (_xTokenId != null && _xTokenId == y) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick two different assets')));
      return;
    }
    final poolType = _xTokenId == null ? 'N2T' : 'T2T';
    setState(() => _working = true);
    try {
      final prepared = await ammService.buildPoolBootstrap(
        poolType: poolType,
        xTokenId: _xTokenId,
        xAmount: xUnits,
        yTokenId: y,
        yAmount: yUnits,
        feeNum: feeNumFor(_feePercent),
        userAddress: widget.args.receiveAddress,
        spendAddresses: widget.args.historyAddresses,
      );
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Create a pool, step 1 of 2',
        confirmLabel: 'Sign & broadcast',
        detail: 'Mints the pool\'s LP supply into a box of yours holding the first reserves. Once it confirms, '
            'step 2 turns that box into the pool. Argus remembers step 2 for you.',
        rows: [
          ConfirmTxRow('Pair', '${_name(_xTokenId)} / ${_name(y)}', bold: true),
          ConfirmTxRow('First reserves', '${formatTokenAmountGrouped(xUnits, _decimals(_xTokenId))} ${_name(_xTokenId)} + ${formatTokenAmountGrouped(yUnits, _decimals(y))} ${_name(y)}'),
          ConfirmTxRow('Swap fee', '${_feePercent.toStringAsFixed(2)}%'),
          ConfirmTxRow('Your LP share', '${prepared['user_lp_share']} of ${prepared['lp_minted']}'),
          ConfirmTxRow('LP token id', shorten(prepared['lp_token_id'] as String, head: 10, tail: 8)),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted || !_ownsWallet) return;
      // Everything step 2 needs is known before step 1 goes out, so write the
      // record first: if the app dies between the broadcast and the write, the
      // bootstrap box would otherwise be stranded with the user's reserves in it.
      final record = <String, dynamic>{
        'bootstrap_box_id': prepared['bootstrap_box_id'],
        'pool_type': poolType,
        'x_token_id': _xTokenId,
        'x_amount': xUnits,
        'y_token_id': y,
        'y_amount': yUnits,
        'fee_num': feeNumFor(_feePercent),
        'lp_token_id': prepared['lp_token_id'],
        'user_lp_share': prepared['user_lp_share'],
        'pair': '${_name(_xTokenId)} / ${_name(y)}',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'sent': false,
      };
      await _savePending(record);
      if (!_ownsWallet) return;
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      await _savePending({...record, 'bootstrap_tx_id': txId, 'sent': true});
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not start the pool', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _create() async {
    final p = _pending;
    if (!_ownsWallet || p == null || _working) return;
    setState(() => _working = true);
    try {
      final prepared = await ammService.buildPoolCreate(
        bootstrapBoxId: p['bootstrap_box_id'] as String,
        poolType: p['pool_type'] as String,
        xTokenId: p['x_token_id'] as String?,
        xAmount: (p['x_amount'] as num).toInt(),
        yTokenId: p['y_token_id'] as String,
        yAmount: (p['y_amount'] as num).toInt(),
        feeNum: (p['fee_num'] as num).toInt(),
        lpTokenId: p['lp_token_id'] as String,
        userLpShare: (p['user_lp_share'] as num).toInt(),
        userAddress: widget.args.receiveAddress,
      );
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Create a pool, step 2 of 2',
        confirmLabel: 'Sign & broadcast',
        detail: 'Spends the bootstrap box into the pool box and hands you your LP share. The pool is live once this confirms.',
        rows: [
          ConfirmTxRow('Pair', p['pair'] as String, bold: true),
          ConfirmTxRow('Pool NFT', shorten(prepared['pool_nft_id'] as String, head: 10, tail: 8)),
          ConfirmTxRow('Your LP share', '${p['user_lp_share']}'),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted || !_ownsWallet) return;
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      await _savePending(null);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Pool created: ${shorten(txId)}')));
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not create the pool', message: '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final pending = _pending;
    final held = widget.args.tokens.where((t) => !t.isNft).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        if (_loadingPending) const LinearProgressIndicator(),
        if (_progressError != null) Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SelectableText(_progressError!),
        ),
        if (pending != null) ...[
          SoftCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Step 2 waiting: ${pending['pair']}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  (pending['sent'] as bool? ?? true)
                      ? 'Step 1 was sent ${formatSyncAge(DateTime.fromMillisecondsSinceEpoch((pending['created_at'] as num).toInt()))}. '
                          'Once it has confirmed, finish the pool.'
                      : 'Step 1 was prepared ${formatSyncAge(DateTime.fromMillisecondsSinceEpoch((pending['created_at'] as num).toInt()))} but Argus never saw it '
                          'accepted. If it did go out, finish the pool once it confirms; if it did not, forget this and start again.',
                  style: TextStyle(color: muted, fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, children: [
                  FilledButton(style: inlineButtonStyle, onPressed: _working || !_ownsWallet ? null : _create, child: const Text('Finish the pool')),
                  TextButton(onPressed: _working ? null : _forget, child: const Text('Forget')),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          'A new Spectrum pool takes two transactions: one mints the LP supply into a box of yours with '
          'the first reserves, the next turns it into the pool. The first reserves set the starting price.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String?>(
          key: const Key('pool-x'),
          initialValue: _xTokenId,
          decoration: const InputDecoration(labelText: 'First asset'),
          items: [
            const DropdownMenuItem(value: null, child: Text('ERG')),
            for (final t in held) DropdownMenuItem(value: t.id, child: Text(t.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _xTokenId = v),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const Key('pool-y'),
          initialValue: _yTokenId,
          decoration: const InputDecoration(labelText: 'Second asset (a token)'),
          items: [for (final t in held) DropdownMenuItem(value: t.id, child: Text(t.label, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _yTokenId = v),
        ),
        const SizedBox(height: 12),
        TextField(key: const Key('pool-x-amount'), controller: _x, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${_name(_xTokenId)} to put in'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        TextField(key: const Key('pool-y-amount'), controller: _y, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '${_name(_yTokenId)} to put in'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        Text('Swap fee ${_feePercent.toStringAsFixed(2)}%', style: TextStyle(color: muted)),
        Slider(key: const Key('pool-fee'), value: _feePercent, min: 0.1, max: 5, divisions: 49, onChanged: (v) => setState(() => _feePercent = v)),
        const SizedBox(height: 8),
        Text('Costs 0.002 ERG for the two boxes plus two miner fees. Only pools with real reserves attract swaps.', style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('pool-start'),
          onPressed: !_ownsWallet || _loadingPending || _progressError != null || _working || pending != null || _yTokenId == null || _x.text.trim().isEmpty || _y.text.trim().isEmpty ? null : _bootstrap,
          child: Text(_working ? 'Preparing…' : 'Start the pool (step 1)'),
        ),
      ],
    );
  }
}

@visibleForTesting
Widget liquidityAddSheetForTest(LiquidityPool pool, WalletRouteArgs args) =>
    _AddSheet(pool: pool, args: args);
