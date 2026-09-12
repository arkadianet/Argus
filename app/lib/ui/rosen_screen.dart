import 'widgets/tx_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../services/network_controller.dart';
import '../services/rosen_service.dart';
import '../services/wallet_service.dart';
import '../services/app_fee.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/error_sheet.dart';
import 'widgets/soft_card.dart';

int rosenMaxAmount({required int held, required bool isErg,
    required int availableErg, required bool hasTokens}) {
  final reserve = txOverheadNano() + (hasTokens ? minBoxNano : 0);
  if (isErg) return (held - reserve).clamp(0, held);
  return availableErg >= reserve + 2000000 ? held : 0;
}

/// Rosen bridge: send ERG or a bridged token to another chain. One
/// transaction locks the asset for the bridge; the bridge pays out on
/// the other side once it has seen enough confirmations.
class RosenScreen extends StatefulWidget {
  const RosenScreen({super.key});

  @override
  State<RosenScreen> createState() => _RosenScreenState();
}

class _RosenScreenState extends State<RosenScreen> with TxReceiptOwner {
  RosenToken? _token;
  RosenTarget? _target;
  final _address = TextEditingController();
  final _amount = TextEditingController();
  RosenQuote? _quote;
  String? _quoteError;
  String? _addressProblem;
  bool _working = false;
  String? _sentTxId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => rosenService.refreshFees());
  }

  @override
  void dispose() {
    _address.dispose();
    _amount.dispose();
    super.dispose();
  }

  int? get _units {
    final t = _token;
    if (t == null) return null;
    return parseDecimalToBase(_amount.text, t.decimals);
  }

  void _requote() {
    final t = _token;
    final target = _target;
    final units = _units;
    setState(() {
      _quote = null;
      _quoteError = null;
      if (t == null || target == null || units == null || units <= 0) return;
      try {
        _quote = rosenService.quote(tokenId: t.ergoTokenId, toChain: target.chain, amount: units);
      } catch (e) {
        _quoteError = e.toString().replaceFirst('Bad state: ', '');
      }
    });
  }

  void _checkAddress() {
    final target = _target;
    setState(() {
      _addressProblem = target == null || _address.text.trim().isEmpty ? null : rosenService.addressProblem(target.chain, _address.text);
      if (_addressProblem != null && _addressProblem!.isEmpty) _addressProblem = null;
    });
  }

  Future<void> _send() async {
    final t = _token;
    final target = _target;
    final q = _quote;
    final units = _units;
    if (_working || t == null || target == null || q == null || units == null) return;
    if (_addressProblem != null || _address.text.trim().isEmpty) {
      showErrorSheet(context, message: 'Enter a valid destination address');
      return;
    }
    if (q.receiving <= 0) {
      showErrorSheet(context, message: 'Send at least ${formatTokenAmountGrouped(q.minTransfer, t.decimals)} ${t.name}');
      return;
    }
    final args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await walletService.rosenPrepareLock(
        senderAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
        changeAddress: args.changeAddress,
        tokenId: t.ergoTokenId,
        amount: units,
        toChain: target.chain,
        toAddress: _address.text.trim(),
        bridgeFee: q.bridgeFee,
        networkFee: q.networkFee,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      String amt(int n) => '${formatTokenAmountGrouped(n, t.decimals)} ${t.name}';
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Bridge to ${rosenChainName(target.chain)}',
        confirmLabel: 'Lock & send',
        detail: 'The asset goes into the bridge\'s lock box with the destination and fees written on it. '
            'Once the bridge has seen enough confirmations it pays ${target.name} to your ${rosenChainName(target.chain)} address. '
            'A transfer the bridge cannot complete is returned to ${shorten(args.receiveAddress, head: 8, tail: 6)}.',
        rows: [
          ConfirmTxRow('Send', amt(q.amount), bold: true),
          ConfirmTxRow('To', '${rosenChainName(target.chain)} · ${shorten(_address.text.trim(), head: 10, tail: 8)}'),
          ConfirmTxRow('Bridge fee', amt(q.bridgeFee)),
          ConfirmTxRow('${rosenChainName(target.chain)} network fee', amt(q.networkFee)),
          ConfirmTxRow('You receive', '${formatTokenAmountGrouped(q.receiving, target.decimals)} ${target.name}', bold: true),
          if (!t.isErg) ConfirmTxRow('Lock box ERG', formatErg((prepared['lock_value'] as num).toInt())),
          ConfirmTxRow('Argus fee', formatErg((prepared['app_fee_nano'] as num?)?.toInt() ?? 0)),
          ConfirmTxRow('Miner fee', formatErg((prepared['miner_fee'] as num).toInt())),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      final txId = await walletService.sendErg(preparationId: (prepared['preparation_id'] as num).toInt());
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
        showTxResultSheet(
          receiptContext,
          txId: txId,
          headline: 'Bridge lock submitted',
        );
        return;
      }
      setState(() => _sentTxId = txId);
    } catch (e) {
      if (mounted) showTxFailureSheet(context, e);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ArgusColors.of(context).muted;
    final args = WalletRouteArgs.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rosen bridge'),
        actions: [
          IconButton(
            tooltip: 'Refresh fees',
            onPressed: rosenService.busy ? null : rosenService.refreshFees,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: rosenService,
        builder: (context, _) {
          final sent = _sentTxId;
          if (sent != null) return _sentPanel(sent);
          final holdings = rosenService.holdings(args.spendableNano ?? 0, {for (final t in args.tokens) t.id: t.amount});
          final t = _token;
          final target = _target;
          final q = _quote;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Text(
                'Move ERG or a bridged token to another chain. One transaction locks the asset for the bridge; '
                'its watchers and guards then pay out on the other side. Fees are set by the bridge and read '
                'from chain.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              Text(
                rosenService.feesReadAt == null
                    ? (rosenService.busy ? 'Reading bridge fees…' : 'Fees not read yet')
                    : 'Fees read ${formatSyncAge(rosenService.feesReadAt)} · contracts ${rosenService.contractsVersion}',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              if (rosenService.lastError != null) ...[
                const SizedBox(height: 6),
                SelectableText('Could not read the bridge fees: ${rosenService.lastError}',
                    style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const Key('rosen-asset'),
                initialValue: t?.ergoTokenId,
                decoration: const InputDecoration(labelText: 'Asset'),
                items: [
                  for (final (tok, held) in holdings)
                    DropdownMenuItem(
                      value: tok.ergoTokenId,
                      child: Text('${tok.name} · ${formatTokenAmountGrouped(held, tok.decimals)} held', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  setState(() {
                    _token = holdings.map((h) => h.$1).where((x) => x.ergoTokenId == v).firstOrNull;
                    _target = _token?.targets.firstOrNull;
                    _amount.clear();
                    _quote = null;
                  });
                  _checkAddress();
                },
              ),
              if (t != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('rosen-chain'),
                  initialValue: target?.chain,
                  decoration: const InputDecoration(labelText: 'To chain'),
                  items: [
                    for (final x in t.targets)
                      DropdownMenuItem(value: x.chain, child: Text('${rosenChainName(x.chain)} · arrives as ${x.name}')),
                  ],
                  onChanged: (v) {
                    setState(() => _target = t.targets.where((x) => x.chain == v).firstOrNull);
                    _checkAddress();
                    _requote();
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('rosen-address'),
                  controller: _address,
                  decoration: InputDecoration(
                    labelText: target == null ? 'Destination address' : '${rosenChainName(target.chain)} address',
                    errorText: _addressProblem,
                    helperText: 'Checked for shape and checksum; the bridge cannot recover a payout to a wrong address.',
                    helperMaxLines: 2,
                  ),
                  style: monoStyle(context, size: 12),
                  autocorrect: false,
                  onChanged: (_) => _checkAddress(),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('rosen-amount'),
                  controller: _amount,
                  decoration: InputDecoration(
                    labelText: '${t.name} to send',
                    helperText: q == null ? null : 'At least ${formatTokenAmountGrouped(q.minTransfer, t.decimals)} ${t.name} delivers anything',
                    suffixIcon: TextButton(
                      onPressed: () {
                        final held = holdings.where((h) => h.$1.ergoTokenId == t.ergoTokenId).firstOrNull?.$2 ?? 0;
                        final max = rosenMaxAmount(held: held, isErg: t.isErg,
                            availableErg: args.spendableNano ?? 0, hasTokens: args.tokens.isNotEmpty);
                        if (max <= 0) {
                          showErrorSheet(context, message: 'There is not enough ERG to pay the transfer fees and keep your remaining tokens.');
                          return;
                        }
                        _amount.text = formatTokenAmount(max, t.decimals);
                        _requote();
                      },
                      child: const Text('MAX'),
                    ),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => _requote(),
                ),
                const SizedBox(height: 12),
                if (_quoteError != null) SelectableText(_quoteError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                if (q != null && target != null)
                  SoftCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _row('Bridge fee', '${formatTokenAmountGrouped(q.bridgeFee, t.decimals)} ${t.name}',
                            note: q.feeRatioBps > 0 ? 'the larger of the minimum and ${(q.feeRatioBps / 100).toStringAsFixed(2)}%' : null),
                        _row('${rosenChainName(target.chain)} network fee', '${formatTokenAmountGrouped(q.networkFee, t.decimals)} ${t.name}'),
                        _row('You receive', '${formatTokenAmountGrouped(q.receiving, target.decimals)} ${target.name}', bold: true),
                        const SizedBox(height: 6),
                        Text(
                          'Plus ${t.isErg ? '' : '0.002 ERG for the lock box, '}the Argus fee and the miner fee on Ergo. '
                          'The bridge pays out after its confirmation count on Ergo, usually within the hour.',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('rosen-continue'),
                  onPressed: _working || q == null || q.receiving <= 0 || _addressProblem != null || _address.text.trim().isEmpty ? null : _send,
                  child: Text(_working ? 'Preparing…' : 'Continue'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, String? note}) {
    final muted = ArgusColors.of(context).muted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
              Text(value, style: monoStyle(context, size: 12.5).copyWith(fontWeight: bold ? FontWeight.w600 : null)),
            ],
          ),
          if (note != null) Text(note, style: TextStyle(color: muted, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _sentPanel(String txId) {
    final muted = ArgusColors.of(context).muted;
    final url = RosenService.trackingUrl(txId);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.check_circle_outline, size: 48, color: accentOf(context)),
          const SizedBox(height: 12),
          if (walletService.broadcastWarning(txId) case final warning?)
            SelectableText(warning, style: TextStyle(color: rustFor(context))),
          Text('Transfer started', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'The lock transaction is on its way. The bridge pays out on the other chain once it has enough '
            'confirmations; follow it on Rosen with the transaction id.',
            style: TextStyle(color: muted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SoftCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(child: SelectableText(txId, style: monoStyle(context, size: 11))),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: txId));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transaction id copied')));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Follow on Rosen'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Uri.parse(networkController.explorerTx(txId)),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('View Ergo lock transaction'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() {
              _sentTxId = null;
              _amount.clear();
              _quote = null;
            }),
            child: const Text('Another transfer'),
          ),
        ],
      ),
    );
  }
}
