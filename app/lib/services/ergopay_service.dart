import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'network_controller.dart';

/// EIP-20 ErgoPay: a dApp hands the wallet a reduced transaction, either
/// inline (`ergopay:<base64url>`) or by URL (`ergopay://host/path`).
sealed class ErgoPayLink {
  const ErgoPayLink();
}

/// The link carries the reduced transaction itself.
class StaticErgoPayLink extends ErgoPayLink {
  const StaticErgoPayLink(this.reducedTx);
  final Uint8List reducedTx;
}

/// The link names a URL that returns an [ErgoPayRequest].
class RemoteErgoPayLink extends ErgoPayLink {
  const RemoteErgoPayLink(this.url);

  /// Fetch URL with `ergopay://` already mapped to https (or http for a
  /// loopback / LAN host). May still contain [addressPlaceholder].
  final String url;

  static const addressPlaceholder = '#P2PK_ADDRESS#';

  bool get needsAddress => url.contains(addressPlaceholder);

  String withAddress(String address) => url.replaceAll(addressPlaceholder, address);
}

bool isErgoPayLink(String raw) => raw.trim().toLowerCase().startsWith('ergopay:');

/// Null when [raw] is not an ErgoPay link.
ErgoPayLink? parseErgoPayLink(String raw) {
  final text = raw.trim();
  if (!isErgoPayLink(text)) return null;
  final rest = text.substring('ergopay:'.length);
  if (rest.startsWith('//')) {
    final target = rest.substring(2);
    if (target.isEmpty) return null;
    final host = target.split(RegExp(r'[/?#:]')).first.toLowerCase();
    final scheme = isLocalNetworkHost(host) ? 'http' : 'https';
    return RemoteErgoPayLink('$scheme://$target');
  }
  if (rest.isEmpty) return null;
  try {
    return StaticErgoPayLink(decodeBase64Loose(rest));
  } on FormatException {
    return null;
  }
}

/// Base64 in either alphabet, with or without padding.
Uint8List decodeBase64Loose(String input) {
  var s = input.trim().replaceAll('-', '+').replaceAll('_', '/');
  final pad = s.length % 4;
  if (pad == 2) {
    s += '==';
  } else if (pad == 3) {
    s += '=';
  } else if (pad == 1) {
    throw const FormatException('bad base64 length');
  }
  return base64Decode(s);
}

enum ErgoPaySeverity { none, information, warning, error }

/// Signing request as returned by an ErgoPay URL.
class ErgoPayRequest {
  const ErgoPayRequest({
    this.reducedTx,
    this.address,
    this.message,
    this.severity = ErgoPaySeverity.none,
    this.replyTo,
  });

  final Uint8List? reducedTx;
  final String? address;
  final String? message;
  final ErgoPaySeverity severity;
  final String? replyTo;

  factory ErgoPayRequest.fromJson(Map<String, dynamic> json) {
    final raw = json['reducedTx'];
    Uint8List? tx;
    if (raw is String && raw.isNotEmpty) tx = decodeBase64Loose(raw);
    final sev = (json['messageSeverity'] as String?)?.toLowerCase();
    return ErgoPayRequest(
      reducedTx: tx,
      address: _nonEmpty(json['address']),
      message: _nonEmpty(json['message']),
      severity: ErgoPaySeverity.values.firstWhere(
        (v) => v.name == sev,
        orElse: () => ErgoPaySeverity.none,
      ),
      replyTo: _nonEmpty(json['replyTo']),
    );
  }

  static String? _nonEmpty(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
}

class ErgoPayException implements Exception {
  const ErgoPayException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// HTTP side of ErgoPay: fetch a request, post the resulting tx id.
class ErgoPayClient {
  ErgoPayClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _timeout = Duration(seconds: 15);

  Future<ErgoPayRequest> fetch(String url) async {
    final http.Response res;
    try {
      res = await _client
          .get(Uri.parse(url), headers: const {'accept': 'application/json'})
          .timeout(_timeout);
    } catch (e) {
      throw ErgoPayException('Could not reach the dApp: $e');
    }
    if (res.statusCode != 200) {
      throw ErgoPayException('The dApp answered HTTP ${res.statusCode}');
    }
    try {
      return ErgoPayRequest.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      throw const ErgoPayException('The dApp sent an unreadable signing request');
    }
  }

  Future<void> reply(String replyTo, String txId) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse(replyTo),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'txId': txId}),
          )
          .timeout(_timeout);
    } catch (e) {
      throw ErgoPayException('Could not notify the dApp: $e');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ErgoPayException('The dApp rejected the reply (HTTP ${res.statusCode})');
    }
  }
}

final ergoPayClient = ErgoPayClient();
