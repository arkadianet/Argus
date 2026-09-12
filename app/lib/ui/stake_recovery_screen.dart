import 'widgets/tx_explorer_link.dart';
import 'package:flutter/material.dart';

import '../services/stake_recovery_service.dart';
import '../services/stake_proxy_service.dart';
import '../services/wallet_service.dart';
import '../services/wallet_sync_controller.dart';
import '../theme/argus_theme.dart';
import 'widgets/soft_card.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/error_sheet.dart';
import 'widgets/tx_result_view.dart';

/// Discovery and Direct Ergopad recovery.
class StakeRecoveryScreen extends StatefulWidget {
  const StakeRecoveryScreen({super.key});
  @override
  State<StakeRecoveryScreen> createState() => _StakeRecoveryScreenState();
}

class _StakeRecoveryScreenState extends State<StakeRecoveryScreen> {
  final _service = stakeRecoveryService;
  bool _working = false;

  Future<void> _refund(TrackedStakeProxy record) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final prepared = await stakeProxyService.prepareRefund(record);
      if (!mounted) return;
      final ok = await showConfirmTransactionSheet(
        context,
        title: 'Refund Paideia proxy',
        detail:
            'A successful unstake burns the stake key permanently. This refund '
            'returns the key and all proxy ERG except the 0.001 ERG miner fee to '
            'the recorded wallet recipient. It needs no pool state or working '
            'unstake. Refund is available only while the proxy remains unspent.',
        confirmLabel: 'Refund proxy',
        rows: [
          for (final row in prepared['rows'] as List)
            ConfirmTxRow(row['label'] as String, row['value'] as String),
        ],
        preparationId: (prepared['preparation_id'] as num).toInt(),
      );
      if (!ok || !mounted) return;
      final txId = await stakeProxyService.commitRefund(prepared);
      if (mounted) {
        showTxResultSheet(context, txId: txId, headline: 'Refund submitted');
      }
      await stakeProxyService.reload();
    } catch (e) {
      if (mounted) {
        showTxFailureSheet(
          context,
          e,
          note:
              'The proxy remains tracked. Refresh to reconcile before retrying.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

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
      if (mounted) {
        showTxResultSheet(context, txId: txId, headline: 'Recovery submitted');
      }
      await _refresh();
    } catch (e) {
      if (mounted) showTxFailureSheet(context, e);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    stakeProxyService.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    stakeProxyService.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final args = WalletRouteArgs.of(context);
    // Refund reconciliation is independent of all pool scans.
    final refunds = stakeProxyService.reload();
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
    await refunds;
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
              'Find abandoned Ergopad and Paideia v1 stakes linked to tokens in this wallet. Ergopad recovery is available. Your stake key returns to your wallet. Paideia proxy creation and unstake are disabled until the execution flow is ready. Tracked proxies can be refunded here, including from earlier sessions.',
            ),
            const SizedBox(height: 12),
            Text(
              'Scanning is free. Ergopad recovery and Paideia proxy creation pay a flat 0.0011 ERG Argus fee. '
              'Paideia execution pays a 0.1 ERG incentive and 0.002 ERG miner fee; the 0.002 ERG executor output returns to your wallet. '
              'Refund deducts only 0.001 ERG for the miner and pays no Argus fee. Successful unstake burns the key permanently.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            if (stakeProxyService.error != null)
              Text(
                'Could not load tracked proxies: ${stakeProxyService.error}',
              ),
            for (final proxy in stakeProxyService.records) ...[
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Paideia proxy · ${proxy.status.name}'),
                    Text('Stake key ${proxy.keyId}'),
                    if (proxy.note != null) Text(proxy.note!),
                    for (final txId in proxy.refundTxIds) ...[
                      Text(
                        proxy.refundConfirmed(txId)
                            ? 'Refund confirmed'
                            : 'Refund attempt — completion not confirmed. Check the transaction before retrying.',
                      ),
                      TxExplorerLink(txId: txId, label: 'Refund transaction'),
                    ],
                    if (proxy.status != ProxyStatus.spent)
                      FilledButton(
                        onPressed: _working ? null : () => _refund(proxy),
                        child: const Text('Refund proxy'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
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
                      // A found position is fully decoded, unambiguous and
                      // checked against pool state. An incomplete scan means
                      // others may be missing, never that this one is wrong.
                      if (result.pool.id == 'ergopad' &&
                          position.eligible == true)
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
