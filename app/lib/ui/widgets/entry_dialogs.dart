import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme/argus_theme.dart';
import '../pin_fields.dart';

// Dialogs that ask for text own their controllers.
//
// A controller created by the caller and disposed as soon as `showDialog`
// returns is disposed while the dialog is still animating out and its
// fields still read it: in debug builds that is the red
// "'_dependents.isEmpty': is not true" screen, in release a use after
// dispose. Each dialog here keeps its controllers in its own State, disposes
// them in dispose() once the route is gone, and answers through
// Navigator.pop.

/// One line of text, or null when cancelled.
class TextEntryDialog extends StatefulWidget {
  const TextEntryDialog({
    super.key,
    required this.title,
    this.intro,
    this.introGap = 16,
    this.footer,
    this.footerGap = 8,
    this.initial = '',
    this.label,
    this.hint,
    this.helper,
    this.maxLength,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.autofocus = true,
    this.submitOnEnter = false,
    this.stretch = false,
    this.confirmLabel = 'Save',
    this.cancelLabel = 'Cancel',
    this.fieldKey,
    this.confirmKey,
  });

  final String title;

  /// Above the field: what the value is for, or the address it labels.
  final Widget? intro;
  final double introGap;

  /// Below the field.
  final Widget? footer;
  final double footerGap;
  final String initial;
  final String? label;
  final String? hint;
  final String? helper;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final bool autofocus;

  /// Enter answers as the confirm button does.
  final bool submitOnEnter;

  /// The intro and field take the dialog's full width.
  final bool stretch;
  final String confirmLabel;
  final String cancelLabel;
  final Key? fieldKey;
  final Key? confirmKey;

  @override
  State<TextEntryDialog> createState() => _TextEntryDialogState();
}

class _TextEntryDialogState extends State<TextEntryDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return AlertDialog(
      title: Text(w.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: w.stretch
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.center,
        children: [
          if (w.intro != null) ...[w.intro!, SizedBox(height: w.introGap)],
          TextField(
            key: w.fieldKey,
            controller: _controller,
            autofocus: w.autofocus,
            maxLength: w.maxLength,
            keyboardType: w.keyboardType,
            textCapitalization: w.textCapitalization,
            decoration: InputDecoration(
              labelText: w.label,
              hintText: w.hint,
              helperText: w.helper,
            ),
            onSubmitted: w.submitOnEnter ? (_) => _submit() : null,
          ),
          if (w.footer != null) ...[SizedBox(height: w.footerGap), w.footer!],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(w.cancelLabel),
        ),
        FilledButton(
          key: w.confirmKey,
          onPressed: _submit,
          child: Text(w.confirmLabel),
        ),
      ],
    );
  }
}

/// A label for one of the wallet's addresses: the address, and the label
/// (empty clears it). Null when cancelled.
Future<String?> showAddressLabelDialog(
  BuildContext context, {
  required String address,
  required String existing,
}) => showDialog<String>(
  context: context,
  builder: (ctx) => TextEntryDialog(
    title: 'Address label',
    intro: SelectableText(
      shorten(address, head: 10, tail: 8),
      style: monoStyle(ctx, size: 11),
    ),
    initial: existing,
    label: 'Label (optional)',
    textCapitalization: TextCapitalization.words,
  ),
);

/// What a PIN dialog collected. Fields it did not ask for are empty.
class PinEntry {
  const PinEntry({this.current = '', this.pin = '', this.confirm = ''});
  final String current;
  final String pin;
  final String confirm;
}

/// PIN fields in a dialog sized to them, answering [PinEntry] on confirm
/// and null on cancel.
class PinEntryDialog extends StatefulWidget {
  const PinEntryDialog({
    super.key,
    required this.title,
    this.askCurrent = false,
    this.currentLabel = 'Current PIN',
    this.pinLabel = 'PIN',
    this.askConfirm = false,
    this.confirmLabel = 'Continue',
    this.cancelLabel = 'Cancel',
  });

  final String title;

  /// A "Current PIN" field above the new one, for a change.
  final bool askCurrent;
  final String currentLabel;
  final String pinLabel;

  /// A second field that must repeat the PIN.
  final bool askConfirm;
  final String confirmLabel;
  final String cancelLabel;

  @override
  State<PinEntryDialog> createState() => _PinEntryDialogState();
}

class _PinEntryDialogState extends State<PinEntryDialog> {
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(
    context,
    PinEntry(current: _current.text, pin: _pin.text, confirm: _confirm.text),
  );

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return AlertDialog(
      title: Text(w.title),
      // Scrolls rather than overflows with the keyboard up at large text.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (w.askCurrent) ...[
            PinFields(pin: _current, label: w.currentLabel),
            const SizedBox(height: 12),
          ],
          PinFields(
            pin: _pin,
            confirm: w.askConfirm ? _confirm : null,
            label: w.pinLabel,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(w.cancelLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(w.confirmLabel)),
      ],
    );
  }
}
