import 'package:shared_preferences/shared_preferences.dart';

/// The one-time stealth addresses each wallet on this phone sent its own
/// change to, kept per wallet.
///
/// A send that spends stealth coins (or both kinds) returns its change to
/// a fresh stealth address of the wallet's own. The stealth scan finds that
/// box like any other receipt, so the money is never lost track of. A
/// transaction's history, though, is read against the wallet's ordinary
/// addresses. Without this list the change output looks like a foreign
/// stealth payment: the row says "Stealth payment" and counts the change
/// as ERG that left. Each address is recorded when the send is built, and
/// that wallet's history rows are read with it as the wallet's own
/// (`reownActivity` in activity_classifier.dart).
///
/// Each wallet has its own list, under its own key, deleted with the
/// wallet. Two wallets never share one: a shared list would link them in
/// the phone's storage, and would let one wallet's change, paid out to
/// another of the phone's wallets, be read as the second wallet's own.
///
/// The addresses stay on this phone, in its app storage, as the rest of
/// the history does. Each list is capped: only change from recent sends is
/// likely to be on screen.
class StealthChangeBook {
  StealthChangeBook({this.limit = 1000});

  static const _prefix = 'argus_stealth_self_change_v2_';

  /// The single phone-wide list of the build that introduced the book
  /// (1.0.0-beta.4), migrated by [migrateLegacy].
  static const legacyKey = 'argus_stealth_self_change_v1';

  static String keyFor(String walletId) => '$_prefix$walletId';

  /// How many addresses each wallet keeps, newest last.
  final int limit;

  final Map<String, List<String>> _byWallet = {};

  /// [walletId]'s addresses; empty until [load] has run for it.
  Set<String> addressesFor(String? walletId) =>
      walletId == null ? const {} : (_byWallet[walletId] ?? const []).toSet();

  /// Reads [walletId]'s list once; later calls return at once. Only the
  /// outcome is kept, not the read in flight, so a caller never waits on a
  /// read that belonged to another (a test's) zone.
  Future<void> load(String? walletId) async {
    if (walletId == null || _byWallet.containsKey(walletId)) return;
    final List<String> stored;
    try {
      final prefs = await SharedPreferences.getInstance();
      stored = prefs.getStringList(keyFor(walletId)) ?? const [];
    } catch (_) {
      // Storage that cannot be read leaves the list empty: history then
      // reads as it did before the list existed, which is no worse.
      return;
    }
    _byWallet[walletId] = [
      for (final a in stored)
        if (a.isNotEmpty) a,
    ];
  }

  /// Records [address] as [walletId]'s own change.
  Future<void> remember(String? walletId, String address) async {
    if (walletId == null || address.isEmpty) return;
    await load(walletId);
    final list = _byWallet.putIfAbsent(walletId, () => [])
      ..remove(address)
      ..add(address);
    if (list.length > limit) list.removeRange(0, list.length - limit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(keyFor(walletId), List.of(list));
  }

  /// Deletes [walletId]'s list, with the wallet.
  Future<void> forget(String walletId) async {
    _byWallet.remove(walletId);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyFor(walletId));
    } catch (_) {
      // Nothing stored, nothing to remove.
    }
  }

  /// Moves the phone-wide list of 1.0.0-beta.4 into per-wallet lists, once.
  ///
  /// That list did not say which wallet each address was change of. With
  /// one wallet with keys on the phone ([seedWalletIds]) every address was
  /// its change, so the list becomes that wallet's. With several there is
  /// no telling them apart without linking the wallets, the thing per-wallet
  /// lists exist to avoid, so the list is dropped: a send made then may
  /// read again as a stealth payment, and nothing else changes. Either way
  /// the phone-wide list is deleted.
  Future<void> migrateLegacy(List<String> seedWalletIds) async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final legacy = prefs.getStringList(legacyKey);
    if (legacy == null) return;
    if (seedWalletIds.length == 1) {
      final walletId = seedWalletIds.single;
      for (final address in legacy) {
        await remember(walletId, address);
      }
    }
    await prefs.remove(legacyKey);
  }

  /// Forgets everything held in memory, for tests.
  void debugReset() => _byWallet.clear();
}

final stealthChangeBook = StealthChangeBook();
