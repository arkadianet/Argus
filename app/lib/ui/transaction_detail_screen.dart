import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../services/network_controller.dart';
import '../services/session_lock.dart';
import '../services/token_metadata.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'widgets/soft_card.dart';

class TransactionDetailScreen extends StatelessWidget {
  const TransactionDetailScreen({super.key});

  /// Tokens are named and scaled by the one token lookup, like the row this
  /// screen was opened from, and repaint when it learns something.
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: walletService.metadataChanges,
    builder: (context, _, _) => _screen(context),
  );

  Widget _tokenLine(BuildContext context, ({String id, BigInt amount}) t) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          tokenAmountText(t.amount, t.id),
          style: monoStyle(context, size: 12),
        ),
      );

  Widget _screen(BuildContext context) {
    final args = WalletRouteArgs.of(context);
    final tx = args.transaction ?? const {};
    final txId = tx['tx_id']?.toString() ?? '';
    final height = (tx['height'] as num?)?.toInt();
    final ts = (tx['timestamp'] as num?)?.toInt();
    final nano = (tx['value_nano_erg'] as num?)?.toInt();
    final rawTokens = tx['token_ids'];
    final tokens = rawTokens is List ? rawTokens.map((e) => e.toString()).toList() : const <String>[];
    final received = (tx['tokens_received'] as List?)
            ?.whereType<Map>()
            .map((m) => (
                  id: m['token_id']?.toString() ?? '',
                  amount: BigInt.from((m['amount'] as num?)?.toInt() ?? 0),
                ))
            .toList() ??
        const <({String id, BigInt amount})>[];
    final confirmed = height != null && height > 0;
    final outgoing = nano != null && nano < 0;
    // A mix round moves nothing in or out; it is a step, not a receipt.
    final neutral = tx['mix'] == true && (nano ?? 0) == 0;
    final fee = (tx['fee_nano_erg'] as num?)?.toInt();
    final counterparty = tx['counterparty']?.toString();
    final sent = (tx['tokens_sent'] as List?)
            ?.whereType<Map>()
            .map((m) => (
                  id: m['token_id']?.toString() ?? '',
                  amount: BigInt.from((m['amount'] as num?)?.toInt() ?? 0),
                ))
            .toList() ??
        const <({String id, BigInt amount})>[];
    // Compare identities, not lengths: token_ids may repeat and arrivals
    // cover a subset of the unique ids.
    final missingTokenIds =
        tokens.toSet().difference(received.map((r) => r.id).toSet());

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (neutral ? accentOf(context) : outgoing ? rust : moss).withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  neutral
                      ? Icons.blender_outlined
                      : outgoing
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                  size: 20,
                  color: neutral ? accentOf(context) : outgoing ? rust : moss,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  neutral
                      ? (tx['mix_label']?.toString() ?? 'Mix round')
                      : '${outgoing ? 'Sent' : 'Received'} ${formatErg(nano?.abs())}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ],
          ),
          if (!neutral && networkController.fiatText(nano?.abs()) != null) ...[
            const SizedBox(height: 4),
            Text(
              networkController.fiatText(nano?.abs())!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            confirmed
                ? 'Confirmed ${formatHeight(height)}'
                : tx['confirmed'] == true
                    ? 'Confirmed'
                    : 'Not yet in a block',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (formatTxTime(ts).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(formatTxTime(ts), style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 24),
          if (tx['mix'] == true) ...[
            const SectionLabel('Mix'),
            const SizedBox(height: 8),
            Text(
              '${tx['mix_label'] ?? 'Mix transaction'}. Rounds move between mixing '
              'contracts, not your addresses, so this is known from the mix record, '
              'not from the address history.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
          ],
          if (counterparty != null && counterparty.isNotEmpty) ...[
            SectionLabel(outgoing ? 'To' : 'From'),
            const SizedBox(height: 8),
            SoftCard(
              padding: const EdgeInsets.all(12),
              child: SelectableText(counterparty, style: monoStyle(context, size: 12)),
            ),
            const SizedBox(height: 16),
          ],
          if (fee != null && fee > 0) ...[
            const SectionLabel('Miner fee'),
            const SizedBox(height: 8),
            Text(formatErg(fee), style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
          ],
          if (sent.isNotEmpty) ...[
            const SectionLabel('Tokens sent'),
            const SizedBox(height: 8),
            for (final t in sent) _tokenLine(context, t),
            const SizedBox(height: 10),
          ],
          const SectionLabel('Id'),
          const SizedBox(height: 8),
          SelectableText(txId, style: monoStyle(context, size: 12)),
          const SizedBox(height: 16),
            if (received.isNotEmpty) ...[
            const SectionLabel('Tokens received'),
            const SizedBox(height: 8),
            for (final t in received) _tokenLine(context, t),
            // Compare identities, not lengths: token_ids may repeat and
            // arrivals cover a subset of the unique ids.
            if (missingTokenIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text(
                  '${missingTokenIds.length} further token id(s) involved — see explorer.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
          ] else if (tokens.isNotEmpty) ...[
            const SectionLabel('Tokens'),
            const SizedBox(height: 8),
            ...tokens.map((id) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    tokenName(id) == null
                        ? shorten(id, head: 12, tail: 10)
                        : '${tokenName(id)} · ${shorten(id, head: 8, tail: 6)}',
                    style: monoStyle(context, size: 12),
                  ),
                )),
            const SizedBox(height: 8),
          ],
          FilledButton(
            onPressed: txId.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: txId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Transaction id copied')),
                    );
                  },
            child: const Text('Copy id'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: txId.isEmpty
                ? null
                : () async {
                    try {
                      final ok = await sessionLock.run(
                        () => launchUrl(
                          Uri.parse(networkController.explorerTx(txId)),
                          mode: LaunchMode.externalApplication,
                        ),
                      );
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Could not open explorer')),
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Could not open explorer')),
                        );
                      }
                    }
                  },
            child: const Text('Open in explorer'),
          ),
        ],
      ),
    );
  }
}
