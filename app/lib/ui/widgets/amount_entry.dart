import 'package:flutter/material.dart';

import '../../format.dart';
import '../../services/network_controller.dart';
import '../../services/wallet_service.dart';
import '../../theme/argus_theme.dart';

/// ERG text for a typed fiat amount at [rate] (fiat per ERG). Empty stays
/// empty; unparsable is null.
String? fiatToErgText(String fiatText, {required double rate}) {
  final t = fiatText.trim();
  if (t.isEmpty) return '';
  final v = double.tryParse(t);
  if (v == null || rate <= 0) return null;
  final nano = (v / rate * 1e9).round();
  return formatErg(nano, unit: false);
}

/// Fiat text for a typed ERG amount at [rate]. Empty stays empty;
/// unparsable is null.
String? ergToFiatText(String ergText, {required double rate, int decimals = 2}) {
  final t = ergText.trim();
  if (t.isEmpty) return '';
  final nano = parseErgToNano(t);
  if (nano == null) return null;
  return (nano / 1e9 * rate).toStringAsFixed(decimals);
}

/// Large amount field with an ERG / fiat toggle. [controller] always holds
/// the ERG text; the fiat view is a derived editor over it.
class AmountEntry extends StatefulWidget {
  const AmountEntry({
    super.key,
    required this.controller,
    this.label = 'Amount',
    this.helperText,
    this.onChanged,
    this.onMax,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String? helperText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onMax;
  final FormFieldValidator<String>? validator;

  @override
  State<AmountEntry> createState() => _AmountEntryState();
}

class _AmountEntryState extends State<AmountEntry> {
  bool _fiatMode = false;
  final _fiatCtrl = TextEditingController();
  bool _syncing = false;

  double? get _rate => networkController.fiatPerErg;
  int get _fiatDecimals => networkController.fiatCode == 'jpy' ? 0 : 2;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_ergChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_ergChanged);
    _fiatCtrl.dispose();
    super.dispose();
  }

  /// Keeps the fiat editor in step when ERG changes from outside (MAX, scan).
  void _ergChanged() {
    if (_syncing || !_fiatMode) return;
    final rate = _rate;
    if (rate == null) return;
    final next = ergToFiatText(widget.controller.text, rate: rate, decimals: _fiatDecimals);
    if (next != null && next != _fiatCtrl.text) {
      _syncing = true;
      _fiatCtrl.text = next;
      _syncing = false;
    }
  }

  void _fiatTyped(String text) {
    final rate = _rate;
    if (rate == null) return;
    final erg = fiatToErgText(text, rate: rate);
    if (erg == null) return;
    _syncing = true;
    widget.controller.text = erg;
    _syncing = false;
    widget.onChanged?.call(erg);
  }

  void _toggle() {
    final rate = _rate;
    if (rate == null) return;
    setState(() {
      _fiatMode = !_fiatMode;
      if (_fiatMode) {
        _fiatCtrl.text =
            ergToFiatText(widget.controller.text, rate: rate, decimals: _fiatDecimals) ?? '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final rate = _rate;
    final unit = _fiatMode ? networkController.fiatCode.toUpperCase() : 'ERG';
    final secondary = _fiatMode
        ? '${formatErg(parseErgToNano(widget.controller.text), unit: false, maxFrac: 4)} ERG'
        : (networkController.fiatText(parseErgToNano(widget.controller.text)) ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(widget.label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: colors.muted)),
            const Spacer(),
            if (rate != null)
              TextButton.icon(
                onPressed: _toggle,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.swap_vert, size: 16),
                label: Text(_fiatMode ? 'Enter ERG' : 'Enter ${networkController.fiatCode.toUpperCase()}'),
              ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: _fiatMode
                  ? TextFormField(
                      controller: _fiatCtrl,
                      style: _bigStyle(context),
                      decoration: _decoration(context),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: _fiatTyped,
                      validator: (_) => widget.validator?.call(widget.controller.text),
                    )
                  : TextFormField(
                      controller: widget.controller,
                      style: _bigStyle(context),
                      decoration: _decoration(context),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: widget.onChanged,
                      validator: widget.validator,
                    ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                unit,
                style: TextStyle(fontFamily: 'Newsreader', fontSize: 20, color: colors.muted),
              ),
            ),
            if (widget.onMax != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2, left: 4),
                child: TextButton(onPressed: widget.onMax, child: const Text('MAX')),
              ),
          ],
        ),
        Row(
          children: [
            if (secondary.isNotEmpty)
              Text(secondary, style: TextStyle(fontSize: 12.5, color: colors.muted)),
            if (secondary.isNotEmpty && widget.helperText != null)
              Text('  ·  ', style: TextStyle(color: colors.muted)),
            if (widget.helperText != null)
              Flexible(
                child: Text(
                  widget.helperText!,
                  style: TextStyle(fontSize: 12.5, color: colors.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ],
    );
  }

  TextStyle _bigStyle(BuildContext context) => const TextStyle(
        fontFamily: 'Newsreader',
        fontWeight: FontWeight.w600,
        fontSize: 36,
        height: 1.1,
      );

  InputDecoration _decoration(BuildContext context) => const InputDecoration(
        hintText: '0',
        filled: false,
        border: UnderlineInputBorder(),
        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0x33000000))),
        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: iris, width: 1.4)),
        contentPadding: EdgeInsets.symmetric(vertical: 6),
        isDense: true,
      );
}
