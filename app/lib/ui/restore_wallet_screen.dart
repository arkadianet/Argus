import 'package:flutter/material.dart';

import '../bridge/argus_error.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
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
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    armSecureFlag(context);
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
    _nameCtrl.dispose();
    super.dispose();
  }

  void _toPin() {
    final words = mnemonicWords(_phraseCtrl.text);
    if (words.isEmpty) {
      _snack('Enter a recovery phrase');
      return;
    }
    if (!isValidMnemonicWordCount(words.length)) {
      _snack('Recovery phrase must be 12, 15, 18, 21, or 24 words');
      return;
    }
    setState(() => _step = 1);
  }

  Future<String?> _restore() async {
    final words = mnemonicWords(_phraseCtrl.text);
    final phrase = words.join(' ');
    if (phrase.isEmpty) {
      _snack('Enter a recovery phrase');
      return null;
    }
    final pinErr = pinError(_pinCtrl.text, _pinConfirmCtrl.text);
    if (pinErr != null) {
      _snack(pinErr);
      return null;
    }
    setState(() => _busy = true);
    try {
      final walletId = await walletService.provisionWallet(
        phrase: phrase,
        passphrase: _passCtrl.text,
        pin: _pinCtrl.text,
        name: _nameCtrl.text,
      );
      if (!mounted) return null;
      Navigator.pop(context, walletId);
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } on SecureStorageException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Could not restore the wallet');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_step > 0) setState(() => _step -= 1);
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Restore wallet'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_step > 0) {
              setState(() => _step -= 1);
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
                20, 8, 20, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          StepDots(total: 2, index: _step),
          const SizedBox(height: 24),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _step == 0 ? _phraseStep() : _pinStep(),
          ),
        ],
      ),
    ),
    );
  }

  Widget _phraseStep() {
    return Column(
      key: const ValueKey(0),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Recovery phrase', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
            '12, 15, 18, 21, or 24 words, in order — 15 is the Ergo standard. Optional BIP-39 passphrase if you used one.'),
        const SizedBox(height: 20),
        TextField(
          controller: _phraseCtrl,
          decoration: const InputDecoration(
            labelText: 'Recovery phrase',
            hintText: '12, 15, 18, 21, or 24 words',
          ),
          minLines: 4,
          maxLines: 6,
          enableSuggestions: false,
          autocorrect: false,
          enableIMEPersonalizedLearning: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passCtrl,
          decoration: const InputDecoration(
            labelText: 'BIP-39 passphrase (optional)',
          ),
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          enableIMEPersonalizedLearning: false,
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _toPin, child: const Text('Continue')),
      ],
    );
  }

  Widget _pinStep() {
    return Column(
      key: const ValueKey(1),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Set a PIN', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('The PIN unwraps the key on this device. It is not a backup.'),
        const SizedBox(height: 20),
        PinFields(pin: _pinCtrl, confirm: _pinConfirmCtrl),
        const SizedBox(height: 16),
        TextField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Wallet name (optional)',
            hintText: 'e.g. Savings, Trading',
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _restore,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Restore'),
        ),
      ],
    );
  }
}
