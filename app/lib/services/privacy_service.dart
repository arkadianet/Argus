import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Change-address policy for outgoing transactions.
///
/// Default sends change back to the first derived address. When enabled,
/// change goes to the next unused address instead, so amounts can't be
/// linked across transactions by address reuse.
class PrivacyService extends ChangeNotifier {
  static const _key = 'argus_privacy_unused_change';

  bool _unusedChange = false;

  bool get useUnusedChangeAddress => _unusedChange;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _unusedChange = prefs.getBool(_key) ?? false;
    notifyListeners();
  }

  Future<void> setUnusedChangeAddress(bool value) async {
    if (value == _unusedChange) return;
    _unusedChange = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
    notifyListeners();
  }
}

final privacyService = PrivacyService();
