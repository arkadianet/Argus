import 'widgets/tx_batch_result_view.dart';
import 'widgets/tx_result_view.dart';
import 'widgets/error_sheet.dart';
import '../services/app_fee.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../services/mix_service.dart';
import '../services/network_controller.dart';
import '../services/storage_rent.dart';
import '../services/utxo_plans.dart';
import '../services/utxo_tools_controller.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'separate_tokens_sheet.dart';
import 'widgets/soft_card.dart';

class UtxoManagementScreen extends StatefulWidget {
  const UtxoManagementScreen({super.key, this.openCleanup = false});

  /// Opens straight into the suggested cleanup's review; what the home
  /// screen's UTXO indicator links to.
  static const cleanupRoute = '/utxos/cleanup';

  /// Review the suggested cleanup as soon as boxes and rent have loaded, or
  /// say there is nothing to clean up.
  final bool openCleanup;

  @override
  State<UtxoManagementScreen> createState() => _UtxoManagementScreenState();
}

class _UtxoManagementScreenState extends State<UtxoManagementScreen>
    with TxReceiptOwner {
  bool _loading = true;
  String? _error;
  final _tools = UtxoToolsController();
  final TextEditingController _searchCtrl = TextEditingController();
  bool _busy = false;

  /// Rent for the listed boxes, from the user's node; null until it arrives.
  RentReport? _rent;
  bool _rentLoading = false;
  bool _rentFailed = false;

  /// Bumped per box load, so a slow rent report cannot land on newer boxes.
  int _loadGeneration = 0;

  /// Boxes this screen has already spent. The node lists confirmed boxes
  /// only, so they stay listed until the transaction is mined; a cleanup
  /// must not propose them again.
  final Set<String> _movingIds = {};

  /// [UtxoManagementScreen.openCleanup] is honoured once per visit.
  bool _cleanupOffered = false;

  List<String>? _consolidationIds;
  int _consolidationPlanned = 0;
  String? _consolidationFailure;

  void _showConsolidationResult() => showTxBatchResultSheet(
    receiptContext,
    txIds: _consolidationIds!,
    plannedCount: _consolidationPlanned,
    failure: _consolidationFailure,
  );

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

  Future<void> _loadBoxes({bool propagateError = false}) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
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
      _movingIds.retainAll(boxes.map((b) => b.boxId));
      setState(() => _loading = false);
      _loadRent(addresses, generation);
      final ids = {for (final b in boxes) for (final a in b.assets) a.tokenId};
      if (ids.isNotEmpty) {
        // Cache only; see mix_screen.
        walletService.ensureWalletTable().then((_) {
          if (mounted) setState(() {});
        }).catchError((_) {});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load UTXOs: $e';
        _loading = false;
      });
      if (propagateError) rethrow;
    }
  }

  /// Rent for the listed boxes, read separately so a slow or failing node
  /// read never holds up the list. The report is a second listing of the
  /// same addresses from the same node, measured in the wallet core.
  Future<void> _loadRent(List<String> addresses, int generation) async {
    setState(() {
      _rentLoading = true;
      _rentFailed = false;
    });
    RentReport? report;
    try {
      report = await storageRent.report(
        addresses,
        nodeUrl: networkController.activeUrl,
      );
    } catch (_) {
      report = null;
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _rentLoading = false;
      _rentFailed = report == null;
      _rent = report;
    });
    _tools.setRent(report?.boxes ?? const {});
    _maybeOpenCleanup();
  }

  /// Boxes a cleanup must leave where they are: mixed coins, funding set
  /// aside for a pending mix, and boxes already spent from this screen.
  Set<String> get _heldBack {
    final ids = <String>{...mixService.mixedBoxIds, ..._movingIds};
    try {
      for (final r in jsonDecode(mixService.reservedFundingJson()) as List) {
        for (final id in (r as Map)['box_ids'] as List? ?? const []) {
          ids.add(id.toString());
        }
      }
    } catch (_) {
      // No pending mix records to honour.
    }
    return ids;
  }

  CleanupSuggestion? get _suggestion => suggestCleanup(
    boxes: _boxes,
    rent: _tools.rent,
    exclude: _heldBack,
  );

  /// Rent parameters to judge a new box by: the report's, or the launch
  /// factor at the dashboard's height when the report could not be read.
  RentParameters? get _rentParameters {
    final fromReport = _rent?.parameters;
    if (fromReport != null) return fromReport;
    final height = networkController.height;
    return height == null ? null : RentParameters.fallback(height: height);
  }

  /// The boxes a cleanup creates and their rent, laid out by the same rules
  /// the consolidation builder uses.
  OutputRentEstimate? _cleanupEstimate(CleanupSuggestion s) {
    final parameters = _rentParameters;
    if (parameters == null || s.afterFeesNano <= BigInt.zero) return null;
    return storageRent.estimateOutput(
      address: s.address,
      valueNano: s.afterFeesNano.toInt(),
      tokens: {for (final e in s.tokens.entries) e.key: e.value.toInt()},
      parameters: parameters,
    );
  }

  void _maybeOpenCleanup() {
    if (!widget.openCleanup || _cleanupOffered || !mounted) return;
    _cleanupOffered = true;
    final suggestion = _suggestion;
    if (suggestion == null) {
      _snack('Nothing to clean up right now');
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_busy) _openCleanupFlow(suggestion);
    });
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
    final submitted = <String>[];
    Object? failure;
    String? bookkeepingWarning;
    try {
      for (final chunk in chunks) {
        final preview = await walletService.prepareConsolidate(
          spendAddresses: addrs,
          selectedBoxIds: chunk,
          changeAddress: changeAddress,
          nodeUrl: networkController.activeUrl,
        );
        final txId = await walletService.sendErg(
          preparationId: preview.preparationId,
        );
        submitted.add(txId);
        _movingIds.addAll(chunk);
      }
    } catch (e) {
      failure = e;
      if (mounted && chunks.length == 1) {
        showTxFailureSheet(
          context,
          e,
          note:
              'Stopped after ${submitted.length} of ${chunks.length}. Refresh boxes and check Activity before retrying.',
        );
      }
    } finally {
      if (submitted.isNotEmpty) {
        bookkeepingWarning = await txBookkeeping(() async {
          if (!mounted) return;
          _tools.clearSelection();
          await Future.delayed(const Duration(seconds: 1));
          await _loadBoxes(propagateError: true);
        });
        if (chunks.length == 1)
          showTxResultSheet(
            receiptContext,
            txId: submitted.single,
            headline: 'Consolidation submitted',
            warning: bookkeepingWarning,
          );
      }
      final classified = failure == null ? null : classifyTxFailure(failure);
      final batchFailure = [
        if (classified != null)
          '${classified.title}\n${classified.message}\nRefresh boxes and check Activity before retrying.',
        if (bookkeepingWarning != null) bookkeepingWarning,
      ].join('\n\n');
      if (mounted) {
        setState(() {
          _busy = false;
          if (chunks.length > 1) {
            _consolidationIds = List.unmodifiable(submitted);
            _consolidationPlanned = chunks.length;
            _consolidationFailure = batchFailure.isEmpty ? null : batchFailure;
          }
        });
      }
      if (chunks.length > 1) {
        showTxBatchResultSheet(
          receiptContext,
          txIds: submitted,
          plannedCount: chunks.length,
          failure: batchFailure.isEmpty ? null : batchFailure,
        );
      }
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

  /// Reviews and runs [s]: one consolidation at one address, back into the
  /// same address. Fee, resulting boxes and the new box's rent are shown
  /// before anything is signed.
  Future<void> _openCleanupFlow(CleanupSuggestion s) async {
    final estimate = _cleanupEstimate(s);
    final parameters = _rentParameters;
    final tokenTypes = s.tokens.length;
    final resulting = estimate?.boxes.length ?? 1;
    final newRent = estimate != null && estimate.chargeable && parameters != null
        ? '${formatErg(estimate.first.feeNano, maxFrac: 5)}, due '
            '${rentWhen(estimate.dueHeight - parameters.height)}'
            '${estimate.covered ? '' : ' (more than it holds)'}'
        : null;
    final confirmed = await showConfirmTransactionSheet(
      context,
      title: 'Suggested cleanup',
      rows: [
        ConfirmTxRow(
          'Boxes merged',
          s.leftAtAddress > 0
              ? '${s.boxes.length} of ${s.boxes.length + s.leftAtAddress} at this address'
              : '${s.boxes.length}',
        ),
        ConfirmTxRow('Address', shorten(s.address, head: 8, tail: 6)),
        ConfirmTxRow(
          'Resulting boxes',
          estimate == null && tokenTypes > 0 ? '1 or more' : '$resulting',
          bold: true,
        ),
        if (s.rentResetCount > 0)
          ConfirmTxRow('Rent clocks restarted', _rentResetLabel(s)),
        if (tokenTypes > 0) ConfirmTxRow('Token types carried', '$tokenTypes'),
        ConfirmTxRow('Total value in', formatNanoErg(s.totalNano)),
        ConfirmTxRow('Miner fee', formatErg(minerFeeNano)),
        ConfirmTxRow('Argus fee', formatErg(argusFeeNano)),
        ConfirmTxRow('Value after fees', formatNanoErg(s.afterFeesNano), bold: true),
        if (newRent != null) ConfirmTxRow('New box rent', newRent),
      ],
      detail:
          'Every listed box is spent into ${resulting == 1 ? 'one new box' : '$resulting new boxes'} '
          'at this address, holding all their ERG and tokens. A moved box '
          'starts a new 4-year storage-rent clock. Only boxes from this one '
          'address are merged, so no addresses are linked.',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      final preview = await walletService.prepareConsolidate(
        spendAddresses: [s.address],
        selectedBoxIds: s.boxIds,
        changeAddress: s.address,
        nodeUrl: networkController.activeUrl,
      );
      final txId = await walletService.sendErg(
        preparationId: preview.preparationId,
      );
      _movingIds.addAll(s.boxIds);
      final warning = await txBookkeeping(() async {
        if (!mounted) return;
        _tools.clearSelection();
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) await _loadBoxes(propagateError: true);
      });
      showTxResultSheet(
        receiptContext,
        txId: txId,
        warning: warning,
        headline: 'Cleanup submitted',
      );
    } catch (e) {
      if (mounted) showTxFailureSheet(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _rentResetLabel(CleanupSuggestion s) => [
    if (s.atRiskCount > 0) '${s.atRiskCount} at risk',
    if (s.dueSoonCount > 0) '${s.dueSoonCount} due within $rentSoonDays days',
  ].join(' · ');

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

          final warning = await txBookkeeping(() async {
            await Future.delayed(const Duration(seconds: 1));
            if (mounted) await _loadBoxes();
          });
          showTxResultSheet(
            receiptContext,
            txId: txId,
            warning: warning,
            headline: 'Split submitted',
          );
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showTxFailureSheet(context, e);
      }
    }
  }

  Future<void> _openSeparateTokensFlow({String? sourceBoxId}) async {
    final plan = await showModalBottomSheet<SeparateTokensPlan>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (_) => SeparateTokensSheet(
        boxes: _boxes,
        initialSourceId:
            sourceBoxId ??
            (_selectedBoxIds.length == 1 ? _selectedBoxIds.single : null),
      ),
    );
    if (plan == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final preview = await walletService.prepareRestructure(
        spendAddresses: [plan.source.address!],
        selectedBoxIds: plan.inputBoxIds,
        outputs: plan.outputs,
        changeAddress: plan.source.address!,
        nodeUrl: networkController.activeUrl,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final confirmed = await showConfirmTransactionChoice(
        context,
        preparationId: preview.preparationId,
        title: 'Separate ${plan.assets.length} token types',
        recipientAddress: plan.source.address,
        rows: [
          ConfirmTxRow(
            'Source box',
            shorten(plan.source.boxId, head: 8, tail: 6),
          ),
          ConfirmTxRow('Inputs spent', '${preview.inputCount} boxes'),
          ConfirmTxRow('Token boxes', '${plan.assets.length}'),
          for (final asset in plan.assets)
            ConfirmTxRow(
              walletService.cachedTokenMeta(asset.tokenId)?.label ??
                  shorten(asset.tokenId, head: 8, tail: 6),
              '${_tokenAmount(asset)} (${asset.amount} raw units)',
            ),
          ConfirmTxRow('ERG in token boxes', formatErg(preview.allocatedErg)),
          ConfirmTxRow('ERG change', formatErg(preview.changeNanoErg)),
          ConfirmTxRow('Miner fee', formatErg(preview.minerFee)),
          argusFeeRow(),
        ],
        detail:
            'Each token type keeps its full balance in a separate box at your source address. All remaining ERG is returned to your wallet.',
        confirmLabel: 'Sign & broadcast separation',
      );
      if (confirmed != ConfirmChoice.broadcast || !mounted) return;
      setState(() => _busy = true);
      final txId = await walletService.sendErg(
        preparationId: preview.preparationId,
      );
      final warning = await txBookkeeping(() async {
        if (!mounted) return;
        _tools.clearSelection();
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) await _loadBoxes(propagateError: true);
      });
      showTxResultSheet(
        receiptContext,
        txId: txId,
        warning: warning,
        headline: 'Token separation submitted',
      );
    } catch (e) {
      if (mounted) showTxFailureSheet(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
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

          final warning = await txBookkeeping(() async {
            await Future.delayed(const Duration(seconds: 1));
            if (mounted) await _loadBoxes();
          });
          showTxResultSheet(
            receiptContext,
            txId: txId,
            warning: warning,
            headline: 'Restructure submitted',
          );
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showTxFailureSheet(context, e);
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
    final ready = !_loading && _error == null;
    final suggestion = ready ? _suggestion : null;
    final filtered = ready ? _filteredBoxes : const <InputBoxInput>[];
    final rentParameters = _rent?.parameters;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet boxes'),
        actions: [
          if (_consolidationIds != null)
            IconButton(
              tooltip: 'Last consolidation result',
              onPressed: _showConsolidationResult,
              icon: const Icon(Icons.receipt_long),
            ),
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
              // One scroll for cards and boxes, so large text never squeezes
              // the list out of the screen.
              : CustomScrollView(
                  slivers: [
                    if (suggestion != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: CleanupSuggestionCard(
                            suggestion: suggestion,
                            resultingBoxes: _cleanupEstimate(suggestion)?.boxes.length,
                            fragmented: _boxes.length > utxoFragmentationThreshold,
                            highlight: widget.openCleanup,
                            onReview: _busy ? null : () => _openCleanupFlow(suggestion),
                          ),
                        ),
                      ),
                    // Overview Summary Card
                    SliverToBoxAdapter(
                      child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SoftCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
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
                              ),
                              const SizedBox(width: 8),
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
                          const SizedBox(height: 6),
                          Text(
                            'Oldest boxes first. Automatic sends prefer older eligible boxes to reduce storage-rent risk; privacy rules and your manual selection still apply.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 6),
                          _rentSummary(context),
                          const SizedBox(height: 14),
                          const Hairline(),
                          const SizedBox(height: 12),
                          // Quick actions. They wrap instead of sharing a
                          // row: at 390 dp a third of the card cannot hold
                          // "Consolidate" without breaking the word.
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                style: inlineButtonStyle,
                                icon: const Icon(Icons.merge_type, size: 16),
                                label: const Text('Consolidate'),
                                onPressed: _busy || _boxes.length < 2
                                    ? null
                                    : _openConsolidateFlow,
                              ),
                              OutlinedButton.icon(
                                style: inlineButtonStyle,
                                icon: const Icon(Icons.call_split, size: 16),
                                label: const Text('Split'),
                                onPressed: _busy || _boxes.isEmpty
                                    ? null
                                    : _openSplitFlow,
                              ),
                              OutlinedButton.icon(
                                style: inlineButtonStyle,
                                icon: const Icon(Icons.tune, size: 16),
                                label: const Text('Restructure'),
                                onPressed: _busy || _boxes.isEmpty
                                    ? null
                                    : _openRestructureFlow,
                              ),
                            ],
                          ),
                          if (_boxes.any((b) => b.assets.length >= 2)) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.account_tree_outlined, size: 16),
                                label: const Text('Separate token types'),
                                onPressed: _busy ? null : _openSeparateTokensFlow,
                              ),
                            ),
                          ],
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
                    ),

                    // Filter & Search
                    SliverToBoxAdapter(
                      child: Padding(
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
                    ),

                    const SliverToBoxAdapter(child: SizedBox(height: 8)),

                    // Filter Chips & Selection Controls
                    SliverToBoxAdapter(
                      child: SingleChildScrollView(
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
                          if (_rent != null) ...[
                            const SizedBox(width: 6),
                            _filterChip(
                              UtxoFilter.rent,
                              'Rent (${_tools.rentFlaggedCount})',
                            ),
                          ],
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
                    ),

                    const SliverToBoxAdapter(child: SizedBox(height: 6)),

                    // Boxes List
                    if (filtered.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(16, 32, 16, 80),
                          child: Center(child: Text('No UTXOs match criteria')),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                        sliver: SliverList.builder(
                          itemCount: filtered.length,
                          itemBuilder: (ctx, i) {
                            final box = filtered[i];
                            final isSelected = _selectedBoxIds.contains(
                              box.boxId,
                            );
                            return _UtxoCard(
                              box: box,
                              isSelected: isSelected,
                              rent: _tools.rent[box.boxId],
                              rentParameters: rentParameters,
                              onToggle: () => _tools.toggle(box.boxId),
                              onSeparateTokens: _busy || box.assets.length < 2
                                  ? null
                                  : () => _openSeparateTokensFlow(sourceBoxId: box.boxId),
                            );
                          },
                        ),
                      ),
                  ],
                ),
      bottomSheet: _selectedBoxIds.isNotEmpty
          ? UtxoSelectionActions(
              count: _selectedBoxIds.length,
              onConsolidate: _busy ? null : _openConsolidateFlow,
              onSplit: _busy ? null : _openSplitFlow,
            )
          : null,
    );
  }

  /// One line on storage rent across the listed boxes.
  Widget _rentSummary(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final report = _rent;
    if (report == null) {
      if (_rentLoading) {
        return Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('Checking storage rent…', style: style)),
          ],
        );
      }
      return Text(
        _rentFailed
            ? 'Storage rent unavailable: your node could not be read. Refresh to try again.'
            : 'Storage rent not checked yet.',
        style: style,
      );
    }
    final atRisk = report.atRiskCount;
    final soon = report.boxes.values.where((b) => b.dueSoon && !b.atRisk).length;
    final parts = [
      if (atRisk > 0)
        '$atRisk ${atRisk == 1 ? 'box' : 'boxes'} at risk of collection',
      if (soon > 0) '$soon due within $rentSoonDays days',
    ];
    final missing = report.unmeasured;
    final unmeasured = missing == 0
        ? ''
        : ' $missing ${missing == 1 ? 'box' : 'boxes'} could not be measured.';
    return Text(
      parts.isEmpty
          ? 'Storage rent: nothing due within $rentSoonDays days, and every '
              '${missing == 0 ? '' : 'measured '}box covers its rent. '
              'Rate ${report.parameters.rateLabel}.$unmeasured'
          : 'Storage rent: ${parts.join(' · ')}. Rate ${report.parameters.rateLabel}.$unmeasured',
      style: parts.isEmpty
          ? style
          : style?.copyWith(color: rustFor(context), fontWeight: FontWeight.w500),
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
    this.rent,
    this.rentParameters,
    this.onSeparateTokens,
  });

  final InputBoxInput box;
  final bool isSelected;
  final VoidCallback onToggle;
  final BoxRent? rent;
  final RentParameters? rentParameters;
  final VoidCallback? onSeparateTokens;

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
                            // Gives way at large text sizes rather than
                            // pushing the copy button off the card.
                            Flexible(
                              child: Text(
                                shorten(box.boxId, head: 8, tail: 6),
                                style: monoStyle(context, size: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
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
              if (rent != null && rentParameters != null) ...[
                const SizedBox(height: 8),
                BoxRentLine(
                  rent: rent!,
                  parameters: rentParameters!,
                  hasTokens: box.assets.isNotEmpty,
                ),
              ],
              if (box.assets.length >= 2)
                TextButton.icon(
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  label: const Text('Separate token types'),
                  onPressed: onSeparateTokens,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// When a box's storage rent falls due, what it costs, and whether the
/// box can pay it.
class BoxRentLine extends StatelessWidget {
  const BoxRentLine({
    super.key,
    required this.rent,
    required this.parameters,
    required this.hasTokens,
  });

  final BoxRent rent;
  final RentParameters parameters;

  /// Whether a collector would take tokens along with the ERG.
  final bool hasTokens;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    // Five places show a fee exactly: factor × bytes is a whole number of
    // 0.00125 ERG steps at the launch factor.
    final fee = formatErg(rent.feeNano, maxFrac: 5);
    final when = rentWhen(rent.blocksUntilDue);
    final block = 'block ${formatWithCommas(rent.dueHeight)}';
    final whole = hasTokens ? 'whole, tokens included' : 'whole';
    final (IconData icon, Color color, String text) = switch (rent) {
      BoxRent(charge: RentCharge.none) => (
        Icons.hourglass_empty,
        colors.muted,
        'No storage rent can be charged on a box over '
            '${formatWithCommas(parameters.overflowBytes)} bytes under current rules.',
      ),
      BoxRent(atRisk: true, collectableNow: true) => (
        Icons.warning_amber_rounded,
        rustFor(context),
        'At risk: its $fee rent is more than it holds, so it can be '
            'collected now${hasTokens ? ', tokens included' : ''}.',
      ),
      BoxRent(atRisk: true) => (
        Icons.warning_amber_rounded,
        rustFor(context),
        'At risk: its $fee rent is more than it holds. From $block '
            '($when) it can be collected $whole.',
      ),
      BoxRent(collectableNow: true) => (
        Icons.schedule,
        colors.accentText,
        'Storage rent of $fee can be charged now (due $block).',
      ),
      BoxRent(dueSoon: true) => (
        Icons.schedule,
        colors.accentText,
        'Storage rent of $fee due $when ($block).',
      ),
      _ => (
        Icons.hourglass_bottom,
        colors.muted,
        'Storage rent of $fee due $when ($block).',
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
  }
}

/// The cleanup the screen proposes, at the top of the list.
class CleanupSuggestionCard extends StatelessWidget {
  const CleanupSuggestionCard({
    super.key,
    required this.suggestion,
    required this.resultingBoxes,
    required this.fragmented,
    this.highlight = false,
    this.onReview,
  });

  final CleanupSuggestion suggestion;

  /// Boxes the cleanup creates, or null when the layout is unknown.
  final int? resultingBoxes;

  /// The wallet has more boxes than the home screen calls tidy.
  final bool fragmented;

  /// Opened from the home screen to show this suggestion.
  final bool highlight;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final colors = ArgusColors.of(context);
    final s = suggestion;
    final n = s.boxes.length;
    final into = switch (resultingBoxes) {
      1 => 'into one',
      final int count => 'into $count',
      null => s.tokens.isEmpty ? 'into one' : 'into one or more',
    };
    final of = s.leftAtAddress > 0 ? ' of ${n + s.leftAtAddress}' : '';
    final reasons = <String>[
      if (s.forRent) _rentReason(s),
      if (fragmented) 'Fewer boxes keep every send small and cheap.',
      if (!s.forRent)
        'Moving old boxes also restarts their 4-year storage-rent clock.',
    ];
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(cardRadius),
        border: Border.all(
          color: highlight ? accentOf(context) : colors.cardBorder,
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_fix_high_outlined, size: 18, color: accentOf(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Suggested cleanup',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Merge $n$of boxes at ${shorten(s.address, head: 6, tail: 4)} $into.',
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
          ),
          for (final reason in reasons) ...[
            const SizedBox(height: 4),
            Text(reason, style: bodySmall),
          ],
          const SizedBox(height: 4),
          Text(
            'Fee ${formatErg(s.feesNano)}. Only this address\'s boxes move, so no addresses are linked.',
            style: bodySmall?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.merge_type, size: 18),
            label: const Text('Review cleanup'),
            onPressed: onReview,
          ),
        ],
      ),
    );
  }

  static String _rentReason(CleanupSuggestion s) {
    final parts = <String>[
      if (s.atRiskCount > 0)
        s.atRiskCount == 1
            ? '1 box can\'t cover its storage rent'
            : '${s.atRiskCount} boxes can\'t cover their storage rent',
      if (s.dueSoonCount > 0)
        '${s.dueSoonCount} ${s.dueSoonCount == 1 ? 'falls' : 'fall'} due within $rentSoonDays days',
    ];
    return '${parts.join(' and ')}. Moving them starts a new 4-year rent clock.';
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

class UtxoSelectionActions extends StatelessWidget {
  const UtxoSelectionActions({super.key, required this.count, this.onConsolidate, this.onSplit});

  final int count;
  final VoidCallback? onConsolidate;
  final VoidCallback? onSplit;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outline)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('$count Selected', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (count >= 2)
            FilledButton(style: inlineButtonStyle, onPressed: onConsolidate, child: const Text('Consolidate')),
          OutlinedButton(style: inlineButtonStyle, onPressed: onSplit, child: const Text('Split')),
        ],
      ),
    ),
  );
}
