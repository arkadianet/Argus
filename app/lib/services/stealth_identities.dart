import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One published stealth identity: a derivation index and the label the user
/// filed it under.
///
/// The index is the whole secret-side story — identity `i` regenerates from
/// the seed at `m/44'/429'/0'/3'/i` — so nothing here needs backing up for
/// funds to survive. Only the *label* is unrecoverable, and losing a label
/// costs a name, not money.
class StealthIdentity {
  const StealthIdentity({
    required this.index,
    required this.label,
    this.publishedAt,
  });

  /// Non-hardened final element of the derivation path.
  final int index;

  /// What the user calls this identity. Empty for an identity recovered by
  /// discovery, which has an index but no remembered name.
  final String label;

  /// When it was added on this device. Null for a discovered identity.
  final DateTime? publishedAt;

  /// The always-present identity, the one a wallet has before the user adds
  /// anything. Its label is fixed so it reads sensibly next to named ones.
  static const defaultLabel = 'Main';

  String get displayLabel =>
      label.isNotEmpty ? label : (index == 0 ? defaultLabel : 'Identity $index');

  StealthIdentity copyWith({String? label}) => StealthIdentity(
        index: index,
        label: label ?? this.label,
        publishedAt: publishedAt,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'label': label,
        'published_at': publishedAt?.millisecondsSinceEpoch,
      };

  static StealthIdentity? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final index = (raw['index'] as num?)?.toInt();
    if (index == null || index < 0 || index > maxStealthIdentity) return null;
    final at = (raw['published_at'] as num?)?.toInt();
    return StealthIdentity(
      index: index,
      label: raw['label']?.toString() ?? '',
      publishedAt:
          at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// Mirrors `stealth::MAX_STEALTH_IDENTITY`. Derivation past this is refused
/// in Rust; the store refuses it here so the UI fails before the FFI does.
const maxStealthIdentity = 255;

/// The durable list of stealth identities, per wallet.
///
/// Argus has no SQL database — [WalletDatabaseService] is SharedPreferences
/// with an obfuscating XOR, explicitly not encryption. Identity records go
/// through the same door, and carry the same caveat: an index and a label are
/// not secrets in the key sense (they buy an attacker nothing they could not
/// get by scanning), but a label is user metadata and is only obfuscated.
/// Never put anything here that must actually stay private.
///
/// What is stored is deliberately minimal: indices and labels. The frontier
/// is `max(index) + 1`, derived rather than stored, so the two cannot drift.
class StealthIdentityStore {
  static const _prefix = 'argus_stealth_identities_v1_';

  static String _key(String walletId) => '$_prefix$walletId';

  /// Every identity for [walletId], lowest index first.
  ///
  /// Always contains identity 0: a wallet has that identity whether or not
  /// anything was ever written down about it.
  static Future<List<StealthIdentity>> load(String walletId) async {
    if (walletId.isEmpty) return const [StealthIdentity(index: 0, label: '')];
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(walletId));
    final out = <int, StealthIdentity>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final item in jsonDecode(raw) as List) {
          final id = StealthIdentity.fromJson(item);
          if (id != null) out[id.index] = id;
        }
      } catch (_) {
        // A corrupted list must not lock the user out of their default
        // identity; fall through to the index-0-only case below.
      }
    }
    out.putIfAbsent(0, () => const StealthIdentity(index: 0, label: ''));
    final list = out.values.toList()..sort((a, b) => a.index.compareTo(b.index));
    return list;
  }

  static Future<void> _save(
    String walletId,
    List<StealthIdentity> identities,
  ) async {
    if (walletId.isEmpty) throw StateError('Missing wallet for stealth identities');
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(
      _key(walletId),
      jsonEncode([for (final i in identities) i.toJson()]),
    );
    // A silent failure here would show the user an identity that vanishes on
    // restart — and they may already have published its string.
    if (!ok) throw StateError('Could not save the stealth identity list');
  }

  /// Append a new identity at the next free index and return it.
  ///
  /// Indices are only ever appended: reusing a gap would hand out a string
  /// that may already have been published under a different label, and
  /// letting the user pick an index turns plumbing into a footgun.
  static Future<StealthIdentity> add(
    String walletId,
    String label, {
    DateTime? now,
  }) async {
    final existing = await load(walletId);
    final next = existing.map((i) => i.index).reduce((a, b) => a > b ? a : b) + 1;
    if (next > maxStealthIdentity) {
      throw StateError(
        'This wallet already has the maximum of ${maxStealthIdentity + 1} '
        'stealth identities',
      );
    }
    final created = StealthIdentity(
      index: next,
      label: label.trim(),
      publishedAt: now ?? DateTime.now(),
    );
    await _save(walletId, [...existing, created]);
    return created;
  }

  /// Rename an existing identity. Unknown indices are ignored.
  static Future<void> rename(String walletId, int index, String label) async {
    final existing = await load(walletId);
    if (!existing.any((i) => i.index == index)) return;
    await _save(walletId, [
      for (final i in existing)
        if (i.index == index) i.copyWith(label: label.trim()) else i,
    ]);
  }

  /// Record identities found by restore-time discovery.
  ///
  /// Discovered identities keep no label — the label lived only on the device
  /// that created them — but their index is what makes the funds spendable,
  /// and the user can rename them afterwards. Existing rows are left alone so
  /// a discovery pass can never overwrite a label the user still has.
  static Future<List<StealthIdentity>> merge(
    String walletId,
    Iterable<int> indices,
  ) async {
    final existing = await load(walletId);
    final known = {for (final i in existing) i.index};
    final fresh = indices
        .where((i) => i >= 0 && i <= maxStealthIdentity && !known.contains(i))
        .toSet()
        .toList()
      ..sort();
    if (fresh.isEmpty) return existing;
    final merged = [
      ...existing,
      for (final i in fresh) StealthIdentity(index: i, label: ''),
    ]..sort((a, b) => a.index.compareTo(b.index));
    await _save(walletId, merged);
    return merged;
  }

  /// One past the highest known index: how many identities to derive.
  static int frontierOf(List<StealthIdentity> identities) => identities.isEmpty
      ? 1
      : identities.map((i) => i.index).reduce((a, b) => a > b ? a : b) + 1;

  static Future<void> clearWallet(String walletId) async {
    if (walletId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(walletId));
  }
}
