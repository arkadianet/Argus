import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as api;

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
        _addresses.clear();
        notifyListeners();
        return;
      }
      final valid = <String>{};
      var failed = false;
      for (final item in stored.whereType<String>()) {
        final trimmed = item.trim();
        if (trimmed.isEmpty) continue;
        try {
          if (await api.validateErgoAddress(address: trimmed)) {
            valid.add(trimmed);
          }
        } catch (_) {
          // Validation could not complete (bridge/FFI failure). Preserve the
          // existing in-memory collection rather than wiping it.
          failed = true;
          break;
        }
      }
      if (!failed) {
        _addresses
          ..clear()
          ..addAll(valid);
      }
    }
    notifyListeners();
  }

  /// Adds [address] after checksum-aware validation and deduplication.
  /// Returns `true` if the address was saved, `false` if it was invalid or a
  /// duplicate.
  Future<bool> add(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return false;
    if (!await api.validateErgoAddress(address: trimmed)) return false;
    if (_addresses.contains(trimmed)) return false;
    _addresses.add(trimmed);
    await _save();
    return true;
  }

  Future<void> remove(String address) async {
    _addresses.removeWhere((a) => a == address);
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_addresses));
    notifyListeners();
  }
}

final watchOnlyService = WatchOnlyService();
