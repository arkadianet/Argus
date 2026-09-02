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

  static const _hideBalancesKey = 'argus_hide_balances';

  final Map<String, bool> _byWallet = {};
  bool? _legacyDefault;

  /// App-wide: mask amounts on the home screen (shoulder-surfing guard).
  bool hideBalances = false;

  Future<void> setHideBalances(bool value) async {
    if (value == hideBalances) return;
    hideBalances = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hideBalancesKey, value);
  }

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
    hideBalances = prefs.getBool(_hideBalancesKey) ?? false;
    notifyListeners();
  }

  Future<void> setUnusedChangeAddress(bool value, {String? walletId}) async {
    if (walletId == null) return;
    if (_byWallet.containsKey(walletId) && _byWallet[walletId] == value) return;
    // Persist first and only then flip the in-memory value: a failed write
    // must leave the previous policy in place.
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setBool('$_prefix$walletId', value);
    if (!ok) {
      throw StateError('Failed to persist change-address policy');
    }
    _byWallet[walletId] = value;
    notifyListeners();
  }
}

final privacyService = PrivacyService();
