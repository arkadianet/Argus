import 'dart:convert';
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
    _load();
  }

  Future<void> _load() async {
    final address = ModalRoute.of(context)?.settings.arguments as String?;
    if (address == null) return;
    try {
      final json = await walletService.getTransactionHistory(address, limit: 50);
      final decoded = jsonDecode(json) as List;
      setState(() {
        _txs = decoded.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
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
                      final value = tx['value_nano_erg']?.toString() ?? '?';
                      final height = tx['height']?.toString() ?? '?';
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.swap_horiz),
                          title: Text('$value nanoERG',
                            style: const TextStyle(fontFamily: 'monospace')),
                          subtitle: Text(txId.length > 20 ? '${txId.substring(0, 20)}...' : txId,
                            style: const TextStyle(fontSize: 11)),
                          trailing: Text('#$height'),
                          isThreeLine: false,
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}