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
      try {
        final stored = jsonDecode(raw) as List;
        final valid = <String>{};
        for (final item in stored.whereType<String>()) {
          final trimmed = item.trim();
          if (trimmed.isNotEmpty && await api.validateErgoAddress(address: trimmed)) {
            valid.add(trimmed);
          }
        }
        _addresses
          ..clear()
          ..addAll(valid);
      } catch (_) {
        _addresses.clear();
      }
    }
    notifyListeners();
  }

  Future<void> add(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;
    if (!await api.validateErgoAddress(address: trimmed)) return;
    if (_addresses.contains(trimmed)) return;
    _addresses.add(trimmed);
    await _save();
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
