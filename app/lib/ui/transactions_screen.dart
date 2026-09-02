import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../format.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'transaction_detail_screen.dart';
import 'widgets/activity_tile.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, this.embedded = false, this.args});

  /// Hosted inside the home tabs: no scaffold or app bar of its own, and
  /// wallet context comes from [args] rather than the route.
  final bool embedded;
  final WalletRouteArgs? args;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  List<Map<String, dynamic>> _txs = [];
  static const _pageSize = 50;
  Map<String, int> _perAddressOffsets = {};
  bool _hasMore = true;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  WalletRouteArgs get _args => widget.args ?? WalletRouteArgs.of(context);

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
    _perAddressOffsets.clear();
    _hasMore = false;
    _loadingMore = false;
    _loadGeneration++;
    final gen = _loadGeneration;
    try {
      final all = await walletService.loadHistory(addresses,
          limit: _pageSize, perAddressOffsets: _perAddressOffsets);
      if (!mounted || gen != _loadGeneration) return;
      _hasMore = all.length >= _pageSize;
      setState(() {
        _txs = all;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _hasMore = true;
        _error = 'Could not load activity';
      });
    }
  }

  Future<void> _loadMore() async {
    if (!mounted) return;
    if (_loadingMore || !_hasMore) return;
    final args = _args;
    final addresses = args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
    if (addresses.isEmpty) return;
    setState(() => _loadingMore = true);
    final gen = _loadGeneration;
    try {
      final more = await walletService.loadHistory(addresses,
          limit: _pageSize, perAddressOffsets: _perAddressOffsets);
      if (!mounted || gen != _loadGeneration) return;
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
      if (mounted && gen == _loadGeneration) {
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

  String _toCsv(List<Map<String, dynamic>> txs) {
    final buffer = StringBuffer();
    buffer.writeln('Tx ID,Value (ERG),Height,Time,Type');
    for (final tx in txs) {
      final txId = tx['tx_id']?.toString() ?? '';
      final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
      final erg = formatErg(nano, unit: false);
      final height = (tx['height'] as num?)?.toInt();
      final ts = (tx['timestamp'] as num?)?.toInt();
      final time = formatTxTime(ts).isNotEmpty ? formatTxTime(ts) : 'Unknown';
      final outgoing = nano < 0;
      final type = outgoing ? 'Outgoing' : 'Incoming';
      buffer.writeln('$txId,$erg,$height,$time,$type');
    }
    return buffer.toString();
  }

  Future<void> _exportCsv() async {
    if (_txs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No transactions to export')),
      );
      return;
    }
    final csv = _toCsv(_txs);
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(
          Uint8List.fromList(utf8.encode(csv)),
          mimeType: 'text/csv',
          name: 'argus_transactions.csv',
        )],
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (widget.embedded) {
      return Column(
        children: [
          if (_txs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
              child: Row(
                children: [
                  Text(
                    '${_txs.length}${_hasMore ? '+' : ''} transactions',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _exportCsv,
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: const Text('Export CSV'),
                  ),
                ],
              ),
            ),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          if (_txs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.file_download),
              tooltip: 'Export CSV',
              onPressed: _exportCsv,
            ),
        ],
      ),
      body: body,
    );
  }

  Widget _body(BuildContext context) {
    return _loading && _txs.isEmpty
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
                      final day = dayKey((tx['timestamp'] as num?)?.toInt());
                      final showDay = i == 0 ||
                          dayKey((_txs[i - 1]['timestamp'] as num?)?.toInt()) != day;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showDay)
                            Padding(
                              padding: const EdgeInsets.only(top: 14, bottom: 6),
                              child: Text(day, style: Theme.of(context).textTheme.bodySmall),
                            )
                          else
                            const Divider(height: 1, indent: 68),
                          ActivityTile(
                            tx: tx,
                            showTxId: true,
                            onTap: () => _open(tx),
                          ),
                        ],
                      );
                    },
                  ),
                );
  }
}
