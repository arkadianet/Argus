import 'package:flutter/material.dart';

import '../services/wallet_service.dart';

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _formKey = GlobalKey<FormState>();
  final _recipientCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _tokenIdCtrl = TextEditingController();
  final _tokenAmtCtrl = TextEditingController();
  bool _sending = false;
  String? _resultTxId;

  static const _nano = 1000000000;

  @override
  void dispose() {
    _recipientCtrl.dispose();
    _amountCtrl.dispose();
    _tokenIdCtrl.dispose();
    _tokenAmtCtrl.dispose();
    super.dispose();
  }

  int? _amountNano() {
    final erg = double.tryParse(_amountCtrl.text.trim());
    if (erg == null) return null;
    return (erg * _nano).round();
  }

  String _erg(int nano) => '${(nano / _nano).toStringAsFixed(4)} ERG';

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    final sender = ModalRoute.of(context)?.settings.arguments as String? ?? '';
    if (sender.isEmpty) {
      _snack('No sender address');
      return;
    }
    final amount = _amountNano();
    if (amount == null) return;

    setState(() => _sending = true);
    try {
      final preview = await walletService.prepareSend(
        senderAddress: sender,
        recipientAddress: _recipientCtrl.text.trim(),
        amountNanoErg: amount,
        tokenId: _tokenIdCtrl.text.isNotEmpty ? _tokenIdCtrl.text.trim() : null,
        tokenAmount: _tokenAmtCtrl.text.isNotEmpty ? int.tryParse(_tokenAmtCtrl.text) : null,
      );
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm send'),
          content: Text(
            'To: ${preview.recipient}\n'
            'Amount: ${_erg(preview.amountNanoErg)}\n'
            'Miner fee: ${_erg(preview.minerFee)}\n'
            'Change: ${_erg(preview.changeNanoErg)}\n'
            'Inputs: ${preview.inputCount}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign & broadcast')),
          ],
        ),
      );
      if (ok != true) {
        setState(() => _sending = false);
        return;
      }
      final txId = await walletService.sendErg(
        senderAddress: sender,
        recipientAddress: _recipientCtrl.text.trim(),
        amountNanoErg: amount,
        tokenId: _tokenIdCtrl.text.isNotEmpty ? _tokenIdCtrl.text.trim() : null,
        tokenAmount: _tokenAmtCtrl.text.isNotEmpty ? int.tryParse(_tokenAmtCtrl.text) : null,
      );
      setState(() {
        _resultTxId = txId;
        _sending = false;
      });
    } catch (e) {
      setState(() => _sending = false);
      _snack('Failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Send ERG')),
      body: _resultTxId != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle, size: 64, color: Colors.green),
                    const SizedBox(height: 16),
                    Text('Broadcast', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    SelectableText(_resultTxId!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                  ],
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: ListView(
                  children: [
                    TextFormField(
                      controller: _recipientCtrl,
                      decoration: const InputDecoration(labelText: 'Recipient address'),
                      validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _amountCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Amount (ERG)',
                        hintText: '0.01',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) {
                        final n = double.tryParse(v ?? '');
                        if (n == null || n < 0.001) return 'Minimum 0.001 ERG';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _tokenIdCtrl,
                      decoration: const InputDecoration(labelText: 'Token ID (optional)'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _tokenAmtCtrl,
                      decoration: const InputDecoration(labelText: 'Token amount (optional)'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _sending ? null : _send,
                      child: _sending
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Review'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
