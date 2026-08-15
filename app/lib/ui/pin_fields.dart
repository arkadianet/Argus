import 'package:flutter/material.dart';

import '../services/wallet_service.dart';

class PinFields extends StatelessWidget {
  final TextEditingController pin;
  final TextEditingController? confirm;
  final String label;

  const PinFields({
    super.key,
    required this.pin,
    this.confirm,
    this.label = 'PIN',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: pin,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: label,
            helperText: '6-32 characters. This unlocks the wallet on this device.',
          ),
        ),
        if (confirm != null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: confirm,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Confirm PIN'),
          ),
        ],
      ],
    );
  }
}

String? pinError(String pin, [String? confirm]) {
  final err = validatePin(pin);
  if (err != null) return err;
  if (confirm != null && confirm != pin) return 'PINs do not match';
  return null;
}
