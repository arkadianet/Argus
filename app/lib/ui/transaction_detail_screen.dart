import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../format.dart';
import '../services/network_controller.dart';
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
    final tokens = (tx['token_ids'] as List?)?.map((e) => e.toString()).toList() ?? const [];
    final confirmed = height != null && height > 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(formatErg(nano), style: Theme.of(context).textTheme.headlineSmall),
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
          if (tokens.isNotEmpty) ...[
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
                : () => Clipboard.setData(ClipboardData(text: txId)),
            child: const Text('Copy id'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: txId.isEmpty
                ? null
                : () => launchUrl(
                      Uri.parse(networkController.explorerTx(txId)),
                      mode: LaunchMode.externalApplication,
                    ),
            child: const Text('Open in explorer'),
          ),
        ],
      ),
    );
  }
}
