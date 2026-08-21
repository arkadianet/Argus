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
  bool _loadingMore = false;
  String? _error;
  List<Map<String, dynamic>> _txs = [];
  static const _pageSize = 50;
  int _offset = 0;
  bool _hasMore = true;
  int _loadGeneration = 0;

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
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    try {
      _offset = 0;
      _hasMore = true;
      _loadGeneration++;
      final gen = _loadGeneration;
      final all = await walletService.loadHistory(addresses, limit: _pageSize, offset: 0);
      if (!mounted || gen != _loadGeneration) return;
      _hasMore = all.length >= _pageSize;
      setState(() {
        _txs = all;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load activity';
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final args = _args;
    final addresses = args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
    if (addresses.isEmpty) return;
    setState(() => _loadingMore = true);
    final gen = _loadGeneration;
    try {
      final nextOffset = _offset + _pageSize;
      final more = await walletService.loadHistory(addresses, limit: _pageSize, offset: nextOffset);
      if (!mounted || gen != _loadGeneration) return;
      _offset = nextOffset;
      _hasMore = more.length >= _pageSize;
      final seen = _txs.map((t) => t['tx_id']?.toString() ?? '').toSet();
      final deduped = more.where((t) {
        final id = t['tx_id']?.toString() ?? '';
        return id.isNotEmpty && !seen.contains(id);
      }).toList();
      setState(() {
        _txs = [..._txs, ...deduped];
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingMore = false;
          _hasMore = false;
        });
      }
    }
  }

  void _open(Map<String, dynamic> tx) {
    Navigator.push(
      context,
      fadeRoute(
        const TransactionDetailScreen(),
        settings: RouteSettings(arguments: _args.copyWith(transaction: tx)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: _loading && _txs.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _txs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _error!,
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
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
                    itemCount: _txs.length + (_loadingMore || _hasMore ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _txs.length) {
                        if (!_loadingMore) {
                          WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                        }
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        );
                      }
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
