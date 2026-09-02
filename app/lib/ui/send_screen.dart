import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams, XFile;
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../services/contacts_service.dart';
import '../services/dexy_quote_controller.dart';
import '../services/dexy_service.dart';
import '../services/ergopay_service.dart';
import '../services/network_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'ergopay_screen.dart';
import 'offline_banner.dart';
import 'scan_screen.dart';
import 'send_recipients.dart';
import 'widgets/amount_entry.dart';

/// One auto-buy route line, e.g. `≈ 3.7196 ERG via FreeMint  ·  cheapest`.
String dexyQuoteLabel(DexyPathQuote quote, {required bool cheapest}) =>
    '≈ ${formatErg(quote.ergCostNano)} via ${quote.path}'
    '${cheapest ? '  ·  cheapest' : ''}';

/// Asset-picker entry for a variant the wallet doesn't hold yet. Names the
/// token (USE), not the protocol implementation (DexyUSD).
String dexyAssetLabel(DexyVariant variant) =>
    '${variant.shortName} · buy & send';

/// Amount-field label for the auto-buy flow.
String dexyAmountLabel(DexyVariant variant) =>
    '${variant.shortName} amount to deliver';

class SendScreen extends StatefulWidget {
  const SendScreen({
    super.key,
    this.initialAssetId,
    this.initialRecipient,
    this.initialAmountErg,
  });

  /// Token id to preselect in the asset picker (e.g. from a token sheet).
  final String? initialAssetId;

  /// Recipient and amount from a scanned `ergo:` payment URI; treated as a
  /// trusted source for the clipboard-hijack gate.
  final String? initialRecipient;
  final String? initialAmountErg;

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
  late String? _assetId = widget.initialAssetId;
  final _quotes = DexyQuoteController();
  Set<String> _selectedSpendAddresses = {};
  final _feeCtrl = TextEditingController();
  final List<_RecipientEntry> _extraRecipients = [];
  bool get _multiRecipient => _extraRecipients.isNotEmpty;


  @override
  void initState() {
    super.initState();
    _quotes.addListener(_onQuotes);
    final r = widget.initialRecipient;
    if (r != null && r.isNotEmpty) {
      _recipientCtrl.text = r;
      _recipientTrusted = true;
    }
    final a = widget.initialAmountErg;
    if (a != null && a.isNotEmpty) _amountCtrl.text = a;
  }

  @override
  void dispose() {
    _quotes.removeListener(_onQuotes);
    _quotes.dispose();
    _recipientCtrl.dispose();
    _amountCtrl.dispose();
    _tokenAmtCtrl.dispose();
    _feeCtrl.dispose();
    for (final e in _extraRecipients) e.dispose();
    super.dispose();
  }

  WalletRouteArgs get _args => WalletRouteArgs.of(context);

  TokenBalance? get _selectedToken {
    if (_assetId == null) return null;
    for (final t in _args.tokens) {
      if (t.id == _assetId) return t;
    }
    return null;
  }

  static const _dexyPrefix = 'dexy:';

  /// Raw balance already held for [variant], which the auto-buy route delivers
  /// alongside whatever it acquires.
  int _heldFor(DexyVariant variant) {
    for (final t in _args.tokens) {
      if (t.id == variant.tokenId) return t.amount;
    }
    return 0;
  }

  /// A swap-supported asset selected that the wallet does not hold. Sending
  /// it auto-buys via the cheapest Dexy route (mint or LP swap) first.
  DexyVariant? get _selectedSwapVariant {
    final id = _assetId;
    if (id == null || !id.startsWith(_dexyPrefix)) return null;
    final code = id.substring(_dexyPrefix.length);
    for (final v in DexyVariant.values) {
      if (v.code == code) return v;
    }
    return null;
  }

  void _onQuotes() {
    if (mounted) setState(() {});
  }

  void _scheduleQuotes() {
    final variant = _selectedSwapVariant;
    if (variant == null) return;
    _quotes.request(variant, _tokenAmtCtrl.text, held: _heldFor(variant));
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

  /// True when the recipient came from a trusted source (contact picker or
  /// scanned payment URI) rather than free-typed/pasted text, so the
  /// clipboard-hijack gate can be skipped.
  bool _recipientTrusted = false;

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
    if (isErgoPayLink(raw)) {
      Navigator.push(
        context,
        fadeRoute(ErgoPayScreen(link: raw), settings: RouteSettings(arguments: _args)),
      );
      return;
    }
    final pay = parseErgoUri(raw);
    if (pay == null) {
      _snack('Not an Ergo address');
      return;
    }
    _recipientCtrl.text = pay.address;
    if (pay.amountErg != null && pay.amountErg!.isNotEmpty) {
      _amountCtrl.text = pay.amountErg!;
    }
    _recipientTrusted = true;
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

  /// Every recipient as typed, main form first. A token send with a blank
  /// ERG field carries the minimum box value.
  List<RecipientDraft> _drafts() {
    final token = _selectedToken;
    final erg = _amountCtrl.text.trim();
    return [
      RecipientDraft(
        address: _recipientCtrl.text,
        ergText: token != null && erg.isEmpty
            ? formatErg(minBoxNano, unit: false)
            : erg,
        tokenId: token?.id,
        tokenAmountText: _tokenAmtCtrl.text,
      ),
      for (final e in _extraRecipients)
        RecipientDraft(
          address: e.address,
          ergText: e.amount,
          tokenId: e.tokenId,
          tokenAmountText: e.tokenAmtCtrl?.text,
        ),
    ];
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedSwapVariant != null) {
      await _sendViaSwap();
      return;
    }
    final args = _args;
    final spend = _selectedSpendAddresses.isNotEmpty
        ? _selectedSpendAddresses.toList()
        : _allSpendAddresses;
    if (spend.isEmpty) {
      _snack('No spendable addresses');
      return;
    }

    final List<Map<String, dynamic>> recipients;
    try {
      recipients = buildRecipients(_drafts(), tokens: args.tokens);
    } on SendFormException catch (e) {
      _snack(e.message);
      return;
    }
    final spendable = args.spendableNano;
    final fee = parseErgToNano(_feeCtrl.text) ?? minerFeeNano;
    if (spendable != null && totalNanoErg(recipients) + fee > spendable) {
      _snack('Amount plus fee exceeds your ${formatErg(spendable, maxFrac: 4)}');
      return;
    }

    final changeAddress =
        args.changeAddress.isEmpty ? args.senderAddress : args.changeAddress;
    final isMulti = recipients.length > 1;
    setState(() => _sending = true);
    try {
      final SendPreview preview;
      if (isMulti) {
        preview = await walletService.prepareSendMulti(
          senderAddress: args.senderAddress,
          spendAddresses: spend,
          changeAddress: changeAddress,
          recipients: recipients,
          nodeUrl: networkController.activeUrl,
          feeNanoErg: parseErgToNano(_feeCtrl.text),
        );
      } else {
        final r = recipients.single;
        preview = await walletService.prepareSend(
          senderAddress: args.senderAddress,
          spendAddresses: spend,
          changeAddress: changeAddress,
          recipientAddress: r['address'] as String,
          amountNanoErg: r['amount_nano_erg'] as int,
          tokenId: r['token_id'] as String?,
          tokenAmount: r['token_amount'] as int?,
          nodeUrl: networkController.activeUrl,
          feeNanoErg: parseErgToNano(_feeCtrl.text),
        );
      }
      await _confirmAndSend(preview: preview, isMulti: isMulti);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Failed: $e');
    }
  }

  /// Auto-buy via the cheapest Dexy route, delivering the tokens straight to
  /// the recipient; ERG change returns to the wallet's change address.
  Future<void> _sendViaSwap() async {
    final variant = _selectedSwapVariant!;
    final args = _args;
    final spend = _selectedSpendAddresses.isNotEmpty
        ? _selectedSpendAddresses.toList()
        : _allSpendAddresses;
    if (spend.isEmpty) {
      _snack('No spendable addresses');
      return;
    }
    final tokenAmount =
        parseDecimalToBase(_tokenAmtCtrl.text, variant.decimals);
    if (tokenAmount == null || tokenAmount <= 0) {
      _snack('Enter a token amount');
      return;
    }
    // Nothing to acquire: the auto-buy routes have no shortfall to price and
    // would fail with NO_ROUTE. Hand the user the ordinary token send instead,
    // which spends the balance they already hold.
    if (shortfallFor(wanted: tokenAmount, held: _heldFor(variant)) == 0) {
      final outputErg = _amountNano();
      if (outputErg == null || outputErg < minBoxNano) {
        _amountCtrl.text = formatErg(minBoxNano, unit: false);
      }
      setState(() => _assetId = variant.tokenId);
      _snack('You already hold enough ${variant.shortName} — '
          'sending it directly. Review to continue.');
      return;
    }

    final changeAddr = args.changeAddress.isNotEmpty
        ? args.changeAddress
        : args.senderAddress;

    // The token send carries a user-supplied recipient too — run the same
    // clipboard-hijack gate as the ordinary flow.
    if (!_recipientTrusted) {
      final clear =
          await _clipboardMatchesIntent(context, _recipientCtrl.text.trim());
      if (!clear) return;
    }

    setState(() => _sending = true);
    DexyBuildResult build;
    try {
      build = await dexService.buildTokenSend(
        variant: variant,
        tokenAmount: tokenAmount,
        recipient: _recipientCtrl.text.trim(),
        changeAddress: changeAddr,
        spendAddresses: spend,
        heldTokens: _heldFor(variant),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Could not build a route: $e');
      return;
    }
    if (!mounted) return;

    final isMint = build.action.startsWith('mint');
    final choice = await showConfirmTransactionChoice(
      context,
      title: 'Send ${variant.shortName}',
      confirmLabel: 'Buy & send',
      recipientAddress: _recipientCtrl.text.trim(),
      rows: [
        ConfirmTxRow(
          'Recipient gets',
          '${formatTokenAmount(build.tokenAmount, variant.decimals)} '
              '${variant.shortName}',
          bold: true,
        ),
        ConfirmTxRow(
          'ERG cost',
          formatErg(isMint ? build.ergCostNano : build.inputAmount),
        ),
        ConfirmTxRow('Miner fee', formatErg(build.minerFee)),
        ConfirmTxRow('Change to you', formatErg(build.changeNanoErg)),
      ],
      detail: 'You don\'t hold enough ${variant.shortName}, so this buys it '
          'first (${isMint ? 'bank mint' : 'LP swap'}) and forwards it in one '
          'transaction.  ·  ${networkController.activeUrl ?? 'Node not chosen yet'}',
    );
    if (!mounted) return;
    if (choice != ConfirmChoice.broadcast) {
      setState(() => _sending = false);
      return;
    }
    try {
      final txId = await walletService.sendErg(preparationId: build.preparationId);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _resultTxId = txId;
        _sending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack('Broadcast may have failed. Check activity before retrying.');
    }
  }

  /// Clipboard-hijack defense: if the OS clipboard holds a *different*
  /// Ergo address than the one entered, make the user acknowledge it before
  /// the confirmation dialog appears.
  ///
  /// Skipped when the recipient came from a trusted source (contact or scan).
  /// Residual risk for free-typed entries — malware that swaps the clipboard
  /// *before* the user pastes is indistinguishable from ordinary paste — is
  /// mitigated by the selectable full-address display in the confirm dialog
  /// and contact-book usage, not by this check.
  Future<bool> _clipboardMatchesIntent(BuildContext ctx, String recipient) async {
    if (_recipientTrusted) return true;
    final clip = await Clipboard.getData('text/plain');
    final clipText = clip?.text?.trim() ?? '';
    if (clipText.isEmpty || clipText == recipient) return true;
    if (!looksLikeErgoAddress(clipText)) return true;
    if (!mounted) return false;
    final proceed = await showDialog<bool>(
      context: ctx,
      builder: (context) => AlertDialog(
        title: const Text('Clipboard holds another address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Something you copied earlier is an Ergo address that differs '
              'from the recipient. Malware can swap addresses on the '
              'clipboard. Verify every character.',
            ),
            const SizedBox(height: 12),
            Text('Recipient:', style: Theme.of(context).textTheme.titleSmall),
            SelectableText(recipient, style: monoStyle(context, size: 12)),
            const SizedBox(height: 8),
            Text('Clipboard:', style: Theme.of(context).textTheme.titleSmall),
            SelectableText(clipText, style: monoStyle(context, size: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Recipient is correct'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _confirmAndSend({
    required SendPreview preview,
    required bool isMulti,
  }) async {
    if (!isMulti) {
      final clear = await _clipboardMatchesIntent(context, preview.recipient);
      if (!clear) {
        setState(() => _sending = false);
        return;
      }
    }
    if (!mounted) return;
    final token = _selectedToken;
    final tokenId = preview.tokenId;
    final rows = <ConfirmTxRow>[
      if (isMulti)
        for (final r in preview.recipients ?? const <Map<String, dynamic>>[])
          ConfirmTxRow(
            shorten(r['address']?.toString() ?? '', head: 8, tail: 6),
            '${formatErg((r['amount_nano_erg'] as num?)?.toInt() ?? 0)}'
            '${r['token_id'] != null ? ' + ${_tokenLabel((r['token_amount'] as num?)?.toInt() ?? 0, r['token_id'] as String)}' : ''}',
          ),
      ConfirmTxRow(
        isMulti ? 'Total sent' : 'Amount',
        formatErg(preview.amountNanoErg),
        bold: true,
      ),
      if (!isMulti && tokenId != null && tokenId.isNotEmpty)
        ConfirmTxRow('Token', _tokenLabel(preview.tokenAmount ?? 0, tokenId), bold: true),
      ConfirmTxRow('Miner fee', formatErg(preview.minerFee)),
      ConfirmTxRow('Change to you', formatErg(preview.changeNanoErg)),
    ];
    final fiat = networkController.fiatText(preview.amountNanoErg);
    final choice = await showConfirmTransactionChoice(
      context,
      title: isMulti ? 'Confirm multi-recipient send' : 'Confirm send',
      rows: rows,
      recipientAddress: isMulti ? null : preview.recipient,
      detail: [
        if (fiat != null) fiat,
        networkController.activeUrl ?? 'Node not chosen yet',
      ].join('  ·  '),
      allowSignOnly: true,
      expandableTitle: 'Show ${preview.inputBoxes.length} input UTXOs',
      expandable: preview.inputBoxes.isEmpty
          ? null
          : _InputBoxList(preview.inputBoxes, token),
    );
    if (!mounted) return;
    switch (choice) {
      case ConfirmChoice.cancel:
        setState(() => _sending = false);
      case ConfirmChoice.signOnly:
        try {
          final rawTxJson = await walletService.signPreparation(
            preparationId: preview.preparationId,
          );
          if (!mounted) return;
          _showRawTx(rawTxJson);
          setState(() => _sending = false);
        } catch (e) {
          if (!mounted) return;
          setState(() => _sending = false);
          _snack('Signing failed: $e');
        }
      case ConfirmChoice.broadcast:
        try {
          final txId = await walletService.sendErg(
            preparationId: preview.preparationId,
          );
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
    }
  }

  String _tokenLabel(int amount, String tokenId) {
    for (final t in _args.tokens) {
      if (t.id == tokenId) return '${formatTokenAmount(amount, t.decimals)} ${t.label}';
    }
    return '$tokenId: $amount';
  }

  /// "Available 12.3456 ERG" under the amount field.
  String? _availableLine() {
    final spendable = _args.spendableNano;
    if (spendable == null) return null;
    return 'Available ${formatErg(spendable, maxFrac: 4)}';
  }

  String _advancedSummary() {
    final all = _allSpendAddresses.length;
    final picked = _selectedSpendAddresses.length;
    final fee = parseErgToNano(_feeCtrl.text) ?? minerFeeNano;
    return [
      picked == 0 ? 'All $all addresses' : '$picked of $all addresses',
      'Fee ${formatErg(fee, unit: false)} ERG',
    ].join('  ·  ');
  }

  TokenBalance? _tokenById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final t in _args.tokens) {
      if (t.id == id) return t;
    }
    return null;
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

  Widget _buildSwapSection(DexyVariant variant) {
    final quotes = _quotes.quotes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        TextFormField(
          controller: _tokenAmtCtrl,
          decoration: InputDecoration(
            labelText: dexyAmountLabel(variant),
            helperText: _heldFor(variant) > 0
                ? 'You hold ${formatTokenAmount(_heldFor(variant), variant.decimals)} '
                    '${variant.shortName} — only the shortfall is bought.'
                : 'You don\'t hold ${variant.shortName} — it is bought automatically at the best rate.',
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => _scheduleQuotes(),
          validator: (v) {
            final n = parseDecimalToBase(v ?? '', variant.decimals);
            if (n == null || n <= 0) return 'Enter an amount';
            return null;
          },
        ),
        const SizedBox(height: 12),
        if (quotes == null)
          Text(
            'Enter an amount to see the ERG cost.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else if (quotes.isEmpty)
          Text(
            'No route available for this amount right now.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: rustFor(context)),
          )
        else
          for (final (i, q) in quotes.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    i == 0 ? Icons.star : Icons.alt_route,
                    size: 16,
                    color: i == 0 ? iris : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dexyQuoteLabel(q, cheapest: i == 0),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final token = _selectedToken;
    final swapVariant = _selectedSwapVariant;
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
                _recipientTrusted = true;
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
                    Text('Sent!', style: Theme.of(context).textTheme.headlineSmall),                    const SizedBox(height: 8),
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
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Done'),
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
                    const OfflineBanner(),
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
                      onChanged: (_) {
                        // Free-typed or re-pasted text loses trusted provenance.
                        _recipientTrusted = false;
                        setState(() {});
                      },
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
                        // Offered even when a balance exists: holding some but
                        // not enough used to hide this route and dead-end the
                        // send. Any shortfall is topped up, so the held balance
                        // rides along rather than being ignored.
                        ...DexyVariant.values.map(
                          (v) => DropdownMenuItem(
                            value: '$_dexyPrefix${v.code}',
                            child: Text(dexyAssetLabel(v)),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() {
                        _assetId = v;
                        _tokenAmtCtrl.clear();
                        _quotes.clear();
                      }),
                    ),
                    if (swapVariant != null)
                      _buildSwapSection(swapVariant)
                    else ...[
                      const SizedBox(height: 12),
                      if (token == null)
                        AmountEntry(
                          controller: _amountCtrl,
                          helperText: _availableLine(),
                          onMax: _applyMaxErg,
                          onChanged: (_) => setState(() {}),
                          validator: (v) {
                            final n = parseErgToNano(v ?? '');
                            if (n == null || n < minBoxNano) return 'Minimum 0.001 ERG';
                            return null;
                          },
                        )
                      else if (!token.isNft)
                        TextFormField(
                          controller: _tokenAmtCtrl,
                          decoration: InputDecoration(
                            labelText: '${token.label} amount',
                            helperText:
                                'Available ${formatTokenAmount(token.amount, token.decimals)} ${token.label}',
                            suffixIcon: TextButton(onPressed: _applyMaxToken, child: const Text('MAX')),
                          ),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          validator: (v) {
                            final n = parseDecimalToBase(v ?? '', token.decimals);
                            if (n == null || n <= 0) return 'Enter an amount';
                            if (n > token.amount) {
                              return 'You hold ${formatTokenAmount(token.amount, token.decimals)}';
                            }
                            return null;
                          },
                        )
                      else
                        Text('Sends 1 ${token.label}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                    const SizedBox(height: 16),
                    if (_multiRecipient && swapVariant == null)
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
                            final entryToken = _tokenById(entry.tokenId);
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
                                      if (entryToken != null && entry.tokenAmtCtrl != null) ...[
                                        const SizedBox(height: 12),
                                        TextFormField(
                                          controller: entry.tokenAmtCtrl,
                                          decoration: InputDecoration(
                                            labelText: '${entryToken.label} amount',
                                            helperText:
                                                'Available ${formatTokenAmount(entryToken.amount, entryToken.decimals)}',
                                          ),
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          onChanged: (_) => setState(() {}),
                                          validator: (v) {
                                            final n = parseDecimalToBase(v ?? '', entryToken.decimals);
                                            if (n == null || n <= 0) return 'Enter a token amount';
                                            if (n > entryToken.amount) {
                                              return 'You hold ${formatTokenAmount(entryToken.amount, entryToken.decimals)}';
                                            }
                                            return null;
                                          },
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
                    else if (swapVariant == null)
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
                      title: const Text('Advanced'),
                      subtitle: Text(
                        _advancedSummary(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      onExpansionChanged: (_) => setState(() {}),
                      children: [
                        if (token != null && swapVariant == null) ...[
                          TextFormField(
                            controller: _amountCtrl,
                            decoration: InputDecoration(
                              labelText: 'ERG carried with the token',
                              hintText: formatErg(minBoxNano, unit: false),
                              helperText:
                                  'Leave blank for the minimum box value of ${formatErg(minBoxNano)}.',
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return null;
                              final n = parseErgToNano(v);
                              if (n == null || n < minBoxNano) return 'Minimum 0.001 ERG';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                        ],
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Spend from',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Deselected addresses are excluded from coin selection.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
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
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => setState(() => _selectedSpendAddresses.clear()),
                              child: const Text('Use all addresses'),
                            ),
                          ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _feeCtrl,
                          decoration: InputDecoration(
                            labelText: 'Miner fee (ERG)',
                            hintText: formatErg(minerFeeNano, unit: false),
                            helperText: 'Leave blank for the default ${formatErg(minerFeeNano)}.',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          onChanged: (_) => setState(() {}),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return null;
                            final n = parseErgToNano(v);
                            if (n == null || n < minBoxNano) return 'Minimum 0.001 ERG';
                            return null;
                          },
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
