import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/amm_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'offline_banner.dart';

/// One quote line. `formatTokenAmount` supplies the number; the symbol is
/// appended once here.
String swapQuoteLabel(
  AmmQuote quote, {
  required String outputSymbol,
  required int outputDecimals,
}) =>
    '≈ ${formatTokenAmount(quote.outputAmount, outputDecimals)} $outputSymbol'
    '  ·  impact ${quote.priceImpactPct.toStringAsFixed(2)}%';

/// Shown when discovery hit its cap, so a missing pair is explainable.
String poolTruncationNotice() =>
    'Pool list was capped — some pairs may be missing.';

/// Swap ERG and tokens directly against Spectrum AMM pools. The pool box is
/// spent in the same signed transaction, so quotes go stale on contention —
/// the service reports that as `POOL_MOVED` and this screen re-quotes.
class SwapScreen extends StatefulWidget {
  const SwapScreen({super.key, this.embedded = false});

  /// When true the screen renders without its own Scaffold/AppBar so it can
  /// live inside the swap hub's tab view.
  final bool embedded;

  @override
  State<SwapScreen> createState() => _SwapScreenState();
}

class _SwapScreenState extends State<SwapScreen> {
  AmmPoolSet? _set;
  bool _loading = true;
  String? _error;

  // null means ERG, matching the bridge's from/to encoding.
  String? _fromToken;
  String? _toToken;

  /// The FROM field is the single source of truth for quoting. The TO field
  /// is a convenience entry: editing it derives a required input via pool
  /// reserves and writes it back into the FROM field.
  final _amountCtrl = TextEditingController();
  final _toAmountCtrl = TextEditingController();
  Timer? _quoteDebounce;
  int _quoteGeneration = 0;
  AmmQuote? _quote;

  /// POOL_MOVED allows exactly one automatic re-quote; after that the user
  /// must decide.
  bool _movedRetried = false;
  bool _busy = false;

  /// Which field the user touched last: the quote result mirrors into the
  /// other one so both sides always show a consistent pair.
  String _lastEdited = 'from';

  WalletRouteArgs get _args =>
      WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);

  List<String> get _spendAddresses {
    final args = _args;
    return args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
  }

  String get _recipient =>
      _args.changeAddress.isNotEmpty
          ? _args.changeAddress
          : _args.receiveAddress;

  String _symbol(String? tokenId) =>
      tokenId == null ? 'ERG' : (_set?.tokens[tokenId]?.name ?? tokenId);

  int _decimals(String? tokenId) =>
      tokenId == null ? 9 : (_set?.tokens[tokenId]?.decimals ?? 0);

  /// Wallet balance for an asset; null = ERG spendable.
  BigInt? _balanceFor(String? tokenId) {
    if (tokenId == null) {
      final nano = _args.spendableNano;
      return nano == null ? null : BigInt.from(nano);
    }
    for (final t in _args.tokens) {
      if (t.id == tokenId) return BigInt.from(t.amount);
    }
    return BigInt.zero;
  }

  String _fmtAmount(BigInt raw, int decimals) {
    if (raw <= BigInt.from(0x7FFFFFFFFFFFFFFF)) {
      return formatTokenAmount(raw.toInt(), decimals);
    }
    // Exact manual scaling for reserves/amounts beyond i64.
    if (decimals <= 0) return raw.toString();
    final base = BigInt.from(10).pow(decimals);
    final whole = raw ~/ base;
    final frac =
        (raw % base).toString().padLeft(decimals, '0').replaceFirst(RegExp(r'0+$'), '');
    return frac.isEmpty ? '$whole' : '$whole.$frac';
  }

  String _fmtReserve(BigInt raw, int decimals) => _fmtAmount(raw, decimals);

  /// Deepest pool for the current pair by the reserve of whichever side the
  /// user is selling into, plus how many pools serve the pair — one scan.
  /// Recomputed per build; the pool list only changes via _loadPools.
  (Map<String, dynamic>?, int) _pairPoolInfo() {
    Map<String, dynamic>? best;
    var bestDepth = BigInt.zero;
    var count = 0;
    for (final pool in _set?.pools ?? const []) {
      if (!poolSupportsPair(pool, _fromToken, _toToken)) continue;
      count++;
      final sides = poolSides(pool);
      final rIn = sides.firstWhere((s) => s.$1 == _fromToken).$2;
      if (best == null || rIn > bestDepth) {
        best = pool;
        bestDepth = rIn;
      }
    }
    return (best, count);
  }

  /// Desired-TO editing: derive required input from pool reserves and seed
  /// the FROM field. The forward FFI quote remains authoritative. Any
  /// derivation failure clears the pay field so the two sides can't disagree
  /// about what is being quoted.
  void _onToAmountChanged(String text) {
    final parsed = parseDecimalToBase(text, _decimals(_toToken));
    if (parsed == null || parsed <= 0 || _fromToken == _toToken) {
      _invalidateFromForFailedDerivation();
      return;
    }
    final outRaw = BigInt.from(parsed);
    final pools = _set?.pools ?? const [];
    final match = bestPoolForOutput(
      pools: pools,
      from: _fromToken,
      to: _toToken,
      output: outRaw,
    );
    if (match == null) {
      _invalidateFromForFailedDerivation();
      return;
    }
    final (_, rIn, rOut) = match;
    final feeNum = (match.$1['fee_num'] as num?)?.toInt() ?? 0;
    final feeDenom = (match.$1['fee_denom'] as num?)?.toInt() ?? 1;
    final requiredIn = requiredInputFor(
      reservesIn: rIn,
      reservesOut: rOut,
      output: outRaw,
      feeNum: feeNum,
      feeDenom: feeDenom,
    );
    if (requiredIn == null) {
      _invalidateFromForFailedDerivation();
      return;
    }
    _amountCtrl.text = _fmtReserve(requiredIn, _decimals(_fromToken));
    _scheduleQuote();
  }

  void _invalidateFromForFailedDerivation() {
    if (_amountCtrl.text.isEmpty) return;
    setState(() => _amountCtrl.clear());
    _scheduleQuote();
  }

  @override
  void initState() {
    super.initState();
    _loadPools();
  }

  @override
  void dispose() {
    _quoteDebounce?.cancel();
    _amountCtrl.dispose();
    _toAmountCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPools() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final set = await ammService.pools();
      if (!mounted) return;
      setState(() {
        _set = set;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool get _extraIndexMissing =>
      (_error ?? '').contains('EXTRA_INDEX_REQUIRED');

  /// The pair changed, so any amount already entered needs re-quoting. This is
  /// also where the POOL_MOVED retry cap resets — a new pair is a new attempt,
  /// whereas repeated presses of Swap on the same pair are not.
  void _onPairChanged() {
    _movedRetried = false;
    _scheduleQuote();
  }

  void _scheduleQuote() {
    _quoteDebounce?.cancel();
    _quoteDebounce =
        Timer(const Duration(milliseconds: 300), _refreshQuote);
  }

  int? get _parsedAmount =>
      parseDecimalToBase(_amountCtrl.text, _decimals(_fromToken));

  Future<void> _refreshQuote() async {
    final amount = _parsedAmount;
    if (amount == null || amount <= 0 || _fromToken == _toToken) {
      if (mounted) setState(() => _quote = null);
      return;
    }
    final gen = ++_quoteGeneration;
    try {
      final q = await ammService.quote(
        fromToken: _fromToken,
        toToken: _toToken,
        amount: amount,
      );
      if (!mounted || gen != _quoteGeneration) return;
      setState(() {
        _quote = q;
        // Mirror the quoted output into the want field so both sides always
        // show a consistent pair — but only when the user's last edit was on
        // the pay side; otherwise it would fight their typing.
        if (_lastEdited == 'from') {
          _toAmountCtrl.text =
              _fmtAmount(BigInt.from(q.outputAmount), _decimals(_toToken));
        }
      });
    } catch (e) {
      if (!mounted || gen != _quoteGeneration) return;
      setState(() => _quote = null);
    }
  }

  Future<void> _swap() async {
    final quote = _quote;
    final amount = _parsedAmount;
    if (quote == null || amount == null || amount <= 0 || _busy) return;
    setState(() => _busy = true);
    try {
      final build = await ammService.buildSwap(
        fromToken: _fromToken,
        toToken: _toToken,
        amount: amount,
        minOutput: quote.minOutput,
        poolId: quote.poolId,
        recipient: _recipient,
        changeAddress: _recipient,
        spendAddresses: _spendAddresses,
      );
      if (!mounted) return;
      final confirmed = await showConfirmTransactionSheet(
        context,
        title: 'Swap ${_symbol(_fromToken)} → ${_symbol(_toToken)}',
        rows: [
          ConfirmTxRow(
            'You receive',
            '${formatTokenAmount(build.outputAmount, _decimals(_toToken))} '
            '${_symbol(_toToken)}',
          ),
          ConfirmTxRow(
            'Minimum received',
            '${formatTokenAmount(build.minOutput, _decimals(_toToken))} '
            '${_symbol(_toToken)}',
          ),
          ConfirmTxRow('Miner fee', formatErg(build.minerFee)),
          ConfirmTxRow('Total cost', formatErg(build.totalErgCost)),
        ],
        detail:
            'Direct Spectrum swap — the pool is a counterparty in this '
            'transaction.',
        confirmLabel: 'Sign & broadcast swap',
      );
      if (confirmed) await _broadcast(build);
    } catch (e) {
      final message = e is ArgusException ? e.message : e.toString();
      if (!mounted) return;
      if (message.contains('POOL_MOVED')) {
        if (!_movedRetried) {
          _movedRetried = true;
          _snack('Pool moved — quoting against current reserves');
          await _refreshQuote();
        } else {
          _snack('Pool moved — re-quote');
        }
      } else {
        _snack('Could not prepare swap: $message');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _broadcast(AmmSwapBuild build) async {
    try {
      final txId = await walletService.sendErg(preparationId: build.preparationId);
      if (!mounted) return;
      _snack('Broadcast! ${shorten(txId, head: 8, tail: 6)}');
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      _snack('Broadcast may have failed. Check activity before retrying. $e');
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final body = Column(
        children: [
          const OfflineBanner(),
          Expanded(child: _buildBody(context)),
        ],
      );
    if (widget.embedded) {
      return body;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Swap')),
      body: body,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_extraIndexMissing) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Your node doesn't support pool discovery"),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/settings'),
                icon: const Icon(Icons.settings, size: 18),
                label: const Text('Node settings'),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load pools. $_error',
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(onPressed: _loadPools, child: const Text('Retry')),
          ],
        ),
      );
    }

    final set = _set!;
    final (pool, poolCount) = _pairPoolInfo();
    final fromBal = _balanceFor(_fromToken);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (set.truncated)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(poolTruncationNotice(),
                style: Theme.of(context).textTheme.bodySmall),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _assetSelector('From', _fromToken, _toToken,
                (v) {
                  setState(() {
                    _fromToken = v;
                    _quote = null;
                  });
                  _onPairChanged();
                })),
            IconButton(
              tooltip: 'Flip direction',
              onPressed: () {
                setState(() {
                  final from = _fromToken;
                  _fromToken = _toToken;
                  _toToken = from;
                  final fromText = _amountCtrl.text;
                  _amountCtrl.text = _toAmountCtrl.text;
                  _toAmountCtrl.text = fromText;
                  _quote = null;
                  _lastEdited = 'from';
                });
                _onPairChanged();
              },
              icon: const Icon(Icons.swap_vert),
            ),
            Expanded(child: _assetSelector('To', _toToken, _fromToken,
                (v) {
                  setState(() {
                    _toToken = v;
                    _quote = null;
                  });
                  _onPairChanged();
                })),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _amountCtrl,
          decoration: InputDecoration(
            labelText: 'You pay (${_symbol(_fromToken)})',
            helperText: fromBal == null
                ? null
                : 'Balance ${_fmtAmount(fromBal, _decimals(_fromToken))}',
            suffixIcon: TextButton(
              onPressed:
                  fromBal == null || fromBal <= BigInt.zero ? null : _applyMax,
              child: const Text('MAX'),
            ),
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) {
            _lastEdited = 'from';
            // A manual pay amount invalidates the previously derived want.
            if (_toAmountCtrl.text.isNotEmpty) _toAmountCtrl.clear();
            _scheduleQuote();
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _toAmountCtrl,
          decoration: InputDecoration(
            labelText: 'You want (${_symbol(_toToken)})',
            helperText: 'Optional — we derive what to pay',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (text) {
            _lastEdited = 'to';
            _onToAmountChanged(text);
          },
        ),
        if (pool != null) ...[
          const SizedBox(height: 16),
          _depthCard(pool, poolCount),
        ],
        const SizedBox(height: 16),
        if (_quote == null)
          Text(
            _fromToken == _toToken
                ? 'Choose two different assets.'
                : 'Enter an amount on either side to see the quote.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else ...[
          Text(swapQuoteLabel(
            _quote!,
            outputSymbol: _symbol(_toToken),
            outputDecimals: _decimals(_toToken),
          )),
          const SizedBox(height: 4),
          Text(
            'Minimum received '
            '${formatTokenAmount(_quote!.minOutput, _decimals(_toToken))} '
            '${_symbol(_toToken)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _quote == null || _busy ? null : _swap,
          child: Text(_busy ? 'Preparing…' : 'Review swap'),
        ),
      ],
    );
  }

  void _applyMax() {
    final bal = _balanceFor(_fromToken);
    if (bal == null || bal <= BigInt.zero) return;
    // Selling ERG must leave room for miner fee + min-box reserve.
    var raw = bal;
    if (_fromToken == null) {
      final reserve = BigInt.from(minerFeeNano + minBoxNano);
      if (raw <= reserve) {
        _snack('Not enough ERG for fee and change');
        return;
      }
      raw -= reserve;
    }
    setState(() {
      _lastEdited = 'from';
      _amountCtrl.text = _fmtAmount(raw, _decimals(_fromToken));
      _toAmountCtrl.clear();
    });
    _scheduleQuote();
  }

  Widget _depthCard(Map<String, dynamic> pool, int poolCount) {
    final sides = poolSides(pool);
    String side((String?, BigInt) s) =>
        '${_fmtAmount(s.$2, _decimals(s.$1))} ${_symbol(s.$1)}';
    final rIn = sides.firstWhere((s) => s.$1 == _fromToken).$2;
    final rOut = sides.firstWhere((s) => s.$1 == _toToken).$2;
    // Rate per one whole FROM unit, expressed in TO raw units so the TO
    // decimals formatter below renders it correctly for any pair direction.
    final rate = (rIn > BigInt.zero)
        ? rOut * BigInt.from(10).pow(_decimals(_fromToken)) ~/ rIn
        : BigInt.zero;
    final verifiedIn = _fromToken != null && isVerifiedToken(_fromToken!);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Rate  ',
                  style: Theme.of(context).textTheme.bodySmall),
              Flexible(
                child: Text(
                  '1 ${_symbol(_fromToken)} ≈ '
                  '${_fmtAmount(rate > BigInt.zero ? rate : BigInt.zero, _decimals(_toToken))} '
                  '${_symbol(_toToken)}'
                  '${verifiedIn ? '' : ' · unverified token'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Pool depth  ${side(sides.firstWhere((s) => s.$1 == _fromToken))}'
            '  /  ${side(sides.firstWhere((s) => s.$1 == _toToken))}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (poolCount > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$poolCount pools available — using the deepest for your direction.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openAssetPicker(
    String label,
    String? current,
    String? otherSide,
    ValueChanged<String?> onPicked,
  ) async {
    // The record wraps the token id so a picked ERG (`(null,)`) is distinct
    // from a dismissed sheet (`null`).
    final result = await showModalBottomSheet<(String?,)>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => _AssetPickerSheet(
        title: label,
        set: _set,
        heldTokens: _args.tokens,
        spendableNano: _args.spendableNano,
        exclude: otherSide,
      ),
    );
    if (result == null) return; // dismissed
    if (result.$1 != current) onPicked(result.$1);
  }

  Widget _assetSelector(
    String label,
    String? value,
    String? otherSide,
    ValueChanged<String?> onChanged,
  ) {
    final verified = value != null && isVerifiedToken(value);
    return InkWell(
      borderRadius: BorderRadius.circular(buttonRadius),
      onTap: () => _openAssetPicker(label, value, otherSide, onChanged),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _symbol(value),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (verified)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Tooltip(
                  message: 'Verified protocol token',
                  child: Icon(Icons.verified_outlined,
                      size: 16, color: moss),
                ),
              ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

class _AssetPickerSheet extends StatefulWidget {
  const _AssetPickerSheet({
    required this.title,
    required this.set,
    required this.heldTokens,
    required this.spendableNano,
    required this.exclude,
  });

  final String title;
  final AmmPoolSet? set;
  final List<TokenBalance> heldTokens;
  final int? spendableNano;

  /// Asset that cannot be picked (the other side of the pair).
  final String? exclude;

  @override
  State<_AssetPickerSheet> createState() => _AssetPickerSheetState();
}

class _AssetPickerSheetState extends State<_AssetPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tokens = widget.set?.tokens ?? const {};
    final poolIds = <String>{for (final id in tokens.keys) id};

    final verified =
        verifiedTokenLabels().keys.where(poolIds.contains).toList();
    final rest = poolIds.where((id) => !verified.contains(id)).toList()..sort();

    String symbol(String? id) =>
        id == null ? 'ERG' : (tokens[id]?.name ?? id);

    bool matches(String? id) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return symbol(id).toLowerCase().contains(q) ||
          (id?.toLowerCase().contains(q) ?? false);
    }

    final showErg = matches(null);
    final heldRows = [
      for (final t in widget.heldTokens)
        if (t.id != widget.exclude && matches(t.id)) t,
    ];
    final verifiedRows = [
      for (final id in verified)
        if (id != widget.exclude &&
            !widget.heldTokens.any((t) => t.id == id) &&
            matches(id))
          id,
    ];
    final restRows = [
      for (final id in rest)
        if (id != widget.exclude &&
            !widget.heldTokens.any((t) => t.id == id) &&
            matches(id))
          id,
    ];

    Widget row(String? id, {BigInt? balance}) {
      final isVerified = id != null && isVerifiedToken(id);
      final disabled = id == widget.exclude;
      return ListTile(
        enabled: !disabled,
        dense: true,
        title: Text(symbol(id)),
        subtitle: balance != null
            ? Text(formatTokenAmount(
                balance <= BigInt.from(0x7FFFFFFFFFFFFFFF)
                    ? balance.toInt()
                    : 0,
                id == null ? 9 : (tokens[id]?.decimals ?? 0)))
            : (isVerified ? const Text('Verified') : null),
        trailing: isVerified
            ? Icon(Icons.verified_outlined, size: 18, color: moss)
            : null,
        onTap: disabled ? null : () => Navigator.pop(context, (id,)),
      );
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: 'Search name or token id',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(widget.title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  const SizedBox(height: 8),
                  if (!showErg &&
                      heldRows.isEmpty &&
                      verifiedRows.isEmpty &&
                      restRows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Nothing matches "$_query".',
                          style: Theme.of(context).textTheme.bodySmall),
                    )
                  else ...[
                    if (showErg || heldRows.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('Your tokens',
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                      if (showErg)
                        row(null,
                            balance: widget.spendableNano == null
                                ? null
                                : BigInt.from(widget.spendableNano!)),
                      for (final t in heldRows)
                        row(t.id, balance: BigInt.from(t.amount)),
                      const Divider(height: 24),
                    ],
                    if (verifiedRows.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('Verified protocols',
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                      for (final id in verifiedRows) row(id),
                      const SizedBox(height: 8),
                    ],
                    if (restRows.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('All pool assets',
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                      for (final id in restRows) row(id),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
