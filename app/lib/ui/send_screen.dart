import 'dart:convert';
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

  @override
  void dispose() {
    _recipientCtrl.dispose();
    _amountCtrl.dispose();
    _tokenIdCtrl.dispose();
    _tokenAmtCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _sending = true);

    try {
      final sender = ModalRoute.of(context)?.settings.arguments as String? ?? '';
      final amount = int.tryParse(_amountCtrl.text) ?? 0;
      final tokenId = _tokenIdCtrl.text.isNotEmpty ? _tokenIdCtrl.text : null;
      final tokenAmt = _tokenAmtCtrl.text.isNotEmpty ? int.tryParse(_tokenAmtCtrl.text) : null;

      final resultJson = await walletService.sendErg(
        senderAddress: sender,
        recipientAddress: _recipientCtrl.text,
        amountNanoErg: amount,
        tokenId: tokenId,
        tokenAmount: tokenAmt,
      );

      final tx = jsonDecode(resultJson) as Map<String, dynamic>;
      setState(() {
        _resultTxId = tx['id']?.toString() ?? 'unknown';
        _sending = false;
      });
    } catch (e) {
      setState(() => _sending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
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
                    Text('Transaction submitted', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    SelectableText(_resultTxId!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Done'),
                    ),
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
                      decoration: const InputDecoration(
                        labelText: 'Recipient address',
                        hintText: '9f...',
                      ),
                      validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _amountCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Amount (nanoERG)',
                        hintText: '1000000000 = 1 ERG',
                      ),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Required';
                        final n = int.tryParse(v);
                        if (n == null || n < 1000000) return 'Min 1000000 (0.001 ERG)';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _tokenIdCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Token ID (optional)',
                        hintText: 'Hex token ID',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _tokenAmtCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Token amount (optional)',
                        hintText: 'Required if token ID set',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _sending ? null : _send,
                      child: _sending
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Send'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}