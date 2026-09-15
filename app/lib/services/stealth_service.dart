import 'dart:async';

import 'dart:convert';

import '../format.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/frb_generated.dart';
import 'network_controller.dart';
import 'stealth_identities.dart';
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
    this.ergoTree = '',
    this.identity = 0,
  });

  final String boxId;
  final String transactionId;
  final int valueNanoErg;
  final int creationHeight;
  final List<StealthToken> tokens;

  /// The one-time script, used to retire a self-change record once spent.
  final String ergoTree;

  /// Which stealth identity of this wallet was paid.
  final int identity;

  factory StealthOwnedBox.fromJson(Map<String, dynamic> json) => StealthOwnedBox(
        boxId: json['box_id']?.toString() ?? '',
        transactionId: json['transaction_id']?.toString() ?? '',
        valueNanoErg: (json['value_nano_erg'] as num?)?.toInt() ?? 0,
        creationHeight: (json['creation_height'] as num?)?.toInt() ?? 0,
        ergoTree: json['ergo_tree']?.toString() ?? '',
        identity: (json['identity'] as num?)?.toInt() ?? 0,
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

/// The outcome of a restore-time search for funded stealth identities.
///
/// Deliberately three-valued. "Searched, found nothing" is reassuring;
/// "could not search" is not, and a user checking whether a restore recovered
/// their money must be able to tell the two apart.
class StealthDiscovery {
  /// The search ran over a complete box list. [adopted] may be empty.
  const StealthDiscovery.found(this.adopted)
      : error = null,
        superseded = false;

  /// The search could not run, or ran on data too partial to conclude from.
  const StealthDiscovery.failed(String this.error)
      : adopted = const [],
        superseded = false;

  /// The wallet changed underneath the search, so its answer is void. Not a
  /// failure to report: whatever replaced it will run its own search.
  const StealthDiscovery.superseded()
      : adopted = const [],
        error = null,
        superseded = true;

  /// Indices newly adopted into the identity list.
  final List<int> adopted;

  /// Why the search could not conclude, or null if it did.
  final String? error;

  final bool superseded;

  /// True only when the search actually covered the whole box list.
  bool get isComplete => error == null && !superseded;
}

/// What one stealth identity holds, as the last scan saw it.
class StealthIdentityBalance {
  const StealthIdentityBalance({
    required this.index,
    required this.ownedCount,
    required this.totalNanoErg,
    required this.tokens,
  });

  final int index;
  final int ownedCount;
  final int totalNanoErg;
  final List<StealthToken> tokens;

  static StealthIdentityBalance fromJson(Map<String, dynamic> json) =>
      StealthIdentityBalance(
        index: (json['index'] as num?)?.toInt() ?? 0,
        ownedCount: (json['owned_count'] as num?)?.toInt() ?? 0,
        totalNanoErg: (json['total_nano_erg'] as num?)?.toInt() ?? 0,
        tokens: [
          for (final t in (json['tokens'] as List? ?? const []))
            if (t is Map)
              StealthToken(
                id: t['token_id']?.toString() ?? '',
                amount:
                    BigInt.tryParse(t['amount']?.toString() ?? '') ?? BigInt.zero,
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
    this.identities = const [],
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

  /// One row per identity that was scanned, funded or not.
  final List<StealthIdentityBalance> identities;

  bool get isEmpty => ownedCount == 0;

  /// What identity [index] holds, or a zero row if it was not scanned.
  ///
  /// A result carrying no per-identity rows came from a scan that knew only
  /// one identity, so its wallet-wide totals *are* identity 0's. Reporting
  /// zero there would hide real funds from the balance line and take the
  /// sweep button away with them.
  StealthIdentityBalance balanceOf(int index) {
    if (identities.isEmpty) {
      return StealthIdentityBalance(
        index: index,
        ownedCount: index == 0 ? ownedCount : 0,
        totalNanoErg: index == 0 ? totalNanoErg : 0,
        tokens: index == 0 ? tokens : const [],
      );
    }
    return identities.firstWhere(
      (i) => i.index == index,
      orElse: () => StealthIdentityBalance(
        index: index,
        ownedCount: 0,
        totalNanoErg: 0,
        tokens: const [],
      ),
    );
  }

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
        identities: [
          for (final i in (json['identities'] as List? ?? const []))
            if (i is Map)
              StealthIdentityBalance.fromJson(i.cast<String, dynamic>()),
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
  StealthService({StealthBoxFetcher? fetcher, WalletService? wallet})
      : _fetch = fetcher ?? _httpFetchStealthBoxes,
        _wallet = wallet ?? walletService;

  static const _enabledKey = 'argus_stealth_scan_enabled';

  final StealthBoxFetcher _fetch;
  final WalletService _wallet;

  /// Whether each sync queries the explorer for stealth boxes. Default on.
  bool scanEnabled = true;

  /// The wallet's published `stealth…` string for the default identity, or
  /// null while locked. Kept as the plain `address` it always was: the
  /// balance card, the change target and every existing caller mean this one.
  String? address;

  /// Every stealth identity of the active wallet, lowest index first.
  /// Always holds at least identity 0.
  List<StealthIdentity> identities = const [
    StealthIdentity(index: 0, label: ''),
  ];

  /// Published string per identity index, filled in as they are derived.
  final Map<int, String> _addressByIdentity = {};

  /// The published string for [index], or null if it has not been derived
  /// yet (or the wallet is locked).
  String? addressOf(int index) =>
      index == 0 ? address ?? _addressByIdentity[0] : _addressByIdentity[index];

  /// How many identities the wallet handle should scan with.
  int get frontier => StealthIdentityStore.frontierOf(identities);

  /// True once the user has more than the one identity every wallet has, so
  /// the UI can stay exactly as it was for everyone else.
  bool get hasMultipleIdentities => identities.length > 1;

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
    identities = const [StealthIdentity(index: 0, label: '')];
    _identitiesLoaded = false;
    _addressByIdentity.clear();
    lastScan = null;
    lastScanFailed = false;
    _lastBoxesJson = null;
    notifyListeners();
  }

  /// Load the persisted identity list, tell the wallet handle about it, and
  /// derive each published string.
  ///
  /// Call after unlock and before the first scan: until the handle knows the
  /// frontier it scans with identity 0 alone, which would report funds on a
  /// later identity as missing rather than as someone else's.
  Future<List<StealthIdentity>> loadIdentities() async {
    final walletId = _wallet.activeWalletId;
    if (walletId == null || !_wallet.isUnlocked) return identities;
    final gen = _generation;
    final loaded = await StealthIdentityStore.load(walletId);
    if (gen != _generation) return identities;
    identities = loaded;
    // Only once the handle has actually accepted the frontier. If that call
    // failed, the flag stays false so the next scan retries instead of
    // scanning narrow for the rest of the session.
    _identitiesLoaded = await _syncFrontier(gen);
    if (gen != _generation) return identities;
    notifyListeners();
    return identities;
  }

  /// False until the persisted list has been read *and* pushed to the wallet
  /// handle for the current wallet. [scan] checks it rather than trusting a
  /// call site to have loaded first: scanning with a frontier of 1 when the
  /// user has more identities would report their funds as absent.
  bool _identitiesLoaded = false;

  /// Push the frontier into the handle and derive any string we are missing.
  ///
  /// Returns whether the handle now covers every identity we know about.
  /// False means a later scan would miss funds, so the caller must not treat
  /// the identities as loaded.
  Future<bool> _syncFrontier(int gen) async {
    if (!_wallet.isUnlocked) return false;
    try {
      await _wallet.stealthUseIdentity(frontier - 1);
    } catch (_) {
      // The handle keeps whatever frontier it had, so this session scans
      // narrow — the safe direction — but the caller must be able to retry.
      return false;
    }
    for (final id in identities) {
      if (gen != _generation) return false;
      if (_addressByIdentity.containsKey(id.index)) continue;
      try {
        final addr = await _wallet.stealthAddressAt(id.index);
        if (gen != _generation) return false;
        _addressByIdentity[id.index] = addr;
        if (id.index == 0) address = addr;
      } catch (_) {
        // A missing string costs a QR, not a detection: the frontier is
        // already in, so the scan still finds this identity's boxes. The row
        // shows as unavailable and the next load retries the derivation.
      }
    }
    return true;
  }

  /// Publish a new identity under [label] and start scanning for it.
  ///
  /// Returns the created identity; its string is available from [addressOf]
  /// once this completes.
  Future<StealthIdentity> addIdentity(String label) async {
    final walletId = _wallet.activeWalletId;
    if (walletId == null || !_wallet.isUnlocked) {
      throw StateError('Unlock the wallet to add a stealth address');
    }
    final gen = _generation;
    final created = await StealthIdentityStore.add(walletId, label);
    if (gen != _generation) return created;
    identities = [...identities, created]
      ..sort((a, b) => a.index.compareTo(b.index));
    await _syncFrontier(gen);
    if (gen != _generation) return created;
    notifyListeners();
    return created;
  }

  /// Rename an identity. The label is local metadata; the string does not
  /// change and anything already published stays valid.
  Future<void> renameIdentity(int index, String label) async {
    final walletId = _wallet.activeWalletId;
    if (walletId == null) return;
    final gen = _generation;
    await StealthIdentityStore.rename(walletId, index, label);
    if (gen != _generation) return;
    identities = [
      for (final i in identities)
        if (i.index == index) i.copyWith(label: label.trim()) else i,
    ];
    notifyListeners();
  }

  /// Restore-time discovery: find identities that hold funds but are not in
  /// this device's list, and adopt them.
  ///
  /// This exists because a stealth identity has no on-chain footprint until
  /// it is paid, so there is no gap-scan that terminates correctly. Only
  /// funded identities can be found — an identity that was published but
  /// never paid is simply re-derived the next time the user adds one, at the
  /// same index and so with the same string.
  ///
  /// Returns what was adopted, or why nothing could be concluded.
  ///
  /// "Looked everywhere and found nothing" and "could not look" must not
  /// collapse into the same answer: this runs at the moment a user is asking
  /// whether their money survived a restore, and an unreachable explorer
  /// reported as "no funds found" is the worst possible lie to tell there.
  Future<StealthDiscovery> discoverIdentities({String? explorerBase}) async {
    final walletId = _wallet.activeWalletId;
    if (walletId == null || !_wallet.isUnlocked) {
      return const StealthDiscovery.failed('Unlock the wallet first');
    }
    final gen = _generation;
    String body;
    try {
      body = _lastBoxesJson ??
          await _fetch(explorerBase ?? networkController.explorer);
    } catch (_) {
      return const StealthDiscovery.failed(
        'Could not reach the explorer to list stealth boxes',
      );
    }
    if (gen != _generation) return const StealthDiscovery.superseded();
    // A truncated list is not a complete view, so an identity missing from it
    // would be wrongly read as unfunded. Say that, rather than report a clean
    // sheet drawn from partial data.
    if (isTruncatedScan(body)) {
      return const StealthDiscovery.failed(
        'The stealth box list is larger than one scan can cover, so this '
        'search would be incomplete',
      );
    }

    final List<int> funded;
    try {
      final result = await _wallet.stealthDiscoverIdentities(body);
      funded = [
        for (final i in (result['funded'] as List? ?? const []))
          if (i is num) i.toInt(),
      ];
    } catch (_) {
      return const StealthDiscovery.failed('Could not search for stealth addresses');
    }
    if (gen != _generation) return const StealthDiscovery.superseded();

    final known = {for (final i in identities) i.index};
    final fresh = funded.where((i) => !known.contains(i)).toList()..sort();
    if (fresh.isEmpty) return const StealthDiscovery.found([]);

    identities = await StealthIdentityStore.merge(walletId, fresh);
    if (gen != _generation) return StealthDiscovery.found(fresh);
    await _syncFrontier(gen);
    if (gen != _generation) return StealthDiscovery.found(fresh);
    notifyListeners();
    return StealthDiscovery.found(fresh);
  }

  /// Loads (and caches) this wallet's published stealth string, and
  /// remembers it so it can be offered as a destination while the wallet
  /// is locked.
  Future<String?> loadAddress() async {
    if (!walletService.isUnlocked) return null;
    final gen = _generation;
    final walletId = walletService.activeWalletId;
    String? found;
    try {
      found = await walletService.stealthAddress();
    } catch (_) {
      found = null;
    }
    if (gen != _generation) return null;
    address = found;
    if (found != null) _addressByIdentity[0] = found;
    if (found != null && walletId != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('$_addressPrefix$walletId', found);
      } catch (_) {
        // A picker without this wallet's stealth address is no loss.
      }
    }
    notifyListeners();
    return address;
  }

  static const _addressPrefix = 'argus_stealth_address_v1_';

  /// The published stealth string last seen for each wallet, by wallet
  /// id. A wallet that never had its stealth address derived is absent.
  static Future<Map<String, String>> rememberedAddresses() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final k in prefs.getKeys())
        if (k.startsWith(_addressPrefix)) k.substring(_addressPrefix.length): prefs.getString(k) ?? '',
    }..removeWhere((_, v) => v.isEmpty);
  }

  /// Fetch the template box list and test it against our key.
  ///
  /// Never throws: an unreachable explorer sets [lastScanFailed] and leaves
  /// the previous result in place.
  Future<StealthScanResult?> scan({String? explorerBase}) async {
    if (!scanEnabled || !_wallet.isUnlocked) return null;
    // The handle must know every identity before the scan, or funds on a
    // later identity read as missing rather than as somebody else's.
    if (!_identitiesLoaded) await loadIdentities();
    final gen = _generation;
    try {
      final base = explorerBase ?? networkController.explorer;
      final body = await _fetch(base);
      if (isTruncatedScan(body)) {
        // Partial data would read as a smaller balance than the truth.
        throw StateError('stealth box list exceeded the scan cap');
      }
      final result =
          StealthScanResult.fromJson(await _wallet.stealthScan(body));
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

  /// Prepare a sweep of owned stealth boxes to [destinationAddress].
  ///
  /// Re-fetches the box list so the sweep never builds on a stale set.
  ///
  /// [onlyIdentity] limits the sweep to one identity. Leaving it null sweeps
  /// every identity into a single output, which puts their funds in one
  /// transaction and so links the contexts the user kept apart — offer that
  /// only when they have asked for it.
  Future<SendPreview> prepareSweep({
    required String destinationAddress,
    String? nodeUrl,
    int? feeNanoErg,
    int? onlyIdentity,
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
      onlyIdentity: onlyIdentity,
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

  /// A fresh one-time address to send our own change to. A box paid to it
  /// carries the stealth payment script, so the template scan finds it
  /// like any other stealth receipt and no list of ours has to track it.
  Future<String?> newSelfChangeAddress() async {
    final mine = address;
    if (mine == null) return null;
    final raw = await walletService.stealthSelfChangeTarget(mine);
    final payTo = raw['address'] as String? ?? '';
    return payTo.isEmpty ? null : payTo;
  }

  /// Used by tests to prime the box list without a fetch.
  @visibleForTesting
  set cachedBoxesJson(String? value) => _lastBoxesJson = value;

  /// Used by widget tests to prime an identity list without a wallet handle.
  @visibleForTesting
  void debugSetIdentities(
    List<StealthIdentity> list,
    Map<int, String> addresses,
  ) {
    identities = list;
    _identitiesLoaded = true;
    _addressByIdentity
      ..clear()
      ..addAll(addresses);
    if (addresses.containsKey(0)) address = addresses[0];
    notifyListeners();
  }
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
          : t.withHolding(t.amount + s.amount,
              stealthAmount: t.stealthAmount + s.amount),
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
