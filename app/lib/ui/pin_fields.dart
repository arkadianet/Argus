import 'package:flutter/material.dart';

import '../services/wallet_service.dart';

class PinFields extends StatelessWidget {
  final TextEditingController pin;
  final TextEditingController? confirm;
  final String label;
  final ValueChanged<String>? onSubmitted;

  const PinFields({
    super.key,
    required this.pin,
    this.confirm,
    this.label = 'PIN',
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _box(pin, label, helper: '6–32 characters. Number pad first.', onSubmitted: onSubmitted),
        if (confirm != null) ...[
          const SizedBox(height: 12),
          _box(confirm!, 'Confirm PIN', onSubmitted: onSubmitted),
        ],
      ],
    );
  }

  Widget _box(
    TextEditingController controller,
    String label, {
    String? helper,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      maxLength: 32,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
      ),
    );
  }
}

String? pinError(String pin, [String? confirm]) {
  final err = validatePin(pin);
  if (err != null) return err;
  if (confirm != null && confirm != pin) return 'PINs do not match';
  return null;
}
