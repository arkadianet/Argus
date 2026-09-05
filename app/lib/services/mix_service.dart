import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as bridge;
import '../format.dart';
import 'network_controller.dart';
import 'notification_service.dart';
import 'wallet_service.dart';

/// One mix as the app keeps it: the Rust engine's state JSON, which is the
/// truth, plus what only the app knows (the last error, when it last
/// looked). No secret is ever here; see the zerojoin crate's `mix` module.
class MixRecord {
  MixRecord({
    required this.state,
    this.lastError,
    this.lastCheckedAt,
    this.fundingNano,
    this.fundingTxId,
    this.fundingBoxIds = const [],
    this.entryAttempt,
    this.entryTxId,
  });

  Map<String, dynamic> state;
  String? lastError;
  DateTime? lastCheckedAt;

  /// What the funding box was made to hold, so a pending mix can find it
  /// again even if the operator's price has moved since.
  int? fundingNano;

  /// The funding self-send, once broadcast, and the ids of its outputs:
  /// the funding box is one of them, found by id rather than by guessing
  /// from its size.
  String? fundingTxId;
  List<String> fundingBoxIds;

  /// The state an entry will produce, persisted before the entry is
  /// broadcast. Still here after a crash means the entry may be on chain.
  Map<String, dynamic>? entryAttempt;
  String? entryTxId;

  int get mixId => (state['mix_id'] as num).toInt();
  Map<String, dynamic> get phase => (state['phase'] as Map).cast<String, dynamic>();
  String get phaseKind => phase['kind'] as String? ?? '';
  String? get boxId => phase['box_id'] as String?;
  int get denomination => ((state['ring'] as Map)['value'] as num).toInt();
  String? get ringTokenId => (state['ring'] as Map)['token_id'] as String?;
  int get roundsDone => (state['rounds_done'] as num?)?.toInt() ?? 0;
  int get roundsTarget => (state['rounds_target'] as num?)?.toInt() ?? 0;
  int get round => (state['round'] as num?)?.toInt() ?? 0;
  String get destinationErgoTree => state['destination_ergo_tree'] as String? ?? '';
  int get createdAt => (state['created_at'] as num?)?.toInt() ?? 0;
  int get updatedAt => (state['updated_at'] as num?)?.toInt() ?? 0;

  /// The mix is waiting in, or moving through, the pool.
  bool get inPool => phaseKind == 'half_posted' || phaseKind == 'full_owned';
  bool get pending => phaseKind == 'pending';
  bool get finished => phaseKind == 'withdrawn' || phaseKind == 'reclaimed';

  /// nanoERG this mix has in the pool right now.
  int get lockedNano => inPool ? denomination : 0;

  /// Rounds done and nothing left to do but leave: the money is mixed and
  /// waiting to be withdrawn.
  bool get readyToWithdraw => phaseKind == 'full_owned' && roundsDone >= roundsTarget;

  /// Recovered from the seed: the engine knows the box but not where the
  /// user wanted the money to go.
  bool get needsDestination => inPool && destinationErgoTree.isEmpty;

  Map<String, dynamic> toJson() => {
        'state': state,
        if (lastError != null) 'last_error': lastError,
        if (lastCheckedAt != null) 'last_checked_at': lastCheckedAt!.millisecondsSinceEpoch,
        if (fundingNano != null) 'funding_nano': fundingNano,
        if (fundingTxId != null) 'funding_tx_id': fundingTxId,
        if (fundingBoxIds.isNotEmpty) 'funding_box_ids': fundingBoxIds,
        if (entryAttempt != null) 'entry_attempt': entryAttempt,
        if (entryTxId != null) 'entry_tx_id': entryTxId,
      };

  static MixRecord fromJson(Map<String, dynamic> m) => MixRecord(
        state: (m['state'] as Map).cast<String, dynamic>(),
        lastError: m['last_error'] as String?,
        fundingNano: (m['funding_nano'] as num?)?.toInt(),
        fundingTxId: m['funding_tx_id'] as String?,
        fundingBoxIds: (m['funding_box_ids'] as List?)?.cast<String>() ?? const [],
        entryAttempt: (m['entry_attempt'] as Map?)?.cast<String, dynamic>(),
        entryTxId: m['entry_tx_id'] as String?,
        lastCheckedAt: (m['last_checked_at'] as num?) == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((m['last_checked_at'] as num).toInt()),
      );
}

/// What the engine needs of the wallet, so the service can be tested
/// without the Rust bridge.
abstract class MixGateway {
  bool get isUnlocked;
  String? get walletId;
  String? get nodeUrl;
  String get explorerBase;

  /// `{"half","full","fee","token","mixing_token_id"}` ErgoTree hexes.
  String contractTrees();
  Future<String> newState({
    required int mixId,
    required int denomination,
    String? tokenId,
    int? tokenAmount,
    required int level,
    required int rounds,
    required String destinationAddress,
    required int nowUnix,
  });
  Future<String> rings(String chainJson);
  Future<String> fundingRequirement(String chainJson, int denomination, int level, int? feeNano);
  Future<String> plan(String stateJson, String chainJson, List<String> ownHalfBoxIds);
  Future<String> observe(String stateJson, String chainJson, int nowUnix);
  Future<String> advance(
    String stateJson,
    String chainJson,
    List<String> ownHalfBoxIds,
    String? nodeUrl,
    int nowUnix,
  );
  Future<String> leave(
    String stateJson,
    String chainJson,
    String? destinationAddress,
    String? nodeUrl,
    int nowUnix,
  );
  Future<String> recover(String chainJson, int nowUnix);
  Future<String> prepareEntry({
    required String stateJson,
    required String chainJson,
    required String fundingAddress,
    required String fundingBoxId,
    required List<String> ownHalfBoxIds,
    String? nodeUrl,
    required int nowUnix,
  });
  Future<void> notify({required String title, required String body});
}

/// The real thing: every call goes through the Rust bridge.
class LiveMixGateway implements MixGateway {
  const LiveMixGateway();

  @override
  bool get isUnlocked => walletService.isUnlocked;
  @override
  String? get walletId => walletService.activeWalletId;
  @override
  String? get nodeUrl => networkController.activeUrl;
  @override
  String get explorerBase => networkController.explorer;

  @override
  String contractTrees() => bridge.mixContractTrees();

  @override
  Future<String> newState({
    required int mixId,
    required int denomination,
    String? tokenId,
    int? tokenAmount,
    required int level,
    required int rounds,
    required String destinationAddress,
    required int nowUnix,
  }) =>
      bridge.mixNewState(
        mixId: mixId,
        denomination: denomination,
        tokenId: tokenId,
        tokenAmount: tokenAmount,
        level: level,
        rounds: rounds,
        destinationAddress: destinationAddress,
        nowUnix: nowUnix,
      );

  @override
  Future<String> rings(String chainJson) => bridge.mixRings(chainJson: chainJson);

  @override
  Future<String> fundingRequirement(String chainJson, int denomination, int level, int? feeNano) =>
      bridge.mixFundingRequirement(
        chainJson: chainJson,
        denomination: denomination,
        level: level,
        feeNano: feeNano,
      );

  @override
  Future<String> plan(String stateJson, String chainJson, List<String> ownHalfBoxIds) =>
      bridge.mixPlan(stateJson: stateJson, chainJson: chainJson, ownHalfBoxIds: ownHalfBoxIds);

  @override
  Future<String> observe(String stateJson, String chainJson, int nowUnix) =>
      walletService.mixObserve(stateJson: stateJson, chainJson: chainJson, nowUnix: nowUnix);

  @override
  Future<String> advance(
    String stateJson,
    String chainJson,
    List<String> ownHalfBoxIds,
    String? nodeUrl,
    int nowUnix,
  ) =>
      walletService.mixAdvance(
        stateJson: stateJson,
        chainJson: chainJson,
        ownHalfBoxIds: ownHalfBoxIds,
        nodeUrl: nodeUrl,
        nowUnix: nowUnix,
      );

  @override
  Future<String> leave(
    String stateJson,
    String chainJson,
    String? destinationAddress,
    String? nodeUrl,
    int nowUnix,
  ) =>
      walletService.mixLeave(
        stateJson: stateJson,
        chainJson: chainJson,
        destinationAddress: destinationAddress,
        nodeUrl: nodeUrl,
        nowUnix: nowUnix,
      );

  @override
  Future<String> recover(String chainJson, int nowUnix) =>
      walletService.mixRecover(chainJson: chainJson, nowUnix: nowUnix);

  @override
  Future<String> prepareEntry({
    required String stateJson,
    required String chainJson,
    required String fundingAddress,
    required String fundingBoxId,
    required List<String> ownHalfBoxIds,
    String? nodeUrl,
    required int nowUnix,
  }) =>
      walletService.mixPrepareEntry(
        stateJson: stateJson,
        chainJson: chainJson,
        fundingAddress: fundingAddress,
        fundingBoxId: fundingBoxId,
        ownHalfBoxIds: ownHalfBoxIds,
        nodeUrl: nodeUrl,
        nowUnix: nowUnix,
      );

  @override
  Future<void> notify({required String title, required String body}) =>
      notificationService.mixProgress(title: title, body: body);
}

/// One HTTP GET returning the body, so the snapshot builder can be tested
/// against canned pages.
typedef MixHttpGet = Future<String> Function(Uri uri);

Future<String> _httpGet(Uri uri) async {
  final res = await http.get(uri).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) {
    throw StateError('explorer returned HTTP ${res.statusCode} for ${uri.path}');
  }
  return res.body;
}

/// Boxes per explorer page.
const mixPageLimit = 500;

/// Most boxes one list fetch will pull. The live pool is a few hundred
/// boxes; this keeps a runaway pool from filling a phone's memory.
const mixListCap = 5000;

/// The snapshot the engine reads, built from explorer pages.
class MixSnapshot {
  MixSnapshot({required this.json, required this.height, required this.truncated});

  /// `{"half_boxes","full_boxes","fee_boxes","token_boxes","height"}`.
  final String json;
  final int height;

  /// A list hit [mixListCap] before its last page. Planning still works,
  /// but a counterpart may have been missed.
  final bool truncated;
}

/// Drives every mix of the active wallet: keeps the records, fetches the
/// chain snapshot, and asks the engine to move each mix along.
///
/// Entries are prepared here but confirmed by the user through the same
/// PIN and confirm sheet as any send; every later move is broadcast by
/// [tick] without asking, since it spends nothing the user has not already
/// committed to the mix.
class MixService extends ChangeNotifier {
  MixService({MixGateway? gateway, MixHttpGet? get, DateTime Function()? clock})
      : _gw = gateway ?? const LiveMixGateway(),
        _get = get ?? _httpGet,
        _clock = clock ?? DateTime.now;

  static const _enabledKey = 'argus_mixing_enabled';
  static String _recordsKey(String walletId) => 'argus_mixes_v1_$walletId';

  /// A copy of a records value that could not be read, kept so the next
  /// write cannot destroy it. The boxes are still on chain and recovery
  /// finds them, but the destinations they carried live only here.
  static String _salvageKey(String walletId) => 'argus_mixes_v1_${walletId}_unreadable';

  /// The next mix index, kept apart from the records: a mix index names a
  /// derivation path, and reusing one after its record was removed would
  /// reuse a secret and its public commitment on chain.
  static String _nextIdKey(String walletId) => 'argus_mixes_v1_${walletId}_next_id';

  final MixGateway _gw;
  final MixHttpGet _get;
  final DateTime Function() _clock;

  /// Off until the user turns mixing on in Settings → Privacy.
  bool enabled = false;

  /// Every mix of the loaded wallet, newest first.
  List<MixRecord> records = const [];

  /// The wallet [records] belong to. Null until [load] runs.
  String? _walletId;

  bool _ticking = false;
  int _generation = 0;

  /// Text of the last failure of [tick] as a whole (fetching the snapshot,
  /// not a single mix), kept so the UI can show and copy it.
  String? lastTickError;
  DateTime? lastTickAt;

  /// True when the stored records for this wallet could not be read. They
  /// were copied aside; a recovery scan can find the boxes again.
  bool recordsUnreadable = false;

  int _nextId = 0;

  bool get busy => _ticking;

  /// Mixes waiting in or moving through the pool.
  List<MixRecord> get active => records.where((r) => r.inPool).toList();

  /// nanoERG still moving through rounds.
  int get inMixNano =>
      records.where((r) => r.inPool && !r.readyToWithdraw).fold(0, (a, r) => a + r.lockedNano);

  /// nanoERG that has done its rounds and sits in the pool until withdrawn.
  int get mixedNano => records.where((r) => r.readyToWithdraw).fold(0, (a, r) => a + r.lockedNano);

  /// Half-mix boxes this wallet posted, which it must never join itself.
  List<String> get ownHalfBoxIds => [
        for (final r in records)
          if (r.phaseKind == 'half_posted' && r.boxId != null) r.boxId!,
      ];

  /// Box ids of the mixes in the pool. A record whose phase somehow lacks
  /// one is left out rather than allowed to stop every other mix.
  List<String> get _activeBoxIds => [
        for (final r in active)
          if (r.boxId != null) r.boxId!,
      ];

  int get _now => _clock().millisecondsSinceEpoch ~/ 1000;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(_enabledKey) ?? false;
    final id = _gw.walletId;
    _walletId = id;
    recordsUnreadable = false;
    _nextId = 0;
    if (id == null) {
      records = const [];
    } else {
      final raw = prefs.getString(_recordsKey(id));
      final decoded = _decode(raw);
      if (decoded == null) {
        // Copy the unreadable value aside before anything can overwrite it.
        recordsUnreadable = true;
        await prefs.setString(_salvageKey(id), raw!);
        records = const [];
      } else {
        records = decoded;
      }
      _nextId = prefs.getInt(_nextIdKey(id)) ?? 0;
      for (final r in records) {
        if (r.mixId + 1 > _nextId) _nextId = r.mixId + 1;
      }
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (value == enabled) return;
    // Persist first, so the UI never claims a setting that will not
    // survive a restart.
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_enabledKey, value)) {
      throw StateError('Failed to persist the mixing setting');
    }
    enabled = value;
    notifyListeners();
  }

  /// Forget the loaded wallet's mixes in memory (never on disk).
  void reset() {
    _generation++;
    _walletId = null;
    records = const [];
    lastTickError = null;
    notifyListeners();
  }

  /// Null when the stored value exists but cannot be read.
  static List<MixRecord>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [for (final m in list) MixRecord.fromJson((m as Map).cast<String, dynamic>())];
    } catch (_) {
      return null;
    }
  }

  /// Runs [body] alone: never alongside a tick or another call that
  /// broadcasts or rewrites the records. Waits for a running tick.
  Future<T> _exclusive<T>(Future<T> Function() body) async {
    while (_ticking) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _ticking = true;
    notifyListeners();
    try {
      return await body();
    } finally {
      _ticking = false;
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final id = _walletId;
    if (id == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_recordsKey(id), jsonEncode([for (final r in records) r.toJson()]));
    notifyListeners();
  }

  Map<String, String> get _trees {
    final m = jsonDecode(_gw.contractTrees()) as Map;
    return m.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  Future<List<dynamic>> _pageAll(String base, String tree, {int cap = mixListCap}) async {
    final items = <dynamic>[];
    final seen = <String>{};
    var offset = 0;
    var truncated = false;
    while (true) {
      final uri = Uri.parse(
        '$base/api/v1/boxes/unspent/byErgoTree/$tree?offset=$offset&limit=$mixPageLimit',
      );
      final body = jsonDecode(await _get(uri)) as Map;
      final page = (body['items'] as List? ?? const []);
      for (final b in page) {
        final id = (b as Map)['boxId']?.toString() ?? '';
        if (id.isNotEmpty && seen.add(id)) items.add(b);
      }
      final total = (body['total'] as num?)?.toInt();
      offset += page.length;
      if (page.length < mixPageLimit || (total != null && offset >= total)) break;
      if (items.length >= cap) {
        truncated = true;
        break;
      }
    }
    _lastListTruncated = _lastListTruncated || truncated;
    return items;
  }

  bool _lastListTruncated = false;

  /// Everything the engine needs, from the explorer: the waiting half
  /// boxes, the operator's boxes, and the current state of each of our own
  /// boxes (unspent, or the outputs of whatever spent it).
  ///
  /// With [allFullBoxes] every unspent full-mix box is included too, which
  /// recovery needs and a routine tick does not.
  Future<MixSnapshot> snapshot({Iterable<String> ownBoxIds = const [], bool allFullBoxes = false}) async {
    final base = _gw.explorerBase.replaceAll(RegExp(r'/+$'), '');
    final trees = _trees;
    _lastListTruncated = false;
    final half = await _pageAll(base, trees['half']!);
    final fee = await _pageAll(base, trees['fee']!, cap: 100);
    final token = await _pageAll(base, trees['token']!, cap: 100);
    final full = allFullBoxes ? await _pageAll(base, trees['full']!) : <dynamic>[];
    for (final id in ownBoxIds) {
      Map<String, dynamic> box;
      try {
        box = (jsonDecode(await _get(Uri.parse('$base/api/v1/boxes/$id'))) as Map).cast();
      } catch (_) {
        // Not found or unreachable: the engine sees the box as "not seen"
        // and waits, which is the safe answer.
        continue;
      }
      final spentBy = box['spentTransactionId']?.toString();
      if (spentBy == null || spentBy.isEmpty) {
        // Unspent: hand it over under both lists; the engine files it by
        // script and ignores duplicates.
        half.add(box);
        full.add(box);
        continue;
      }
      try {
        final tx = (jsonDecode(await _get(Uri.parse('$base/api/v1/transactions/$spentBy'))) as Map);
        for (final o in (tx['outputs'] as List? ?? const [])) {
          full.add(o);
        }
      } catch (_) {
        // The engine will report the box as not seen and wait.
      }
    }
    final state = jsonDecode(await _get(Uri.parse('$base/api/v1/networkState'))) as Map;
    final height = (state['height'] as num).toInt();
    return MixSnapshot(
      json: jsonEncode({
        'half_boxes': half,
        'full_boxes': full,
        'fee_boxes': fee,
        'token_boxes': token,
        'height': height,
      }),
      height: height,
      truncated: _lastListTruncated,
    );
  }

  /// What the pool offers now, as the engine reports it.
  Future<Map<String, dynamic>> rings() async {
    final snap = await snapshot();
    return (jsonDecode(await _gw.rings(snap.json)) as Map).cast<String, dynamic>();
  }

  /// nanoERG a funding box needs for `denomination` at `level`.
  Future<Map<String, dynamic>> fundingRequirement({
    required int denomination,
    required int level,
    int? feeNano,
  }) async {
    final snap = await snapshot();
    final raw = await _gw.fundingRequirement(snap.json, denomination, level, feeNano);
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  /// A new mix, persisted as pending. Nothing is on chain until
  /// [prepareEntry] is confirmed and [commitEntry] records it.
  Future<MixRecord> createMix({
    required int denomination,
    String? tokenId,
    int? tokenAmount,
    required int level,
    required int rounds,
    required String destinationAddress,
    int? fundingNano,
  }) async {
    final id = _walletId;
    if (id == null) throw StateError('No wallet is loaded');
    final mixId = _nextId;
    // Reserve the index before the record exists, so a crash in between
    // still never hands this path to another mix.
    final prefs = await SharedPreferences.getInstance();
    _nextId = mixId + 1;
    await prefs.setInt(_nextIdKey(id), _nextId);
    final raw = await _gw.newState(
      mixId: mixId,
      denomination: denomination,
      tokenId: tokenId,
      tokenAmount: tokenAmount,
      level: level,
      rounds: rounds,
      destinationAddress: destinationAddress,
      nowUnix: _now,
    );
    final record = MixRecord(
      state: (jsonDecode(raw) as Map).cast<String, dynamic>(),
      fundingNano: fundingNano,
    );
    records = [record, ...records];
    await _persist();
    return record;
  }

  /// Build the entry for a pending mix from `fundingBoxId`, one of the
  /// wallet's own boxes at `fundingAddress`. Returns the preparation the
  /// confirm sheet needs plus the state to commit once it is broadcast.
  Future<Map<String, dynamic>> prepareEntry(
    MixRecord record, {
    required String fundingAddress,
    required String fundingBoxId,
  }) async {
    if (!record.pending) throw StateError('This mix has already entered the pool');
    final snap = await snapshot();
    final raw = await _gw.prepareEntry(
      stateJson: jsonEncode(record.state),
      chainJson: snap.json,
      fundingAddress: fundingAddress,
      fundingBoxId: fundingBoxId,
      ownHalfBoxIds: ownHalfBoxIds,
      nodeUrl: _gw.nodeUrl,
      nowUnix: _now,
    );
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  /// Record that the funding self-send went out.
  Future<void> recordFunding(
    MixRecord record, {
    required String txId,
    required List<String> outputBoxIds,
  }) async {
    record.fundingTxId = txId;
    record.fundingBoxIds = List.unmodifiable(outputBoxIds);
    await _persist();
  }

  /// Persist what an entry will produce, before it is broadcast.
  Future<void> stageEntry(MixRecord record, Map<String, dynamic> nextState) async {
    record.entryAttempt = nextState;
    await _persist();
  }

  /// Record that a prepared entry was broadcast as `txId` (empty when the
  /// id was lost with a crash; the next check reads the box from chain).
  Future<void> commitEntry(MixRecord record, Map<String, dynamic> nextState, String txId) async {
    final events = (nextState['events'] as List?)?.cast<Map>() ?? const [];
    if (events.isNotEmpty && txId.isNotEmpty) {
      // The engine could not know the id before broadcast.
      events.last['tx_id'] = txId;
    }
    record.state = nextState;
    record.entryAttempt = null;
    record.entryTxId = txId.isEmpty ? null : txId;
    record.lastError = null;
    record.lastCheckedAt = _clock();
    await _persist();
  }

  /// Drop a finished or never-started mix from the list. A mix with money
  /// in the pool cannot be forgotten: its box is only spendable through
  /// its record or a recovery scan.
  Future<void> remove(MixRecord record) async {
    if (record.inPool) throw StateError('This mix still has money in the pool');
    records = records.where((r) => r.mixId != record.mixId).toList();
    await _persist();
  }

  /// Look at the chain once and move every active mix that can move.
  ///
  /// Never throws. Failures land on the mix ([MixRecord.lastError]) or on
  /// [lastTickError]. Runs at most once at a time; a tick that arrives
  /// while another runs is dropped, not queued.
  Future<void> tick() async {
    if (_ticking || !enabled || !_gw.isUnlocked) return;
    if (_walletId == null || _walletId != _gw.walletId) return;
    if (active.isEmpty) return;
    _ticking = true;
    final gen = _generation;
    try {
      final snap = await snapshot(ownBoxIds: _activeBoxIds);
      if (gen != _generation) return;
      lastTickError = null;
      for (final r in active) {
        await _step(r, snap);
        if (gen != _generation) return;
      }
      lastTickAt = _clock();
      await _persist();
    } catch (e) {
      if (gen != _generation) return;
      lastTickError = e.toString();
      notifyListeners();
    } finally {
      _ticking = false;
    }
  }

  /// Advance one mix by one move.
  Future<void> _step(MixRecord r, MixSnapshot snap) async {
    final before = r.roundsDone;
    r.lastCheckedAt = _clock();
    try {
      final observed = await _gw.observe(jsonEncode(r.state), snap.json, _now);
      r.state = (jsonDecode(observed) as Map).cast<String, dynamic>();
      if (r.roundsDone > before) await _announceRound(r);

      final plan = (jsonDecode(await _gw.plan(jsonEncode(r.state), snap.json, ownHalfBoxIds)) as Map)
          .cast<String, dynamic>();
      final action = plan['action'] as String? ?? 'wait';
      if (action == 'wait') {
        r.lastError = null;
        return;
      }
      if (action == 'withdraw' && r.destinationErgoTree.isEmpty) {
        // A recovered mix: the user must say where it goes.
        r.lastError = null;
        return;
      }
      final raw = await _gw.advance(jsonEncode(r.state), snap.json, ownHalfBoxIds, _gw.nodeUrl, _now);
      final result = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if (result['action'] == 'wait') {
        r.lastError = null;
        return;
      }
      r.state = (result['state'] as Map).cast<String, dynamic>();
      r.lastError = null;
      if (r.finished) {
        await _gw.notify(
          title: 'Mix finished',
          body: '${formatErg(r.denomination, maxFrac: 4)} delivered after ${r.roundsDone} '
              '${r.roundsDone == 1 ? 'round' : 'rounds'}',
        );
      } else if (r.roundsDone > before) {
        await _announceRound(r);
      }
    } catch (e) {
      r.lastError = e.toString();
    }
  }

  Future<void> _announceRound(MixRecord r) => _gw.notify(
        title: 'Mix round ${r.roundsDone} of ${r.roundsTarget} done',
        body: '${formatErg(r.denomination, maxFrac: 4)} is still mixing',
      );

  /// Withdraw or reclaim now. Broadcasts and records the result.
  Future<String> leave(MixRecord r, {String? destinationAddress}) async {
    if (!r.inPool || r.boxId == null) throw StateError('This mix has nothing in the pool');
    if (destinationAddress == null && r.destinationErgoTree.isEmpty) {
      throw StateError('Choose where the money should go');
    }
    // Exclusive with the tick: both would try to spend the same box, and
    // whichever lost on the node must not be the state that survives.
    return _exclusive(() async {
      final snap = await snapshot(ownBoxIds: [r.boxId!]);
      final raw =
          await _gw.leave(jsonEncode(r.state), snap.json, destinationAddress, _gw.nodeUrl, _now);
      final result = (jsonDecode(raw) as Map).cast<String, dynamic>();
      r.state = (result['state'] as Map).cast<String, dynamic>();
      r.lastError = null;
      r.lastCheckedAt = _clock();
      await _persist();
      return result['tx_id'] as String? ?? '';
    });
  }

  /// Find mixes of this wallet the records do not know about, from the
  /// seed and every unspent pool box. Returns how many were added.
  Future<int> recover() async {
    if (!_gw.isUnlocked || _walletId == null) return 0;
    return _exclusive(() async {
      final snap = await snapshot(allFullBoxes: true);
      final found = (jsonDecode(await _gw.recover(snap.json, _now)) as List)
          .map((m) => MixRecord(state: (m as Map).cast<String, dynamic>()))
          .toList();
      final known = {for (final r in records) r.mixId: r};
      final fresh = <MixRecord>[];
      var reconciled = 0;
      for (final f in found) {
        final have = known[f.mixId];
        if (have == null) {
          fresh.add(f);
        } else if (have.pending) {
          // The chain knows more than we do: the entry went out and the
          // record never heard. Take the chain's phase, keep what only we
          // know (destination, rounds wanted).
          have.state = {
            ...f.state,
            'destination_ergo_tree': have.destinationErgoTree,
            'rounds_target': have.roundsTarget,
            'level': have.state['level'] ?? f.state['level'],
          };
          have.entryAttempt = null;
          have.lastError = null;
          reconciled++;
        }
      }
      if (fresh.isEmpty && reconciled == 0) return 0;
      records = [...fresh, ...records];
      // A recovered index is taken: nothing new may derive on it.
      final prefs = await SharedPreferences.getInstance();
      for (final r in fresh) {
        if (r.mixId + 1 > _nextId) _nextId = r.mixId + 1;
      }
      await prefs.setInt(_nextIdKey(_walletId!), _nextId);
      await _persist();
      return fresh.length + reconciled;
    });
  }
}

final mixService = MixService();
