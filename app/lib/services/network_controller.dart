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

String describeNode(NodeEntry node, NodeProbe? probe, {required bool active}) {
  final bits = <String>[
    if (!node.enabled) 'Off' else if (active) 'In use' else 'Standby',
  ];
  if (probe != null) {
    if (probe.extraIndex == true) {
      bits.add('extraIndex');
    } else if (probe.extraIndex == false) {
      bits.add('no extraIndex');
    }
    if (probe.height != null) bits.add('#${probe.height}');
    if (!probe.ok) bits.add('unreachable');
  }
  return bits.join('  ·  ');
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

  List<NodeEntry> nodes = [
    for (final url in defaultNodes) NodeEntry(url: url),
  ];
  String explorer = defaultExplorer;
  String? activeUrl;
  String? lastGood;
  int? height;
  bool probing = false;
  double? usdPerErg;
  double? audPerErg;

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
    _priceAt = null;
    // Invalidate any in-flight price fetch for the previous currency so a
    // late response cannot overwrite the new currency's rate.
    _fiatGen++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fiatPrefKey, code);
    await refreshPrice();
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

  List<String> get orderedUrls => probeOrder(enabledUrls, lastGood);

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
      NodeProbe? first;
      for (final p in results) {
        if (p.ok) {
          first = p;
          break;
        }
      }
      activeUrl = first?.url;
      height = first?.height;
      if (activeUrl != null) {
        lastGood = activeUrl;
        await persist();
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

  DateTime? _priceAt;
  static const _priceTtl = Duration(minutes: 5);
  static const _fiatPrefKey = 'argus_fiat_currency';

  /// Bumped on currency change so a stale in-flight [refreshPrice] response
  /// for the previous currency is discarded instead of applied.
  int _fiatGen = 0;

  Future<void> refreshPrice() async {
    final now = DateTime.now();
    if (_priceAt != null && now.difference(_priceAt!) < _priceTtl) return;
    final gen = _fiatGen;
    final code = fiatCode.toLowerCase();
    try {
      final res = await http
          .get(Uri.parse(
              'https://api.coingecko.com/api/v3/simple/price?ids=ergo&vs_currencies=$code'))
          .timeout(const Duration(seconds: 8));
      final stillCurrent = gen == _fiatGen && code == fiatCode.toLowerCase();
      if (!stillCurrent) return;
      if (res.statusCode != 200) {
        notifyListeners();
        return;
      }
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final ergo = map['ergo'] as Map?;
      final value = ergo?[code];
      if (value is num) {
        fiatPerErg = value.toDouble();
        if (code == 'usd') usdPerErg = value.toDouble();
        if (code == 'aud') audPerErg = value.toDouble();
        _priceAt = now;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<String?> addNode(String url) async {
    final clean = normalizeNodeUrl(url);
    if (clean == null) return 'Enter https://host or http://ip:port';
    if (nodes.any((n) => n.url == clean)) return 'Node already added';
    nodes.add(NodeEntry(url: clean));
    await persist();
    await probe();
    return null;
  }

  Future<void> removeNode(int index) async {
    if (index < 0 || index >= nodes.length) return;
    final enabled = enabledUrls;
    if (nodes[index].enabled && enabled.length <= 1) return;
    nodes.removeAt(index);
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
