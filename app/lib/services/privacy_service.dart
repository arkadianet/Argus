import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Change-address policy for outgoing transactions, stored per wallet.
///
/// Default sends change back to the first derived address. When enabled,
/// change goes to the next unused address instead, so amounts can't be
/// linked across transactions by address reuse.
class PrivacyService extends ChangeNotifier {
  static const _prefix = 'argus_privacy_unused_change_v2_';

  /// Pre-multi-wallet key. Treated as the default for wallets that have no
  /// per-wallet value yet.
  static const _legacyKey = 'argus_privacy_unused_change';

  final Map<String, bool> _byWallet = {};
  bool? _legacyDefault;

  bool? get legacyDefault => _legacyDefault;

  /// Whether [walletId] sends change to unused addresses. Null wallet context
  /// falls back to the migrated global default, then false.
  bool useUnusedChangeAddress(String? walletId) {
    if (walletId == null) return _legacyDefault ?? false;
    return _byWallet[walletId] ?? _legacyDefault ?? false;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _byWallet.clear();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final walletId = key.substring(_prefix.length);
      if (walletId.isEmpty) continue;
      _byWallet[walletId] = prefs.getBool(key) ?? false;
    }
    _legacyDefault = prefs.getBool(_legacyKey);
    notifyListeners();
  }

  Future<void> setUnusedChangeAddress(bool value, {String? walletId}) async {
    if (walletId == null) return;
    if (useUnusedChangeAddress(walletId) == value && _byWallet.containsKey(walletId)) {
      return;
    }
    _byWallet[walletId] = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefix$walletId', value);
    notifyListeners();
  }
}

final privacyService = PrivacyService();
