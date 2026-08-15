import 'package:flutter/material.dart';

import '../bridge/argus_error.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import 'pin_fields.dart';

class CreateWalletScreen extends StatefulWidget {
  const CreateWalletScreen({super.key});

  @override
  State<CreateWalletScreen> createState() => _CreateWalletScreenState();
}

class _CreateWalletScreenState extends State<CreateWalletScreen> {
  String? _mnemonic;
  final _confirmCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _pinConfirmCtrl = TextEditingController();
  bool _busy = false;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    SecureStorageService.setSecureFlag(true).then((ok) {
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Screenshot blocking is unavailable on this device')),
        );
      }
    });
  }

  @override
  void dispose() {
    SecureStorageService.setSecureFlag(false);
    _confirmCtrl.clear();
    _pinCtrl.clear();
    _pinConfirmCtrl.clear();
    _confirmCtrl.dispose();
    _pinCtrl.dispose();
    _pinConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final phrase = await walletService.generateMnemonic(strength: 256);
      setState(() {
        _mnemonic = phrase;
        _revealed = false;
        _confirmCtrl.clear();
      });
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final phrase = _mnemonic;
    if (phrase == null) return;
    if (_confirmCtrl.text.trim() != phrase) {
      _snack('Confirmation does not match the recovery phrase');
      return;
    }
    final pinErr = pinError(_pinCtrl.text, _pinConfirmCtrl.text);
    if (pinErr != null) {
      _snack(pinErr);
      return;
    }
    setState(() => _busy = true);
    try {
      if (!await confirmReplaceExistingWallet(context)) return;
      final session = await walletService.createWallet(phrase);
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
      appBar: AppBar(title: const Text('Create wallet')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Write these 24 words on paper. They are the only way to recover this wallet. Android blocks screenshots here; iOS hides the app in the switcher and during screen recording.',
          ),
          const SizedBox(height: 16),
          if (_mnemonic == null)
            FilledButton(
              onPressed: _busy ? null : _generate,
              child: const Text('Generate recovery phrase'),
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  _revealed ? _mnemonic! : '•••• •••• •••• (tap reveal)',
                  style: const TextStyle(fontFamily: 'monospace', height: 1.6),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _revealed = !_revealed),
                child: Text(_revealed ? 'Hide' : 'Reveal'),
              ),
            ),
            TextField(
              controller: _confirmCtrl,
              decoration: const InputDecoration(
                labelText: 'Re-enter the recovery phrase',
              ),
              minLines: 3,
              maxLines: 5,
              enableSuggestions: false,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            PinFields(pin: _pinCtrl, confirm: _pinConfirmCtrl),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _finish,
              child: const Text('I have backed up my phrase'),
            ),
          ],
        ],
      ),
    );
  }
}

Future<bool> confirmReplaceExistingWallet(BuildContext context) async {
  if (!await SecureStorageService.hasEncryptedSeed()) return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Replace existing wallet?'),
      content: const Text(
        'A wallet is already stored on this device. Replacing it overwrites the encrypted seed. The recovery phrase is the only way to recover the old wallet.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
      ],
    ),
  );
  return ok == true;
}
