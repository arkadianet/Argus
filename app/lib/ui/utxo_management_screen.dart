import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../services/network_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';

enum UtxoFilter { all, ergOnly, withTokens, dust }

const _dustThresholdNano = 100000000;

class UtxoManagementScreen extends StatefulWidget {
  const UtxoManagementScreen({super.key});

  @override
  State<UtxoManagementScreen> createState() => _UtxoManagementScreenState();
}

class _UtxoManagementScreenState extends State<UtxoManagementScreen> {
  bool _loading = true;
  String? _error;
  List<InputBoxInput> _boxes = [];
  final Set<String> _selectedBoxIds = {};
  UtxoFilter _activeFilter = UtxoFilter.all;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
    _loadBoxes();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBoxes() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final addresses = await _getWalletAddresses();
      if (addresses.isEmpty) {
        setState(() {
          _boxes = [];
          _loading = false;
        });
        return;
      }
      final boxes = await walletService.listUnspentBoxes(
        addresses,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      setState(() {
        _boxes = boxes;
        _loading = false;
        _selectedBoxIds.retainAll(boxes.map((b) => b.boxId));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load UTXOs: $e';
        _loading = false;
      });
    }
  }

  Future<List<String>> _getWalletAddresses() async {
    final list = <String>[];
    try {
      final primary = await walletService.deriveAddress(0);
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

  List<InputBoxInput> get _filteredBoxes {
    return _boxes.where((box) {
      switch (_activeFilter) {
        case UtxoFilter.all:
          break;
        case UtxoFilter.ergOnly:
          if (box.assets.isNotEmpty) return false;
          break;
        case UtxoFilter.withTokens:
          if (box.assets.isEmpty) return false;
          break;
        case UtxoFilter.dust:
          if (box.valueNanoErg >= BigInt.from(_dustThresholdNano)) return false;
          break;
      }
      if (_searchQuery.isNotEmpty) {
        final matchId = box.boxId.toLowerCase().contains(_searchQuery);
        final matchToken = box.assets.any(
          (a) => a.tokenId.toLowerCase().contains(_searchQuery),
        );
        if (!matchId && !matchToken) return false;
      }
      return true;
    }).toList();
  }

  void _toggleSelect(String boxId) {
    setState(() {
      if (_selectedBoxIds.contains(boxId)) {
        _selectedBoxIds.remove(boxId);
      } else {
        _selectedBoxIds.add(boxId);
      }
    });
  }

  void _selectAllFiltered() {
    setState(() {
      for (final b in _filteredBoxes) {
        _selectedBoxIds.add(b.boxId);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedBoxIds.clear());
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: isError ? rust : null),
    );
  }

  Future<void> _openConsolidateFlow() async {
    final targets = _selectedBoxIds.isNotEmpty
        ? _boxes.where((b) => _selectedBoxIds.contains(b.boxId)).toList()
        : _boxes;

    if (targets.length < 2) {
      _snack('Consolidation requires at least 2 boxes', isError: true);
      return;
    }

    final addrs = await _getWalletAddresses();
    if (!mounted || addrs.isEmpty) return;
    final changeAddress = addrs.first;

    setState(() => _busy = true);
    try {
      final preview = await walletService.prepareConsolidate(
        spendAddresses: addrs,
        selectedBoxIds: _selectedBoxIds.isNotEmpty
            ? _selectedBoxIds.toList()
            : null,
        changeAddress: changeAddress,
        nodeUrl: networkController.activeUrl,
      );

      if (!mounted) return;
      setState(() => _busy = false);

      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        isScrollControlled: true,
        builder: (ctx) => _ConsolidatePreviewSheet(
          preview: preview,
          targetCount: targets.length,
          changeAddress: changeAddress,
        ),
      );

      if (confirmed == true) {
        setState(() => _busy = true);
        try {
          final txId = await walletService.sendErg(
            preparationId: preview.preparationId,
          );
          _snack(
            'Consolidation broadcast! Tx: ${shorten(txId, head: 8, tail: 6)}',
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
        _snack('Consolidation failed: $e', isError: true);
      }
    }
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

      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (ctx) =>
            _SplitPreviewSheet(preview: preview, isToken: isToken),
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
        _snack('Split failed: $e', isError: true);
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

      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (ctx) => _RestructurePreviewSheet(preview: preview),
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
        _snack('Restructure failed: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalErgNano = _boxes.fold(BigInt.zero, (s, b) => s + b.valueNanoErg);
    final totalTokensCount = _boxes.fold(0, (s, b) => s + b.assets.length);

    String healthLabel;
    Color healthColor;
    if (_boxes.length <= 20) {
      healthLabel = 'Optimal';
      healthColor = const Color(0xFF5B9E6D);
    } else if (_boxes.length <= 80) {
      healthLabel = 'Moderate';
      healthColor = iris;
    } else {
      healthLabel = 'Fragmented';
      healthColor = rust;
    }

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
                      style: const TextStyle(color: rust),
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
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                      ),
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
                          const SizedBox(height: 16),
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
                        ],
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
                          suffixIcon: _searchQuery.isNotEmpty
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
                        'Dust (${_boxes.where((b) => b.valueNanoErg < BigInt.from(_dustThresholdNano)).length})',
                      ),
                          const SizedBox(width: 12),
                          if (_selectedBoxIds.isNotEmpty) ...[
                            TextButton(
                              onPressed: _clearSelection,
                              child: Text('Clear (${_selectedBoxIds.length})'),
                            ),
                          ] else ...[
                            TextButton(
                              onPressed: _selectAllFiltered,
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
                                  onToggle: () => _toggleSelect(box.boxId),
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
    final active = _activeFilter == filter;
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(fontSize: 12, color: active ? ink : null),
      ),
      selected: active,
      selectedColor: iris,
      onSelected: (_) => setState(() => _activeFilter = filter),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    );
  }
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
          color: isSelected ? iris : Theme.of(context).colorScheme.outline,
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
                    activeColor: iris,
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
                        color: iris.withValues(alpha: 0.12),
                        border: Border.all(color: iris.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        '${a.amount} ${shorten(a.tokenId, head: 4, tail: 4)}',
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

class _ConsolidatePreviewSheet extends StatelessWidget {
  const _ConsolidatePreviewSheet({
    required this.preview,
    required this.targetCount,
    required this.changeAddress,
  });

  final ConsolidatePreview preview;
  final int targetCount;
  final String changeAddress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Consolidate UTXOs',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Hairline(),
          const SizedBox(height: 16),
          _row('Inputs Merged', '$targetCount boxes'),
          _row('Total Value In', formatErg(preview.totalErgIn)),
          _row('Tokens Included', '${preview.tokenCount} token types'),
          _row('Miner Fee', formatErg(preview.minerFee)),
          const Hairline(),
          const SizedBox(height: 8),
          _row(
            'Consolidated Output',
            formatErg(preview.changeNanoErg),
            bold: true,
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Confirm'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
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

class _SplitConfigSheetState extends State<_SplitConfigSheet> {
  bool _isToken = false;
  int _count = 2;
  final TextEditingController _amountCtrl = TextEditingController();
  String? _selectedTokenId;

  List<String> get _availableTokenIds {
    final ids = widget.boxes
        .expand((box) => box.assets.map((asset) => asset.tokenId))
        .toSet()
        .toList();
    ids.sort();
    return ids;
  }

  @override
  void initState() {
    super.initState();
    _amountCtrl.text = '1.0';
    final tokenIds = _availableTokenIds;
    _selectedTokenId = tokenIds.isEmpty ? null : tokenIds.first;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  void _setTokenMode(bool isToken) {
    if (_isToken == isToken) return;
    setState(() {
      _isToken = isToken;
      _amountCtrl.clear();
      if (isToken && !_availableTokenIds.contains(_selectedTokenId)) {
        final tokenIds = _availableTokenIds;
        _selectedTokenId = tokenIds.isEmpty ? null : tokenIds.first;
      }
    });
  }

  void _showValidation(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
          Text('Split UTXO', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          Row(
            children: [
              ChoiceChip(
                label: const Text('Split ERG'),
                selected: !_isToken,
                onSelected: (_) => _setTokenMode(false),
                selectedColor: iris,
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Split Token'),
                selected: _isToken,
                onSelected: (_) => _setTokenMode(true),
                selectedColor: iris,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_isToken) ...[
            DropdownButtonFormField<String>(
              initialValue: _selectedTokenId,
              decoration: const InputDecoration(
                labelText: 'Token',
                isDense: true,
              ),
              items: _availableTokenIds
                  .map(
                    (id) => DropdownMenuItem(
                      value: id,
                      child: Text(shorten(id, head: 8, tail: 6)),
                    ),
                  )
                  .toList(),
              onChanged: (id) => setState(() => _selectedTokenId = id),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _isToken
                  ? 'Amount per box (raw integer)'
                  : 'ERG amount per box',
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Number of Outputs: $_count',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          Slider(
            value: _count.toDouble(),
            min: 2,
            max: 20,
            divisions: 18,
            label: '$_count',
            onChanged: (v) => setState(() => _count = v.toInt()),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (!_isToken) {
                final nano = parseErgToNano(_amountCtrl.text);
                if (nano == null || nano <= 0) {
                  _showValidation('Enter a valid ERG amount');
                  return;
                }
                Navigator.pop(context, {
                  'is_token': false,
                  'count': _count,
                  'amount_nano_erg': nano,
                  'selected_box_ids': widget.selectedBoxIds.toList(),
                });
              } else {
                final tokenId = _selectedTokenId;
                final amt = BigInt.tryParse(_amountCtrl.text);
                if (tokenId == null || !_availableTokenIds.contains(tokenId)) {
                  _showValidation('Select a token to split');
                  return;
                }
                if (amt == null || amt <= BigInt.zero) {
                  _showValidation('Enter a valid whole token amount');
                  return;
                }
                Navigator.pop(context, {
                  'is_token': true,
                  'count': _count,
                  'token_id': tokenId,
                  'amount_per_box': amt,
                  'erg_per_box_nano': minBoxNano,
                  'selected_box_ids': widget.selectedBoxIds.toList(),
                });
              }
            },
            child: const Text('Preview Split'),
          ),
        ],
      ),
    );
  }
}

class _SplitPreviewSheet extends StatelessWidget {
  const _SplitPreviewSheet({required this.preview, required this.isToken});

  final SplitPreview preview;
  final bool isToken;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Confirm Split', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Hairline(),
          const SizedBox(height: 12),
          _row('Outputs Created', '${preview.splitCount} boxes'),
          _row(
            'Amount per Box',
            isToken
                ? '${preview.amountPerBox} tokens'
                : formatErg(preview.amountPerBox.toInt()),
          ),
          _row('Change Returned', formatErg(preview.changeNanoErg)),
          _row('Miner Fee', formatErg(preview.minerFee)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Execute Split'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
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

class _RestructurePreviewSheet extends StatelessWidget {
  const _RestructurePreviewSheet({required this.preview});

  final RestructurePreview preview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Confirm Restructure',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Hairline(),
          const SizedBox(height: 12),
          _row('Inputs Consumed', '${preview.inputCount} boxes'),
          _row('Outputs Generated', '${preview.outputCount} boxes'),
          _row('Total Value In', formatErg(preview.totalErgIn)),
          _row('Allocated to Outputs', formatErg(preview.allocatedErg)),
          _row('Change Output', formatErg(preview.changeNanoErg)),
          _row('Miner Fee', formatErg(preview.minerFee)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Execute Restructure'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
