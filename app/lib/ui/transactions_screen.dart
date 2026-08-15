import 'package:flutter/material.dart';

import '../format.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _txs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final args = WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);
    final addresses = args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
    if (addresses.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final all = await walletService.loadHistory(addresses, limit: 50);
      if (!mounted) return;
      setState(() {
        _txs = all;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _txs.isEmpty
              ? Center(
                  child: Text(
                    'No transactions found',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    itemCount: _txs.length,
                    separatorBuilder: (_, _) => const Hairline(),
                    itemBuilder: (context, i) {
                      final tx = _txs[i];
                      final txId = tx['tx_id']?.toString() ?? '';
                      final nano = (tx['value_nano_erg'] as num?)?.toInt();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    formatErg(nano),
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(shorten(txId, head: 12, tail: 10), style: monoStyle(context, size: 11)),
                                ],
                              ),
                            ),
                            Text(
                              '#${tx['height'] ?? '?'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
