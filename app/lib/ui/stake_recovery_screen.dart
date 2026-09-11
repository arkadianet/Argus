import 'package:flutter/material.dart';

import '../services/stake_recovery_service.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import '../theme/argus_theme.dart';
import 'widgets/soft_card.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/error_sheet.dart';

/// Discovery and Direct Ergopad recovery.
class StakeRecoveryScreen extends StatefulWidget {
  const StakeRecoveryScreen({super.key});
  @override
  State<StakeRecoveryScreen> createState() => _StakeRecoveryScreenState();
}

class _StakeRecoveryScreenState extends State<StakeRecoveryScreen> {
  final _service = stakeRecoveryService;
  bool _working = false;

  Future<void> _recover(StakePoolResult result, StakePosition position) async {
    if (_working) return;
    final args = WalletRouteArgs.of(context);
    setState(() => _working = true);
    try {
      final prepared = await _service.prepareDirect(
        result: result,
        position: position,
        userAddress: args.receiveAddress,
        spendAddresses: args.historyAddresses,
      );
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Recover Ergopad stake',
        detail:
            'Receive your full stake. Your stake key returns to your wallet.',
        confirmLabel: 'Recover stake',
        rows: [
          for (final row in prepared['rows'] as List)
            ConfirmTxRow(row['label'] as String, row['value'] as String),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      await _service.revalidateCommit(prepared);
      if (!mounted || !_service.canCommit(prepared)) return;
      final txId = await walletService.sendErg(
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Recovery submitted: $txId')));
      await _refresh();
    } catch (e) {
      if (mounted)
        showErrorSheet(
          context,
          title: 'Could not recover stake',
          message: '$e',
        );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final args = WalletRouteArgs.of(context);
    // Every positive wallet token is a candidate, regardless of its metadata.
    // A name or an NFT label cannot establish possession of a stake key.
    await _service.refresh(
      {
        for (final token in args.tokens)
          if (token.amount > 0) token.id,
      },
      walletTokensComplete:
          walletSyncController.balanceNano != null &&
          !walletSyncController.isStale &&
          !walletSyncController.isSyncing &&
          walletSyncController.phase != SyncPhase.idle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stake recovery'),
        actions: [
          IconButton(
            tooltip: 'Scan again',
            onPressed: _service.busy || _working ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            const Text(
              'Find abandoned Ergopad and Paideia v1 stakes linked to tokens in this wallet. Ergopad recovery is available. Your stake key returns to your wallet. Paideia recovery is not available yet.',
            ),
            const SizedBox(height: 12),
            Text(
              'Scanning is free. Recovery will pay a flat 0.0011 ERG Argus fee per transaction, plus miner and contract costs. '
              'Paideia needs two transactions (0.0022 ERG in Argus fees), a 0.1 ERG incentive and a 0.002 ERG execution miner fee. '
              'The 0.002 ERG executor output returns to your wallet. A refund also pays the Argus fee.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            if (_service.busy) const LinearProgressIndicator(),
            if (_service.results.isEmpty && !_service.busy)
              const Text('Scan this wallet to check for stakes.'),
            for (final result in _service.results) ...[
              const SizedBox(height: 12),
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.pool.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (result.status) {
                        StakeScanStatus.scanning => 'Scanning…',
                        StakeScanStatus.complete =>
                          result.positions.isEmpty
                              ? 'Nothing found for this wallet — scan complete'
                              : 'Scan complete',
                        StakeScanStatus.incomplete =>
                          'Incomplete — more positions may exist',
                        StakeScanStatus.unavailable =>
                          'Unavailable — stakes could not be checked',
                      },
                      style: TextStyle(
                        color: result.status == StakeScanStatus.complete
                            ? muted
                            : Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    if (result.message != null) Text(result.message!),
                    if (result.stateError != null) Text(result.stateError!),
                    if (result.state != null)
                      Text(
                        'Pool checkpoint ${result.state!['checkpoint']}',
                        style: TextStyle(color: muted),
                      ),
                    if (result.status != StakeScanStatus.scanning)
                      Text(
                        '${result.scanned} boxes scanned · ${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s${result.source == null ? '' : ' · ${result.source}'}',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    for (final position in result.positions) ...[
                      const Divider(),
                      Text(
                        '${position.amount(result.pool.decimals)} ${result.pool.name}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        'Stake key ${position.keyId.substring(0, 12)}…',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                      Text(
                        position.eligible == true
                            ? 'Recovery inputs match the current pool state'
                            : position.eligible == false
                            ? 'Not currently recoverable: ${position.eligibilityError}'
                            : 'Recovery eligibility unknown until the pool state can be read',
                      ),
                      if (result.pool.id == 'ergopad' &&
                          position.eligible == true &&
                          result.status == StakeScanStatus.complete)
                        FilledButton(
                          onPressed: _working || _service.busy
                              ? null
                              : () => _recover(result, position),
                          child: Text(
                            _working ? 'Preparing…' : 'Recover stake',
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
