import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        final list = jsonDecode(raw) as List;
        _addresses
          ..clear()
          ..addAll(list.whereType<String>().where((a) => a.isNotEmpty));
      } catch (_) {
        _addresses.clear();
      }
    }
    notifyListeners();
  }

  Future<void> add(String address) async {
    if (address.trim().isEmpty || _addresses.contains(address.trim())) return;
    _addresses.add(address.trim());
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
