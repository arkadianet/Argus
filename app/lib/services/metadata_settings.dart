import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether token metadata may be resolved without a per-token prompt.
///
/// Off by default, so an existing install keeps asking. The switch only has
/// an effect while the node pinned in Settings is the one serving the
/// session; see [WalletService.autoResolveEligible] for the reasoning and
/// for the cases that keep asking regardless.
class MetadataSettings extends ChangeNotifier {
  static const _autoResolveKey = 'argus_auto_metadata_v1';

  bool _autoResolve = false;
  bool get autoResolve => _autoResolve;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _autoResolve = prefs.getBool(_autoResolveKey) ?? false;
    notifyListeners();
  }

  /// Persists before changing memory, so a failed write cannot leave the
  /// switch showing off while the next launch reads on and resolves without
  /// asking. Throws when the write fails; the caller is expected to say so.
  Future<void> setAutoResolve(bool value) async {
    if (value == _autoResolve) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_autoResolveKey, value)) {
      throw StateError('Could not save the token details setting.');
    }
    _autoResolve = value;
    notifyListeners();
  }
}

final metadataSettings = MetadataSettings();
