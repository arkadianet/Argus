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
  final _tokenAmtCtrl = TextEditingController();
  bool _sending = false;
  String? _resultTxId;
  String? _assetId;

  static const _nano = 1000000000;

  @override
  void dispose() {
    _recipientCtrl.dispose();
    _amountCtrl.dispose();
    _tokenAmtCtrl.dispose();
    super.dispose();
  }

  WalletRouteArgs get _args => WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);

  TokenBalance? get _selectedToken {
    if (_assetId == null) return null;
    for (final t in _args.tokens) {
      if (t.id == _assetId) return t;
    }
    return null;
  }

  int? _amountNano() => parseErgToNano(_amountCtrl.text);

  String _erg(int nano) => '${(nano / _nano).toStringAsFixed(4)} ERG';

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    final args = _args;
    if (args.senderAddress.isEmpty) {
      _snack('No sender address');
      return;
    }
    final amount = _amountNano();
    if (amount == null) return;
    final token = _selectedToken;
    int? tokenAmount;
    if (token != null) {
      if (token.isNft) {
        tokenAmount = 1;
      } else {
        tokenAmount = parseDecimalToBase(_tokenAmtCtrl.text, token.decimals);
        if (tokenAmount == null || tokenAmount <= 0) {
          _snack('Enter a token amount');
          return;
        }
      }
    }

    setState(() => _sending = true);
    try {
      final preview = await walletService.prepareSend(
        senderAddress: args.senderAddress,
        changeAddress: args.changeAddress.isEmpty ? args.senderAddress : args.changeAddress,
        recipientAddress: _recipientCtrl.text.trim(),
        amountNanoErg: amount,
        tokenId: token?.id,
        tokenAmount: tokenAmount,
      );
      if (!mounted) return;
      final tokenLines = preview.tokenId != null && preview.tokenId!.isNotEmpty
          ? '\nToken: ${token?.label ?? preview.tokenId}\nToken amount: ${preview.tokenAmount}'
          : '';
      final changeLine = preview.changeAddress != null && preview.changeAddress!.isNotEmpty
          ? '\nChange to: ${preview.changeAddress}'
          : '';
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm send'),
          content: Text(
            'To: ${preview.recipient}\n'
            'Amount: ${_erg(preview.amountNanoErg)}\n'
            'Miner fee: ${_erg(preview.minerFee)}\n'
            'Change: ${_erg(preview.changeNanoErg)}'
            '$changeLine\n'
            'Inputs: ${preview.inputCount}'
            '$tokenLines',
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
      final txId = await walletService.sendErg(preparationId: preview.preparationId);
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
    final token = _selectedToken;
    return Scaffold(
      appBar: AppBar(title: const Text('Send')),
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
                    DropdownButtonFormField<String?>(
                      initialValue: _assetId,
                      decoration: const InputDecoration(labelText: 'Asset'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('ERG')),
                        ..._args.tokens.map(
                          (t) => DropdownMenuItem(value: t.id, child: Text(t.label)),
                        ),
                      ],
                      onChanged: (v) => setState(() => _assetId = v),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _amountCtrl,
                      decoration: InputDecoration(
                        labelText: token == null ? 'Amount (ERG)' : 'ERG for the output box',
                        hintText: '0.001',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) {
                        final n = parseErgToNano(v ?? '');
                        if (n == null || n < 1000000) return 'Minimum 0.001 ERG';
                        return null;
                      },
                    ),
                    if (token != null && !token.isNft) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _tokenAmtCtrl,
                        decoration: InputDecoration(labelText: '${token.label} amount'),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        validator: (v) {
                          final n = parseDecimalToBase(v ?? '', token.decimals);
                          if (n == null || n <= 0) return 'Enter an amount';
                          return null;
                        },
                      ),
                    ],
                    if (token != null && token.isNft) ...[
                      const SizedBox(height: 12),
                      Text('Sends 1 ${token.label}', style: theme.textTheme.bodySmall),
                    ],
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
