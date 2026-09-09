import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../format.dart';
import '../services/mix_activity.dart';
import '../services/stealth_service.dart';
import '../services/mix_service.dart';
import '../services/wallet_sync_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'transaction_detail_screen.dart';
import 'widgets/activity_tile.dart';
import 'widgets/empty_state.dart';

typedef ActivityPage = ({List<Map<String, dynamic>> rows, bool partial});
typedef HistoryLoader = Future<ActivityPage> Function(List<String> addresses,
    {required int limit, required Map<String, int> perAddressOffsets});

Future<ActivityPage> _readHistory(List<String> addresses,
    {required int limit, required Map<String, int> perAddressOffsets}) async {
  final rows = await walletService.loadHistory(addresses, limit: limit, perAddressOffsets: perAddressOffsets);
  return (rows: rows, partial: walletService.lastHistoryPartial);
}

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, this.embedded = false, this.args, this.loadHistory = _readHistory});

  final HistoryLoader loadHistory;

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
  bool _retryMore = false;
  List<Map<String, dynamic>> _txs = [];
  static const _pageSize = 50;
  Map<String, int> _perAddressOffsets = {};
  bool _hasMore = true;
  int _loadGeneration = 0;

  /// The ids and heights the home sync last showed, stealth rows
  /// included, so the list reloads when a transaction arrives or a
  /// Pending row confirms, and not on every notification.
  String _syncSignature = '';

  /// A change that arrived while a load was running; replayed after it.
  bool _reloadWanted = false;
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    _syncSignature = _currentSignature();
    walletSyncController.addListener(_onSyncChanged);
    mixService.addListener(_onSyncChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    walletSyncController.removeListener(_onSyncChanged);
    mixService.removeListener(_onSyncChanged);
    super.dispose();
  }

  String _currentSignature() => activitySignature(walletSyncController.displayActivity);

  List<Map<String, dynamic>> _withLocal(List<Map<String, dynamic>> rows) {
    final ids = {for (final row in rows) row['tx_id']};
    final merged = mergeStealthActivity(mergeMixActivity([
      ...rows,
      for (final row in walletSyncController.recentTxs)
        if (!ids.contains(row['tx_id'])) row,
    ], mixService.mixActivityRows()), walletSyncController.stealthRows);
    merged.sort(compareActivityRows);
    return merged;
  }

  void _onSyncChanged() {
    final next = _currentSignature();
    if (next == _syncSignature) return;
    _syncSignature = next;
    if (_loading || _loadingMore || _reloading) {
      _reloadWanted = true;
      return;
    }
    _reload();
  }

  /// One reload at a time; a change that lands meanwhile runs one more.
  Future<void> _reload() async {
    _reloading = true;
    try {
      do {
        _reloadWanted = false;
        await _load();
      } while (_reloadWanted && mounted);
    } finally {
      _reloading = false;
    }
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
    setState(() { _error = null; _retryMore = false; });
    _perAddressOffsets.clear();
    _hasMore = false;
    _loadingMore = false;
    _loadGeneration++;
    final gen = _loadGeneration;
    try {
      final page = await widget.loadHistory(addresses,
          limit: _pageSize, perAddressOffsets: _perAddressOffsets);
      if (!mounted || gen != _loadGeneration) return;
      final all = page.rows;
      _hasMore = page.partial || all.length >= _pageSize;
      setState(() {
        _txs = _withLocal(all);
        _loading = false;
        _loadingMore = false;
        _error = page.partial ? 'Some addresses could not be checked. Activity is incomplete.' : null;
      });
      _prefetchNames(all);
    } catch (e) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _hasMore = true;
        _txs = _withLocal(_txs);
        _error = 'Could not load activity: $e';
      });
    }
  }

  /// Learns token names for the rows on screen, then repaints.
  Future<void> _prefetchNames(List<Map<String, dynamic>> txs) async {
    final ids = <String>{
      for (final tx in txs)
        for (final key in const ['tokens_received', 'tokens_sent'])
          for (final t in (tx[key] as List? ?? const []))
            if (t is Map) t['token_id']?.toString() ?? '',
    }..remove('');
    if (ids.isEmpty) return;
    try {
      await walletService.prefetchTokenMeta(ids);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _loadMore() async {
    if (!mounted) return;
    if (_loadingMore || !_hasMore) return;
    final args = _args;
    final addresses = args.historyAddresses.isNotEmpty
        ? args.historyAddresses
        : [if (args.senderAddress.isNotEmpty) args.senderAddress];
    if (addresses.isEmpty) return;
    setState(() { _loadingMore = true; _error = null; });
    final gen = _loadGeneration;
    try {
      final page = await widget.loadHistory(addresses,
          limit: _pageSize, perAddressOffsets: _perAddressOffsets);
      if (!mounted || gen != _loadGeneration) return;
      final more = page.rows;
      _hasMore = page.partial || more.length >= _pageSize;
      final seen = _txs.map((t) => t['tx_id']?.toString() ?? '').toSet();
      final deduped = more.where((t) {
        final id = t['tx_id']?.toString() ?? '';
        return id.isNotEmpty && !seen.contains(id);
      }).toList();
      setState(() {
        _txs = _withLocal([..._txs, ...deduped]);
        _loadingMore = false;
        _retryMore = false;
        _error = page.partial ? 'Some addresses could not be checked. Activity is incomplete.' : null;
      });
      _prefetchNames(deduped);
    } catch (e) {
      if (mounted && gen == _loadGeneration) {
        setState(() {
          _loadingMore = false;
          _hasMore = true;
          _retryMore = true;
          _error = 'Could not load older activity: $e';
        });
      }
    }
    // A change that arrived during the page load runs now.
    if (_reloadWanted && !_reloading && mounted) _reload();
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

  Widget _body(BuildContext context) => Column(children: [
    if (_error != null) Padding(
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        SelectableText(_error!),
        TextButton(onPressed: _retryMore ? _loadMore : _reload, child: const Text('Retry')),
      ]),
    ),
    Expanded(child: _listBody(context)),
  ]);

  Widget _listBody(BuildContext context) {
    return _loading && _txs.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _txs.isEmpty
              ? const SizedBox.shrink()
          : _txs.isEmpty
              ? EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'No activity yet',
                  body: 'Transactions to and from this wallet will show up here, newest first.',
                  actionLabel: 'Refresh',
                  onAction: _load,
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    itemCount: _txs.length + (_loadingMore || (_hasMore && _error == null) ? 1 : 0),
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

/// Ids and heights of the rows, in order: what changes when a transaction
/// arrives, confirms, or drops from the mempool.
String activitySignature(List<Map<String, dynamic>> txs) => [
      for (final tx in txs) '${tx['tx_id']}@${tx['height'] ?? 0}',
    ].join(',');
