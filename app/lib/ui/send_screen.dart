import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../services/contacts_service.dart';
import '../services/network_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'scan_screen.dart';

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

  bool get _recipientValid =>
      _recipientCtrl.text.trim().isNotEmpty &&
      looksLikeErgoAddress(_recipientCtrl.text.trim());

  int? _amountNano() => parseErgToNano(_amountCtrl.text);

  void _applyMaxErg() {
    final spendable = _args.spendableNano;
    if (spendable == null) {
      _snack('Spendable balance is unknown');
      return;
    }
    final max = spendable - minerFeeNano - minBoxNano;
    if (max < minBoxNano) {
      _snack('Not enough ERG for fee and change');
      return;
    }
    _amountCtrl.text = formatErg(max, unit: false);
    setState(() {});
  }

  void _applyMaxToken() {
    final token = _selectedToken;
    if (token == null || token.isNft) {
      _snack('No token selected');
      return;
    }
    _tokenAmtCtrl.text = formatTokenAmount(token.amount, token.decimals);
    setState(() {});
  }

  Future<void> _scan() async {
    final raw = await Navigator.push<String>(context, fadeRoute(const ScanScreen()));
    if (!mounted) return;
    if (raw == null) return;
    final pay = parseErgoUri(raw);
    if (pay == null) {
      _snack('Not an Ergo address');
      return;
    }
    _recipientCtrl.text = pay.address;
    if (pay.amountErg != null && pay.amountErg!.isNotEmpty) {
      _amountCtrl.text = pay.amountErg!;
    }
    setState(() {});
  }

  Future<void> _saveRecipientToContacts() async {
    final addr = _recipientCtrl.text.trim();
    if (!looksLikeErgoAddress(addr)) return;
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save to contacts'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.words,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Text(shorten(addr, head: 10, tail: 10), style: monoStyle(ctx, size: 11)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (ok != true || name.isEmpty) return;
    await contactsService.load();
    await contactsService.add(name, addr);
    _snack('Contact saved');
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    final args = _args;
    final spend = args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
    if (spend.isEmpty) {
      _snack('No spendable addresses');
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
        spendAddresses: spend,
        changeAddress: args.changeAddress.isEmpty ? args.senderAddress : args.changeAddress,
        recipientAddress: _recipientCtrl.text.trim(),
        amountNanoErg: amount,
        tokenId: token?.id,
        tokenAmount: tokenAmount,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm send'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('To', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(preview.recipient, style: monoStyle(ctx, size: 12)),
              const SizedBox(height: 12),
              Text('Amount  ${formatErg(preview.amountNanoErg)}'),
              Text('Fee  ${formatErg(preview.minerFee)}'),
              Text('Change  ${formatErg(preview.changeNanoErg)}'),
              if (preview.tokenId != null && preview.tokenId!.isNotEmpty)
                Text('Token  ${token?.label ?? preview.tokenId}  × ${preview.tokenAmount}'),
              const SizedBox(height: 12),
              Text(
                networkController.activeUrl ?? 'Node not chosen yet',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign & broadcast')),
          ],
        ),
      );
      if (!mounted) return;
      if (ok != true) {
        setState(() => _sending = false);
        return;
      }
      try {
        final txId = await walletService.sendErg(preparationId: preview.preparationId);
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        setState(() {
          _resultTxId = txId;
          _sending = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _sending = false);
        _snack('Broadcast may have failed. Check activity before sending again.');
      }
    } catch (e) {
      if (!mounted) return;
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
    final token = _selectedToken;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send'),
        actions: [
          IconButton(
            tooltip: 'Contacts',
            onPressed: () async {
              final result = await Navigator.pushNamed<WalletContact>(context, '/contacts');
              if (result != null && result.address.isNotEmpty) {
                _recipientCtrl.text = result.address;
                setState(() {});
              }
            },
            icon: const Icon(Icons.people_outline),
          ),
          IconButton(
            tooltip: 'Scan',
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
          ),
        ],
      ),
      body: _resultTxId != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const IrisMark(size: 64),
                    const SizedBox(height: 20),
                    Text('Broadcast', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    const SizedBox(width: 48, child: Hairline(gold: true)),
                    const SizedBox(height: 16),
                    SelectableText(_resultTxId!, style: monoStyle(context, size: 12)),
                    const SizedBox(height: 28),
                    FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
                  ],
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Form(
                key: _formKey,
                child: ListView(
                  children: [
                    const SectionLabel('Destination'),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _recipientCtrl,
                      style: monoStyle(context, size: 13),
                      decoration: const InputDecoration(labelText: 'Recipient address'),
                      onChanged: (_) => setState(() {}),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (!looksLikeErgoAddress(v)) return 'Not an Ergo address';
                        return null;
                      },
                    ),
                    if (_recipientValid)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _saveRecipientToContacts,
                          icon: const Icon(Icons.person_add_alt, size: 18),
                          label: const Text('Save to contacts'),
                        ),
                      ),
                    const SizedBox(height: 24),
                    const SectionLabel('Asset'),
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
                      onChanged: (v) => setState(() {
                        _assetId = v;
                        _tokenAmtCtrl.clear();
                      }),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _amountCtrl,
                      decoration: InputDecoration(
                        labelText: token == null ? 'Amount (ERG)' : 'ERG for the output box',
                        hintText: '0.001',
                        suffixIcon: TextButton(onPressed: _applyMaxErg, child: const Text('MAX')),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) {
                        final n = parseErgToNano(v ?? '');
                        if (n == null || n < minBoxNano) return 'Minimum 0.001 ERG';
                        return null;
                      },
                    ),
                    if (token != null && !token.isNft) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _tokenAmtCtrl,
                        decoration: InputDecoration(
                          labelText: '${token.label} amount',
                          suffixIcon: TextButton(onPressed: _applyMaxToken, child: const Text('MAX')),
                        ),
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
                      Text('Sends 1 ${token.label}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                    const SizedBox(height: 28),
                    FilledButton(
                      onPressed: _sending ? null : _send,
                      child: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Review'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
