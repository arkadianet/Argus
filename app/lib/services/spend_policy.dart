import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api/mempool.dart' as mempool;

/// Whether the wallet spends funds before they confirm, until the user says
/// otherwise. This constant is the one place the default lives.
const bool defaultSpendUnconfirmed = true;

/// What the switch does, in plain words, for the note under it.
const spendUnconfirmedNote =
    'Off: money you receive, and the change from your own sends, waits for '
    'one confirmation (the next block, usually a few minutes) before Argus '
    'spends it. On: it can '
    'be spent at once, but if the transaction that brought it is dropped, '
    'the one spending it fails too. Either way, coins a pending transaction '
    'is already spending are never used again.';

/// Settings → Security → Spend unconfirmed funds.
///
/// On, an incoming payment or the change of the wallet's own send can be
/// spent at once (0-conf); if the transaction that created it is dropped,
/// the one spending it fails with it. Off, both wait for one confirmation.
/// Either way a box a pending transaction already spends is never used
/// again — that is not a preference but a double spend.
///
/// The Rust core holds the policy every spend gathers its inputs under, so
/// the setting reaches every path at once: it is handed over at startup
/// (`WalletService.init`) and on every change.
class SpendPolicy extends ChangeNotifier {
  /// [push] stands in for the Rust core in tests.
  SpendPolicy({void Function(bool allow)? push}) : _push = push ?? _pushToRust;

  static const storageKey = 'argus_spend_unconfirmed';

  final void Function(bool allow) _push;
  bool _allow = defaultSpendUnconfirmed;
  bool _loaded = false;

  /// True when unconfirmed funds may be spent.
  bool get spendUnconfirmed => _allow;

  static void _pushToRust(bool allow) =>
      mempool.setSpendUnconfirmed(allow: allow);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _allow = prefs.getBool(storageKey) ?? defaultSpendUnconfirmed;
    _loaded = true;
    notifyListeners();
  }

  /// Hand the stored setting to the Rust core. Loads it first when needed,
  /// so a background isolate that never ran [load] still applies the
  /// user's choice rather than the default.
  Future<void> apply() async {
    if (!_loaded) await load();
    _push(_allow);
  }

  /// Persist first, then apply: a failed write leaves the previous policy
  /// in force everywhere.
  Future<void> setSpendUnconfirmed(bool allow) async {
    if (_loaded && allow == _allow) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(storageKey, allow)) {
      throw StateError('Could not save the spending setting');
    }
    _allow = allow;
    _loaded = true;
    try {
      _push(allow);
    } catch (_) {
      // The bridge is not up yet; WalletService.init applies the stored
      // value before any spend can run.
    }
    notifyListeners();
  }
}

final spendPolicy = SpendPolicy();
