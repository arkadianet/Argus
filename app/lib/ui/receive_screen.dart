import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';

class ReceiveScreen extends StatelessWidget {
  const ReceiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final args = WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);
    final address = args.receiveAddress;

    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 40),
        children: [
          const SectionLabel('Unused address'),
          const SizedBox(height: 8),
          Text(
            'A new address is shown after this one is used.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 28),
          if (address.isNotEmpty)
            Center(
              child: Container(
                color: paper,
                padding: const EdgeInsets.all(16),
                child: QrImageView(
                  data: address,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: paper,
                  padding: EdgeInsets.zero,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: ink,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: ink,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 28),
          SelectableText(
            address,
            style: monoStyle(context, size: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: address.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied')),
                    );
                  },
            child: const Text('Copy address'),
          ),
        ],
      ),
    );
  }
}
