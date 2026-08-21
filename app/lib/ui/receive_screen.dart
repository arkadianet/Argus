import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../services/session_lock.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _amountCtrl = TextEditingController();
  String _qrData = '';

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_updateQr);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateQr();
  }

  @override
  void dispose() {
    _amountCtrl.removeListener(_updateQr);
    _amountCtrl.dispose();
    super.dispose();
  }

  void _updateQr() {
    final args = WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);
    final address = args.receiveAddress;
    final amount = _amountCtrl.text.trim();
    if (amount.isEmpty) {
      if (address != _qrData) setState(() => _qrData = address);
      return;
    }
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(amount)) return;
    final data = 'ergo:$address?amount=$amount';
    if (data != _qrData) setState(() => _qrData = data);
  }

  String get _address =>
      WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments).receiveAddress;

  @override
  Widget build(BuildContext context) {
    final address = _address;

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
          const SizedBox(height: 20),
          TextField(
            controller: _amountCtrl,
            decoration: const InputDecoration(
              labelText: 'Optional amount (ERG)',
              hintText: '0.001',
              suffixIcon: Icon(Icons.tag),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 28),
          if (address.isNotEmpty)
            Center(
              child: Container(
                color: paper,
                padding: const EdgeInsets.all(16),
                child: QrImageView(
                  data: _qrData.isEmpty ? address : _qrData,
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
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: address.isEmpty
                ? null
                : () => sessionLock.run(
                      () => SharePlus.instance.share(ShareParams(text: address)),
                    ),
            child: const Text('Share'),
          ),
        ],
      ),
    );
  }
}
