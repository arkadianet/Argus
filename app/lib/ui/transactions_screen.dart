import 'package:flutter/material.dart';

import '../services/wallet_service.dart';

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

  String _erg(dynamic nano) {
    final n = (nano as num?)?.toInt();
    if (n == null) return '?';
    return '${(n / 1e9).toStringAsFixed(4)} ERG';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transaction History')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _txs.isEmpty
              ? const Center(child: Text('No transactions found'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _txs.length,
                    itemBuilder: (context, i) {
                      final tx = _txs[i];
                      final txId = tx['tx_id']?.toString() ?? '';
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.swap_horiz),
                          title: Text(_erg(tx['value_nano_erg']),
                              style: const TextStyle(fontFamily: 'monospace')),
                          subtitle: Text(
                            txId.length > 20 ? '${txId.substring(0, 20)}...' : txId,
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: Text('#${tx['height'] ?? '?'}'),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
