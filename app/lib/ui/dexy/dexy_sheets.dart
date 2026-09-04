import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app_fee.dart';

import '../../format.dart';
import '../../services/dexy_service.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';
import '../dexy_screen.dart';
import '../widgets/error_sheet.dart';

class DexyMintSheet extends StatefulWidget {
  const DexyMintSheet({
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
  State<DexyMintSheet> createState() => DexyMintSheetState();
}

class DexyMintSheetState extends State<DexyMintSheet> {
  final _ergCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  Timer? _debounce;
  DexyMintPreview? _preview;
  bool _previewing = false;
  String? _previewError;
  bool _building = false;

  /// Oracle rate for this sheet's variant; zero when the state handed in
  /// belongs to the other variant, so no conversion runs on wrong numbers.
  double get _effectiveRate => mintRateFor(widget.state, widget.variant);

  @override
  void dispose() {
    _debounce?.cancel();
    _ergCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  /// Set when the ERG typed does not divide into whole token units, so the
  /// sheet can say what the entered ERG actually buys.
  String? _roundingNote;

  void _onErgChanged() {
    final parsed = double.tryParse(_ergCtrl.text.trim());
    _roundingNote = null;
    if (parsed != null && parsed > 0 && _effectiveRate > 0) {
      final decimals = widget.variant.decimals;
      final tokenVal = parsed / _effectiveRate;
      var scale = 1;
      for (var i = 0; i < decimals; i++) {
        scale *= 10;
      }
      final baseUnits = (tokenVal * scale).floor();
      _tokenCtrl.text = formatScaled(baseUnits, decimals);
      _roundingNote = mintRoundingNote(
        ergTyped: parsed,
        baseUnits: baseUnits,
        decimals: decimals,
        ergPerToken: _effectiveRate,
        shortName: widget.variant.shortName,
      );
    } else {
      _tokenCtrl.clear();
    }
    _triggerPreview();
  }

  void _onTokenChanged() {
    final parsed = double.tryParse(_tokenCtrl.text.trim());
    _roundingNote = null;
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
    final maxNano = spendable - minerFeeNano - argusFeeNano - minBoxNano;
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
      await showErrorSheet(context, title: 'Could not prepare', message: '$e');
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
          Text(dexyMintTitle(variant),
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
              helperText: _roundingNote ??
                  'Fixed oracle rate: ${_effectiveRate.toStringAsFixed(4)} ERG / ${variant.shortName}',
              helperMaxLines: 3,
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
            for (final r in mintCostRows(_preview!, shortName: variant.shortName))
              _sheetRow(r.$1, r.$2),
          ] else if (_previewError != null)
            Text(_previewError!,
                style: TextStyle(color: rustFor(context), fontSize: 12)),
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
class DexySwapSheet extends StatefulWidget {
  const DexySwapSheet({
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
  State<DexySwapSheet> createState() => DexySwapSheetState();
}

class DexySwapSheetState extends State<DexySwapSheet> {
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
      await showErrorSheet(context, title: 'Could not prepare', message: '$e');
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
                selectedColor: accentOf(context),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text('← ${variant.shortName}'),
                selected: !_ergInput,
                onSelected: (_) => _setDirection('dexy_to_erg'),
                selectedColor: accentOf(context),
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
            Text(_quoteError!, style: TextStyle(color: rustFor(context), fontSize: 12)),
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
class DexyLiquiditySheet extends StatefulWidget {
  const DexyLiquiditySheet({
    required this.variant,
    required this.state,
    required this.onBuild,
    this.initialAction = 'deposit',
    this.tokenBalance,
    this.lpBalance,
    this.spendableBalance,
  });

  final DexyVariant variant;
  /// Pool reserves, needed to pair the two deposit sides at the current ratio.
  final DexyState state;
  final Future<DexyBuildResult> Function(
      String action, int ergAmt, int dexyAmt, int lpAmt) onBuild;
  final String initialAction;
  final int? tokenBalance;
  final int? lpBalance;
  final int? spendableBalance;

  @override
  State<DexyLiquiditySheet> createState() => DexyLiquiditySheetState();
}

class DexyLiquiditySheetState extends State<DexyLiquiditySheet> {
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

  /// A deposit must match the pool's reserve ratio, and the ratio is not
  /// something a user can work out. Typing in either side fills the other.
  ///
  /// Guarded by [_pairing] so writing to a controller does not re-enter through
  /// that field's own onChanged and fight the user's cursor.
  bool _pairing = false;

  void _onErgChanged() {
    if (_pairing) return;
    _pairing = true;
    final erg = parseErgToNano(_ergCtrl.text);
    final dexy = (erg == null || erg <= 0)
        ? 0
        : dexyForErgDeposit(widget.state, erg);
    _dexyCtrl.text =
        dexy <= 0 ? '' : formatTokenAmount(dexy, widget.variant.decimals);
    _pairing = false;
    _onChanged();
  }

  void _onDexyChanged() {
    if (_pairing) return;
    _pairing = true;
    final dexy =
        parseDecimalToBase(_dexyCtrl.text, widget.variant.decimals);
    final erg = (dexy == null || dexy <= 0)
        ? 0
        : ergForDexyDeposit(widget.state, dexy);
    _ergCtrl.text = erg <= 0 ? '' : formatErg(erg, unit: false);
    _pairing = false;
    _onChanged();
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
      await showErrorSheet(context, title: 'Could not prepare', message: '$e');
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
                selectedColor: accentOf(context),
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
                selectedColor: accentOf(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isDeposit) ...[
            TextField(
              controller: _ergCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => _onErgChanged(),
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
                        final pairable = maxPairableErg(
                          widget.state,
                          ergAvailable: max,
                          tokenBalance: widget.tokenBalance ?? 0,
                        );
                        if (pairable <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'No ${variant.shortName} to pair with ERG'),
                            ),
                          );
                        } else {
                          _ergCtrl.text = formatErg(pairable, unit: false);
                        }
                      }
                    }
                    _onErgChanged();
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
              onChanged: (_) => _onDexyChanged(),
              decoration: InputDecoration(
                labelText: '${variant.shortName} to deposit',
                suffixIcon: TextButton(
                  onPressed: () {
                    final b = widget.tokenBalance;
                    if (b != null) {
                      final spendable = widget.spendableBalance ?? 0;
                      final ergAvailable = spendable - minerFeeNano - minBoxNano;
                      final pairable = maxPairableDexy(
                        widget.state,
                        tokenBalance: b,
                        ergAvailable: ergAvailable,
                      );
                      if (pairable <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Not enough ERG to pair a deposit'),
                          ),
                        );
                      } else {
                        _dexyCtrl.text =
                            formatTokenAmount(pairable, variant.decimals);
                      }
                    }
                    _onDexyChanged();
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
              if (redeemRoundingNote(_preview!, variant) case final note?) ...[
                const SizedBox(height: 6),
                Text(note, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ] else if (_previewError != null)
            Text(_previewError!,
                style: TextStyle(color: rustFor(context), fontSize: 12)),
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

/// Explains what a typed ERG amount buys when the token only mints in
/// whole units (DexyGold has no decimals). Null when nothing is lost.
String? mintRoundingNote({
  required double ergTyped,
  required int baseUnits,
  required int decimals,
  required double ergPerToken,
  required String shortName,
}) {
  var scale = 1;
  for (var i = 0; i < decimals; i++) {
    scale *= 10;
  }
  final costErg = baseUnits / scale * ergPerToken;
  final leftover = ergTyped - costErg;
  if (baseUnits <= 0) {
    return '${ergTyped.toStringAsFixed(4)} ERG is less than one $shortName '
        '(${ergPerToken.toStringAsFixed(4)} ERG)';
  }
  if (leftover < 0.00005) return null;
  final units = formatScaled(baseUnits, decimals);
  return '$shortName mints in ${decimals == 0 ? 'whole units' : 'steps of 1/$scale'}: '
      '$units for ${costErg.toStringAsFixed(4)} ERG, '
      '${leftover.toStringAsFixed(4)} ERG stays in your wallet';
}

/// Cost breakdown for the mint preview: token cost, box minimum when the
/// preview reserves one, miner fee, Argus fee, and the total you spend.
List<(String, String)> mintCostRows(DexyMintPreview p, {required String shortName}) {
  final boxMin = p.totalCostNano - p.ergCostNano - p.txFeeNano;
  return [
    ('$shortName cost', formatErg(p.ergCostNano)),
    if (boxMin > 0) ('Token box minimum', formatErg(boxMin, unit: false)),
    ('Miner fee', formatErg(p.txFeeNano, unit: false)),
    ('Argus fee', formatErg(argusFeeNano, unit: false)),
    ('Total', formatErg(p.totalCostNano + argusFeeNano)),
  ];
}

/// ERG per whole token from [state], or 0 when [state] is not for [variant].
double mintRateFor(DexyState state, DexyVariant variant) =>
    state.variant == variant ? state.rates.ergPerToken : 0;

/// Explains a redemption that returns fewer whole tokens than the share
/// after the fee, which happens for DexyGold (no decimals). Null when the
/// rounding loses less than a twentieth of a unit.
String? redeemRoundingNote(DexyLpPreview p, DexyVariant variant) {
  final exact = p.dexyShareExact;
  final next = p.lpForNextUnit;
  if (exact == null) return null;
  var scale = 1.0;
  for (var i = 0; i < variant.decimals; i++) {
    scale *= 10;
  }
  final got = p.dexyOut / scale;
  if (exact - got < 0.05 / scale) return null;
  final unit = variant.decimals == 0 ? '1 ${variant.shortName}' : '${formatTokenAmount(1, variant.decimals)} ${variant.shortName}';
  final base = 'Your share after the ${p.redemptionFeePct}% fee is '
      '${exact.toStringAsFixed(variant.decimals + 2)} ${variant.shortName}; '
      '${variant.shortName} is paid in steps of $unit, so ${formatTokenAmount(p.dexyOut, variant.decimals)} is returned and the rest stays in the pool.';
  if (next == null || next <= p.lpAmount) return base;
  return '$base Redeeming $next LP tokens would return ${formatTokenAmount(p.dexyOut + 1, variant.decimals)}.';
}
