import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/frb_generated.dart';

class NodeEntry {
  String url;
  bool enabled;
  NodeEntry({required this.url, this.enabled = true});

  Map<String, dynamic> toJson() => {'url': url, 'enabled': enabled};

  factory NodeEntry.fromJson(Map<String, dynamic> json) {
    return NodeEntry(
      url: json['url'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

class NodeProbe {
  final String url;
  final bool ok;
  final int? height;
  final bool? extraIndex;
  final int? indexedHeight;
  final String? error;

  NodeProbe({
    required this.url,
    required this.ok,
    this.height,
    this.extraIndex,
    this.indexedHeight,
    this.error,
  });

  /// Blocks the extra index is behind the chain, when both are known.
  int? get indexLag =>
      height != null && indexedHeight != null ? height! - indexedHeight! : null;

  factory NodeProbe.fromJson(Map<String, dynamic> json) {
    return NodeProbe(
      url: json['url'] as String? ?? '',
      ok: json['ok'] == true,
      height: (json['height'] as num?)?.toInt(),
      extraIndex: json['extra_index'] as bool?,
      indexedHeight: (json['indexed_height'] as num?)?.toInt(),
      error: json['error'] as String?,
    );
  }
}

int? chainHeightFromInfo(Map<dynamic, dynamic> info) {
  final raw = info['fullHeight'] ?? info['headersHeight'];
  return raw is num ? raw.toInt() : null;
}

int? indexedHeightFromJson(Map<dynamic, dynamic> json) {
  final raw = json['indexedHeight'] ?? json['indexed_height'];
  return raw is num ? raw.toInt() : null;
}

String describeNode(NodeEntry node, NodeProbe? probe, {required bool active, bool preferred = false}) {
  final bits = <String>[
    if (!node.enabled) 'Off' else if (active) 'In use' else 'Standby',
    if (preferred && node.enabled) 'chosen',
  ];
  if (probe != null) {
    if (probe.extraIndex == true) {
      final lag = probe.indexLag;
      bits.add(lag != null && lag > 2 ? 'extraIndex, lag $lag' : 'extraIndex');
    } else if (probe.extraIndex == false) {
      bits.add('no extraIndex');
    }
    if (probe.height != null) bits.add('#${probe.height}');
    if (!probe.ok) bits.add('unreachable');
  }
  return bits.join('  ·  ');
}

/// Picks the node to use. The chosen node wins while it answers; otherwise
/// the best automatic candidate: reachable, with extraIndex, smallest index
/// lag, then the list order as the tie-break.
NodeProbe? chooseActive(List<NodeProbe> probes, {String? preferred}) {
  if (preferred != null) {
    for (final p in probes) {
      if (p.url == preferred && p.ok) return p;
    }
  }
  final ok = probes.where((p) => p.ok).toList();
  if (ok.isEmpty) return null;
  int score(NodeProbe p) {
    if (p.extraIndex != true) return 1 << 30;
    return p.indexLag ?? (1 << 20);
  }
  ok.sort((a, b) => score(a).compareTo(score(b)));
  return ok.first;
}

/// REST endpoints advertised by an Ergo node's `/peers/all` list, HTTPS
/// only, deduplicated, excluding [known].
List<String> restApiUrlsFromPeers(List<dynamic> peers, {Iterable<String> known = const []}) {
  final seen = <String>{...known};
  final out = <String>[];
  for (final p in peers) {
    if (p is! Map) continue;
    final raw = p['restApiUrl']?.toString() ?? '';
    final clean = normalizeNodeUrl(raw);
    if (clean == null || !clean.startsWith('https://')) continue;
    if (seen.add(clean)) out.add(clean);
  }
  return out;
}

class NetworkController extends ChangeNotifier {
  static const defaultNodes = [
    'https://ergo-node.eutxo.de',
    'https://ergo-node.zoomout.io',
    'https://ergo1.oette.info',
    'https://node.sigmaspace.io',
  ];
  static const defaultExplorer = 'https://api.sigmaspace.io';
  static const _nodesKey = 'argus_nodes';
  static const _explorerKey = 'argus_explorer';
  static const _lastGoodKey = 'argus_last_good_node';
  static const _preferredKey = 'argus_preferred_node';

  /// Node the user chose in Settings; null means automatic selection.
  String? preferredUrl;

  /// Nodes found via the active node's peer list, not yet in [nodes].
  List<NodeProbe> discovered = const [];
  bool discovering = false;

  List<NodeEntry> nodes = [
    for (final url in defaultNodes) NodeEntry(url: url),
  ];
  String explorer = defaultExplorer;
  String? activeUrl;
  String? lastGood;
  int? height;
  bool probing = false;
  double? usdPerErg;

  /// Display currency for fiat conversions (CoinGecko vs_currency code).
  String fiatCode = 'usd';
  double? fiatPerErg;

  static const fiatOptions = <String, String>{
    'usd': r'$',
    'eur': '€',
    'gbp': '£',
    'aud': 'A\$',
    'cad': 'C\$',
    'jpy': '¥',
  };

  String get fiatSymbol => fiatOptions[fiatCode] ?? '\$';

  /// Formatted fiat line for a nanoERG balance, or null when the price is
  /// unknown.
  String? fiatText(int? nano) {
    final rate = fiatPerErg;
    if (rate == null || nano == null) return null;
    final digits = fiatCode == 'jpy' ? 0 : 2;
    return '≈ $fiatSymbol${(nano / 1e9 * rate).toStringAsFixed(digits)} '
        '${fiatCode.toUpperCase()}';
  }

  Future<void> setFiatCurrency(String code) async {
    if (!fiatOptions.containsKey(code) || code == fiatCode) return;
    fiatCode = code;
    fiatPerErg = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fiatPrefKey, code);
    await refreshPrice(force: true);
  }

  Future<void> _loadFiatCurrency() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_fiatPrefKey);
    if (saved != null && fiatOptions.containsKey(saved)) {
      fiatCode = saved;
    }
  }

  final Map<String, NodeProbe> probes = {};

  List<String> get enabledUrls =>
      nodes.where((n) => n.enabled && n.url.isNotEmpty).map((n) => n.url).toList();

  /// Chosen node first, then the last one that worked, then list order.
  List<String> get orderedUrls =>
      probeOrder(probeOrder(enabledUrls, lastGood), activeUrl ?? preferredUrl);

  String get statusLabel {
    if (activeUrl == null || height == null) return 'Offline';
    final host = Uri.tryParse(activeUrl!)?.host;
    return '${(host != null && host.isNotEmpty) ? host : activeUrl}  ·  #$height';
  }

  String explorerTx(String txId) => explorerTransactionUrl(explorer, txId);
  String explorerToken(String tokenId) => explorerTokenUrl(explorer, tokenId);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_nodesKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        final parsed = list
            .whereType<Map>()
            .map((e) => NodeEntry.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.url.isNotEmpty)
            .toList();
        if (parsed.isNotEmpty) nodes = parsed;
      } catch (_) {}
    }
    explorer = prefs.getString(_explorerKey) ?? defaultExplorer;
    lastGood = prefs.getString(_lastGoodKey);
    preferredUrl = prefs.getString(_preferredKey);
    await _loadFiatCurrency();
    try {
      await apply();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nodesKey, jsonEncode(nodes.map((n) => n.toJson()).toList()));
    await prefs.setString(_explorerKey, explorer);
    if (lastGood != null && lastGood!.isNotEmpty) {
      await prefs.setString(_lastGoodKey, lastGood!);
    }
    if (preferredUrl == null) {
      await prefs.remove(_preferredKey);
    } else {
      await prefs.setString(_preferredKey, preferredUrl!);
    }
  }

  Future<void> setPreferredNode(String? url) async {
    if (url == preferredUrl) return;
    preferredUrl = url;
    notifyListeners();
    await persist();
    await probe();
  }

  /// Asks the active node for peers that advertise a REST URL and probes
  /// them. Results land in [discovered] for the user to add.
  Future<void> discoverNodes() async {
    final base = activeUrl;
    if (base == null || discovering) return;
    discovering = true;
    notifyListeners();
    try {
      final res = await http.get(Uri.parse('$base/peers/all')).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final peers = jsonDecode(res.body);
      final urls = restApiUrlsFromPeers(peers is List ? peers : const [], known: nodes.map((n) => n.url));
      final results = await Future.wait(urls.take(40).map(probeNodeDetails));
      final good = results.where((p) => p.ok).toList();
      good.sort((a, b) {
        final ai = a.extraIndex == true ? 0 : 1;
        final bi = b.extraIndex == true ? 0 : 1;
        if (ai != bi) return ai - bi;
        return (a.indexLag ?? 1 << 20).compareTo(b.indexLag ?? 1 << 20);
      });
      discovered = good;
    } catch (_) {
      discovered = const [];
    } finally {
      discovering = false;
      notifyListeners();
    }
  }

  Future<void> apply() async {
    final urls = orderedUrls;
    if (urls.isEmpty) return;
    await RustLib.instance.api.crateApiSetNetwork(
      nodeUrls: urls,
      explorerUrl: explorer,
    );
  }

  Future<void> probe() async {
    if (probing) return;
    probing = true;
    notifyListeners();
    try {
      await apply();
      final urls = orderedUrls;
      final results = await Future.wait(urls.map(probeNodeDetails));
      probes
        ..clear()
        ..addEntries(results.map((p) => MapEntry(p.url, p)));
      final chosen = chooseActive(results, preferred: preferredUrl);
      activeUrl = chosen?.url;
      height = chosen?.height;
      if (activeUrl != null) {
        lastGood = activeUrl;
        await persist();
        // Rust takes the list in order and uses the first that answers.
        await apply();
      }
      try {
        await RustLib.instance.api.crateApiProbeNetwork();
      } catch (_) {}
    } catch (_) {
      activeUrl = null;
      height = null;
    } finally {
      probing = false;
      notifyListeners();
    }
    await refreshPrice();
  }

  Future<NodeProbe> probeNodeDetails(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/$'), '');
    try {
      final infoRes = await http
          .get(Uri.parse('$clean/info'))
          .timeout(const Duration(seconds: 8));
      if (infoRes.statusCode != 200) {
        return NodeProbe(url: clean, ok: false, error: 'HTTP ${infoRes.statusCode}');
      }
      final info = jsonDecode(infoRes.body);
      if (info is! Map) {
        return NodeProbe(url: clean, ok: false, error: 'bad /info');
      }
      final chain = chainHeightFromInfo(info);
      bool? extraIndex;
      int? indexed;
      try {
        final idxRes = await http
            .get(Uri.parse('$clean/blockchain/indexedHeight'))
            .timeout(const Duration(seconds: 6));
        if (idxRes.statusCode == 200) {
          final idx = jsonDecode(idxRes.body);
          if (idx is Map) {
            indexed = indexedHeightFromJson(idx);
            extraIndex = indexed == null ? null : true;
          }
        } else if (idxRes.statusCode == 404) {
          extraIndex = false;
        }
      } catch (_) {}
      return NodeProbe(
        url: clean,
        ok: chain != null,
        height: chain,
        extraIndex: extraIndex,
        indexedHeight: indexed,
        error: chain == null ? 'no height' : null,
      );
    } catch (e) {
      return NodeProbe(url: clean, ok: false, error: e.toString());
    }
  }

  static const _fiatPrefKey = 'argus_fiat_currency';

  /// Installed by the token pricer; it owns every price fetch and reports
  /// the ERG rate back through [setErgRate].
  Future<void> Function({bool force})? priceRefresher;

  Future<void> refreshPrice({bool force = false}) async {
    final r = priceRefresher;
    if (r == null) return;
    try {
      await r(force: force);
    } catch (_) {}
  }

  void setErgRate({required double? fiatPerErg, required double? usdPerErg}) {
    this.fiatPerErg = fiatPerErg;
    usdPerErg = usdPerErg;
    notifyListeners();
  }

  /// Formatted display-currency text for a USD amount, or null when the
  /// USD→display rate is unknown.
  String? fiatFromUsd(double? usd, {required double fiatPerUsd, int maxFrac = 2}) {
    if (usd == null) return null;
    final v = usd * fiatPerUsd;
    final digits = fiatCode == 'jpy' ? 0 : (v != 0 && v.abs() < 0.01 ? maxFrac : 2);
    return '≈ $fiatSymbol${v.toStringAsFixed(digits)}';
  }

  Future<String?> addNode(String url) async {
    final clean = normalizeNodeUrl(url);
    if (clean == null) return 'Enter https://host or http://ip:port';
    if (nodes.any((n) => n.url == clean)) return 'Node already added';
    nodes.add(NodeEntry(url: clean));
    discovered = discovered.where((p) => p.url != clean).toList();
    await persist();
    await probe();
    return null;
  }

  Future<void> removeNode(int index) async {
    if (index < 0 || index >= nodes.length) return;
    final enabled = enabledUrls;
    if (nodes[index].enabled && enabled.length <= 1) return;
    final removed = nodes.removeAt(index);
    if (removed.url == preferredUrl) preferredUrl = null;
    await persist();
    await probe();
  }

  Future<void> toggleNode(int index) async {
    if (index < 0 || index >= nodes.length) return;
    if (nodes[index].enabled && enabledUrls.length <= 1) return;
    nodes[index].enabled = !nodes[index].enabled;
    await persist();
    await probe();
  }

  Future<void> moveNode(int index, int delta) async {
    final next = index + delta;
    if (index < 0 || next < 0 || next >= nodes.length) return;
    final item = nodes.removeAt(index);
    nodes.insert(next, item);
    await persist();
    await probe();
  }

  Future<void> setExplorer(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/$'), '');
    if (clean.isEmpty) return;
    explorer = clean;
    await persist();
    try {
      await apply();
    } catch (_) {}
    notifyListeners();
  }
}

bool isAbsoluteHttpUrl(String url) {
  final parsed = Uri.tryParse(url);
  return parsed != null &&
      parsed.hasScheme &&
      (parsed.scheme == 'http' || parsed.scheme == 'https') &&
      parsed.host.isNotEmpty;
}

List<String> probeOrder(List<String> urls, String? lastGood) {
  if (lastGood == null || lastGood.isEmpty || !urls.contains(lastGood)) {
    return List<String>.from(urls);
  }
  return [lastGood, ...urls.where((u) => u != lastGood)];
}

String explorerTransactionUrl(String explorer, String txId) {
  final host = Uri.tryParse(explorer)?.host ?? '';
  if (host.endsWith('sigmaspace.io')) {
    return 'https://sigmaspace.io/en/transaction/$txId';
  }
  if (host.endsWith('ergoplatform.com')) {
    return 'https://explorer.ergoplatform.com/en/transactions/$txId';
  }
  return '${explorer.replaceAll(RegExp(r'/$'), '')}/en/transactions/$txId';
}

String explorerTokenUrl(String explorer, String tokenId) {
  final host = Uri.tryParse(explorer)?.host ?? '';
  if (host.endsWith('sigmaspace.io')) {
    return 'https://sigmaspace.io/en/token/$tokenId';
  }
  if (host.endsWith('ergoplatform.com')) {
    return 'https://explorer.ergoplatform.com/en/token/$tokenId';
  }
  return '${explorer.replaceAll(RegExp(r'/$'), '')}/en/token/$tokenId';
}

/// Accepts `https://host` or a bare `host[:port]` (upgraded to https).
///
/// Explicit `http://` is accepted only for loopback/LAN hosts: Dart's
/// dart:io HTTP client bypasses the platform cleartext policy, so TLS is
/// enforced here for anything reachable beyond the local network.
String? normalizeNodeUrl(String raw) {
  var clean = raw.trim().replaceAll(RegExp(r'/$'), '');
  if (clean.isEmpty) return null;
  if (!clean.contains('://')) clean = 'https://$clean';
  if (!isAbsoluteHttpUrl(clean)) return null;
  final uri = Uri.tryParse(clean);
  if (uri == null) return null;
  if (uri.scheme == 'http' && !isLocalNetworkHost(uri.host)) return null;
  return clean;
}

/// Loopback or RFC-1918 host, where plain http is acceptable.
bool isLocalNetworkHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h == '::1') return true;
  if (h.startsWith('127.') || h.startsWith('10.')) return true;
  if (h.startsWith('192.168.')) return true;
  final second = RegExp(r'^172\.(\d+)\.').firstMatch(h);
  if (second != null) {
    final n = int.tryParse(second.group(1)!) ?? -1;
    if (n >= 16 && n <= 31) return true;
  }
  return false;
}

final networkController = NetworkController();
