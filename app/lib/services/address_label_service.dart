import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores user-assigned labels for addresses, persisted in SharedPreferences.
/// Labels are purely cosmetic metadata (not secrets), so unencrypted storage
/// is acceptable.
class AddressLabelService extends ChangeNotifier {
  static const _key = 'argus_address_labels';
  final Map<String, String> _labels = {};

  Map<String, String> get labels => Map.unmodifiable(_labels);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _labels
          ..clear()
          ..addEntries(
            list
                .whereType<Map>()
                .map((e) => MapEntry(
                      (e['address'] as String? ?? '').trim(),
                      (e['label'] as String? ?? '').trim(),
                    ))
                .where((e) => e.key.isNotEmpty && e.value.isNotEmpty),
          );
      } catch (_) {
        _labels.clear();
      }
    }
    notifyListeners();
  }

  String? labelFor(String address) {
    final label = _labels[address.trim()];
    return (label != null && label.isNotEmpty) ? label : null;
  }

  Future<void> setLabel(String address, String label) async {
    final trimmed = address.trim();
    final normalized = label.trim();
    if (trimmed.isEmpty) return;
    if (normalized.isEmpty) {
      _labels.remove(trimmed);
    } else {
      _labels[trimmed] = normalized;
    }
    await _save();
  }

  Future<void> removeLabel(String address) => setLabel(address, '');

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(
        _labels.entries.map((e) => {'address': e.key, 'label': e.value}).toList(),
      ),
    );
    notifyListeners();
  }
}

final addressLabelService = AddressLabelService();
