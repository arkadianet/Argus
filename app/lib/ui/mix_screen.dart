import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';
import '../services/mix_activity.dart';
import '../services/mix_service.dart';
import '../services/mix_start_flow.dart';
import '../services/network_controller.dart';
import '../services/stealth_service.dart';
import '../services/wallet_service.dart';
import '../theme/argus_theme.dart';
import 'confirm_transaction_sheet.dart';
import 'transaction_detail_screen.dart';
import 'widgets/battery_note.dart';
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
        prepareFunding: (needed, {tokenId, tokenAmount}) async {
          final p = await walletService.prepareSend(
            senderAddress: args.senderAddress,
            spendAddresses: args.historyAddresses,
            changeAddress: args.changeAddress,
            recipientAddress: args.receiveAddress,
            amountNanoErg: needed,
            tokenId: tokenId,
            tokenAmount: tokenAmount,
            nodeUrl: networkController.activeUrl,
          );
          return MixPrepared(
            preparationId: p.preparationId,
            amountNano: p.amountNanoErg,
            minerFeeNano: p.minerFee,
            tokenId: tokenId,
            tokenAmount: tokenAmount,
          );
        },
        confirm: (step, prepared, record) async {
          if (!mounted) return false;
          return switch (step) {
            MixStartStep.funding => showConfirmTransactionSheet(
                context,
                preparationId: prepared.preparationId,
                title: 'Fund the mix',
                detail: 'A box of exactly this size, on your own address, is what '
                    'the mixing contract accepts. Entering is the next step.',
                rows: [
                  ConfirmTxRow('To', 'Your own address'),
                  ConfirmTxRow('Amount', formatErg(prepared.amountNano), bold: true),
                  if (prepared.tokenId != null)
                    ConfirmTxRow('Token', ringAmountText(prepared.amountNano, prepared.tokenId, prepared.tokenAmount), bold: true),
                  ConfirmTxRow('Miner fee', formatErg(prepared.minerFeeNano)),
                ],
              ),
            MixStartStep.entry => showConfirmTransactionSheet(
                context,
                preparationId: prepared.preparationId,
                title: 'Enter the mix',
                detail: 'The operator fee buys the level: one mixing token per round. '
                    'From here on the rounds run on their own '
                    '${mixService.backgroundEnabled ? 'about every fifteen minutes, with Argus closed too' : 'while Argus is open and unlocked'}.',
                rows: [
                  ConfirmTxRow('Mixing', record == null ? formatErg(prepared.amountNano) : mixAmountText(record), bold: true),
                  ConfirmTxRow('Rounds', 'about ${record?.roundsTarget ?? ''}'),
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
        findFundingBox: (needed, candidates, {tokenId, tokenAmount}) async {
          // Straight from the node, not through the wallet's coin selection:
          // once the funding is recorded, that selection hides the funding
          // box from every spend but the mix entry, and this finder is the
          // entry. Keep it that way if this ever changes source.
          final boxes = await walletService.listUnspentBoxes(
            [args.receiveAddress],
            nodeUrl: networkController.activeUrl,
          );
          for (final b in boxes) {
            if (candidates.isNotEmpty && !candidates.contains(b.boxId)) continue;
            if (b.valueNanoErg != BigInt.from(needed)) continue;
            // An ERG mix box carries nothing else; a token mix box carries
            // exactly the token the entry accounts for.
            final ok = tokenId == null
                ? b.assets.isEmpty
                : b.assets.length == 1 &&
                    b.assets.single.tokenId == tokenId &&
                    b.assets.single.amount == BigInt.from(tokenAmount ?? -1);
            if (ok) return b.boxId;
          }
          return null;
        },
        findBox: mixService.boxOnChain,
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
        // Token rings are named by their token; look the names up first.
        await walletService.prefetchTokenMeta([
          for (final r in (pool['rings'] as List? ?? const []))
            if ((r as Map)['token_id'] is String) r['token_id'] as String,
        ]);
        if (!mounted) return;
        final choice = await showModalBottomSheet<_StartChoice>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(cardRadius)),
          ),
          builder: (_) => _StartMixSheet(pool: pool, tokens: args.tokens),
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
          tokenId: choice.tokenId,
          tokenAmount: choice.tokenAmount,
        );
        final neededToken = (need['needed_token_amount'] as num?)?.toInt();
        final plan = MixStartPlan(
          denomination: choice.denomination,
          tokenId: choice.tokenId,
          tokenAmount: choice.tokenAmount,
          neededTokenAmount: neededToken,
          level: choice.level,
          // As ErgoMixer: the level is the number of rounds, one token each.
          rounds: choice.level,
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
        if (choice.tokenId != null && neededToken != null) {
          final have = args.tokens.where((t) => t.id == choice.tokenId).fold(0, (a, t) => a + t.amount);
          if (have < neededToken) {
            throw StateError(
              'Entering needs ${ringAmountText(choice.denomination, choice.tokenId, neededToken)} '
              '(${ringAmountText(choice.denomination, choice.tokenId, choice.tokenAmount)} to mix plus the '
              'operator\'s commission); this wallet has ${ringAmountText(choice.denomination, choice.tokenId, have)}.',
            );
          }
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
          tokenId: r.ringTokenId,
          tokenAmount: r.ringTokenAmount,
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
          title: 'Withdraw from the mix',
          confirmLabel: 'Withdraw',
          detail: isHalf
              ? 'This box is still waiting for a partner, so it has not been mixed '
                  'this round. It goes to your destination minus the miner fee, and '
                  'the mixing tokens on it are lost.'
              : 'After ${r.roundsDone} ${r.roundsDone == 1 ? 'round' : 'rounds'} of about '
                  '${r.roundsTarget}. The money leaves the pool for the destination you chose.',
          rows: [
            ConfirmTxRow('Amount', mixAmountText(r), bold: true),
            ConfirmTxRow('Rounds done', '${r.roundsDone} of ${r.roundsTarget}'),
          ],
        );
        if (!ok) return;
        final tx = await mixService.leave(r, destinationAddress: destination);
        _snack('Withdrawing: ${shorten(tx)}');
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
              'A mix is only as private as the node Argus talks to: that node '
              'sees which pool boxes are yours and where the money ends up, so '
              'use your own node for mixing if you can (Settings → Network). '
              'The mix records on this phone (boxes, rounds, destination) are '
              'stored unencrypted for now; the seed and the keys are not. '
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
                  'needs a partner, and a mix can take days. It only '
                  'moves while Argus is open and unlocked. The node Argus uses '
                  'still sees which boxes are yours: mix through your own node.',
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
                'needs a partner and can take hours, so a mix takes days. The pool is '
                'shared with ErgoMixer; today it is thin. The node Argus talks to '
                'sees which pool boxes are yours and the withdrawal, so a mix is '
                'only as private as that node: use your own where you can.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                mixService.backgroundEnabled
                    ? 'Mixes keep moving about every fifteen minutes while Argus is closed.'
                    : 'Mixes move only while Argus is open and unlocked. Settings → Security '
                        'can keep them moving in the background.',
                style: TextStyle(color: ArgusColors.of(context).muted, fontSize: 12),
              ),
              if (mixService.backgroundEnabled) ...[
                const SizedBox(height: 6),
                const BatteryNote(),
              ],
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
                  body: 'Start one above. You choose the amount, the mixing level, '
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

/// One muted line under a ring: who is waiting, how many boxes there are
/// to hide among, and the fee. Nothing here is a warning; [ringNote] is.
String ringSubtitle({
  required int value,
  required int waiting,
  required int depth,
  required int? operatorFee,
  String? tokenFee,
}) {
  final who = waiting == 0 ? 'Nobody waiting' : '$waiting waiting';
  final hide = depth == 0 ? 'nobody mixing here yet' : '$depth ${depth == 1 ? 'box' : 'boxes'} to hide among';
  if (operatorFee == null || value <= 0) return '$who · $hide';
  // A token ring's ERG is a sliver; its fee is the ERG price plus a
  // commission in the token, and a percentage of the sliver means nothing.
  if (tokenFee != null) return '$who · $hide · fee ${formatErg(operatorFee, maxFrac: 3)} + $tokenFee';
  return '$who · $hide · fee ${formatErg(operatorFee, maxFrac: 3)} (${_pct(operatorFee, value)}%)';
}

String _pct(int fee, int value) {
  final pct = fee * 100 / value;
  return pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1);
}

/// How fast a ring moves, from full boxes made in the past week: a join
/// creates two, so joins a day is recent boxes over fourteen. Empty when
/// it did not move.
String ringPace(int recentRounds) {
  if (recentRounds == 0) return '';
  final perDay = recentRounds / 14;
  if (perDay >= 1) {
    final n = perDay.round();
    return 'about $n ${n == 1 ? 'round' : 'rounds'} a day';
  }
  final perWeek = recentRounds / 2;
  final n = perWeek.round();
  return 'about ${n < 1 ? 1 : n} ${perWeek >= 1.5 ? 'rounds' : 'round'} a week';
}

/// The second line under a ring, only when there is something to say: a
/// fee above five percent (a flat batch price makes a small mix dear), a
/// partner already waiting, a quiet ring, or its pace. Red for the fee only.
({String text, bool warning}) ringNote({
  required int value,
  required int waiting,
  required int recentRounds,
  required int? operatorFee,
  bool tokenRing = false,
}) {
  final expensive = !tokenRing && operatorFee != null && value > 0 && operatorFee * 20 > value;
  final pace = ringPace(recentRounds);
  final movement = recentRounds == 0
      ? (waiting > 0
          ? 'A partner is waiting, so your first round could start at once'
          : 'Quiet: no rounds here in the past week')
      : '${pace[0].toUpperCase()}${pace.substring(1)} here';
  if (!expensive) return (text: movement, warning: false);
  final fee = 'Fee is ${_pct(operatorFee, value)}% of this amount';
  return (text: '$fee · ${movement[0].toLowerCase()}${movement.substring(1)}', warning: true);
}

/// A ring is offered when someone is waiting in it, it moved in the past
/// week, or it is a standard amount. The pool carries old rings with
/// hundreds of boxes and no movement; those would only mislead.
bool ringOffered({required int value, required int waiting, required int recentRounds, String? tokenId}) =>
    waiting > 0 || recentRounds > 0 || (tokenId == null && defaultErgRings.contains(value));

/// "Level 1 · 30 rounds": ErgoMixer's numbering, one token per round.
String levelTitle({required int index, required int rounds}) => 'Level ${index + 1} · $rounds rounds';

/// What a level costs and, at the chosen ring's pace, how long it takes.
String levelSubtitle({required int price, required int rounds, required String ringLabel, required int recentRounds}) {
  final cost = '${formatErg(price, maxFrac: 4)} in mixing tokens';
  final ring = '$ringLabel ring';
  if (recentRounds == 0) return '$cost · no estimate: the $ring had no rounds in the past week';
  final days = (rounds / (recentRounds / 14)).ceil();
  final eta = days >= 60 ? 'about ${(days / 7).round()} weeks' : 'about $days ${days == 1 ? 'day' : 'days'}';
  return "$cost · $eta for $rounds rounds at the $ring's pace";
}

/// How long a half box has waited since its last event, and after two
/// days a nudge towards Withdraw now. Empty when the wait is under an hour,
/// the events carry no time, or the clock went backwards.
String waitingHint(List<Map<String, dynamic>> events, DateTime now) {
  final at = events.isEmpty ? null : (events.last['at'] as num?)?.toInt();
  if (at == null) return '';
  final waited = now.difference(DateTime.fromMillisecondsSinceEpoch(at * 1000));
  if (waited.inHours < 1) return '';
  final how = waited.inDays >= 1
      ? ' Waiting ${waited.inDays} ${waited.inDays == 1 ? 'day' : 'days'}.'
      : ' Waiting ${waited.inHours} ${waited.inHours == 1 ? 'hour' : 'hours'}.';
  final nudge = waited.inDays >= 2 ? ' The pool is thin; Withdraw now takes it back, minus the mixing tokens.' : '';
  return '$how$nudge';
}

/// "12 mixing tokens on the box · about 11 more rounds affordable".
String tokensLeftText(int tokens, int rounds) => rounds == 0
    ? '$tokens mixing ${tokens == 1 ? 'token' : 'tokens'} on the box · no more rounds affordable, it withdraws next'
    : '$tokens mixing tokens on the box · about $rounds more ${rounds == 1 ? 'round' : 'rounds'} affordable';

/// What a mix is doing, in words the user can act on.
String mixPhaseText(MixRecord r) {
  switch (r.phaseKind) {
    case 'pending':
      return 'Funded but not in the pool yet. Continue to enter.';
    case 'half_posted':
      return 'Round ${r.roundsDone + 1} of about ${r.roundsTarget} · waiting for a partner.${waitingHint(r.events, DateTime.now())}';
    case 'full_owned':
      if (r.needsDestination) return 'Recovered from your seed. Choose where it should go.';
      if (r.readyToWithdraw) return 'Rounds done. Withdrawing on the next check.';
      return 'Round ${r.roundsDone} of about ${r.roundsTarget} done · mixing.';
    case 'withdrawn':
      return 'Finished after ${r.roundsDone} ${r.roundsDone == 1 ? 'round' : 'rounds'}.';
    case 'reclaimed':
      return 'Withdrawn before a partner joined.';
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
                  mixAmountText(r),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text('#${r.mixId}', style: TextStyle(color: muted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          Text(mixPhaseText(r), style: theme.textTheme.bodyMedium),
          if (r.finished) ...[
            const SizedBox(height: 6),
            Text(mixFinishedText(r), style: TextStyle(color: muted, fontSize: 12.5)),
          ],
          if (r.inPool) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6),
            ),
          ],
          if (r.inPool && r.tokensLeft != null) ...[
            const SizedBox(height: 6),
            Text(tokensLeftText(r.tokensLeft!, r.roundsAffordable!), style: TextStyle(color: muted, fontSize: 12)),
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
                  child: Text(r.needsDestination ? 'Withdraw to…' : 'Withdraw now'),
                ),
              if (r.finished && mixFinalRow(r) != null)
                FilledButton.tonal(
                  key: const Key('mix-see-tx'),
                  onPressed: () => Navigator.push(
                    context,
                    fadeRoute(
                      const TransactionDetailScreen(),
                      settings: RouteSettings(
                        arguments: WalletRouteArgs.of(context).copyWith(transaction: mixFinalRow(r)),
                      ),
                    ),
                  ),
                  child: const Text('See transaction'),
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
    this.tokenId,
    this.tokenAmount,
    required this.level,
    required this.toStealth,
  });
  final int denomination;

  /// A token ring: the token and the ring amount.
  final String? tokenId;
  final int? tokenAmount;

  /// Mixing tokens bought, which is also the number of rounds.
  final int level;
  final bool toStealth;
}

/// One ring the pool offers: an ERG amount, or an amount of a token on a
/// sliver of ERG.
class _Ring {
  const _Ring({
    required this.value,
    this.tokenId,
    this.tokenAmount,
    required this.waiting,
    required this.depth,
    required this.recentRounds,
  });
  final int value;
  final String? tokenId;
  final int? tokenAmount;
  final int waiting;
  final int depth;
  final int recentRounds;

  String get label => ringAmountText(value, tokenId, tokenAmount);
}

/// Ring, token level, rounds, destination. `tokens` is what the wallet
/// holds, so a token ring it cannot fund is shown but not offered.
class _StartMixSheet extends StatefulWidget {
  const _StartMixSheet({required this.pool, required this.tokens});
  final Map<String, dynamic> pool;
  final List<TokenBalance> tokens;

  @override
  State<_StartMixSheet> createState() => _StartMixSheetState();
}

class _StartMixSheetState extends State<_StartMixSheet> {
  late List<_Ring> _rings;
  late List<({int level, int price, int rate})> _levels;
  int _hiddenRings = 0;
  int? _selected;
  int? _level;
  bool _toStealth = true;

  @override
  void initState() {
    super.initState();
    final seen = <_Ring>[];
    for (final r in (widget.pool['rings'] as List? ?? const [])) {
      final m = r as Map;
      seen.add(_Ring(
        value: (m['value'] as num).toInt(),
        tokenId: m['token_id'] as String?,
        tokenAmount: (m['token_amount'] as num?)?.toInt(),
        waiting: (m['waiting'] as num?)?.toInt() ?? 0,
        depth: (m['depth'] as num?)?.toInt() ?? 0,
        recentRounds: (m['recent_rounds'] as num?)?.toInt() ?? 0,
      ));
    }
    for (final d in defaultErgRings) {
      if (!seen.any((r) => r.tokenId == null && r.value == d)) {
        seen.add(_Ring(value: d, waiting: 0, depth: 0, recentRounds: 0));
      }
    }
    // ERG rings by amount, then token rings by token and amount.
    seen.sort((a, b) {
      final t = (a.tokenId ?? '').compareTo(b.tokenId ?? '');
      if (t != 0) return t;
      final v = a.value.compareTo(b.value);
      return v != 0 ? v : (a.tokenAmount ?? 0).compareTo(b.tokenAmount ?? 0);
    });
    _rings = [
      for (final r in seen)
        if (ringOffered(value: r.value, waiting: r.waiting, recentRounds: r.recentRounds, tokenId: r.tokenId)) r,
    ];
    _hiddenRings = seen.length - _rings.length;
    _levels = [
      for (final l in (widget.pool['token_levels'] as List? ?? const []))
        (
          level: ((l as Map)['level'] as num).toInt(),
          price: (l['price_nano_erg'] as num).toInt(),
          // The rate of the box that sells this level; the pool-wide rate
          // is the fallback for a level answer without one.
          rate: (l['rate'] as num?)?.toInt() ?? (widget.pool['token_rate'] as num?)?.toInt() ?? 0,
        ),
    ];
    // The cheapest token batch first: what a token ring needs (ring amount
    // plus commission) depends on the level's rate, so the level is known
    // before any ring is judged fundable. Then prefer a fundable ring with
    // someone waiting.
    _level = _levels.isEmpty ? null : _levels.first.level;
    final fundable = _rings.indexed.where((e) => _held(e.$2) == null).toList();
    final waiting = fundable.where((e) => e.$2.waiting > 0).toList();
    _selected = _rings.isEmpty
        ? null
        : waiting.isNotEmpty
            ? waiting.first.$1
            : fundable.isNotEmpty
                ? fundable.first.$1
                : 0;
  }

  _Ring? get _ring => _selected == null ? null : _rings[_selected!];

  /// Why the wallet cannot fund a token ring, or null when it can.
  String? _held(_Ring r) {
    if (r.tokenId == null) return null;
    final have = widget.tokens.where((t) => t.id == r.tokenId).fold(0, (a, t) => a + t.amount);
    final need = _neededToken(r) ?? r.tokenAmount ?? 0;
    if (have <= 0) return 'You hold none of this token';
    if (have < need) return 'You hold ${ringAmountText(r.value, r.tokenId, have)}, less than the ${ringAmountText(r.value, r.tokenId, need)} this needs';
    return null;
  }

  /// Ring amount plus the operator's commission in the token.
  int? _neededToken(_Ring r) {
    final amount = r.tokenAmount;
    if (r.tokenId == null || amount == null) return null;
    final rate = _rate;
    if (rate == null || rate <= 0) return null;
    return amount + amount ~/ rate;
  }

  int? get _rate {
    final level = _level;
    if (level == null) return null;
    return _levels.where((l) => l.level == level).firstOrNull?.rate;
  }

  String? _tokenFee(_Ring r) {
    final need = _neededToken(r);
    final amount = r.tokenAmount;
    if (need == null || amount == null) return null;
    return ringAmountText(r.value, r.tokenId, need - amount);
  }

  int get _deepest => _rings.fold(0, (m, r) => r.depth > m ? r.depth : m);

  /// What entering `value` costs the user in operator fees at the chosen
  /// batch: the batch price plus the pool's cut of the amount.
  int? _operatorFee(int value) {
    final level = _level;
    if (level == null) return null;
    final batch = _levels.where((l) => l.level == level).firstOrNull;
    if (batch == null || batch.rate <= 0) return null;
    return batch.price + value ~/ batch.rate;
  }

  @override
  Widget build(BuildContext context) {
    final muted = ArgusColors.of(context).muted;
    final theme = Theme.of(context);
    // A level change can raise a token ring's commission past what the
    // wallet holds, so the chosen ring is judged again here, not only when
    // it was tapped.
    final canStart = _ring != null && _level != null && _held(_ring!) == null;
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
              for (final (i, r) in _rings.indexed)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  enabled: _held(r) == null,
                  leading: Icon(
                    i == _selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: i == _selected ? accentOf(context) : muted,
                  ),
                  onTap: _held(r) == null ? () => setState(() => _selected = i) : null,
                  title: Text(
                    r.depth == _deepest && r.depth > 0 ? '${r.label} · deepest ring' : r.label,
                  ),
                  subtitle: Builder(builder: (context) {
                    final note = ringNote(
                      value: r.value,
                      waiting: r.waiting,
                      recentRounds: r.recentRounds,
                      operatorFee: _operatorFee(r.value),
                      tokenRing: r.tokenId != null,
                    );
                    final cannot = _held(r);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ringSubtitle(
                            value: r.value,
                            waiting: r.waiting,
                            depth: r.depth,
                            operatorFee: _operatorFee(r.value),
                            tokenFee: _tokenFee(r),
                          ),
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                        Text(
                          cannot ?? note.text,
                          style: TextStyle(color: note.warning ? theme.colorScheme.error : muted, fontSize: 12),
                        ),
                      ],
                    );
                  }),
                ),
              if (_hiddenRings > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '$_hiddenRings other ${_hiddenRings == 1 ? 'ring' : 'rings'} in the pool had nobody waiting '
                    'and no rounds in the past week, so ${_hiddenRings == 1 ? 'it is' : 'they are'} not offered.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              const SectionLabel('Mixing level'),
              const SizedBox(height: 4),
              if (_levels.isEmpty)
                Text('None for sale right now', style: TextStyle(color: theme.colorScheme.error))
              else
                for (final (i, l) in _levels.indexed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      l.level == _level ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: l.level == _level ? accentOf(context) : muted,
                    ),
                    onTap: () => setState(() => _level = l.level),
                    title: Text(levelTitle(index: i, rounds: l.level)),
                    subtitle: Text(
                      levelSubtitle(
                        price: l.price,
                        rounds: l.level,
                        ringLabel: _ring?.label ?? '',
                        recentRounds: _ring?.recentRounds ?? 0,
                      ),
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
              Text(
                'A level is how many rounds the mix runs, one mixing token each, as in '
                'ErgoMixer. Rounds wait for partners, so the estimate is the pool\'s pace '
                'today. You can withdraw at any round; the mixed money is yours throughout.',
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
                            denomination: _ring!.value,
                            tokenId: _ring!.tokenId,
                            tokenAmount: _ring!.tokenAmount,
                            level: _level!,
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
