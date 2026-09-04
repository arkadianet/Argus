import 'dart:async';

import 'dart:convert';

import '../format.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/frb_generated.dart';
import 'network_controller.dart';
import 'wallet_service.dart';

/// A token sitting in stealth boxes.
class StealthToken {
  const StealthToken({required this.id, required this.amount});
  final String id;
  final BigInt amount;
}

/// Outcome of one stealth scan.
/// One detected stealth box: enough to render a receipt without any
/// further lookup, since detection already read the creating transaction.
class StealthOwnedBox {
  const StealthOwnedBox({
    required this.boxId,
    required this.transactionId,
    required this.valueNanoErg,
    required this.creationHeight,
    required this.tokens,
  });

  final String boxId;
  final String transactionId;
  final int valueNanoErg;
  final int creationHeight;
  final List<StealthToken> tokens;

  factory StealthOwnedBox.fromJson(Map<String, dynamic> json) => StealthOwnedBox(
        boxId: json['box_id']?.toString() ?? '',
        transactionId: json['transaction_id']?.toString() ?? '',
        valueNanoErg: (json['value_nano_erg'] as num?)?.toInt() ?? 0,
        creationHeight: (json['creation_height'] as num?)?.toInt() ?? 0,
        tokens: [
          for (final a in (json['assets'] as List? ?? const []))
            if (a is Map)
              StealthToken(
                id: a['token_id']?.toString() ?? '',
                amount: BigInt.tryParse(a['amount']?.toString() ?? '') ?? BigInt.zero,
              ),
        ],
      );
}

class StealthScanResult {
  const StealthScanResult({
    required this.scanned,
    required this.ownedCount,
    required this.totalNanoErg,
    required this.tokens,
    required this.boxIds,
    this.boxes = const [],
  });

  /// How many stealth boxes the explorer returned in total.
  final int scanned;

  /// How many of them are ours.
  final int ownedCount;
  final int totalNanoErg;
  final List<StealthToken> tokens;
  final List<String> boxIds;

  /// Every owned box as detection saw it, for the activity list.
  final List<StealthOwnedBox> boxes;

  bool get isEmpty => ownedCount == 0;

  static const empty = StealthScanResult(
    scanned: 0,
    ownedCount: 0,
    totalNanoErg: 0,
    tokens: [],
    boxIds: [],
  );

  factory StealthScanResult.fromJson(Map<String, dynamic> json) =>
      StealthScanResult(
        scanned: (json['scanned'] as num?)?.toInt() ?? 0,
        ownedCount: (json['owned_count'] as num?)?.toInt() ?? 0,
        totalNanoErg: (json['total_nano_erg'] as num?)?.toInt() ?? 0,
        tokens: [
          for (final t in (json['tokens'] as List? ?? const []))
            if (t is Map)
              StealthToken(
                id: t['token_id']?.toString() ?? '',
                amount: BigInt.tryParse(t['amount']?.toString() ?? '') ??
                    BigInt.zero,
              ),
        ],
        boxIds: [
          for (final b in (json['boxes'] as List? ?? const []))
            if (b is Map && b['box_id'] != null) b['box_id'].toString(),
        ],
        boxes: [
          for (final b in (json['boxes'] as List? ?? const []))
            if (b is Map && b['box_id'] != null)
              StealthOwnedBox.fromJson(b.cast<String, dynamic>()),
        ],
      );
}

/// Fetches the explorer's stealth box list. Injectable so tests never hit
/// the network.
typedef StealthBoxFetcher = Future<String> Function(String explorerBase);

/// One explorer page, so pagination can be tested without the network.
typedef StealthPageFetcher = Future<String> Function(String explorerBase, int offset);

Future<String> _httpFetchStealthPage(String explorerBase, int offset) async {
  final base = explorerBase.replaceAll(RegExp(r'/+$'), '');
  final hash = RustLib.instance.api.crateApiStealthTemplateHash();
  final uri = Uri.parse(
    '$base/api/v1/boxes/unspent/byErgoTreeTemplateHash/$hash'
    '?offset=$offset&limit=$boxPageLimit',
  );
  final res = await http.get(uri).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) {
    throw StateError('explorer returned HTTP ${res.statusCode}');
  }
  return res.body;
}

/// Boxes per request. The live set is tens of boxes; paging keeps a future
/// growth spurt from arriving as one huge response.
const boxPageLimit = 500;

/// Hard cap on a whole scan, so a pathological template set cannot pull
/// unbounded data onto a phone.
const boxScanCap = 5000;

/// Walks every page and returns one explorer-shaped body, de-duplicated by
/// box id. Stops at the last partial page, at [boxScanCap], or when the
/// explorer reports a total it has already delivered.
Future<String> fetchAllStealthBoxes(
  String explorerBase, {
  required StealthPageFetcher page,
}) async {
  final items = <String, Map<String, dynamic>>{};
  var offset = 0;
  // Bounded by pages, not by unique ids: an explorer that keeps returning
  // the same boxes must not spin this loop forever.
  final maxPages = (boxScanCap / boxPageLimit).ceil();
  var truncated = false;
  for (var pageNo = 0; pageNo < maxPages && items.length < boxScanCap; pageNo++) {
    final body = jsonDecode(await page(explorerBase, offset));
    final list = body is Map
        ? (body['items'] as List? ?? const [])
        : (body is List ? body : const []);
    for (final e in list) {
      if (e is Map && e['boxId'] != null) {
        items[e['boxId'].toString()] = e.cast<String, dynamic>();
      }
    }
    final total = body is Map ? (body['total'] as num?)?.toInt() : null;
    if (list.length < boxPageLimit) break;
    offset += list.length;
    if (total != null && offset >= total) break;
    if (pageNo == maxPages - 1 || items.length >= boxScanCap) truncated = true;
  }
  // A scan that stopped at the cap is not a complete view of the set. Say
  // so, so the balance stays "unknown" and a sweep is blocked rather than
  // quietly leaving owned boxes behind.
  return jsonEncode({
    'items': items.values.toList(),
    'total': items.length,
    if (truncated) 'argus_truncated': true,
  });
}

Future<String> _httpFetchStealthBoxes(String explorerBase) =>
    fetchAllStealthBoxes(explorerBase, page: _httpFetchStealthPage);

/// Owns the stealth-address feature: the published string, the opt-in scan
/// switch, and the last scan result.
///
/// Scanning is best effort by design. When the explorer is unreachable the
/// result becomes "unknown" rather than an error: a wallet sync must never
/// fail because the stealth lookup did.
class StealthService extends ChangeNotifier {
  StealthService({StealthBoxFetcher? fetcher})
      : _fetch = fetcher ?? _httpFetchStealthBoxes;

  static const _enabledKey = 'argus_stealth_scan_enabled';

  final StealthBoxFetcher _fetch;

  /// Whether each sync queries the explorer for stealth boxes. Default on.
  bool scanEnabled = true;

  /// The wallet's published `stealth…` string, or null while locked.
  String? address;

  /// Last successful scan. Null means "never scanned this session".
  StealthScanResult? lastScan;

  /// True when the last attempt could not reach the explorer, so the
  /// stealth balance shown (if any) is stale or unknown.
  bool lastScanFailed = false;

  /// The raw explorer body from the last successful fetch, kept so a sweep
  /// can be prepared without a second round trip.
  String? _lastBoxesJson;

  bool get hasFunds => (lastScan?.ownedCount ?? 0) > 0;

  int get balanceNano => lastScan?.totalNanoErg ?? 0;

  /// True when we have never managed a scan, so the UI should say the
  /// stealth balance is unknown rather than zero.
  bool get balanceUnknown => lastScan == null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    scanEnabled = prefs.getBool(_enabledKey) ?? true;
    notifyListeners();
  }

  Future<void> setScanEnabled(bool value) async {
    if (value == scanEnabled) return;
    // Persist first: a failed write must not leave the UI claiming a
    // setting that will not survive a restart.
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setBool(_enabledKey, value);
    if (!ok) throw StateError('Failed to persist stealth scan setting');
    scanEnabled = value;
    if (!value) {
      lastScan = null;
      lastScanFailed = false;
      _lastBoxesJson = null;
    }
    notifyListeners();
  }

  /// Bumped by [reset] so a request started for the previous wallet can
  /// never publish its address or scan into the new session.
  int _generation = 0;

  /// Clears everything derived from the unlocked wallet.
  void reset() {
    _generation++;
    address = null;
    lastScan = null;
    lastScanFailed = false;
    _lastBoxesJson = null;
    notifyListeners();
  }

  /// Loads (and caches) this wallet's published stealth string.
  Future<String?> loadAddress() async {
    if (!walletService.isUnlocked) return null;
    final gen = _generation;
    String? found;
    try {
      found = await walletService.stealthAddress();
    } catch (_) {
      found = null;
    }
    if (gen != _generation) return null;
    address = found;
    notifyListeners();
    return address;
  }

  /// Fetch the template box list and test it against our key.
  ///
  /// Never throws: an unreachable explorer sets [lastScanFailed] and leaves
  /// the previous result in place.
  Future<StealthScanResult?> scan({String? explorerBase}) async {
    if (!scanEnabled || !walletService.isUnlocked) return null;
    final gen = _generation;
    try {
      final body = await _fetch(explorerBase ?? networkController.explorer);
      if (isTruncatedScan(body)) {
        // Partial data would read as a smaller balance than the truth.
        throw StateError('stealth box list exceeded the scan cap');
      }
      final result =
          StealthScanResult.fromJson(await walletService.stealthScan(body));
      if (gen != _generation) return null;
      _lastBoxesJson = body;
      lastScan = result;
      lastScanFailed = false;
      notifyListeners();
      return result;
    } catch (_) {
      if (gen != _generation) return null;
      lastScanFailed = true;
      notifyListeners();
      return null;
    }
  }

  /// Prepare a sweep of every owned stealth box to [destinationAddress].
  ///
  /// Re-fetches the box list so the sweep never builds on a stale set.
  Future<SendPreview> prepareSweep({
    required String destinationAddress,
    String? nodeUrl,
    int? feeNanoErg,
  }) async {
    var body = _lastBoxesJson;
    try {
      body = await _fetch(networkController.explorer);
      _lastBoxesJson = body;
    } catch (_) {
      // Fall back to the last body we saw; the node still validates the
      // inputs, so a spent box fails loudly at broadcast instead of
      // silently sweeping nothing.
    }
    if (body == null) {
      throw StateError('Could not reach the explorer to list stealth boxes');
    }
    if (isTruncatedScan(body)) {
      // Sweeping a partial list would leave owned boxes behind and, worse,
      // report a smaller total than the user actually holds.
      throw StateError(
        'The stealth box list is larger than one scan can cover; '
        'sweeping is blocked until it can be read in full',
      );
    }
    return walletService.prepareStealthSweep(
      explorerBoxesJson: body,
      destinationAddress: destinationAddress,
      nodeUrl: nodeUrl,
      feeNanoErg: feeNanoErg,
    );
  }

  /// The explorer body a send can offer as extra spendable inputs, or null
  /// when the scan is off, has not run, or was truncated.
  String? get spendableBoxesJson {
    final body = _lastBoxesJson;
    // A failed scan leaves the previous body in place so the balance can
    // still be reported as "unknown"; it must not be spent from, because a
    // box in it may already have been spent elsewhere.
    if (!scanEnabled || lastScanFailed || body == null || isTruncatedScan(body)) {
      return null;
    }
    return body;
  }

  /// Used by tests to prime the box list without a fetch.
  @visibleForTesting
  set cachedBoxesJson(String? value) => _lastBoxesJson = value;
}

/// True for a well-formed `stealth…` string (prefix, Base58, checksum).
bool isStealthAddress(String value) =>
    RustLib.instance.api.crateApiValidateStealthAddress(address: value.trim());

/// A fresh, unlinkable one-time payment address for a stealth recipient.
/// Call once per payment, at build time.
Future<String> stealthPaymentAddress(String stealthAddress) =>
    RustLib.instance.api
        .crateApiStealthPaymentAddress(stealthAddress: stealthAddress.trim());

/// Merge spendable holdings with stealth ones so the asset list shows the
/// whole position, each entry knowing how much of it sits in stealth boxes.
List<TokenBalance> mergeStealthTokens(
  List<TokenBalance> spendable,
  List<TokenBalance> stealth,
) {
  if (stealth.isEmpty) return spendable;
  final out = <TokenBalance>[];
  final byId = {for (final t in stealth) t.id: t};
  for (final t in spendable) {
    final s = byId.remove(t.id);
    out.add(
      s == null
          ? t
          : TokenBalance(
              id: t.id,
              amount: t.amount + s.amount,
              name: t.name,
              decimals: t.decimals,
              emissionAmount: t.emissionAmount,
              iconUrl: t.iconUrl,
              stealthAmount: t.stealthAmount + s.amount,
            ),
    );
  }
  out.addAll(byId.values);
  return out;
}

/// Shortens a stealth string for display: `stealth3Qm…7Fk`.
String shortStealth(String value, {int head = 10, int tail = 4}) {
  final v = value.trim();
  if (v.length <= head + tail + 1) return v;
  return '${v.substring(0, head)}…${v.substring(v.length - tail)}';
}

/// Explorer JSON body → owned-box scan is done in Rust; this is only the
/// bookkeeping singleton the UI listens to.
final stealthService = StealthService();

/// True when [body] came from a scan that stopped at [boxScanCap] and so
/// does not describe the whole template set.
bool isTruncatedScan(String body) {
  try {
    final v = jsonDecode(body);
    return v is Map && v['argus_truncated'] == true;
  } catch (_) {
    return false;
  }
}

/// Activity rows for stealth receipts, in the same shape the transaction
/// list already renders. One row per creating transaction: several boxes
/// can arrive together, and the user saw one payment.
///
/// Marked `stealth: true` so a row can say where the funds sit, and so the
/// sweep that later moves them is not mistaken for a second receipt.
List<Map<String, dynamic>> stealthActivityRows(List<StealthOwnedBox> boxes) {
  final byTx = <String, List<StealthOwnedBox>>{};
  for (final b in boxes) {
    if (b.transactionId.isEmpty) continue;
    byTx.putIfAbsent(b.transactionId, () => []).add(b);
  }
  final rows = <Map<String, dynamic>>[];
  byTx.forEach((txId, group) {
    var nano = 0;
    final tokens = <String, BigInt>{};
    var height = 0;
    for (final b in group) {
      nano += b.valueNanoErg;
      if (b.creationHeight > height) height = b.creationHeight;
      for (final t in b.tokens) {
        tokens[t.id] = (tokens[t.id] ?? BigInt.zero) + t.amount;
      }
    }
    rows.add({
      'tx_id': txId,
      'height': height,
      'timestamp': 0,
      'value_nano_erg': nano,
      'token_ids': tokens.keys.toList(),
      'tokens_received': [
        for (final e in tokens.entries)
          {'token_id': e.key, 'amount': e.value.toString()},
      ],
      'tokens_sent': const [],
      'confirmed': true,
      'stealth': true,
    });
  });
  rows.sort((a, b) => (b['height'] as int).compareTo(a['height'] as int));
  return rows;
}

/// Merges stealth receipts into the address-derived history, newest first,
/// without duplicating a transaction the address history already covers.
List<Map<String, dynamic>> mergeStealthActivity(
  List<Map<String, dynamic>> history,
  List<Map<String, dynamic>> stealthRows,
) {
  if (stealthRows.isEmpty) return history;
  final known = {for (final t in history) t['tx_id']?.toString()};
  final out = [...history, ...stealthRows.where((r) => !known.contains(r['tx_id']))];
  out.sort((a, b) {
    final ha = (a['height'] as num?)?.toInt() ?? 0;
    final hb = (b['height'] as num?)?.toInt() ?? 0;
    return hb.compareTo(ha);
  });
  return out;
}

/// What one wallet row should show. The active row must agree with the
/// portfolio card, which counts stealth funds, while a locked row can only
/// report its cached spendable snapshot.
({int? balanceNano, String? note}) walletRowDisplay({
  required bool isActive,
  required int? spendableNano,
  required int stealthNano,
  required int? cachedNano,
  required bool hidden,
}) {
  if (!isActive) return (balanceNano: cachedNano, note: null);
  final total = spendableNano == null ? null : spendableNano + stealthNano;
  final note = stealthNano > 0 && !hidden
      ? 'includes ${formatErg(stealthNano, maxFrac: 4)} stealth'
      : null;
  return (balanceNano: total, note: note);
}

/// Detected stealth boxes as send inputs. Their `address` is null, which is
/// how the picker and the privacy warning tell them apart from boxes that
/// sit on an address of this wallet.
List<InputBoxInput> stealthInputBoxes(StealthScanResult? scan) {
  if (scan == null) return const [];
  return [
    for (final b in scan.boxes)
      InputBoxInput(
        boxId: b.boxId,
        valueNanoErg: BigInt.from(b.valueNanoErg),
        creationHeight: b.creationHeight,
        address: null,
        assets: [
          for (final t in b.tokens)
            InputAsset(tokenId: t.id, amount: t.amount),
        ],
      ),
  ];
}

/// True for a box the picker should mark as stealth.
bool isStealthInputBox(InputBoxInput box, StealthScanResult? scan) =>
    scan != null && scan.boxIds.contains(box.boxId);
