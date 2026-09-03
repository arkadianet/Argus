
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../bridge/argus_error.dart';
import '../format.dart';
import '../services/address_label_service.dart';
import '../services/ergopay_service.dart';
import '../services/ergopay_summary.dart';
import '../services/network_controller.dart';
import '../services/session_lock.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'offline_banner.dart';
import 'widgets/soft_card.dart';

enum _Stage { loading, message, ready, signing, done, error }

/// EIP-20 ErgoPay: resolve a link into a signing request, show what the
/// transaction does, sign, broadcast, and tell the dApp the tx id.
class ErgoPayScreen extends StatefulWidget {
  const ErgoPayScreen({super.key, required this.link});

  /// Raw `ergopay:` link from a deep link or QR code.
  final String link;

  @override
  State<ErgoPayScreen> createState() => _ErgoPayScreenState();
}

class _ErgoPayScreenState extends State<ErgoPayScreen> {
  _Stage _stage = _Stage.loading;
  String _status = 'Contacting the dApp…';
  String? _error;
  ErgoPayRequest? _request;
  ErgoPaySummary? _summary;
  Uint8List? _reducedTx;
  String? _txId;
  String? _replyError;

  WalletRouteArgs get _args => WalletRouteArgs.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    try {
      final parsed = parseErgoPayLink(widget.link);
      if (parsed == null) {
        _fail('This is not an ErgoPay link.');
        return;
      }
      final ErgoPayRequest request;
      switch (parsed) {
        case StaticErgoPayLink(:final reducedTx):
          request = ErgoPayRequest(reducedTx: reducedTx);
        case RemoteErgoPayLink():
          var url = parsed.url;
          if (parsed.needsAddress) {
            final chosen = await _pickAddress();
            if (chosen == null) {
              if (mounted) Navigator.pop(context);
              return;
            }
            url = parsed.withAddress(chosen);
          }
          setState(() => _status = 'Contacting the dApp…');
          request = await ergoPayClient.fetch(url);
      }
      if (!mounted) return;
      _request = request;

      final wanted = request.address;
      if (wanted != null && !await walletService.ownsAddress(wanted)) {
        _fail('This request is for ${shorten(wanted, head: 8, tail: 6)}, '
            'which is not an address of this wallet.');
        return;
      }
      final tx = request.reducedTx;
      if (tx == null || request.severity == ErgoPaySeverity.error) {
        setState(() => _stage = _Stage.message);
        return;
      }
      _reducedTx = tx;
      setState(() => _status = 'Reading the transaction…');
      final json = await walletService.describeReducedTransaction(
        tx,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      setState(() {
        _summary = ErgoPaySummary.fromJson(json);
        _stage = _Stage.ready;
      });
    } on ErgoPayException catch (e) {
      _fail(e.message);
    } on ArgusException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail(_describe(e));
    }
  }

  String _describe(Object e) {
    if (e is String) return ArgusException.fromJson(e).message;
    return e.toString();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _stage = _Stage.error;
    });
  }

  Future<String?> _pickAddress() async {
    final args = _args;
    final addresses = args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
    if (addresses.isEmpty) return null;
    if (addresses.length == 1) return addresses.first;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Which address should the dApp use?',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
            ),
            for (final a in addresses)
              ListTile(
                title: Text(shorten(a, head: 12, tail: 10), style: monoStyle(ctx, size: 12)),
                subtitle: addressLabelService.labelFor(a) != null
                    ? Text(addressLabelService.labelFor(a)!)
                    : (a == args.senderAddress ? const Text('Main address') : null),
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndSign() async {
    final summary = _summary;
    final tx = _reducedTx;
    if (summary == null || tx == null) return;
    final request = _request;
    final recipient = summary.recipients.isNotEmpty ? summary.recipients.first.address : null;
    final choice = await showConfirmTransactionChoice(
      context,
      title: 'Sign for dApp',
      rows: summary.confirmRows(tokens: _args.tokens),
      recipientAddress: recipient,
      detail: [
        if (request?.message != null) request!.message!,
        networkController.activeUrl ?? 'Node not chosen yet',
      ].join('  ·  '),
    );
    if (!mounted || choice != ConfirmChoice.broadcast) return;
    setState(() {
      _stage = _Stage.signing;
      _status = 'Signing…';
    });
    try {
      final signed = await sessionLock.run(() => walletService.signReducedTransaction(tx));
      if (!mounted) return;
      setState(() => _status = 'Broadcasting…');
      final txId = await walletService.submitSignedTransaction(
        signed,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      _txId = txId;
      final replyTo = request?.replyTo;
      if (replyTo != null) {
        setState(() => _status = 'Telling the dApp…');
        try {
          await ergoPayClient.reply(replyTo, txId);
        } on ErgoPayException catch (e) {
          _replyError = e.message;
        }
      }
      if (!mounted) return;
      setState(() => _stage = _Stage.done);
    } on ArgusException catch (e) {
      _signFailed(e.message);
    } catch (e) {
      _signFailed(_describe(e));
    }
  }

  void _signFailed(String message) {
    if (!mounted) return;
    setState(() => _stage = _Stage.ready);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ErgoPay')),
      body: switch (_stage) {
        _Stage.loading || _Stage.signing => _busy(),
        _Stage.message => _messageOnly(),
        _Stage.ready => _ready(),
        _Stage.done => _done(),
        _Stage.error => _errorView(),
      },
    );
  }

  Widget _busy() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 16),
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );

  Widget _messageCard() {
    final r = _request;
    final msg = r?.message;
    if (msg == null) return const SizedBox.shrink();
    final color = switch (r!.severity) {
      ErgoPaySeverity.error => rust,
      ErgoPaySeverity.warning => accentOf(context),
      _ => moss,
    };
    final icon = switch (r.severity) {
      ErgoPaySeverity.error => Icons.error_outline,
      ErgoPaySeverity.warning => Icons.warning_amber_outlined,
      _ => Icons.info_outline,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }

  Widget _messageOnly() => ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          _messageCard(),
          const SizedBox(height: 12),
          Text(
            'The dApp did not send a transaction to sign.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      );

  Widget _ready() {
    final s = _summary!;
    final muted = ArgusColors.of(context).muted;
    final warning = s.warning;
    final rows = s.confirmRows(tokens: _args.tokens);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        const OfflineBanner(),
        _messageCard(),
        if (_request?.message != null) const SizedBox(height: 16),
        const SectionLabel('This transaction'),
        const SizedBox(height: 10),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(r.label, style: TextStyle(color: muted)),
                      Flexible(
                        child: Text(
                          r.value,
                          textAlign: TextAlign.end,
                          style: TextStyle(fontWeight: r.bold ? FontWeight.w600 : FontWeight.normal),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (s.recipients.isNotEmpty) ...[
          const SizedBox(height: 20),
          const SectionLabel('To'),
          const SizedBox(height: 10),
          SoftCard(
            padding: EdgeInsets.zero,
            child: DividedColumn(
              indent: 16,
              children: [
                for (final o in s.recipients)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(o.address, style: monoStyle(context, size: 11.5)),
                        const SizedBox(height: 4),
                        Text(
                          [
                            formatErg(o.valueNano),
                            for (final t in o.tokens) '${t.amount} × ${shorten(t.id, head: 6, tail: 4)}',
                          ].join('  ·  '),
                          style: TextStyle(fontSize: 12.5, color: muted),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (warning != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: rust.withValues(alpha: 0.1),
              border: Border.all(color: rust.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.gpp_bad_outlined, color: rust, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(warning, style: TextStyle(fontSize: 13, color: rustFor(context))),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 28),
        FilledButton(onPressed: _confirmAndSign, child: const Text('Review & sign')),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Decline')),
      ],
    );
  }

  Widget _done() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, size: 64, color: Color(0xFF5B9E6D)),
              const SizedBox(height: 20),
              Text('Signed and sent', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const SizedBox(width: 48, child: Hairline(gold: true)),
              const SizedBox(height: 16),
              SelectableText(_txId ?? '', style: monoStyle(context, size: 12)),
              if (_replyError != null) ...[
                const SizedBox(height: 12),
                Text(
                  'The transaction is on the network, but the dApp could not be notified: $_replyError',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: rustFor(context)),
                ),
              ],
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _txId == null
                    ? null
                    : () => launchUrl(
                          Uri.parse(networkController.explorerTx(_txId!)),
                          mode: LaunchMode.externalApplication,
                        ),
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: const Text('View on explorer'),
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: () => Navigator.pop(context, _txId), child: const Text('Done')),
            ],
          ),
        ),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.link_off, size: 48, color: rust),
              const SizedBox(height: 16),
              Text(_error ?? 'Something went wrong', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            ],
          ),
        ),
      );
}
