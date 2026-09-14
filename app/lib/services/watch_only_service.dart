import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as api;

Future<({Map<String, int?> balances, String? error})> readWatchBalances(
  List<String> addresses,
  Future<int> Function(String) read,
) async {
  final errors = <String>[];
  final entries = await Future.wait(
    addresses.map((address) async {
      try {
        return MapEntry<String, int?>(address, await read(address));
      } catch (e) {
        errors.add('$address: $e');
        return MapEntry<String, int?>(address, null);
      }
    }),
  );
  return (
    balances: Map.fromEntries(entries),
    error: errors.isEmpty
        ? null
        : 'Some watched balances are unavailable.\n${errors.join('\n')}',
  );
}

/// Stores addresses to monitor without holding a wallet seed.
/// Watch-only addresses use getBalance/loadHistory directly — no
/// wallet handle required.
class WatchOnlyService extends ChangeNotifier {
  static const _key = 'argus_watch_only_addresses';
  final List<String> _addresses = [];

  List<String> get addresses => List.unmodifiable(_addresses);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      final List<dynamic> stored;
      try {
        stored = jsonDecode(raw) as List;
      } catch (_) {
        notifyListeners();
        return;
      }
      // Entries were validated on add. Loading must work before RustLib.init
      // and must never reinterpret validation failure as user removal.
      _addresses
        ..clear()
        ..addAll(stored.whereType<String>());
    }
    notifyListeners();
  }

  /// Adds an address or P2PK public key, deduplicating the normalized address.
  /// Returns `true` if the address was saved, `false` if it was invalid or a
  /// duplicate.
  Future<bool> add(String address) async {
    final trimmed = await api.normalizeWatchInput(input: address.trim());
    if (trimmed == null) return false;
    if (_addresses.contains(trimmed)) return false;
    _addresses.add(trimmed);
    try {
      await _save();
    } catch (_) {
      _addresses.remove(trimmed);
      rethrow;
    }
    return true;
  }

  Future<void> remove(String address) async {
    final index = _addresses.indexOf(address);
    if (index < 0) return;
    _addresses.removeAt(index);
    try {
      await _save();
    } catch (_) {
      _addresses.insert(index.clamp(0, _addresses.length), address);
      rethrow;
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key, jsonEncode(_addresses))) {
      await prefs.reload();
      throw StateError('Could not save watched addresses. Please try again.');
    }
    notifyListeners();
  }
}

final watchOnlyService = WatchOnlyService();
