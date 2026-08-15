import 'package:flutter/material.dart';

import '../format.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'transaction_detail_screen.dart';

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

  WalletRouteArgs get _args => WalletRouteArgs.from(ModalRoute.of(context)?.settings.arguments);

  Future<void> _load() async {
    final args = _args;
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

  void _open(Map<String, dynamic> tx) {
    Navigator.push(
      context,
      fadeRoute(
        const TransactionDetailScreen(),
        settings: RouteSettings(
          arguments: WalletRouteArgs(
            senderAddress: _args.senderAddress,
            receiveAddress: _args.receiveAddress,
            changeAddress: _args.changeAddress,
            historyAddresses: _args.historyAddresses,
            transaction: tx,
          ),
        ),
      ),
    );
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
                    'No activity yet. Receive to this wallet first.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    itemCount: _txs.length,
                    itemBuilder: (context, i) {
                      final tx = _txs[i];
                      final txId = tx['tx_id']?.toString() ?? '';
                      final nano = (tx['value_nano_erg'] as num?)?.toInt();
                      final height = (tx['height'] as num?)?.toInt();
                      final day = dayKey((tx['timestamp'] as num?)?.toInt());
                      final showDay = i == 0 ||
                          dayKey((_txs[i - 1]['timestamp'] as num?)?.toInt()) != day;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showDay)
                            Padding(
                              padding: const EdgeInsets.only(top: 12, bottom: 6),
                              child: Text(day, style: Theme.of(context).textTheme.bodySmall),
                            ),
                          if (i > 0 && !showDay) const Hairline(),
                          InkWell(
                            onTap: () => _open(tx),
                            child: Padding(
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
                                        Text(
                                          shorten(txId, head: 12, tail: 10),
                                          style: monoStyle(context, size: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    formatHeight(height),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
    );
  }
}
