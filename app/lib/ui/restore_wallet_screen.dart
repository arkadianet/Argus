import 'package:flutter/material.dart';

import '../bridge/argus_error.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import 'create_wallet_screen.dart';
import 'pin_fields.dart';

class RestoreWalletScreen extends StatefulWidget {
  const RestoreWalletScreen({super.key});

  @override
  State<RestoreWalletScreen> createState() => _RestoreWalletScreenState();
}

class _RestoreWalletScreenState extends State<RestoreWalletScreen> {
  final _phraseCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _pinConfirmCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    SecureStorageService.setSecureFlag(true);
  }

  @override
  void dispose() {
    SecureStorageService.setSecureFlag(false);
    _phraseCtrl.clear();
    _passCtrl.clear();
    _pinCtrl.clear();
    _pinConfirmCtrl.clear();
    _phraseCtrl.dispose();
    _passCtrl.dispose();
    _pinCtrl.dispose();
    _pinConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final phrase = _phraseCtrl.text.trim();
    if (phrase.isEmpty) return;
    final pinErr = pinError(_pinCtrl.text, _pinConfirmCtrl.text);
    if (pinErr != null) {
      _snack(pinErr);
      return;
    }
    setState(() => _busy = true);
    try {
      if (!await confirmReplaceExistingWallet(context)) return;
      final session = await walletService.createWallet(
        phrase,
        passphrase: _passCtrl.text,
      );
      final pinWrap = await walletService.wrapKeyWithPin(session.wrapKey, _pinCtrl.text);
      await SecureStorageService.saveWalletWithPin(
        encryptedSeedJson: session.encryptedSeedJson,
        pinWrapJson: pinWrap,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } on SecureStorageException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Restore wallet')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _phraseCtrl,
            decoration: const InputDecoration(
              labelText: 'Recovery phrase',
              hintText: '12 or 24 words',
            ),
            minLines: 3,
            maxLines: 5,
            enableSuggestions: false,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passCtrl,
            decoration: const InputDecoration(
              labelText: 'BIP-39 passphrase (optional)',
            ),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          PinFields(pin: _pinCtrl, confirm: _pinConfirmCtrl),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _restore,
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }
}
