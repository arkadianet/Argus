import 'package:shared_preferences/shared_preferences.dart';

/// The one-time stealth addresses this phone sent its own change to.
///
/// A send that spends stealth coins (or both kinds) returns its change to
/// a fresh stealth address of the wallet's own. The stealth scan finds that
/// box like any other receipt, so the money is never lost track of. A
/// transaction's history, though, is read against the wallet's ordinary
/// addresses. Without this list the change output looks like a foreign
/// stealth payment: the row says "Stealth payment" and counts the change
/// as ERG that left. Each address is recorded when the send is built, and
/// history rows are read with it as the wallet's own (`reownActivity` in
/// activity_classifier.dart).
///
/// The addresses stay on this phone, in its app storage, as the rest of
/// the history does. The list is capped: only change from recent sends is
/// likely to be on screen.
class StealthChangeBook {
  StealthChangeBook({this.limit = 1000});

  static const storageKey = 'argus_stealth_self_change_v1';

  /// How many addresses are kept, newest last.
  final int limit;

  final List<String> _addresses = [];
  bool _loaded = false;

  /// Every address recorded so far; empty until [load] has run.
  Set<String> get addresses => _addresses.toSet();

  /// Reads the list once; later calls return at once. Only the outcome is
  /// kept, not the read in flight, so a caller never waits on a read that
  /// belonged to another (a test's) zone.
  Future<void> load() async {
    if (_loaded) return;
    final List<String> stored;
    try {
      final prefs = await SharedPreferences.getInstance();
      stored = prefs.getStringList(storageKey) ?? const [];
    } catch (_) {
      // Storage that cannot be read leaves the list empty: history then
      // reads as it did before the list existed, which is no worse.
      return;
    }
    _loaded = true;
    for (final a in stored) {
      if (a.isNotEmpty && !_addresses.contains(a)) _addresses.add(a);
    }
  }

  /// Records [address] as change of the wallet's own.
  Future<void> remember(String address) async {
    if (address.isEmpty) return;
    await load();
    _addresses
      ..remove(address)
      ..add(address);
    if (_addresses.length > limit) _addresses.removeRange(0, _addresses.length - limit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(storageKey, List.of(_addresses));
  }

  /// Forgets everything, for tests.
  void debugReset() {
    _addresses.clear();
    _loaded = false;
  }
}

final stealthChangeBook = StealthChangeBook();
