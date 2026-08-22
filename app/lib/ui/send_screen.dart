import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;
import 'package:url_launcher/url_launcher.dart';

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

class _RecipientEntry {
  _RecipientEntry() {}
  final addressCtrl = TextEditingController();
  final amountCtrl = TextEditingController();
  TextEditingController? tokenAmtCtrl;
  String? tokenId;

  String get address => addressCtrl.text.trim();
  String get amount => amountCtrl.text.trim();

  void dispose() {
    addressCtrl.dispose();
    amountCtrl.dispose();
    tokenAmtCtrl?.dispose();
  }
}

class _SendScreenState extends State<SendScreen> {
  final _formKey = GlobalKey<FormState>();
  final _recipientCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _tokenAmtCtrl = TextEditingController();
  bool _sending = false;
  String? _resultTxId;
  String? _assetId;
  Set<String> _selectedSpendAddresses = {};
  final _feeCtrl = TextEditingController();
  final List<_RecipientEntry> _extraRecipients = [];
  bool get _multiRecipient => _extraRecipients.isNotEmpty;


  @override
  void dispose() {
    _recipientCtrl.dispose();
    _amountCtrl.dispose();
    _tokenAmtCtrl.dispose();
    _feeCtrl.dispose();
    for (final e in _extraRecipients) e.dispose();
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

  List<String> get _allSpendAddresses {
    final args = _args;
    return args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
  }

  bool get _recipientValid =>
      _recipientCtrl.text.trim().isNotEmpty &&
      looksLikeErgoAddress(_recipientCtrl.text.trim());

  int? _amountNano() => parseErgToNano(_amountCtrl.text);

  String? get _contactForRecipient {
    final addr = _recipientCtrl.text.trim();
    if (addr.isEmpty) return null;
    for (final c in contactsService.contacts) {
      if (c.address == addr) return 'Contact: ${c.name}';
    }
    return null;
  }

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
    await contactsService.add(name, addr);
    _snack('Contact saved');
  }

   Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    final args = _args;
    final allAddrs = _allSpendAddresses;
    final spend = _selectedSpendAddresses.isNotEmpty
        ? _selectedSpendAddresses.toList()
        : allAddrs;
    if (spend.isEmpty) {
      _snack('No spendable addresses');
      return;
    }
    final amount = _amountNano();
    if (amount == null) return;

    // Build the list of all recipients for multi-send path
    final List<Map<String, dynamic>> allRecipients = [];
    if (_recipientValid) {
      final recipient = <String, dynamic>{
        'address': _recipientCtrl.text.trim(),
        'amount_nano_erg': amount,
      };
      final token = _selectedToken;
      if (token != null) {
        recipient['token_id'] = token.id;
        if (token.isNft) {
          recipient['token_amount'] = 1;
        } else {
          final tokenAmount = parseDecimalToBase(_tokenAmtCtrl.text, token.decimals);
          if (tokenAmount == null || tokenAmount <= 0) {
            _snack('Enter a token amount');
            return;
          }
          recipient['token_amount'] = tokenAmount;
        }
      }
      allRecipients.add(recipient);
    }

    // Collect extra recipients
    for (final entry in _extraRecipients) {
      final entryAmount = parseErgToNano(entry.amount);
      if (entryAmount == null) {
        _snack('Validate all recipient amounts');
        return;
      }
      if (!looksLikeErgoAddress(entry.address)) {
        _snack('Validate all recipient addresses');
        return;
      }
      final r = <String, dynamic>{
        'address': entry.address,
        'amount_nano_erg': entryAmount,
      };
      if (entry.tokenId != null && entry.tokenId!.isNotEmpty) {
        TokenBalance? token;
        for (final t in _args.tokens) {
          if (t.id == entry.tokenId) {
            token = t;
            break;
          }
        }
        if (token == null) {
          _snack('Validate all token amounts');
          return;
        }
        r['token_id'] = entry.tokenId;
        if (entry.tokenAmtCtrl == null || entry.tokenAmtCtrl!.text.trim().isEmpty) {
          _snack('Enter a token amount');
          return;
        }
        final parsed = parseDecimalToBase(entry.tokenAmtCtrl!.text, token.decimals);
        if (parsed == null || parsed <= 0) {
          _snack('Validate all token amounts');
          return;
        }
        r['token_amount'] = parsed;
      }
      allRecipients.add(r);
    }

    if (allRecipients.length < 2) {
      // Single recipient — use legacy prepareSend
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
          feeNanoErg: parseErgToNano(_feeCtrl.text),
        );
        await _confirmAndSend(ctx: context, preview: preview, token: token, spend: spend);
      } catch (e) {
        if (!mounted) return;
        setState(() => _sending = false);
        _snack('Failed: $e');
      }
      return;
    }

    // Multi-recipient — use prepareSendMulti
    setState(() => _sending = true);
    try {
      final preview = await walletService.prepareSendMulti(
        senderAddress: args.senderAddress,
        spendAddresses: spend,
        changeAddress: args.changeAddress.isEmpty ? args.senderAddress : args.changeAddress,
        recipients: allRecipients,
        nodeUrl: networkController.activeUrl,
        feeNanoErg: parseErgToNano(_feeCtrl.text),
      );
      await _confirmAndSend(ctx: context, preview: preview, token: _selectedToken, spend: spend, isMulti: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Failed: $e');
    }
  }

  Future<void> _confirmAndSend({
    required BuildContext ctx,
    required SendPreview preview,
    required TokenBalance? token,
    required List<String> spend,
    bool isMulti = false,
  }) async {
    final ok = await showDialog<dynamic>(
      context: ctx,
      builder: (context) {
        var showUtxos = true;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(isMulti ? 'Confirm multi-recipient send' : 'Confirm send'),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isMulti) ..._multiRecipientSummary(ctx, preview) else ...[
                        Text('To', style: Theme.of(ctx).textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(preview.recipient, style: monoStyle(ctx, size: 12)),
                        const SizedBox(height: 12),
                        Text('Amount  ${formatErg(preview.amountNanoErg)}'),
                        const SizedBox(height: 8),
                      ],
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Miner fee', style: TextStyle(fontWeight: FontWeight.w600)),
                                Text(formatErg(preview.minerFee), style: monoStyle(ctx, size: 12)),
                              ],
                            ),
                            if (preview.inputCount > 0)
                              Text(
                                '${preview.inputCount} inputs selected  ·  Network-computed',
                                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('Change  ${formatErg(preview.changeNanoErg)}'),
                      if (!isMulti && preview.tokenId != null && preview.tokenId!.isNotEmpty)
                        Text('Token  ${token?.label ?? preview.tokenId}  × ${preview.tokenAmount}'),
                      if (preview.inputBoxes.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: showUtxos,
                          onChanged: (v) => setDialogState(() => showUtxos = v ?? false),
                          title: const Text('Show UTXOs'),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (showUtxos) _InputBoxList(preview.inputBoxes, token),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        networkController.activeUrl ?? 'Node not chosen yet',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                TextButton.icon(
                  onPressed: () => Navigator.pop(context, 'sign_only'),
                  icon: const Icon(Icons.save, size: 16),
                  label: const Text('Sign only'),
                ),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign & broadcast')),
              ],
            );
          },
        );
      },
    );
    if (!mounted) return;
    if (ok != true && ok != 'sign_only') {
      setState(() => _sending = false);
      return;
    }
    try {
      if (ok == 'sign_only') {
        final rawTxJson = await walletService.signPreparation(preparationId: preview.preparationId);
        if (!mounted) return;
        _showRawTx(rawTxJson);
        setState(() => _sending = false);
      } else {
        final txId = await walletService.sendErg(preparationId: preview.preparationId);
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        setState(() {
          _resultTxId = txId;
          _sending = false;
        });
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted) Navigator.pop(context);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      if (ok == 'sign_only') {
        _snack('Signing failed: $e');
      } else {
        _snack('Broadcast may have failed. Check activity before sending again.');
      }
    }
  }

  List<Widget> _multiRecipientSummary(BuildContext ctx, SendPreview preview) {
    final recips = preview.recipients ?? [];
    return [
      Text('Recipients (${recips.length})', style: Theme.of(ctx).textTheme.titleSmall),
      const SizedBox(height: 4),
      ...recips.asMap().entries.map((e) {
        final r = e.value;
        final nano = r['amount_nano_erg'] as int? ?? 0;
        final tokenId = r['token_id'] as String?;
        final tokenAmt = r['token_amount'] as int?;
        final suffix = tokenId != null
            ? ' + ${_tokenLabel(tokenAmt ?? 0, tokenId)}'
            : '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            '${r['address']}: ${formatErg(nano)}$suffix',
            style: monoStyle(ctx, size: 12),
          ),
        );
      }),
      const SizedBox(height: 12),
      Text('Total sent  ${formatErg(preview.amountNanoErg)}'),
      const SizedBox(height: 8),
    ];
  }

  String _tokenLabel(int amount, String tokenId) {
    for (final t in _args.tokens) {
      if (t.id == tokenId) return '${formatTokenAmount(amount, t.decimals)} ${t.label}';
    }
    return '$tokenId: $amount';
  }
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showRawTx(String rawTxJson) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Raw signed transaction'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Transaction is signed but not broadcast. Share or save the raw transaction '
                'to submit later via an explorer or another wallet.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: SelectableText(
                    rawTxJson,
                    style: monoStyle(ctx, size: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: rawTxJson)),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
          ),
          TextButton.icon(
                onPressed: () async {
                  final bytes = Uint8List.fromList(utf8.encode(rawTxJson));
                  await SharePlus.instance.share(ShareParams(
                    files: [XFile.fromData(bytes, name: 'signed_tx.json', mimeType: 'application/json')],
                  ));
                },
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Share'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
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
              final result =
                  await Navigator.pushNamed<WalletContact>(context, '/contacts', arguments: true);
              if (!mounted) return;
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
                    const Icon(Icons.check_circle, size: 64, color: Color(0xFF5B9E6D)),
                    const SizedBox(height: 20),
                    Text('Sent!', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    const SizedBox(width: 48, child: Hairline(gold: true)),
                    const SizedBox(height: 16),
                    SelectableText(_resultTxId!, style: monoStyle(context, size: 12)),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () {
                        final url = networkController.explorerTx(_resultTxId!);
                        launchUrl(Uri.parse(url));
                      },
                      icon: const Icon(Icons.open_in_browser, size: 16),
                      label: const Text('View on explorer'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Returning to dashboard…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
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
                      decoration: InputDecoration(
                        labelText: 'Recipient address',
                        hintText: 'Or tap contacts to pick a saved one',
                        helperText: _contactForRecipient,
                      ),
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
                    const SizedBox(height: 16),
                    if (_multiRecipient)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Additional recipients',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          ..._extraRecipients.asMap().entries.map((e) {
                            final idx = e.key;
                            final entry = e.value;
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextFormField(
                                      controller: entry.addressCtrl,
                                      decoration: InputDecoration(
                                        labelText: 'Recipient ${idx + 2} address',
                                        hintText: '9...',
                                      ),
                                      style: monoStyle(context, size: 13),
                                      onChanged: (_) => setState(() {}),
                                      validator: (v) {
                                        if (v == null || v.trim().isEmpty) return 'Required';
                                        if (!looksLikeErgoAddress(v)) return 'Not an Ergo address';
                                        return null;
                                      },
                                    ),
                                    const SizedBox(height: 12),
                                    TextFormField(
                                      controller: entry.amountCtrl,
                                      decoration: const InputDecoration(
                                        labelText: 'Amount (ERG)',
                                        hintText: '0.001',
                                      ),
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      validator: (v) {
                                        final n = parseErgToNano(v ?? '');
                                        if (n == null || n < minBoxNano) return 'Minimum 0.001 ERG';
                                        return null;
                                      },
                                    ),
                                    if (_args.tokens.any((t) => !t.isNft)) ...[
                                      const SizedBox(height: 12),
                                      DropdownButtonFormField<String?>(
                                        initialValue: entry.tokenId,
                                        decoration: const InputDecoration(labelText: 'Token'),
                                        items: [
                                          const DropdownMenuItem(value: null, child: Text('None')),
                                          ..._args.tokens.where((t) => !t.isNft).map(
                                            (t) => DropdownMenuItem(value: t.id, child: Text(t.label)),
                                          ),
                                        ],
                                        onChanged: (v) {
                                          entry.tokenId = v;
                                          if (v != null && v.isNotEmpty && entry.tokenAmtCtrl == null) {
                                            entry.tokenAmtCtrl = TextEditingController();
                                          }
                                          setState(() {});
                                        },
                                      ),
                                      if (entry.tokenId != null &&
                                          entry.tokenId!.isNotEmpty &&
                                          entry.tokenAmtCtrl != null) ...[
                                        const SizedBox(height: 12),
                                        TextFormField(
                                          controller: entry.tokenAmtCtrl,
                                          decoration: const InputDecoration(labelText: 'Token amount'),
                                          keyboardType: const TextInputType.numberWithOptions(),
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ],
                                    ],
                                    const SizedBox(height: 8),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        onPressed: () {
                                          setState(() => _extraRecipients.removeAt(idx));
                                          WidgetsBinding.instance.addPostFrameCallback((_) => entry.dispose());
                                        },
                                        icon: const Icon(Icons.delete, size: 16),
                                        label: const Text('Remove'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _extraRecipients.add(_RecipientEntry());
                              });
                            },
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add another recipient'),
                          ),
                        ],
                      )
                    else
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _extraRecipients.add(_RecipientEntry());
                          });
                        },
                        icon: const Icon(Icons.person_add, size: 18),
                        label: const Text('Add another recipient'),
                      ),
                    const SizedBox(height: 16),
                    ExpansionTile(
                      title: const Text('Spend addresses'),
                      subtitle: Text(
                        _selectedSpendAddresses.isEmpty
                            ? 'All ${_allSpendAddresses.length} wallet addresses'
                            : '${_selectedSpendAddresses.length} of ${_allSpendAddresses.length} selected',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      onExpansionChanged: (_) => setState(() {}),
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Select which wallet addresses to spend from. Deselecting excludes those addresses from coin selection.',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          children: _allSpendAddresses.map((addr) {
                              final sel = _selectedSpendAddresses.contains(addr);
                              return FilterChip(
                                label: Text(
                                  shorten(addr, head: 4, tail: 4),
                                  style: monoStyle(context, size: 10),
                                ),
                                selected: sel,
                                onSelected: (_) {
                                  setState(() {
                                    if (sel) {
                                      _selectedSpendAddresses.remove(addr);
                                    } else {
                                      _selectedSpendAddresses.add(addr);
                                    }
                                  });
                                },
                              );
                            }).toList(),
                        ),
                        if (_selectedSpendAddresses.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: TextButton(
                              onPressed: () => setState(() => _selectedSpendAddresses.clear()),
                              child: const Text('Use all addresses'),
                            ),
                          ),
                        const Divider(height: 24),
                        TextFormField(
                          controller: _feeCtrl,
                          decoration: InputDecoration(
                            labelText: 'Custom miner fee (optional)',
                            hintText: 'e.g. 0.0011',
                             helperText: 'Default: ${formatErg(minerFeeNano, unit: false)} ERG. Leave blank for default.',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        ),
                      ],
                    ),
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

class _InputBoxList extends StatelessWidget {
  const _InputBoxList(this.inputBoxes, this.selectedToken);

  final List<InputBoxInput> inputBoxes;
  final TokenBalance? selectedToken;

  String _formatAsset(InputAsset asset) {
    final known = selectedToken?.id == asset.tokenId ? selectedToken : null;
    final label = known != null
        ? known.label
        : shorten(asset.tokenId, head: 8, tail: 8);
    if (known != null) {
      return '$label  ${formatTokenAmountBigInt(asset.amount, known.decimals)}';
    }
    return '$label  ${asset.amount.toString()}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Selected inputs', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('Inputs: ${inputBoxes.length}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        ...inputBoxes.map((box) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(shorten(box.boxId, head: 8, tail: 8), style: monoStyle(context, size: 11)),
                const SizedBox(height: 2),
                Text(
                  '${formatNanoErg(box.valueNanoErg)} (height ${box.creationHeight})',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (box.assets.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      for (final a in box.assets)
                        Text(
                          _formatAsset(a),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          );
        }),
      ],
    );
  }
}
