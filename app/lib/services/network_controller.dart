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

  List<NodeEntry> nodes = [
    for (final url in defaultNodes) NodeEntry(url: url),
  ];
  String explorer = defaultExplorer;
  String? activeUrl;
  int? height;
  bool probing = false;
  double? usdPerErg;

  List<String> get enabledUrls =>
      nodes.where((n) => n.enabled && n.url.isNotEmpty).map((n) => n.url).toList();

  String get statusLabel {
    if (activeUrl == null || height == null) return 'Offline';
    final host = Uri.tryParse(activeUrl!)?.host;
    return '${(host != null && host.isNotEmpty) ? host : activeUrl}  ·  #$height';
  }

  String explorerTx(String txId) => explorerTransactionUrl(explorer, txId);

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
    try {
      await apply();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nodesKey, jsonEncode(nodes.map((n) => n.toJson()).toList()));
    await prefs.setString(_explorerKey, explorer);
  }

  Future<void> apply() async {
    final urls = enabledUrls;
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
      final raw = await RustLib.instance.api.crateApiProbeNetwork();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map['nodes'] as List? ?? []).whereType<Map>();
      String? nextUrl;
      int? nextHeight;
      for (final n in list) {
        if (n['ok'] == true) {
          nextUrl = n['url'] as String?;
          nextHeight = (n['height'] as num?)?.toInt();
          break;
        }
      }
      activeUrl = nextUrl;
      height = nextHeight;
    } catch (_) {
      activeUrl = null;
      height = null;
    } finally {
      probing = false;
      notifyListeners();
    }
    await refreshPrice();
  }

  DateTime? _priceAt;
  static const _priceTtl = Duration(minutes: 5);

  Future<void> refreshPrice() async {
    final now = DateTime.now();
    if (_priceAt != null && now.difference(_priceAt!) < _priceTtl) return;
    try {
      final res = await http
          .get(Uri.parse('https://api.coingecko.com/api/v3/simple/price?ids=ergo&vs_currencies=usd'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        notifyListeners();
        return;
      }
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final usd = (map['ergo'] as Map?)?['usd'];
      if (usd is num) {
        usdPerErg = usd.toDouble();
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

/// Accepts `https://host`, `http://ip:port`, or a bare `ip:port` (treated as http).
String? normalizeNodeUrl(String raw) {
  var clean = raw.trim().replaceAll(RegExp(r'/$'), '');
  if (clean.isEmpty) return null;
  if (!clean.contains('://')) clean = 'http://$clean';
  return isAbsoluteHttpUrl(clean) ? clean : null;
}

final networkController = NetworkController();
