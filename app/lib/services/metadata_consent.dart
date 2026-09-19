import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Canonical form of a metadata provider endpoint: scheme, host and port.
///
/// Consent is keyed on this rather than on the hostname, so the same host
/// reached over http, or on another port, is a different provider and needs
/// its own grant.
String? metadataEndpoint(String? url) {
  if (url == null || url.isEmpty) return null;
  // Checked before parsing: Uri percent-encodes a non-ASCII host, so by the
  // time it is a Uri the escape hatch looks like a valid ASCII name. Encoded
  // punycode (xn--) is ASCII already and still passes.
  if (url.runes.any((c) => c > 127)) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return '${uri.scheme}://${uri.host}:${uri.port}';
}

/// Which providers may resolve token metadata without asking per token.
///
/// This authorises a disclosure rather than denying that one happens. A
/// granted provider sees the connection's IP address, the token ids asked
/// for and when they were asked for; from that it can infer the holdings and
/// link activity across visits and wallets. Revoking stops later requests and
/// cannot retract what was already sent.
///
/// Grants are per endpoint and never transfer: pinning a different node does
/// not carry permission over to it.
class MetadataConsent extends ChangeNotifier {
  static const _key = 'argus_metadata_consent_v1';

  /// The pre-consent global switch. Deliberately never migrated — a value
  /// saved under "the node already knows this" is not consent under terms
  /// that name the timing and correlation signal.
  static const _legacyKey = 'argus_auto_metadata_v1';

  final Set<String> _granted = {};

  /// Endpoints allowed to resolve automatically, for display in settings.
  Set<String> get granted => Set.unmodifiable(_granted);

  bool allows(String? providerUrl) {
    final endpoint = metadataEndpoint(providerUrl);
    return endpoint != null && _granted.contains(endpoint);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyKey);
    _granted.clear();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final entry in (jsonDecode(raw) as List).take(32)) {
          final endpoint = metadataEndpoint(entry as String?);
          if (endpoint != null) _granted.add(endpoint);
        }
      } catch (_) {
        // A grant list that will not parse is not a grant.
      }
    }
    notifyListeners();
  }

  Future<void> grant(String providerUrl) => _write((next) {
    final endpoint = metadataEndpoint(providerUrl);
    if (endpoint == null) {
      throw StateError('Not a usable provider address.');
    }
    next.add(endpoint);
  });

  Future<void> revoke(String providerUrl) => _write((next) {
    final endpoint = metadataEndpoint(providerUrl);
    if (endpoint != null) next.remove(endpoint);
  });

  /// Persists before changing memory, so a failed write cannot leave a
  /// revoked provider still resolving, or a granted one silently withdrawn.
  Future<void> _write(void Function(Set<String>) change) async {
    final next = {..._granted};
    change(next);
    if (setEquals(next, _granted)) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key, jsonEncode(next.toList()))) {
      throw StateError('Could not save the token details permission.');
    }
    _granted
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}

final metadataConsent = MetadataConsent();
