import 'mix_service.dart';

/// What the user chose on the start sheet, plus what entering will cost.
class MixStartPlan {
  const MixStartPlan({
    required this.denomination,
    required this.level,
    required this.rounds,
    required this.destinationAddress,
    required this.neededNano,
    required this.operatorFeeNano,
    required this.minerFeeNano,
  });

  final int denomination;
  final int level;
  final int rounds;
  final String destinationAddress;

  /// What the funding box must hold: denomination, operator fee, miner fee.
  final int neededNano;
  final int operatorFeeNano;
  final int minerFeeNano;
}

/// A prepared transaction the user must confirm: the id to broadcast and
/// the figures to show.
class MixPrepared {
  const MixPrepared({
    required this.preparationId,
    required this.amountNano,
    required this.minerFeeNano,
    this.appFeeNano = 0,
  });

  final int preparationId;
  final int amountNano;
  final int minerFeeNano;
  final int appFeeNano;
}

/// Which of the two confirmations is being asked for.
enum MixStartStep { funding, entry }

/// Prepare the self-send that creates the funding box.
typedef PrepareFunding = Future<MixPrepared> Function(int neededNano);

/// Ask the user. False means stop where we are.
typedef ConfirmStep = Future<bool> Function(MixStartStep step, MixPrepared prepared, MixRecord? record);

/// Sign and broadcast a preparation; returns the transaction id.
typedef Broadcast = Future<String> Function(int preparationId);

/// The id of an unspent, asset-free box holding exactly `neededNano` at the
/// funding address, or null while there is none yet.
typedef FindFundingBox = Future<String?> Function(int neededNano);

/// Putting money into the pool takes two confirmed transactions: a plain
/// self-send that makes a box of exactly the right size, and the entry
/// that spends it. This runs those steps in order, over injected calls, so
/// the order and the failure handling can be tested without a wallet.
///
/// The mix record is created as soon as the funding transaction is out,
/// so a crash or a timeout while waiting for the box leaves a pending mix
/// the user can continue from the list instead of money in limbo.
class MixStartFlow {
  MixStartFlow({
    required this.service,
    required this.prepareFunding,
    required this.confirm,
    required this.broadcast,
    required this.findFundingBox,
    this.pollInterval = const Duration(seconds: 6),
    this.maxWait = const Duration(minutes: 12),
    this.onStatus,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final MixService service;
  final PrepareFunding prepareFunding;
  final ConfirmStep confirm;
  final Broadcast broadcast;
  final FindFundingBox findFundingBox;
  final Duration pollInterval;
  final Duration maxWait;
  final void Function(String)? onStatus;
  final Future<void> Function(Duration) _delay;

  /// Start a new mix. Returns the record, which is in the pool on success,
  /// pending when the user stopped after funding, or null when they
  /// stopped before anything was sent.
  Future<MixRecord?> start(MixStartPlan plan, {required String fundingAddress}) async {
    onStatus?.call('Preparing the funding transaction');
    final funding = await prepareFunding(plan.neededNano);
    if (!await confirm(MixStartStep.funding, funding, null)) return null;
    final fundingTx = await broadcast(funding.preparationId);
    onStatus?.call('Funding sent: $fundingTx');

    final record = await service.createMix(
      denomination: plan.denomination,
      level: plan.level,
      rounds: plan.rounds,
      destinationAddress: plan.destinationAddress,
      fundingNano: plan.neededNano,
    );
    return enter(record, fundingAddress: fundingAddress, neededNano: plan.neededNano);
  }

  /// Enter the pool with a pending mix, waiting for its funding box first.
  /// Returns the record: in the pool on success, still pending when the
  /// user declined the entry. `neededNano` is only a fallback for a record
  /// that does not remember what it was funded with.
  Future<MixRecord> enter(
    MixRecord record, {
    required String fundingAddress,
    required int neededNano,
  }) async {
    if (!record.pending) throw StateError('This mix has already entered the pool');
    onStatus?.call('Waiting for the funding box to confirm');
    final boxId = await _waitForBox(record.fundingNano ?? neededNano);
    if (boxId == null) {
      throw StateError(
        'The funding box has not confirmed yet. The mix is saved; '
        'open it again once the transaction has a confirmation.',
      );
    }
    onStatus?.call('Preparing the entry');
    final entry = await service.prepareEntry(
      record,
      fundingAddress: fundingAddress,
      fundingBoxId: boxId,
    );
    final summary = (entry['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    final prepared = MixPrepared(
      preparationId: (entry['preparation_id'] as num).toInt(),
      amountNano: (summary['denomination'] as num?)?.toInt() ?? record.denomination,
      minerFeeNano: (summary['miner_fee_nano'] as num?)?.toInt() ?? 0,
      appFeeNano: (summary['operator_fee_nano'] as num?)?.toInt() ?? 0,
    );
    if (!await confirm(MixStartStep.entry, prepared, record)) return record;
    final txId = await broadcast(prepared.preparationId);
    await service.commitEntry(record, (entry['next_state'] as Map).cast<String, dynamic>(), txId);
    onStatus?.call('Entered the pool: $txId');
    return record;
  }

  Future<String?> _waitForBox(int neededNano) async {
    var waited = Duration.zero;
    while (true) {
      final id = await findFundingBox(neededNano);
      if (id != null) return id;
      if (waited >= maxWait) return null;
      await _delay(pollInterval);
      waited += pollInterval;
    }
  }
}
