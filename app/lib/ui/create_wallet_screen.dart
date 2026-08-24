import 'package:flutter/material.dart';

import '../bridge/argus_error.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
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
  int _step = 0;

  @override
  void initState() {
    super.initState();
    armSecureFlag(context);
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
      final phrase = await walletService.generateMnemonic(strength: 160);
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

  void _toConfirm() {
    if (_mnemonic == null) return;
    setState(() => _step = 1);
  }

  void _toPin() {
    final phrase = _mnemonic;
    if (phrase == null || !mnemonicWordsEqual(_confirmCtrl.text, phrase)) {
      _snack('Confirmation does not match the recovery phrase');
      return;
    }
    setState(() => _step = 2);
  }

  Future<String?> _finish() async {
    final phrase = _mnemonic;
    if (phrase == null) return null;
    final pinErr = pinError(_pinCtrl.text, _pinConfirmCtrl.text);
    if (pinErr != null) {
      _snack(pinErr);
      return null;
    }
    setState(() => _busy = true);
    try {
      final walletId = await walletService.provisionWallet(
        phrase: phrase,
        passphrase: '',
        pin: _pinCtrl.text,
      );
      if (!mounted) return null;
      Navigator.pop(context, walletId);
    } on ArgusException catch (e) {
      _snack('${e.code}: ${e.message}');
    } on SecureStorageException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Could not create the wallet');
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
        title: const Text('Create wallet'),
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
          StepDots(total: 3, index: _step),
          const SizedBox(height: 24),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: switch (_step) {
              1 => _confirmStep(),
              2 => _pinStep(),
              _ => _backupStep(),
            },
          ),
        ],
      ),
    ),
    );
  }

  Widget _backupStep() {
    final words = _mnemonic?.split(RegExp(r'\s+')) ?? const <String>[];
    return Column(
      key: const ValueKey(0),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Write these words down', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Paper only. They are the only way to recover this wallet. Android blocks screenshots here; iOS hides the app in the switcher and during screen recording.',
        ),
        const SizedBox(height: 20),
        if (_mnemonic == null)
          FilledButton(
            onPressed: _busy ? null : _generate,
            child: const Text('Generate recovery phrase'),
          )
        else ...[
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: _revealed
                  ? Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        for (var i = 0; i < words.length; i++)
                          SizedBox(
                            width: 140,
                            child: Text(
                              '${i + 1}.  ${words[i]}',
                              style: monoStyle(context, size: 14),
                            ),
                          ),
                      ],
                    )
                  : Text(
                      '••••  ••••  ••••  ••••',
                      style: monoStyle(context, size: 16),
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
          FilledButton(
            onPressed: _toConfirm,
            child: const Text('I wrote these down'),
          ),
        ],
      ],
    );
  }

  Widget _confirmStep() {
    return Column(
      key: const ValueKey(1),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Confirm the phrase', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('Type the words back in order. This proves the backup is readable.'),
        const SizedBox(height: 20),
        TextField(
          controller: _confirmCtrl,
          decoration: const InputDecoration(labelText: 'Recovery phrase'),
          minLines: 4,
          maxLines: 6,
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
      key: const ValueKey(2),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Set a PIN', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('The PIN unwraps the key on this device. It is not a backup.'),
        const SizedBox(height: 20),
        PinFields(pin: _pinCtrl, confirm: _pinConfirmCtrl),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _finish,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create wallet'),
        ),
      ],
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

Future<void> armSecureFlag(BuildContext context) async {
  try {
    final ok = await SecureStorageService.setSecureFlag(true);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Screenshot blocking is unavailable on this device')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Screenshot blocking is unavailable on this device')),
      );
    }
  }
}
