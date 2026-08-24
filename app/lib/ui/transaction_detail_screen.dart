import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../services/network_controller.dart';
import '../services/session_lock.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';

class TransactionDetailScreen extends StatelessWidget {
  const TransactionDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final args = WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);
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
                  color: (outgoing ? rust : moss).withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  outgoing ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 20,
                  color: outgoing ? rust : moss,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${outgoing ? 'Sent' : 'Received'} ${formatErg(nano?.abs())}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            confirmed ? 'Confirmed ${formatHeight(height)}' : 'Not yet in a block',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (formatTxTime(ts).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(formatTxTime(ts), style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 24),
          const SectionLabel('Id'),
          const SizedBox(height: 8),
          SelectableText(txId, style: monoStyle(context, size: 12)),
          const SizedBox(height: 16),
            if (received.isNotEmpty) ...[
            const SectionLabel('Tokens received'),
            const SizedBox(height: 8),
            for (final t in received)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: FutureBuilder<TokenBalance>(
                  future: walletService.tokenMeta(t.id, 0),
                  builder: (context, snap) {
                    final sym = snap.data?.name ?? shorten(t.id, head: 10, tail: 6);
                    final decimals = snap.data?.decimals ?? 0;
                    return Text(
                      '${formatTokenAmount(t.amount <= BigInt.from(0x7FFFFFFFFFFFFFFF) ? t.amount.toInt() : 0, decimals)} $sym'
                      '${t.amount > BigInt.from(0x7FFFFFFFFFFFFFFF) ? ' (large amount)' : ''}',
                      style: monoStyle(context, size: 12),
                    );
                  },
                ),
              ),
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
                  child: Text(shorten(id, head: 12, tail: 10), style: monoStyle(context, size: 12)),
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
