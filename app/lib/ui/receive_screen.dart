import '../services/watch_account_service.dart';
import 'widgets/tx_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../format.dart';
import '../services/address_label_service.dart';
import '../services/network_controller.dart';
import '../services/session_lock.dart';
import '../services/privacy_service.dart';
import '../services/stealth_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/error_sheet.dart';
import 'widgets/soft_card.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> with TxReceiptOwner {
  final _amountCtrl = TextEditingController();
  String _qrData = '';
  String? _amountError;

  bool _sweeping = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_updateQr);
    privacyService.addListener(_privacyChanged);
  }

  bool _loadedStealth = false;

  /// Which stealth identity the section is showing. Identity 0 for a wallet
  /// that has never added one, which is every wallet until it does.
  int _identity = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!WalletRouteArgs.of(context).watchOnly && !_loadedStealth) {
      _loadedStealth = true;
      if (stealthService.address == null) stealthService.loadAddress();
      stealthService.loadIdentities();
    }
    _updateQr();
  }

  @override
  void dispose() {
    privacyService.removeListener(_privacyChanged);
    _amountCtrl.removeListener(_updateQr);
    _amountCtrl.dispose();
    super.dispose();
  }

  void _privacyChanged() {
    if (mounted) setState(() {});
  }

  void _updateQr() {
    final request = receiveRequest(
      address: WalletRouteArgs.of(context).receiveAddress,
      amount: _amountCtrl.text,
    );
    if (request.payload != _qrData || request.error != _amountError) {
      setState(() {
        _qrData = request.payload;
        _amountError = request.error;
      });
    }
  }

  Future<void> _editLabel(String address) async {
    final existing = addressLabelService.labelFor(address) ?? '';
    final ctrl = TextEditingController(text: existing);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Address label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              shorten(address, head: 10, tail: 8),
              style: monoStyle(ctx, size: 11),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'Label (optional)'),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final label = ctrl.text;
    ctrl.dispose();
    if (ok != true) return;
    await addressLabelService.setLabel(address, label);
  }

  Widget _usedAddressRow(BuildContext context, String a) {
    final colors = ArgusColors.of(context);
    final label = addressLabelService.labelFor(a);
    return InkWell(
      onTap: () async {
        await sessionLock.run(() => Clipboard.setData(ClipboardData(text: a)));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${shorten(a, head: 8, tail: 6)} copied')),
          );
        }
      },
      onLongPress: () => _editLabel(a),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(shorten(a, head: 12, tail: 10), style: monoStyle(context, size: 12)),
                  if (label != null && label.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(label, style: TextStyle(fontSize: 12, color: colors.muted)),
                  ],
                ],
              ),
            ),
            Icon(Icons.copy, size: 16, color: colors.muted),
          ],
        ),
      ),
    );
  }

  /// Ask for a label and publish a new identity at the next index.
  Future<void> _addIdentity() async {
    final controller = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add stealth address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'A separate address you can publish in a different place. '
              'Nothing links it to your other stealth addresses, and it '
              'comes back from your recovery phrase like everything else.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('stealth-identity-label-field'),
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'Donations',
                helperText: 'Stored on this device only.',
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('stealth-identity-add-confirm'),
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label == null || !mounted) return;
    try {
      final created = await stealthService.addIdentity(label);
      if (!mounted) return;
      setState(() => _identity = created.index);
    } catch (e) {
      if (!mounted) return;
      showTxFailureSheet(context, e);
    }
  }

  Future<void> _sweepStealth(String destination, {int? onlyIdentity}) async {
    setState(() => _sweeping = true);
    try {
      final preview = await stealthService.prepareSweep(
        destinationAddress: destination,
        nodeUrl: networkController.activeUrl,
        onlyIdentity: onlyIdentity,
      );
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        preparationId: preview.preparationId,
        title: 'Sweep stealth funds',
        rows: [
          ConfirmTxRow('To', shorten(destination, head: 8, tail: 6)),
          ConfirmTxRow('Amount', formatErg(preview.amountNanoErg), bold: true),
          ConfirmTxRow('Stealth boxes', '${preview.inputCount}'),
          ConfirmTxRow('Miner fee', formatErg(preview.minerFee)),
        ],
      );
      if (!mounted) return;
      if (!ok) {
        setState(() => _sweeping = false);
        return;
      }
      final txId =
          await walletService.sendErg(preparationId: preview.preparationId);
      if (mounted) setState(() => _sweeping = false);
      final warning = await txBookkeeping(() async {
        await stealthService.scan();
        if (stealthService.lastScanFailed) {
          throw StateError('Could not refresh stealth funds');
        }
      });
      showTxResultSheet(
        receiptContext,
        txId: txId,
        headline: 'Stealth sweep submitted',
        warning: warning,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sweeping = false);
      showTxFailureSheet(context, e);
    }
  }

  /// What the line under the QR says about the shown identity.
  ///
  /// A single-identity wallet reads exactly as it did before; once there are
  /// several, the figure is that address's alone, said explicitly, so nobody
  /// reads one pocket's balance as the whole stealth balance.
  static String _stealthStatus(
    StealthScanResult? scan,
    StealthIdentityBalance? balance,
    bool multiple,
  ) {
    if (!stealthService.scanEnabled) {
      return 'Stealth scanning is off. Turn it on in Settings → Security '
          'to see funds sent here.';
    }
    if (scan == null || balance == null) {
      return 'Stealth balance unknown — the explorer could not be reached yet.';
    }
    if (balance.ownedCount == 0) {
      return multiple
          ? 'No payments to this stealth address.'
          : 'No stealth payments found.';
    }
    final amount = '${formatErg(balance.totalNanoErg)} in '
        '${balance.ownedCount} stealth '
        'box${balance.ownedCount == 1 ? '' : 'es'}';
    return multiple ? '$amount on this address.' : '$amount.';
  }

  Widget _stealthSection(BuildContext context, String sweepTo) {
    final colors = ArgusColors.of(context);
    return ListenableBuilder(
      listenable: stealthService,
      builder: (context, _) {
        final identities = stealthService.identities;
        // A wallet that never added one shows exactly what it always did.
        final selected = identities.any((i) => i.index == _identity)
            ? _identity
            : 0;
        final stealth = stealthService.addressOf(selected);
        if (stealth == null) return const SizedBox.shrink();
        final scan = stealthService.lastScan;
        final balance = scan?.balanceOf(selected);
        final multiple = identities.length > 1;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            SectionLabel(multiple ? 'Stealth addresses' : 'Stealth address'),
            const SizedBox(height: 8),
            Text(
              'An address you can publish anywhere. Each payment to it lands '
              'on a different one-time script, so nothing on chain links two '
              'payments to you or to this string. Amounts and timing are '
              'still public. Finding incoming stealth payments needs the '
              'explorer, so it works only while you are online.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (multiple) ...[
              const SizedBox(height: 16),
              // Labels, not indices: the derivation index is plumbing and
              // choosing one by hand is how a user strands a published
              // string on the wrong path.
              DropdownButtonFormField<int>(
                key: const Key('stealth-identity-picker'),
                initialValue: selected,
                decoration: const InputDecoration(labelText: 'Address'),
                items: [
                  for (final id in identities)
                    DropdownMenuItem(
                      value: id.index,
                      child: Text(id.displayLabel),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _identity = v);
                },
              ),
              const SizedBox(height: 4),
              Text(
                'Two of your stealth addresses cannot be linked to each '
                'other, so publishing one per context keeps them apart.',
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
            ],
            const SizedBox(height: 20),
            Center(
              child: Container(
                decoration: BoxDecoration(
                  color: paper,
                  borderRadius: BorderRadius.circular(cardRadius),
                  border: Border.all(
                      color: accentOf(context).withValues(alpha: 0.45)),
                ),
                padding: const EdgeInsets.all(18),
                child: QrImageView(
                  key: const Key('stealth-qr'),
                  data: stealth,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: paper,
                  padding: EdgeInsets.zero,
                  eyeStyle:
                      const QrEyeStyle(eyeShape: QrEyeShape.square, color: ink),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: ink,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(
              stealth,
              key: const Key('stealth-address-text'),
              style: monoStyle(context, size: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('stealth-copy'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: stealth));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Stealth address copied')),
                );
              },
              child: const Text('Copy stealth address'),
            ),
            const SizedBox(height: 12),
            Text(
              _stealthStatus(scan, balance, multiple),
              style: TextStyle(fontSize: 12, color: colors.muted),
              textAlign: TextAlign.center,
            ),
            if ((balance?.ownedCount ?? 0) > 0 && sweepTo.isNotEmpty) ...[
              const SizedBox(height: 12),
              // Sweeping one identity at a time by default: pulling every
              // identity into one output would spend them together and link
              // the contexts the user separated.
              OutlinedButton.icon(
                key: const Key('stealth-sweep'),
                onPressed: _sweeping
                    ? null
                    : () => _sweepStealth(sweepTo, onlyIdentity: selected),
                icon: const Icon(Icons.move_down, size: 18),
                label: Text(_sweeping ? 'Sweeping…' : 'Sweep stealth funds'),
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              key: const Key('stealth-identity-add'),
              onPressed: _addIdentity,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add stealth address'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final args = WalletRouteArgs.of(context);
    final address = args.receiveAddress;
    final fresh = !args.watchOnly &&
        privacyService.useUnusedChangeAddress(walletService.activeWalletId);

    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
                28, 16, 28, 40 + MediaQuery.paddingOf(context).bottom),
        children: [
          SectionLabel(fresh
              ? 'Unused address' : 'Receive address'),
          const SizedBox(height: 8),
          Text(
            args.watchOnly
                ? args.watchAccount
                    ? 'Unused payment address. A new one is offered after payment. $watchAccountLimitations'
                    : 'Payments to this address go to the watched wallet.'
                : fresh
                ? 'A new address is shown after this one is used.'
                : 'This address stays the same. Turn on Fresh addresses in Settings to use a new one after each payment.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('receive-amount'),
            controller: _amountCtrl,
            decoration: InputDecoration(
              labelText: 'Optional amount (ERG)',
              hintText: '0.001',
              errorText: _amountError,
              suffixIcon: const Icon(Icons.tag),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 28),
          if (address.isNotEmpty)
            Center(
              child: Container(
                // Scanners need dark-on-light; the pale card reads as a
                // deliberate "ticket" in both palettes.
                decoration: BoxDecoration(
                  color: paper,
                  borderRadius: BorderRadius.circular(cardRadius),
                  border: Border.all(color: accentOf(context).withValues(alpha: 0.45)),
                ),
                padding: const EdgeInsets.all(18),
                child: QrImageView(
                  data: _qrData.isEmpty ? address : _qrData,
                  semanticsLabel: _qrData.isEmpty ? address : _qrData,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: paper,
                  padding: EdgeInsets.zero,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: ink,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: ink,
                  ),
          ),
            ),
          ),
          const SizedBox(height: 28),
          if (address.isNotEmpty)
            ListenableBuilder(
              listenable: addressLabelService,
              builder: (context, _) {
                final label = addressLabelService.labelFor(address);
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (label != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: accentOf(context).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(label, style: TextStyle(color: accentOf(context), fontSize: 12)),
                      ),
                    if (label != null) const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => _editLabel(address),
                      icon: const Icon(Icons.edit, size: 14),
                      label: Text(label == null ? 'Add label' : 'Edit label'),
                    ),
                  ],
                );
              },
            ),
          const SizedBox(height: 20),
          SelectableText(
            address,
            style: monoStyle(context, size: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: address.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Address copied')),
                    );
                  },
            child: const Text('Copy address'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: address.isEmpty || _amountError != null
                ? null
                : () => sessionLock.run(
                      () => SharePlus.instance.share(ShareParams(text: _qrData)),
                    ),
            child: const Text('Share'),
          ),
          if (!args.watchOnly) _stealthSection(context, address),
          if (!args.watchOnly && args.historyAddresses.where((a) => a != address).isNotEmpty) ...[
            const SizedBox(height: 28),
            const SectionLabel('Used addresses'),
            const SizedBox(height: 4),
            Text(
              'Older addresses keep working; tap one to copy it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            ListenableBuilder(
              listenable: addressLabelService,
              builder: (context, _) => SoftCard(
                padding: EdgeInsets.zero,
                child: DividedColumn(
                  indent: 16,
                  children: [
                    for (final a in args.historyAddresses)
                      if (a != address) _usedAddressRow(context, a),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What a receive request says: the string the QR encodes and Share sends,
/// and why an amount was rejected. Sharing the bare address would drop the
/// amount the payer is meant to see, so both carry the same payload.
({String payload, String? error}) receiveRequest({required String address, required String amount}) {
  final trimmed = amount.trim();
  if (trimmed.isEmpty) return (payload: address, error: null);
  final nano = parseErgToNano(trimmed);
  if (nano == null) {
    return (payload: address, error: 'Amount must be a decimal number, like 0.001');
  }
  if (nano <= 0) {
    return (payload: address, error: 'Amount must be greater than zero');
  }
  return (payload: 'ergo:$address?amount=${formatErg(nano, unit: false)}', error: null);
}
