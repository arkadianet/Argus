import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../services/mix_service.dart';
import '../services/mix_start_flow.dart';
import '../services/network_controller.dart';
import '../services/stealth_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'widgets/empty_state.dart';
import 'widgets/error_sheet.dart';
import 'widgets/soft_card.dart';

/// ERG rings offered even when nobody is waiting in them, so a user can be
/// the first to post a half box. These are the sizes ErgoMixer users mix.
const defaultErgRings = [1000000000, 10000000000, 100000000000];

/// The mixer: what is in the pool, and a way in and out.
class MixScreen extends StatefulWidget {
  const MixScreen({super.key});

  @override
  State<MixScreen> createState() => _MixScreenState();
}

class _MixScreenState extends State<MixScreen> {
  bool _working = false;
  String _status = '';

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _guard(String failureTitle, Future<void> Function() body) async {
    if (_working) return;
    setState(() {
      _working = true;
      _status = '';
    });
    try {
      await body();
    } catch (e) {
      if (!mounted) return;
      showErrorSheet(context, title: failureTitle, message: '$e');
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _status = '';
        });
      }
    }
  }

  MixStartFlow _flow(WalletRouteArgs args) => MixStartFlow(
        service: mixService,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
        prepareFunding: (needed) async {
          final p = await walletService.prepareSend(
            senderAddress: args.senderAddress,
            spendAddresses: args.historyAddresses,
            changeAddress: args.changeAddress,
            recipientAddress: args.receiveAddress,
            amountNanoErg: needed,
            nodeUrl: networkController.activeUrl,
          );
          return MixPrepared(
            preparationId: p.preparationId,
            amountNano: p.amountNanoErg,
            minerFeeNano: p.minerFee,
          );
        },
        confirm: (step, prepared, record) async {
          if (!mounted) return false;
          return switch (step) {
            MixStartStep.funding => showConfirmTransactionSheet(
                context,
                title: 'Fund the mix',
                detail: 'A box of exactly this size, on your own address, is what '
                    'the mixing contract accepts. Entering is the next step.',
                rows: [
                  ConfirmTxRow('To', 'Your own address'),
                  ConfirmTxRow('Amount', formatErg(prepared.amountNano), bold: true),
                  ConfirmTxRow('Miner fee', formatErg(prepared.minerFeeNano)),
                ],
              ),
            MixStartStep.entry => showConfirmTransactionSheet(
                context,
                title: 'Enter the mix',
                detail: 'The operator fee buys the mixing tokens that pay for each '
                    'round. From here on the rounds run on their own while Argus '
                    'is open and unlocked.',
                rows: [
                  ConfirmTxRow('Mixing', formatErg(prepared.amountNano), bold: true),
                  ConfirmTxRow('Rounds', '${record?.roundsTarget ?? ''}'),
                  ConfirmTxRow('Operator fee', formatErg(prepared.appFeeNano)),
                  ConfirmTxRow('Miner fee', formatErg(prepared.minerFeeNano)),
                ],
              ),
          };
        },
        broadcast: (id) async {
          final r = await walletService.sendErgDetailed(preparationId: id);
          return MixBroadcast(
            txId: r['tx_id'] as String? ?? '',
            outputBoxIds: (r['output_box_ids'] as List?)?.cast<String>() ?? const [],
          );
        },
        findFundingBox: (needed, candidates) async {
          final boxes = await walletService.listUnspentBoxes(
            [args.receiveAddress],
            nodeUrl: networkController.activeUrl,
          );
          for (final b in boxes) {
            if (candidates.isNotEmpty && !candidates.contains(b.boxId)) continue;
            if (b.valueNanoErg == BigInt.from(needed) && b.assets.isEmpty) return b.boxId;
          }
          return null;
        },
      );

  Future<void> _start(WalletRouteArgs args) => _guard('Could not start the mix', () async {
        final pool = await mixService.rings();
        if (!mounted) return;
        if (pool['token_box_available'] != true) {
          throw StateError(
            'The mixer operator has no mixing tokens for sale right now, so '
            'nobody can enter the pool. Try again later.',
          );
        }
        final choice = await showModalBottomSheet<_StartChoice>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
          ),
          builder: (_) => _StartMixSheet(pool: pool),
        );
        if (choice == null || !mounted) return;

        final destination = choice.toStealth
            ? await stealthService.newSelfChangeAddress()
            : args.receiveAddress;
        if (destination == null || destination.isEmpty) {
          throw StateError('Could not derive a stealth destination; unlock the wallet and retry');
        }
        final need = await mixService.fundingRequirement(
          denomination: choice.denomination,
          level: choice.level,
        );
        final plan = MixStartPlan(
          denomination: choice.denomination,
          level: choice.level,
          rounds: choice.rounds,
          destinationAddress: destination,
          neededNano: (need['needed_nano_erg'] as num).toInt(),
          operatorFeeNano: (need['operator_fee_nano'] as num).toInt(),
          minerFeeNano: (need['miner_fee_nano'] as num).toInt(),
        );
        final spendable = args.spendableNano ?? 0;
        if (spendable < plan.neededNano) {
          throw StateError(
            'Entering needs ${formatErg(plan.neededNano)} '
            '(${formatErg(plan.denomination)} to mix, ${formatErg(plan.operatorFeeNano)} '
            'operator fee, ${formatErg(plan.minerFeeNano)} miner fee) plus the funding '
            'transaction\'s own fee; this wallet has ${formatErg(spendable)}.',
          );
        }
        final record = await _flow(args).start(plan, fundingAddress: args.receiveAddress);
        if (record == null) return;
        _snack(record.inPool ? 'In the pool' : 'Mix saved; continue it from the list');
      });

  Future<void> _continue(WalletRouteArgs args, MixRecord r) =>
      _guard('Could not enter the pool', () async {
        final need = await mixService.fundingRequirement(
          denomination: r.denomination,
          level: (r.state['level'] as num).toInt(),
        );
        await _flow(args).enter(
          r,
          fundingAddress: args.receiveAddress,
          neededNano: (need['needed_nano_erg'] as num).toInt(),
        );
        _snack(r.inPool ? 'In the pool' : 'Entry not sent');
      });

  Future<void> _leave(WalletRouteArgs args, MixRecord r) =>
      _guard('Could not take the money out', () async {
        String? destination;
        if (r.needsDestination) {
          destination = await _pickDestination(args);
          if (destination == null) return;
        }
        final isHalf = r.phaseKind == 'half_posted';
        final ok = await showConfirmTransactionSheet(
          context,
          title: isHalf ? 'Reclaim the half-mix box' : 'Withdraw from the mix',
          confirmLabel: isHalf ? 'Reclaim' : 'Withdraw',
          detail: isHalf
              ? 'Nobody joined this box. It goes back to your destination and '
                  'the mixing tokens on it are lost.'
              : 'After ${r.roundsDone} ${r.roundsDone == 1 ? 'round' : 'rounds'}. '
                  'The money leaves the pool for the destination you chose.',
          rows: [
            ConfirmTxRow('Amount', formatErg(r.denomination), bold: true),
            ConfirmTxRow('Rounds done', '${r.roundsDone} of ${r.roundsTarget}'),
          ],
        );
        if (!ok) return;
        final tx = await mixService.leave(r, destinationAddress: destination);
        _snack('Sent: ${shorten(tx)}');
      });

  Future<String?> _pickDestination(WalletRouteArgs args) async {
    final toStealth = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Where should the money go?'),
        content: const Text(
          'This mix was recovered from your seed, so its destination is not '
          'known. A stealth address of your own keeps it unlinked; your public '
          'address is simpler to spend from.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Public address')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stealth')),
        ],
      ),
    );
    if (toStealth == null) return null;
    if (!toStealth) return args.receiveAddress;
    final s = await stealthService.newSelfChangeAddress();
    if (s == null) throw StateError('Could not derive a stealth destination');
    return s;
  }

  Future<void> _enable() => _guard('Could not turn on mixing', () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Turn on mixing?'),
            content: const Text(
              'Argus will use the public ErgoMixer pool and its contracts. The '
              'operator charges a fee on every entry, shown before you confirm. '
              'Some app stores do not allow a wallet with a built-in mixer, so '
              'this stays off unless you choose it. You can turn it off again '
              'in Settings → Security.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
            ],
          ),
        );
        if (ok == true) await mixService.setEnabled(true);
      });

  Future<void> _recover() => _guard('Could not scan for mixes', () async {
        final n = await mixService.recover();
        _snack(n == 0 ? 'No unknown mixes found' : 'Found $n ${n == 1 ? 'mix' : 'mixes'}');
      });

  Future<void> _remove(MixRecord r) async {
    try {
      await mixService.remove(r);
    } catch (e) {
      if (mounted) showErrorSheet(context, title: 'Could not remove the mix', message: '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final args = WalletRouteArgs.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mix'),
        actions: [
          IconButton(
            tooltip: 'Check now',
            onPressed: _working || !mixService.enabled ? null : () => mixService.tick(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: mixService,
        builder: (context, _) {
          if (!mixService.enabled) {
            return EmptyState(
              icon: Icons.blender_outlined,
              title: 'Mixing is off',
              body: 'Mixing moves a fixed amount of ERG through rounds with strangers '
                  'in the public ErgoMixer pool, so nothing on chain ties what comes '
                  'out to what went in. Entering costs an operator fee, each round '
                  'needs a counterpart, and a mix can take hours or days. It only '
                  'moves while Argus is open and unlocked.',
              actionLabel: 'Turn on mixing',
              onAction: _working ? null : _enable,
            );
          }
          final records = mixService.records;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Text(
                'A mix moves a fixed amount through rounds with strangers until '
                'nothing on chain ties what comes out to what went in. Each round '
                'needs a counterpart, so a mix can take hours or days, and only '
                'moves while Argus is open and unlocked. The pool is shared with '
                'ErgoMixer; today it is thin.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (_working) ...[
                SoftCard(
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_status.isEmpty ? 'Working…' : _status)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                key: const Key('mix-start'),
                onPressed: _working ? null : () => _start(args),
                icon: const Icon(Icons.add),
                label: const Text('Start a mix'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _working ? null : _recover,
                icon: const Icon(Icons.manage_search),
                label: const Text('Find mixes from this seed'),
              ),
              if (mixService.recordsUnreadable) ...[
                const SizedBox(height: 12),
                Text(
                  'The saved mix list could not be read. A copy was kept; use '
                  '"Find mixes from this seed" to see the boxes again.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (mixService.lastTickError != null) ...[
                const SizedBox(height: 12),
                _ErrorLine('Last check failed', mixService.lastTickError!),
              ],
              const SizedBox(height: 24),
              if (records.isEmpty)
                const EmptyState(
                  icon: Icons.blender_outlined,
                  title: 'No mixes yet',
                  body: 'Start one above. You choose the amount, how many rounds, '
                      'and where the money goes when it is done.',
                  compact: true,
                )
              else ...[
                const SectionLabel('Your mixes'),
                const SizedBox(height: 8),
                for (final r in records) ...[
                  _MixCard(
                    record: r,
                    working: _working,
                    onContinue: () => _continue(args, r),
                    onLeave: () => _leave(args, r),
                    onRemove: () => _remove(r),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.label, this.text);
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SelectableText(
            '$label: $text',
            style: TextStyle(color: error, fontSize: 12),
          ),
        ),
        IconButton(
          tooltip: 'Copy error',
          iconSize: 18,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error copied')));
          },
          icon: const Icon(Icons.copy),
        ),
      ],
    );
  }
}

/// One line under a ring: who is waiting, and what entering costs. Above
/// five percent the fee is called out, because a flat batch price makes a
/// small mix expensive and a large one cheap.
String ringSubtitle({required int value, required int waiting, required int? operatorFee}) {
  final who = waiting == 0
      ? 'Nobody waiting: you would post the first box'
      : '$waiting waiting: you could join at once';
  if (operatorFee == null || value <= 0) return who;
  final pct = operatorFee * 100 / value;
  final pctText = pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1);
  final cost = 'fees ${formatErg(operatorFee, maxFrac: 3)} ($pctText%)';
  return pct >= 5 ? '$who · $cost, expensive for this amount' : '$who · $cost';
}

/// What a mix is doing, in words the user can act on.
String mixPhaseText(MixRecord r) {
  switch (r.phaseKind) {
    case 'pending':
      return 'Funded but not in the pool yet. Continue to enter.';
    case 'half_posted':
      return 'Waiting for someone to join. Round ${r.roundsDone + 1} of ${r.roundsTarget}.';
    case 'full_owned':
      if (r.needsDestination) return 'Recovered from your seed. Choose where it should go.';
      if (r.readyToWithdraw) return 'Rounds done. Withdrawing on the next check.';
      return 'Mixing. Round ${r.roundsDone} of ${r.roundsTarget} done.';
    case 'withdrawn':
      return 'Finished after ${r.roundsDone} ${r.roundsDone == 1 ? 'round' : 'rounds'}.';
    case 'reclaimed':
      return 'Taken back before anyone joined.';
  }
  return r.phaseKind;
}

class _MixCard extends StatelessWidget {
  const _MixCard({
    required this.record,
    required this.working,
    required this.onContinue,
    required this.onLeave,
    required this.onRemove,
  });

  final MixRecord record;
  final bool working;
  final VoidCallback onContinue;
  final VoidCallback onLeave;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final muted = ArgusColors.of(context).muted;
    final theme = Theme.of(context);
    final progress = r.roundsTarget == 0 ? 0.0 : (r.roundsDone / r.roundsTarget).clamp(0.0, 1.0);
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatErg(r.denomination),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text('#${r.mixId}', style: TextStyle(color: muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          Text(mixPhaseText(r), style: theme.textTheme.bodyMedium),
          if (r.inPool) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6),
            ),
          ],
          if (r.lastCheckedAt != null) ...[
            const SizedBox(height: 6),
            Text('Checked ${formatSyncAge(r.lastCheckedAt!)}',
                style: TextStyle(color: muted, fontSize: 12)),
          ],
          if (r.lastError != null) ...[
            const SizedBox(height: 6),
            _ErrorLine('Last move failed', r.lastError!),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              if (r.pending)
                FilledButton.tonal(
                  onPressed: working ? null : onContinue,
                  child: const Text('Continue'),
                ),
              if (r.inPool)
                OutlinedButton(
                  onPressed: working ? null : onLeave,
                  child: Text(r.phaseKind == 'half_posted'
                      ? 'Reclaim'
                      : r.needsDestination
                          ? 'Withdraw to…'
                          : 'Withdraw now'),
                ),
              if (r.finished || r.pending)
                TextButton(
                  onPressed: working ? null : onRemove,
                  child: const Text('Remove'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StartChoice {
  const _StartChoice({
    required this.denomination,
    required this.level,
    required this.rounds,
    required this.toStealth,
  });
  final int denomination;
  final int level;
  final int rounds;
  final bool toStealth;
}

/// Ring, token level, rounds, destination.
class _StartMixSheet extends StatefulWidget {
  const _StartMixSheet({required this.pool});
  final Map<String, dynamic> pool;

  @override
  State<_StartMixSheet> createState() => _StartMixSheetState();
}

class _StartMixSheetState extends State<_StartMixSheet> {
  late List<({int value, int waiting})> _rings;
  late List<({int level, int price})> _levels;
  late int _rate;
  int? _denomination;
  int? _level;
  int _rounds = 3;
  bool _toStealth = true;

  @override
  void initState() {
    super.initState();
    final seen = <int, int>{};
    for (final r in (widget.pool['rings'] as List? ?? const [])) {
      final m = r as Map;
      if (m['token_id'] != null) continue; // token rings: not in the UI yet
      seen[(m['value'] as num).toInt()] = (m['waiting'] as num?)?.toInt() ?? 0;
    }
    for (final d in defaultErgRings) {
      seen.putIfAbsent(d, () => 0);
    }
    final values = seen.keys.toList()..sort();
    _rings = [for (final v in values) (value: v, waiting: seen[v]!)];
    _levels = [
      for (final l in (widget.pool['token_levels'] as List? ?? const []))
        (level: ((l as Map)['level'] as num).toInt(), price: (l['price_nano_erg'] as num).toInt()),
    ];
    _rate = (widget.pool['token_rate'] as num?)?.toInt() ?? 0;
    // Prefer a ring with someone waiting, and the cheapest token batch.
    final waiting = _rings.where((r) => r.waiting > 0).toList();
    _denomination = (waiting.isNotEmpty ? waiting.first : _rings.first).value;
    _level = _levels.isEmpty ? null : _levels.first.level;
  }

  /// What entering `value` costs the user in operator fees at the chosen
  /// batch: the batch price plus the pool's cut of the amount.
  int? _operatorFee(int value) {
    final level = _level;
    if (level == null || _rate <= 0) return null;
    final batch = _levels.where((l) => l.level == level).firstOrNull;
    if (batch == null) return null;
    return batch.price + value ~/ _rate;
  }

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final theme = Theme.of(context);
    final canStart = _denomination != null && _level != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Start a mix', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              const SectionLabel('Amount'),
              const SizedBox(height: 4),
              for (final r in _rings)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    r.value == _denomination
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: r.value == _denomination ? accentOf(context) : muted,
                  ),
                  onTap: () => setState(() => _denomination = r.value),
                  title: Text(formatErg(r.value)),
                  subtitle: Text(
                    ringSubtitle(value: r.value, waiting: r.waiting, operatorFee: _operatorFee(r.value)),
                    style: TextStyle(
                      color: (_operatorFee(r.value) ?? 0) * 20 >= r.value ? theme.colorScheme.error : muted,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              const SectionLabel('Mixing tokens'),
              const SizedBox(height: 4),
              if (_levels.isEmpty)
                Text('None for sale right now', style: TextStyle(color: theme.colorScheme.error))
              else
                DropdownButtonFormField<int>(
                  initialValue: _level,
                  items: [
                    for (final l in _levels)
                      DropdownMenuItem(
                        value: l.level,
                        child: Text('${l.level} tokens · ${formatErg(l.price, maxFrac: 4)}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _level = v),
                ),
              Text(
                'Each round burns one or two tokens; the smallest batch covers more '
                'rounds than you can choose here. Tokens left when the mix ends are lost.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              const SectionLabel('Rounds'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _rounds.toDouble(),
                      min: 1,
                      max: 10,
                      divisions: 9,
                      label: '$_rounds',
                      onChanged: (v) => setState(() => _rounds = v.round()),
                    ),
                  ),
                  SizedBox(width: 28, child: Text('$_rounds', textAlign: TextAlign.end)),
                ],
              ),
              Text(
                'More rounds, more strangers between what went in and what comes out, '
                'and more waiting.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              const SectionLabel('When it is done, send to'),
              const SizedBox(height: 4),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _toStealth,
                onChanged: (v) => setState(() => _toStealth = v),
                title: Text(_toStealth ? 'A stealth address of yours' : 'Your public address'),
                subtitle: Text(
                  _toStealth
                      ? 'Nothing on chain links the mixed money to this wallet'
                      : 'Simpler to spend, but the wallet\'s addresses are linked to it',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('mix-start-confirm'),
                onPressed: canStart
                    ? () => Navigator.pop(
                          context,
                          _StartChoice(
                            denomination: _denomination!,
                            level: _level!,
                            rounds: _rounds,
                            toStealth: _toStealth,
                          ),
                        )
                    : null,
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
