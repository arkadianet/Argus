import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/amm_service.dart';
import '../services/wallet_service.dart';
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

  final _amountCtrl = TextEditingController();
  Timer? _quoteDebounce;
  int _quoteGeneration = 0;
  AmmQuote? _quote;

  /// POOL_MOVED allows exactly one automatic re-quote; after that the user
  /// must decide.
  bool _movedRetried = false;
  bool _busy = false;

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

  @override
  void initState() {
    super.initState();
    _loadPools();
  }

  @override
  void dispose() {
    _quoteDebounce?.cancel();
    _amountCtrl.dispose();
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
      setState(() => _quote = q);
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

  List<DropdownMenuItem<String?>> _assetItems(bool includeFrom) {
    final tokens = _set?.tokens ?? const {};
    return [
      DropdownMenuItem<String?>(
        value: null,
        child: Text(includeFrom ? 'ERG' : 'ERG'),
      ),
      ...tokens.entries.map(
        (e) => DropdownMenuItem(value: e.key, child: Text(e.value.name)),
      ),
    ];
  }

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
            Expanded(child: _dropdown('From', _fromToken, _assetItems(true),
                (v) {
                  setState(() {
                    _fromToken = v;
                    _quote = null;
                  });
                  _onPairChanged();
                })),
            IconButton(
              onPressed: () {
                setState(() {
                  final from = _fromToken;
                  _fromToken = _toToken;
                  _toToken = from;
                  _quote = null;
                });
                _onPairChanged();
              },
              icon: const Icon(Icons.swap_vert),
            ),
            Expanded(child: _dropdown('To', _toToken, _assetItems(false),
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
            labelText: '${_symbol(_fromToken)} amount',
            suffixText: _symbol(_fromToken),
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => _scheduleQuote(),
        ),
        const SizedBox(height: 16),
        if (_quote == null)
          Text(
            _fromToken == _toToken
                ? 'Choose two different assets.'
                : 'Enter an amount to see the quote.',
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

  Widget _dropdown(
    String label,
    String? value,
    List<DropdownMenuItem<String?>> items,
    ValueChanged<String?> onChanged,
  ) {
    return DropdownButtonFormField<String?>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: onChanged,
    );
  }
}
