/// Storage rent, as the wallet core reports it.
///
/// Ergo lets a miner charge a box that has not moved for four years
/// ([rentPeriodBlocks]): the fee is the voted `storageFeeFactor` times the
/// box's serialized size. The miner recreates the box with the rest, tokens
/// kept and a fresh four-year clock; a box holding no more than the fee may
/// be taken whole, tokens included. The rules and every figure come from the
/// Rust core (`wallet_core::rent`) and the user's own node; nothing here
/// computes a fee.
library;

import 'dart:convert';

import '../bridge/api/storage_rent.dart' as ffi;
import '../format.dart';

/// Blocks a box may sit untouched before rent can be charged: four years of
/// 2-minute blocks. Fixed by the protocol; the core reports it too.
const rentPeriodBlocks = 1051200;

/// `storageFeeFactor` at launch, nanoERG per byte per period. Stands in only
/// when the node cannot be read, and the UI then says "default rate".
const fallbackStorageFeeFactor = 1250000;

/// Target block interval, for turning blocks into approximate dates when
/// the core has not said otherwise ([RentParameters.blockSeconds]).
const targetBlockSeconds = 120;

/// How far ahead rent counts as due soon: such boxes are highlighted and
/// offered for cleanup first.
const rentSoonDays = 30;

/// [rentSoonDays] in blocks at the target interval (21,600).
const rentSoonBlocks = rentSoonDays * 24 * 3600 ~/ targetBlockSeconds;

/// What a collector may do with a box once rent is due.
enum RentCharge {
  /// Take the fee; the box is recreated with the rest, tokens kept.
  fee,

  /// The box holds no more than the fee: all of it may be taken, tokens
  /// included.
  wholeBox,

  /// The protocol's 32-bit fee product overflows for a box this large, so
  /// nothing can be charged under current rules.
  none;

  static RentCharge parse(Object? raw) => switch (raw) {
    'fee' => RentCharge.fee,
    'whole_box' => RentCharge.wholeBox,
    _ => RentCharge.none,
  };
}

/// The chain tip and fee factor rent is judged against.
class RentParameters {
  const RentParameters({
    required this.height,
    required this.storageFeeFactor,
    required this.factorFromNode,
    this.blockSeconds = targetBlockSeconds,
  });

  /// The launch factor at [height], for when the node cannot be read.
  const RentParameters.fallback({required this.height})
    : storageFeeFactor = fallbackStorageFeeFactor,
      factorFromNode = false,
      blockSeconds = targetBlockSeconds;

  factory RentParameters.fromJson(Map<String, dynamic> json) => RentParameters(
    height: _int(json['height']),
    storageFeeFactor: _int(json['storage_fee_factor']),
    factorFromNode: json['factor_from_node'] == true,
    blockSeconds: json['target_block_secs'] is num
        ? (json['target_block_secs'] as num).toInt()
        : targetBlockSeconds,
  );

  final int height;
  final int storageFeeFactor;

  /// False when the launch factor stands in for one the node did not give.
  final bool factorFromNode;

  /// Block interval the core dates rent by.
  final int blockSeconds;

  /// Largest box the fee can be computed for before the node's 32-bit
  /// product overflows (1,717 bytes at the launch factor).
  int get overflowBytes =>
      storageFeeFactor <= 0 ? 0 : 2147483647 ~/ storageFeeFactor;

  /// Why a box owes nothing: miners voted the rate to zero, or the box is
  /// past [overflowBytes].
  String get noChargeReason => storageFeeFactor <= 0
      ? 'No storage rent is charged at the current rate.'
      : 'No storage rent can be charged on a box over '
            '${formatWithCommas(overflowBytes)} bytes under current rules.';

  /// "0.00125 ERG per byte".
  String get rateLabel =>
      '${formatErg(storageFeeFactor)} per byte${factorFromNode ? '' : ' (default rate)'}';
}

/// One box's rent position, judged at a [RentParameters.height].
class BoxRent {
  const BoxRent({
    required this.boxId,
    required this.valueNano,
    required this.creationHeight,
    required this.sizeBytes,
    required this.feeNano,
    required this.charge,
    required this.chargeNano,
    required this.dueHeight,
    required this.blocksUntilDue,
    required this.collectableNow,
  });

  factory BoxRent.fromJson(Map<String, dynamic> json) => BoxRent(
    boxId: json['box_id'] as String? ?? '',
    valueNano: _int(json['value_nano_erg']),
    creationHeight: _int(json['creation_height']),
    sizeBytes: _int(json['size_bytes']),
    feeNano: _int(json['fee_nano']),
    charge: RentCharge.parse(json['charge']),
    chargeNano: _int(json['charge_nano']),
    dueHeight: _int(json['due_height']),
    blocksUntilDue: _int(json['blocks_until_due']),
    collectableNow: json['collectable_now'] == true,
  );

  final String boxId;
  final int valueNano;
  final int creationHeight;
  final int sizeBytes;

  /// The node's fee; zero or below when it overflows ([RentCharge.none]).
  final int feeNano;
  final RentCharge charge;

  /// What a collector takes: the fee, the whole value, or nothing.
  final int chargeNano;
  final int dueHeight;

  /// Blocks from the tip to [dueHeight]; one or less is due now.
  final int blocksUntilDue;
  final bool collectableNow;

  /// The box holds too little to pay its rent: once due, all of it can be
  /// taken, tokens included.
  bool get atRisk => charge == RentCharge.wholeBox;

  /// Chargeable now or within [rentSoonDays].
  bool get dueSoon =>
      charge != RentCharge.none && blocksUntilDue <= rentSoonBlocks;

  /// Worth acting on: at risk, or due soon.
  bool get flagged => atRisk || dueSoon;
}

/// Rent for every box the node listed, keyed by box id.
class RentReport {
  const RentReport({
    required this.parameters,
    required this.boxes,
    this.unmeasured = 0,
  });

  factory RentReport.fromJson(Map<String, dynamic> json) {
    final boxes = <String, BoxRent>{};
    for (final item in json['boxes'] as List? ?? const []) {
      if (item is! Map) continue;
      final rent = BoxRent.fromJson(item.cast<String, dynamic>());
      if (rent.boxId.isNotEmpty) boxes[rent.boxId] = rent;
    }
    return RentReport(
      parameters: RentParameters.fromJson(json),
      boxes: Map.unmodifiable(boxes),
      unmeasured: _int(json['unmeasured']),
    );
  }

  final RentParameters parameters;
  final Map<String, BoxRent> boxes;

  /// Boxes the node listed that the core could not parse, so has no
  /// figures for.
  final int unmeasured;

  int get atRiskCount => boxes.values.where((b) => b.atRisk).length;
  int get dueSoonCount => boxes.values.where((b) => b.dueSoon).length;
}

/// One box an output will become, with its rent.
class OutputBoxRent {
  const OutputBoxRent({
    required this.valueNano,
    required this.tokenCount,
    required this.sizeBytes,
    required this.feeNano,
    required this.charge,
  });

  factory OutputBoxRent.fromJson(Map<String, dynamic> json) => OutputBoxRent(
    valueNano: _int(json['value_nano']),
    tokenCount: _int(json['token_count']),
    sizeBytes: _int(json['size_bytes']),
    feeNano: _int(json['fee_nano']),
    charge: RentCharge.parse(json['charge']),
  );

  final int valueNano;
  final int tokenCount;
  final int sizeBytes;
  final int feeNano;
  final RentCharge charge;
}

/// Rent a token-carrying output will owe if it is never moved.
class OutputRentEstimate {
  const OutputRentEstimate({
    required this.valueNano,
    required this.dueHeight,
    required this.suggestedNano,
    required this.boxes,
    required this.parameters,
  });

  factory OutputRentEstimate.fromJson(
    Map<String, dynamic> json,
    RentParameters parameters,
  ) {
    final boxes = [
      for (final b in json['boxes'] as List? ?? const [])
        if (b is Map) OutputBoxRent.fromJson(b.cast<String, dynamic>()),
    ];
    if (boxes.isEmpty) throw const FormatException('estimate without boxes');
    final suggested = json['suggested_nano_erg'];
    return OutputRentEstimate(
      valueNano: _int(json['value_nano_erg']),
      dueHeight: _int(json['due_height']),
      suggestedNano: suggested is num ? suggested.toInt() : null,
      boxes: List.unmodifiable(boxes),
      parameters: parameters,
    );
  }

  /// ERG the output will carry once raised to its size floor.
  final int valueNano;
  final int dueHeight;

  /// Recipient amount that pays one charge and keeps the minimum box value,
  /// or null when nothing can be charged.
  final int? suggestedNano;

  /// The boxes the builders create for it; usually one.
  final List<OutputBoxRent> boxes;
  final RentParameters parameters;

  OutputBoxRent get first => boxes.first;

  /// The protocol can charge the box the amount goes into.
  bool get chargeable => first.feeNano > 0;

  /// The box the amount goes into holds more than its rent.
  bool get covered => first.charge != RentCharge.wholeBox;

  /// [suggestedNano] is above what the output carries now.
  bool get belowSuggestion =>
      suggestedNano != null && valueNano < suggestedNano!;
}

/// Reads rent from the user's node through the wallet core. Never contacts
/// anything but the configured node.
class StorageRentService {
  StorageRentService({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// `/info` changes once a block; a short cache spares the node a read per
  /// screen open without letting the height drift far.
  static const parametersTtl = Duration(minutes: 2);

  RentParameters? _cached;
  String? _cachedFor;
  DateTime? _cachedAt;

  /// Tip and fee factor from the node at [nodeUrl], cached briefly.
  Future<RentParameters> parameters({String? nodeUrl}) async {
    final at = _cachedAt;
    if (_cached != null &&
        _cachedFor == nodeUrl &&
        at != null &&
        _clock().difference(at) < parametersTtl) {
      return _cached!;
    }
    final raw = await ffi.rentParameters(nodeUrl: nodeUrl);
    final parsed = RentParameters.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    _remember(parsed, nodeUrl);
    return parsed;
  }

  /// [parameters], or the launch factor at [knownHeight] when the node
  /// cannot be read. Null when not even a height is known.
  Future<RentParameters?> parametersOrFallback({
    String? nodeUrl,
    int? knownHeight,
  }) async {
    try {
      return await parameters(nodeUrl: nodeUrl);
    } catch (_) {
      return knownHeight == null || knownHeight <= 0
          ? null
          : RentParameters.fallback(height: knownHeight);
    }
  }

  /// Rent for every confirmed box at [addresses]. Throws when the node
  /// cannot be read; there is no meaningful fallback for box sizes.
  Future<RentReport> report(List<String> addresses, {String? nodeUrl}) async {
    final raw = await ffi.boxRentReport(addresses: addresses, nodeUrl: nodeUrl);
    final report = RentReport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    _remember(report.parameters, nodeUrl);
    return report;
  }

  /// What an output paying [address] [valueNano] and [tokens] (id → raw
  /// amount) will owe, or null when it cannot be estimated (an address the
  /// core cannot read, for one).
  OutputRentEstimate? estimateOutput({
    required String address,
    required int valueNano,
    required Map<String, int> tokens,
    required RentParameters parameters,
  }) {
    try {
      final raw = ffi.outputRentEstimate(
        address: address,
        valueNano: valueNano,
        tokensJson: jsonEncode([
          for (final e in tokens.entries)
            {'token_id': e.key, 'amount': e.value},
        ]),
        height: parameters.height,
        storageFeeFactor: parameters.storageFeeFactor,
      );
      return OutputRentEstimate.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
        parameters,
      );
    } catch (_) {
      return null;
    }
  }

  void _remember(RentParameters parameters, String? nodeUrl) {
    _cached = parameters;
    _cachedFor = nodeUrl;
    _cachedAt = _clock();
  }
}

final storageRent = StorageRentService();

/// Approximate time [blocks] from [now] at [blockSeconds] a block.
DateTime approxTimeIn(
  int blocks, {
  DateTime? now,
  int blockSeconds = targetBlockSeconds,
}) => (now ?? DateTime.now()).add(Duration(seconds: blocks * blockSeconds));

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// When rent falls due, in words: "now", "in ~12 days", "~Mar 2030".
String rentWhen(
  int blocksUntilDue, {
  DateTime? now,
  int blockSeconds = targetBlockSeconds,
}) {
  if (blocksUntilDue <= 1) return 'now';
  final seconds = blocksUntilDue * blockSeconds;
  final days = (seconds / 86400).ceil();
  if (days <= 1) return 'within a day';
  if (days <= 60) return 'in ~$days days';
  final at = approxTimeIn(blocksUntilDue, now: now, blockSeconds: blockSeconds);
  return '~${_months[at.month - 1]} ${at.year}';
}

int _int(Object? raw) => switch (raw) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};
