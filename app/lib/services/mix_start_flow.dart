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

/// What a broadcast produced: the transaction and the ids of its outputs.
class MixBroadcast {
  const MixBroadcast({required this.txId, this.outputBoxIds = const []});
  final String txId;
  final List<String> outputBoxIds;
}

/// Which of the two confirmations is being asked for.
enum MixStartStep { funding, entry }

/// Prepare the self-send that creates the funding box.
typedef PrepareFunding = Future<MixPrepared> Function(int neededNano);

/// Ask the user. False means stop where we are.
typedef ConfirmStep = Future<bool> Function(MixStartStep step, MixPrepared prepared, MixRecord? record);

/// Sign and broadcast a preparation.
typedef Broadcast = Future<MixBroadcast> Function(int preparationId);

/// The id of the funding box, or null while it is not there.
///
/// When `candidates` is not empty it names the outputs of the funding
/// transaction, and only one of those, unspent, asset-free and holding
/// `neededNano`, qualifies: an unrelated box of the same size must not be
/// taken while the real one is still pending. With no candidates (a record
/// from before the ids were kept) the amount is all there is to go on.
typedef FindFundingBox = Future<String?> Function(int neededNano, List<String> candidates);

/// Putting money into the pool takes two confirmed transactions: a plain
/// self-send that makes a box of exactly the right size, and the entry
/// that spends it. This runs those steps in order, over injected calls, so
/// the order and the failure handling can be tested without a wallet.
///
/// Every broadcast is preceded by a persisted record of what is about to
/// happen, and followed by a record of what did. So a crash at any point
/// leaves a pending mix the user can continue, and continuing reconciles
/// with the chain instead of sending again.
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

    // The record exists before the money moves, so nothing sent is ever
    // unaccounted for.
    final record = await service.createMix(
      denomination: plan.denomination,
      level: plan.level,
      rounds: plan.rounds,
      destinationAddress: plan.destinationAddress,
      fundingNano: plan.neededNano,
    );
    final sent = await broadcast(funding.preparationId);
    await service.recordFunding(record, txId: sent.txId, outputBoxIds: sent.outputBoxIds);
    onStatus?.call('Funding sent: ${sent.txId}');
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
    final needed = record.fundingNano ?? neededNano;

    // An entry was staged and may have been broadcast before the app
    // stopped. If the funding box is gone, it was: adopt the staged state
    // and let the next check confirm it on chain. If the box is still
    // there, the entry never went out and is built again.
    final staged = record.entryAttempt;
    if (staged != null) {
      final still = await findFundingBox(needed, record.fundingBoxIds);
      if (still == null) {
        await service.commitEntry(record, staged, record.entryTxId ?? '');
        onStatus?.call('Entry already sent; the next check confirms it');
        return record;
      }
    }

    onStatus?.call('Waiting for the funding box to confirm');
    final boxId = await _waitForBox(needed, record.fundingBoxIds);
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

    final nextState = (entry['next_state'] as Map).cast<String, dynamic>();
    await service.stageEntry(record, nextState);
    final sent = await broadcast(prepared.preparationId);
    await service.commitEntry(record, nextState, sent.txId);
    onStatus?.call('Entered the pool: ${sent.txId}');
    return record;
  }

  Future<String?> _waitForBox(int neededNano, List<String> candidates) async {
    var waited = Duration.zero;
    while (true) {
      final id = await findFundingBox(neededNano, candidates);
      if (id != null) return id;
      if (waited >= maxWait) return null;
      final remaining = maxWait - waited;
      final wait = pollInterval < remaining ? pollInterval : remaining;
      await _delay(wait);
      waited += wait;
    }
  }
}
