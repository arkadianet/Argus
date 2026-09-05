import 'widgets/error_sheet.dart';
import '../services/app_fee.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../services/network_controller.dart';
import '../services/utxo_plans.dart';
import '../services/utxo_tools_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/soft_card.dart';

class UtxoManagementScreen extends StatefulWidget {
  const UtxoManagementScreen({super.key});

  @override
  State<UtxoManagementScreen> createState() => _UtxoManagementScreenState();
}

class _UtxoManagementScreenState extends State<UtxoManagementScreen> {
  bool _loading = true;
  String? _error;
  final _tools = UtxoToolsController();
  final TextEditingController _searchCtrl = TextEditingController();
  bool _busy = false;

  List<InputBoxInput> get _boxes => _tools.boxes;

  @override
  void initState() {
    super.initState();
    _tools.addListener(_onToolsChanged);
    _searchCtrl.addListener(() => _tools.setSearch(_searchCtrl.text));
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBoxes());
  }

  void _onToolsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tools.removeListener(_onToolsChanged);
    _tools.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBoxes() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final addresses = await _getWalletAddresses();
      if (!mounted) return;
      if (addresses.isEmpty) {
        _tools.setBoxes(const []);
        setState(() => _loading = false);
        return;
      }
      final boxes = await walletService.listUnspentBoxes(
        addresses,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      _tools.setBoxes(boxes);
      setState(() => _loading = false);
      final ids = {for (final b in boxes) for (final a in b.assets) a.tokenId};
      if (ids.isNotEmpty) {
        walletService.prefetchTokenMeta(ids).then((_) {
          if (mounted) setState(() {});
        }).catchError((_) {});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load UTXOs: $e';
        _loading = false;
      });
    }
  }

  /// The wallet's addresses from the live route context; falls back to a
  /// discovery only when the context is empty (deep-linked open).
  Future<List<String>> _getWalletAddresses() async {
    final args = WalletRouteArgs.of(context);
    if (args.historyAddresses.isNotEmpty) {
      final list = <String>[
        if (args.receiveAddress.isNotEmpty) args.receiveAddress,
      ];
      for (final a in args.historyAddresses) {
        if (!list.contains(a)) list.add(a);
      }
      return list;
    }
    return _discoverAddresses();
  }

  Future<List<String>> _discoverAddresses() async {
    final list = <String>[];
    try {
      final pinnedIndex = await walletService.getPinnedAddressIndex();
      final primary = pinnedIndex > 0
          ? await walletService.tryDeriveAddress(pinnedIndex) ??
              await walletService.deriveAddress(0)
          : await walletService.deriveAddress(0);
      list.add(primary);
      final raw = await walletService.discoverAddresses();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final used = (map['addresses'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e['address']?.toString())
          .whereType<String>()
          .where((a) => a.isNotEmpty);
      for (final a in used) {
        if (!list.contains(a)) list.add(a);
      }
    } catch (_) {
      try {
        final a0 = await walletService.deriveAddress(0);
        if (!list.contains(a0)) list.add(a0);
      } catch (_) {}
    }
    return list;
  }

  List<InputBoxInput> get _filteredBoxes => _tools.filtered;
  Set<String> get _selectedBoxIds => _tools.selectedIds;

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: isError ? rust : null),
    );
  }

  /// Consolidates the selection (or everything) into one box per batch of
  /// [consolidationMaxInputs] inputs. Several batches mean several
  /// transactions, each signed and sent in turn.
  Future<void> _openConsolidateFlow() async {
    final targets = _tools.consolidateTargets;
    final chunks = consolidationChunks(targets.map((b) => b.boxId).toList());
    if (chunks.isEmpty) {
      _snack('Consolidation needs at least 2 boxes', isError: true);
      return;
    }
    final addrs = await _getWalletAddresses();
    if (!mounted || addrs.isEmpty) return;
    final changeAddress = addrs.first;
    final totalIn = targets.fold(BigInt.zero, (s, b) => s + b.valueNanoErg);
    final tokenTypes = {for (final b in targets) for (final a in b.assets) a.tokenId}.length;
    final fees = (minerFeeNano + argusFeeNano) * chunks.length;

    final confirmed = await showConfirmTransactionSheet(
      context,
      title: chunks.length == 1 ? 'Consolidate UTXOs' : 'Consolidate in ${chunks.length} transactions',
      rows: [
        ConfirmTxRow('Boxes merged', '${targets.length}'),
        ConfirmTxRow('Into', '${chunks.length} ${chunks.length == 1 ? 'box' : 'boxes'}'),
        ConfirmTxRow('Total value in', formatNanoErg(totalIn)),
        if (tokenTypes > 0) ConfirmTxRow('Token types carried', '$tokenTypes'),
        ConfirmTxRow('Miner fee', formatErg(minerFeeNano * chunks.length)),
        ConfirmTxRow('Argus fee', formatErg(argusFeeNano * chunks.length)),
        ConfirmTxRow('Value after fees', formatNanoErg(totalIn - BigInt.from(fees)), bold: true),
      ],
      detail: chunks.length == 1
          ? 'Every selected box is spent into one new box holding all its ERG and tokens.'
          : 'Ergo transactions are kept under $consolidationMaxInputs inputs each, so this runs as ${chunks.length} transactions back to back. You can consolidate the results again afterwards.',
      confirmLabel: chunks.length == 1 ? 'Sign & broadcast' : 'Sign & broadcast ${chunks.length}',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    var done = 0;
    try {
      for (final chunk in chunks) {
        final preview = await walletService.prepareConsolidate(
          spendAddresses: addrs,
          selectedBoxIds: chunk,
          changeAddress: changeAddress,
          nodeUrl: networkController.activeUrl,
        );
        final txId = await walletService.sendErg(preparationId: preview.preparationId);
        done++;
        if (!mounted) return;
        _snack(chunks.length == 1
            ? 'Consolidation broadcast · ${shorten(txId, head: 8, tail: 6)}'
            : 'Transaction $done of ${chunks.length} broadcast · ${shorten(txId, head: 8, tail: 6)}');
      }
      _tools.clearSelection();
      await Future.delayed(const Duration(seconds: 1));
      await _loadBoxes();
    } catch (e) {
      if (mounted) {
        showErrorSheet(
          context,
          title: done == 0 ? 'Consolidation failed' : 'Stopped after $done of ${chunks.length}',
          message: '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Selects every dust box and opens consolidation.
  Future<void> _sweepDust() async {
    final dust = _boxes.where((b) => b.valueNanoErg < BigInt.from(dustThresholdNano)).toList();
    if (dust.length < 2) {
      _snack('Fewer than two dust boxes to sweep');
      return;
    }
    _tools.clearSelection();
    for (final b in dust) {
      _tools.toggle(b.boxId);
    }
    await _openConsolidateFlow();
  }

  Future<void> _openSplitFlow() async {
    final addrs = await _getWalletAddresses();
    if (!mounted || addrs.isEmpty) return;
    final changeAddress = addrs.first;

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _SplitConfigSheet(
        boxes: _boxes,
        selectedBoxIds: _selectedBoxIds,
        changeAddress: changeAddress,
      ),
    );

    if (result == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final isToken = result['is_token'] == true;
      final selectedBoxes = (result['selected_box_ids'] as List).cast<String>();
      final count = result['count'] as int;

      final SplitPreview preview;
      if (!isToken) {
        final nanoPerBox = result['amount_nano_erg'] as int;
        preview = await walletService.prepareSplitErg(
          spendAddresses: addrs,
          selectedBoxIds: selectedBoxes.isNotEmpty ? selectedBoxes : null,
          count: count,
          amountPerBoxNano: nanoPerBox,
          changeAddress: changeAddress,
          nodeUrl: networkController.activeUrl,
        );
      } else {
        final tokenId = result['token_id'] as String;
        final amountPerBox = result['amount_per_box'] as BigInt;
        final ergPerBoxNano = result['erg_per_box_nano'] as int;
        preview = await walletService.prepareSplitToken(
          spendAddresses: addrs,
          selectedBoxIds: selectedBoxes.isNotEmpty ? selectedBoxes : null,
          tokenId: tokenId,
          count: count,
          amountPerBox: amountPerBox,
          ergPerBoxNano: ergPerBoxNano,
          changeAddress: changeAddress,
          nodeUrl: networkController.activeUrl,
        );
      }

      if (!mounted) return;
      setState(() => _busy = false);

      final confirmed = await showConfirmTransactionSheet(
        context,
        preparationId: preview.preparationId,
        title: 'Split UTXO',
        rows: [
          ConfirmTxRow('Outputs Created', '${preview.splitCount} boxes'),
          ConfirmTxRow(
            'Amount per Box',
            isToken
                ? '${preview.amountPerBox} tokens'
                : formatErg(preview.amountPerBox.toInt()),
          ),
          ConfirmTxRow('Change Returned', formatErg(preview.changeNanoErg)),
          ConfirmTxRow('Miner Fee', formatErg(preview.minerFee)),
          argusFeeRow(),
        ],
        detail: 'Fee is computed by the transaction builder.',
        confirmLabel: 'Sign & broadcast split',
      );

      if (confirmed == true) {
        setState(() => _busy = true);
        try {
          final txId = await walletService.sendErg(
            preparationId: preview.preparationId,
          );
          _snack(
            'Split transaction broadcast! Tx: ${shorten(txId, head: 8, tail: 6)}',
          );
        await Future.delayed(const Duration(seconds: 1));
        await _loadBoxes();
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSheet(context, title: 'Split failed', message: '$e');
      }
    }
  }

  Future<void> _openRestructureFlow() async {
    final addrs = await _getWalletAddresses();
    if (!mounted || addrs.isEmpty) return;
    final changeAddress = addrs.first;

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (ctx) => _RestructureConfigSheet(
        boxes: _boxes,
        selectedBoxIds: _selectedBoxIds,
        changeAddress: changeAddress,
      ),
    );

    if (result == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final selectedBoxes = (result['selected_box_ids'] as List).cast<String>();
      final outputs = (result['outputs'] as List).cast<Map<String, dynamic>>();

      final preview = await walletService.prepareRestructure(
        spendAddresses: addrs,
        selectedBoxIds: selectedBoxes.isNotEmpty ? selectedBoxes : null,
        outputs: outputs,
        changeAddress: changeAddress,
        nodeUrl: networkController.activeUrl,
      );

      if (!mounted) return;
      setState(() => _busy = false);

      final confirmed = await showConfirmTransactionSheet(
        context,
        preparationId: preview.preparationId,
        title: 'Restructure UTXOs',
        rows: [
          ConfirmTxRow('Inputs Consumed', '${preview.inputCount} boxes'),
          ConfirmTxRow('Outputs Generated', '${preview.outputCount} boxes'),
          ConfirmTxRow('Total Value In', formatErg(preview.totalErgIn)),
          ConfirmTxRow('Allocated to Outputs', formatErg(preview.allocatedErg)),
          ConfirmTxRow('Change Output', formatErg(preview.changeNanoErg)),
          ConfirmTxRow('Miner Fee', formatErg(preview.minerFee)),
          argusFeeRow(),
        ],
        detail: 'Fee is computed by the transaction builder.',
        confirmLabel: 'Sign & broadcast restructure',
      );

      if (confirmed == true) {
        setState(() => _busy = true);
        try {
          final txId = await walletService.sendErg(
            preparationId: preview.preparationId,
          );
          _snack(
            'Restructure transaction broadcast! Tx: ${shorten(txId, head: 8, tail: 6)}',
          );
        await Future.delayed(const Duration(seconds: 1));
        await _loadBoxes();
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSheet(context, title: 'Restructure failed', message: '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalErgNano = _boxes.fold(BigInt.zero, (s, b) => s + b.valueNanoErg);
    final totalTokensCount = _boxes.fold(0, (s, b) => s + b.assets.length);

    final health = utxoHealth(_boxes.length);
    final healthLabel = health.label;
    final healthColor = health.color;
    final dustCount = _boxes.where((b) => b.valueNanoErg < BigInt.from(dustThresholdNano)).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('UTXO Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh boxes',
            onPressed: _busy ? null : _loadBoxes,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: rustFor(context)),
                    ),
                        const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _loadBoxes,
                      child: const Text('Retry'),
                    ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    // Overview Summary Card
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SoftCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_boxes.length} UTXOs',
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${formatNanoErg(totalErgNano)} · $totalTokensCount tokens',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              const Spacer(),
                              Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                                decoration: BoxDecoration(
                                  color: healthColor.withValues(alpha: 0.15),
                                  border: Border.all(color: healthColor),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  healthLabel,
                                  style: TextStyle(
                                    color: healthColor,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${health.hint}${dustCount > 0 ? ' $dustCount dust ${dustCount == 1 ? 'box' : 'boxes'} under ${formatErg(dustThresholdNano)}.' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 14),
                          const Hairline(),
                          const SizedBox(height: 12),
                          // Quick Actions Row
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.merge_type, size: 16),
                                  label: const Text('Consolidate'),
                              onPressed: _busy || _boxes.length < 2
                                  ? null
                                  : _openConsolidateFlow,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.call_split, size: 16),
                                  label: const Text('Split'),
                              onPressed: _busy || _boxes.isEmpty
                                  ? null
                                  : _openSplitFlow,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.tune, size: 16),
                                  label: const Text('Restructure'),
                              onPressed: _busy || _boxes.isEmpty
                                  ? null
                                  : _openRestructureFlow,
                                ),
                              ),
                            ],
                          ),
                          if (dustCount >= 2) ...[
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                              label: Text('Sweep $dustCount dust boxes into one'),
                              onPressed: _busy ? null : _sweepDust,
                            ),
                          ],
                        ],
                      ),
                    ),
                    ),

                    // Filter & Search
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: InputDecoration(
                          hintText: 'Search box ID or token...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          isDense: true,
                          suffixIcon: _tools.search.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () => _searchCtrl.clear(),
                                )
                              : null,
                        ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Filter Chips & Selection Controls
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          _filterChip(UtxoFilter.all, 'All (${_boxes.length})'),
                          const SizedBox(width: 6),
                      _filterChip(
                        UtxoFilter.ergOnly,
                        'ERG Only (${_boxes.where((b) => b.assets.isEmpty).length})',
                      ),
                          const SizedBox(width: 6),
                      _filterChip(
                        UtxoFilter.withTokens,
                        'Tokens (${_boxes.where((b) => b.assets.isNotEmpty).length})',
                      ),
                          const SizedBox(width: 6),
                      _filterChip(
                        UtxoFilter.dust,
                        'Dust (${_boxes.where((b) => b.valueNanoErg < BigInt.from(dustThresholdNano)).length})',
                      ),
                          const SizedBox(width: 12),
                          if (_selectedBoxIds.isNotEmpty) ...[
                            TextButton(
                              onPressed: _tools.clearSelection,
                              child: Text('Clear (${_selectedBoxIds.length})'),
                            ),
                          ] else ...[
                            TextButton(
                              onPressed: _tools.selectAllFiltered,
                              child: const Text('Select All'),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 6),

                    // Boxes List
                    Expanded(
                      child: _filteredBoxes.isEmpty
                          ? const Center(child: Text('No UTXOs match criteria'))
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                              itemCount: _filteredBoxes.length,
                              itemBuilder: (ctx, i) {
                                final box = _filteredBoxes[i];
                            final isSelected = _selectedBoxIds.contains(
                              box.boxId,
                            );
                                return _UtxoCard(
                                  box: box,
                                  isSelected: isSelected,
                                  onToggle: () => _tools.toggle(box.boxId),
                                );
                              },
                            ),
                    ),
                  ],
                ),
      bottomSheet: _selectedBoxIds.isNotEmpty
          ? Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(color: Theme.of(context).colorScheme.outline),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    '${_selectedBoxIds.length} Selected',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (_selectedBoxIds.length >= 2)
                    FilledButton(
                      onPressed: _busy ? null : _openConsolidateFlow,
                      child: const Text('Consolidate'),
                    ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _openSplitFlow,
                    child: const Text('Split'),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  Widget _filterChip(UtxoFilter filter, String label) {
    final active = _tools.filter == filter;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(fontSize: 12, color: active ? ink : null),
      ),
      selected: active,
      selectedColor: accentOf(context),
      onSelected: (_) => _tools.setFilter(filter),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    );
  }
}

String _tokenAmount(InputAsset a) {
  final meta = walletService.cachedTokenMeta(a.tokenId);
  if (meta == null || a.amount > BigInt.from(0x7FFFFFFFFFFFFFFF)) return a.amount.toString();
  return formatTokenAmount(a.amount.toInt(), meta.decimals);
}

class _UtxoCard extends StatelessWidget {
  const _UtxoCard({
    required this.box,
    required this.isSelected,
    required this.onToggle,
  });

  final InputBoxInput box;
  final bool isSelected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isSelected ? accentOf(context) : Theme.of(context).colorScheme.outline,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => onToggle(),
                    activeColor: accentOf(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatNanoErg(box.valueNanoErg),
                          style: const TextStyle(
                            fontFamily: 'Newsreader',
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              shorten(box.boxId, head: 8, tail: 6),
                              style: monoStyle(context, size: 11),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 13),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              tooltip: 'Copy Box ID',
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: box.boxId),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Box ID copied'),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (box.creationHeight > 0)
                    Text(
                      'H: ${box.creationHeight}',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                ],
              ),
              if (box.assets.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: box.assets.map((a) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: accentOf(context).withValues(alpha: 0.12),
                        border: Border.all(color: accentOf(context).withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        '${_tokenAmount(a)} ${walletService.cachedTokenMeta(a.tokenId)?.label ?? shorten(a.tokenId, head: 4, tail: 4)}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'IBMPlexMono',
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SplitConfigSheet extends StatefulWidget {
  const _SplitConfigSheet({
    required this.boxes,
    required this.selectedBoxIds,
    required this.changeAddress,
  });

  final List<InputBoxInput> boxes;
  final Set<String> selectedBoxIds;
  final String changeAddress;

  @override
  State<_SplitConfigSheet> createState() => _SplitConfigSheetState();
}

enum _SplitMode { equal, fixed, token }

class _SplitConfigSheetState extends State<_SplitConfigSheet> {
  static const _presets = [2, 5, 10, 25, 50, 100];
  static const _maxOutputs = 100;

  _SplitMode _mode = _SplitMode.equal;
  int _count = 5;
  final _countCtrl = TextEditingController(text: '5');
  final _amountCtrl = TextEditingController();
  String? _selectedTokenId;

  List<InputBoxInput> get _source => widget.selectedBoxIds.isNotEmpty
      ? widget.boxes.where((b) => widget.selectedBoxIds.contains(b.boxId)).toList()
      : widget.boxes;

  BigInt get _totalNano => _source.fold(BigInt.zero, (s, b) => s + b.valueNanoErg);

  List<String> get _availableTokenIds {
    final ids = _source.expand((box) => box.assets.map((a) => a.tokenId)).toSet().toList();
    ids.sort();
    return ids;
  }

  BigInt _tokenTotal(String id) => _source.fold(
      BigInt.zero, (s, b) => s + b.assets.where((a) => a.tokenId == id).fold(BigInt.zero, (t, a) => t + a.amount));

  @override
  void initState() {
    super.initState();
    final tokenIds = _availableTokenIds;
    _selectedTokenId = tokenIds.isEmpty ? null : tokenIds.first;
  }

  @override
  void dispose() {
    _countCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  void _setCount(int n) {
    final clamped = n.clamp(2, _maxOutputs);
    setState(() {
      _count = clamped;
      if (_countCtrl.text != '$clamped') _countCtrl.text = '$clamped';
    });
  }

  int? get _equalPerBox => equalSplitAmount(
        totalNano: _totalNano.toInt(),
        count: _count,
        feesNano: minerFeeNano + argusFeeNano,
      );

  String _tokenLabel(String id) => walletService.cachedTokenMeta(id)?.label ?? shorten(id, head: 8, tail: 6);
  int _tokenDecimals(String id) => walletService.cachedTokenMeta(id)?.decimals ?? 0;

  String? get _summary {
    switch (_mode) {
      case _SplitMode.equal:
        final per = _equalPerBox;
        if (per == null) return null;
        final change = _totalNano.toInt() - minerFeeNano - argusFeeNano - per * _count;
        return '$_count boxes of ${formatErg(per, maxFrac: 4)}'
            '${change > 0 ? ' · ${formatErg(change, maxFrac: 4)} change' : ''}';
      case _SplitMode.fixed:
        final per = parseErgToNano(_amountCtrl.text);
        if (per == null || per < minBoxNano) return null;
        final change = _totalNano.toInt() - minerFeeNano - argusFeeNano - per * _count;
        if (change < 0) return null;
        return '$_count boxes of ${formatErg(per, maxFrac: 4)} · ${formatErg(change, maxFrac: 4)} change';
      case _SplitMode.token:
        final id = _selectedTokenId;
        if (id == null) return null;
        final per = parseDecimalToBase(_amountCtrl.text, _tokenDecimals(id));
        if (per == null || per <= 0) return null;
        final total = _tokenTotal(id);
        final need = BigInt.from(per) * BigInt.from(_count);
        if (need > total) return null;
        return '$_count boxes of ${formatTokenAmount(per, _tokenDecimals(id))} ${_tokenLabel(id)}, '
            'each with ${formatErg(minBoxNano)}';
    }
  }

  void _submit() {
    final summary = _summary;
    if (summary == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch (_mode) {
          _SplitMode.equal => 'Not enough ERG for $_count boxes after fees',
          _SplitMode.fixed => 'Enter an amount of at least 0.001 ERG that fits the selection',
          _SplitMode.token => 'Enter a token amount that fits the selection',
        }),
      ));
      return;
    }
    switch (_mode) {
      case _SplitMode.equal:
        Navigator.pop(context, {
          'is_token': false,
          'count': _count,
          'amount_nano_erg': _equalPerBox,
          'selected_box_ids': widget.selectedBoxIds.toList(),
        });
      case _SplitMode.fixed:
        Navigator.pop(context, {
          'is_token': false,
          'count': _count,
          'amount_nano_erg': parseErgToNano(_amountCtrl.text),
          'selected_box_ids': widget.selectedBoxIds.toList(),
        });
      case _SplitMode.token:
        final id = _selectedTokenId!;
        Navigator.pop(context, {
          'is_token': true,
          'count': _count,
          'token_id': id,
          'amount_per_box': BigInt.from(parseDecimalToBase(_amountCtrl.text, _tokenDecimals(id))!),
          'erg_per_box_nano': minBoxNano,
          'selected_box_ids': widget.selectedBoxIds.toList(),
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final summary = _summary;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 20, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Split', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'From ${_source.length} ${_source.length == 1 ? 'box' : 'boxes'} holding ${formatNanoErg(_totalNano)}.',
              style: TextStyle(fontSize: 12.5, color: colors.muted),
            ),
            const SizedBox(height: 14),
            SegmentedButton<_SplitMode>(
              segments: [
                const ButtonSegment(value: _SplitMode.equal, label: Text('Equal parts')),
                const ButtonSegment(value: _SplitMode.fixed, label: Text('Amount each')),
                if (_availableTokenIds.isNotEmpty) const ButtonSegment(value: _SplitMode.token, label: Text('Token')),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                _mode = s.first;
                _amountCtrl.clear();
              }),
            ),
            const SizedBox(height: 16),
            Text('HOW MANY BOXES', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: colors.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final n in _presets)
                  ChoiceChip(
                    label: Text('$n'),
                    selected: _count == n,
                    selectedColor: accentOf(context),
                    labelStyle: TextStyle(color: _count == n ? ink : null),
                    onSelected: (_) => _setCount(n),
                  ),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _countCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Custom', isDense: true, hintText: '2–100'),
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null) _setCount(n);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_mode == _SplitMode.token) ...[
              DropdownButtonFormField<String>(
                initialValue: _selectedTokenId,
                decoration: const InputDecoration(labelText: 'Token', isDense: true),
                items: [
                  for (final id in _availableTokenIds)
                    DropdownMenuItem(
                      value: id,
                      child: Text('${_tokenLabel(id)} · ${formatTokenAmount(_tokenTotal(id).toInt(), _tokenDecimals(id))} available'),
                    ),
                ],
                onChanged: (id) => setState(() => _selectedTokenId = id),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '${_selectedTokenId == null ? 'Token' : _tokenLabel(_selectedTokenId!)} per box',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ] else if (_mode == _SplitMode.fixed) ...[
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'ERG per box', isDense: true, hintText: '1.0'),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: colors.inset, borderRadius: BorderRadius.circular(12)),
              child: Text(
                summary ?? 'Adjust the count or amount until it fits the selection.',
                style: TextStyle(fontSize: 13, color: summary == null ? rustFor(context) : null),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Fees: ${formatErg(minerFeeNano)} miner + ${formatErg(argusFeeNano)} Argus. Remaining ERG and every token return to you as change.',
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: summary == null ? null : _submit, child: const Text('Preview split')),
          ],
        ),
      ),
    );
  }
}

class _RestructureConfigSheet extends StatefulWidget {
  const _RestructureConfigSheet({
    required this.boxes,
    required this.selectedBoxIds,
    required this.changeAddress,
  });

  final List<InputBoxInput> boxes;
  final Set<String> selectedBoxIds;
  final String changeAddress;

  @override
  State<_RestructureConfigSheet> createState() =>
      _RestructureConfigSheetState();
}

class _RestructureConfigSheetState extends State<_RestructureConfigSheet> {
  final List<TextEditingController> _outputAmounts = [];

  @override
  void initState() {
    super.initState();
    _outputAmounts.add(TextEditingController(text: '1.0'));
    _outputAmounts.add(TextEditingController(text: '1.0'));
  }

  @override
  void dispose() {
    for (final c in _outputAmounts) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOutput() {
    setState(() {
      _outputAmounts.add(TextEditingController(text: '1.0'));
    });
  }

  void _removeOutput(int index) {
    if (_outputAmounts.length <= 1) return;
    setState(() {
      _outputAmounts.removeAt(index).dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Custom Restructure',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Add output',
                onPressed: _addOutput,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Define desired output boxes. Remainder returns to change.',
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _outputAmounts.length,
              itemBuilder: (ctx, i) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _outputAmounts[i],
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Box #${i + 1} ERG Amount',
                            isDense: true,
                          ),
                        ),
                      ),
                      if (_outputAmounts.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _removeOutput(i),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final outputs = <Map<String, dynamic>>[];
              for (final c in _outputAmounts) {
                final nano = parseErgToNano(c.text);
                if (nano == null || nano < 1000000) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Invalid amount: min 0.001 ERG per box'),
                    ),
                  );
                  return;
                }
                outputs.add({'value_nano_erg': nano, 'tokens': []});
              }
              Navigator.pop(context, {
                'outputs': outputs,
                'selected_box_ids': widget.selectedBoxIds.toList(),
              });
            },
            child: const Text('Preview Restructure'),
          ),
        ],
      ),
    );
  }
}
