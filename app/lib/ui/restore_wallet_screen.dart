import 'widgets/error_sheet.dart';
import 'package:flutter/material.dart';

import '../bridge/argus_error.dart';
import '../services/network_controller.dart';
import '../services/privacy_service.dart';
import '../services/secure_storage.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'create_wallet_screen.dart';
import 'pin_fields.dart';
import 'wallet_dialogs.dart';

/// The phrase check and derivation probe the screen depends on, so tests
/// can stand in for the bridge.
abstract class RestorePhraseGateway {
  PhraseCheck check(String raw);
  Future<RestoreDerivationProbe> probe({
    required String phrase,
    required String passphrase,
    required bool queryNode,
  });
}

class _BridgeGateway implements RestorePhraseGateway {
  const _BridgeGateway();
  @override
  PhraseCheck check(String raw) => walletService.checkMnemonic(raw);
  @override
  Future<RestoreDerivationProbe> probe({
    required String phrase,
    required String passphrase,
    required bool queryNode,
  }) =>
      walletService.probeRestoreDerivation(
        phrase: phrase,
        passphrase: passphrase,
        nodeUrl: networkController.activeUrl,
        queryNode: queryNode,
      );
}

class RestoreWalletScreen extends StatefulWidget {
  const RestoreWalletScreen({super.key, this.gateway = const _BridgeGateway()});

  final RestorePhraseGateway gateway;

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
  bool _checking = false;
  int _step = 0;
  bool _showPass = false;

  /// Live result of the Rust BIP-39 check for the current field text.
  PhraseCheck _check = PhraseCheck.empty;

  /// Shown once Continue was tapped on a phrase that does not pass.
  String? _continueError;

  /// Advanced: force the pre-1627 derivation.
  bool _forceLegacy = false;

  /// What Continue decided; used by Restore.
  bool _useLegacy = false;
  String? _derivationNotice;

  @override
  void initState() {
    super.initState();
    armSecureFlag(context);
    _phraseCtrl.addListener(_onPhraseChanged);
    _passCtrl.addListener(_onPassChanged);
  }

  void _onPassChanged() => setState(() {});

  @override
  void dispose() {
    privacyService.applyScreenshotPolicy();
    _phraseCtrl.removeListener(_onPhraseChanged);
    _phraseCtrl.clear();
    _passCtrl.removeListener(_onPassChanged);
    _passCtrl.clear();
    _pinCtrl.clear();
    _pinConfirmCtrl.clear();
    _phraseCtrl.dispose();
    _passCtrl.dispose();
    _pinCtrl.dispose();
    _pinConfirmCtrl.dispose();
    _nameCtrl.dispose();
    _check = PhraseCheck.empty;
    super.dispose();
  }

  void _onPhraseChanged() {
    final raw = _phraseCtrl.text;
    PhraseCheck next;
    try {
      next = widget.gateway.check(raw);
    } catch (_) {
      next = PhraseCheck.empty;
    }
    setState(() {
      _check = next;
      _continueError = null;
    });
  }

  void _applySuggestion(UnknownWord word, String suggestion) {
    final text = _check.replaceWord(word.position, suggestion);
    _phraseCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _toPin() async {
    final check = widget.gateway.check(_phraseCtrl.text);
    final error = check.continueError;
    setState(() {
      _check = check;
      _continueError = error;
    });
    if (error != null) return;

    setState(() => _checking = true);
    RestoreDerivationProbe? probe;
    try {
      probe = await widget.gateway.probe(
        phrase: check.phrase,
        passphrase: _passCtrl.text,
        queryNode: !_forceLegacy,
      );
    } catch (_) {
      // Only the node can fail here: the phrase already passed. The
      // decision below says plainly that the check could not be made.
      probe = null;
    }
    if (!mounted) return;
    final decision = decideRestoreDerivation(forced: _forceLegacy, probe: probe);
    setState(() {
      _checking = false;
      _useLegacy = decision.legacy;
      _derivationNotice = decision.notice;
      _step = 1;
    });
  }

  Future<String?> _restore() async {
    final phrase = _check.phrase;
    if (!_check.isValid) {
      setState(() => _step = 0);
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
        legacyDerivation: _useLegacy,
      );
      if (!mounted) return null;
      await offerBiometricUnlock(context, walletId: walletId, pin: _pinCtrl.text);
      if (!mounted) return null;
      Navigator.pop(context, walletId);
    } on ArgusException catch (e) {
      showErrorSheet(context, code: e.code, message: e.message);
    } on SecureStorageException catch (e) {
      showErrorSheet(context, message: e.message);
    } catch (e) {
      showErrorSheet(context, title: 'Could not restore the wallet', message: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  void _snack(String msg) {
    if (mounted) showErrorSheet(context, message: msg);
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
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    final unknown = _check.visibleUnknown(_phraseCtrl.text);
    final count = _check.words.length;
    final passTrimmed = _passCtrl.text != _passCtrl.text.trim();
    return Column(
      key: const ValueKey(0),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Recovery phrase', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
            '12, 15, 18, 21, or 24 words, in order — 15 is the Ergo standard. Optional BIP-39 passphrase if you used one.'),
        const SizedBox(height: 20),
        TextField(
          key: const ValueKey('restore-phrase'),
          controller: _phraseCtrl,
          decoration: InputDecoration(
            labelText: 'Recovery phrase',
            hintText: '12, 15, 18, 21, or 24 words',
            helperText: count == 0 ? null : '$count ${count == 1 ? 'word' : 'words'}',
          ),
          minLines: 4,
          maxLines: 6,
          // A password keyboard: no suggestions, no learning, no
          // autocorrect on the platforms that honour it.
          keyboardType: TextInputType.visiblePassword,
          enableSuggestions: false,
          autocorrect: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          enableIMEPersonalizedLearning: false,
        ),
        for (final u in unknown) ...[
          const SizedBox(height: 10),
          Text(u.message, style: theme.textTheme.bodyMedium?.copyWith(color: error)),
          if (u.suggestions.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final s in u.suggestions)
                  ActionChip(
                    key: ValueKey('suggest-${u.position}-$s'),
                    label: Text(s),
                    onPressed: () => _applySuggestion(u, s),
                  ),
              ],
            ),
        ],
        if (_check.languageNote != null) ...[
          const SizedBox(height: 10),
          Text(_check.languageNote!, style: theme.textTheme.bodySmall),
        ],
        if (_continueError != null) ...[
          const SizedBox(height: 12),
          Text(
            _continueError!,
            key: const ValueKey('restore-phrase-error'),
            style: theme.textTheme.bodyMedium?.copyWith(color: error),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _passCtrl,
          decoration: InputDecoration(
            labelText: 'BIP-39 passphrase (optional)',
            helperText: passTrimmed
                ? 'Starts or ends with a space. Spaces count: leave them only if they were there when the phrase was made.'
                : 'Only if you added an extra passphrase ("25th word") when the phrase was made. Not a wallet password or PIN: leave empty if unsure.',
            helperMaxLines: 3,
            suffixIcon: IconButton(
              tooltip: _showPass ? 'Hide passphrase' : 'Show passphrase',
              icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showPass = !_showPass),
            ),
          ),
          obscureText: !_showPass,
          enableSuggestions: false,
          autocorrect: false,
          enableIMEPersonalizedLearning: false,
        ),
        const SizedBox(height: 8),
        Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const ValueKey('restore-advanced'),
            tilePadding: EdgeInsets.zero,
            title: const Text('Advanced'),
            children: [
              SwitchListTile(
                key: const ValueKey('restore-legacy-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Legacy (pre-1627) derivation'),
                subtitle: const Text(
                  'For phrases from early versions of the Ergo node and the wallets built on it, '
                  'made before their BIP-32 fix (ergo issue #1627). Argus checks this for you; '
                  'turn it on only to force it.',
                ),
                value: _forceLegacy,
                onChanged: (v) => setState(() => _forceLegacy = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('restore-continue'),
          onPressed: _checking ? null : _toPin,
          child: _checking
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
      ],
    );
  }

  Widget _pinStep() {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey(1),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Set a PIN', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('The PIN unwraps the key on this device. It is not a backup.'),
        if (_derivationNotice != null) ...[
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _derivationNotice!,
                key: const ValueKey('restore-derivation-notice'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
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
