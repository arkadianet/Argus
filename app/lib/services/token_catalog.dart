import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'token_descriptor_store.dart';
import 'wallet_service.dart';

/// App-wide descriptors for tokens that appear in a public list — today the
/// Spectrum pool list — so Swap and Liquidity can name a pool's tokens
/// whether or not this wallet holds them.
///
/// App-wide, unlike `TokenDescriptorStore`, and that is safe only because of
/// what may enter it. A pool list is the same for every wallet: Argus
/// downloads all of it, and the node that serves it already holds every
/// token id in it. Resolving those ids from that node, in an order taken
/// from the list and never from what a wallet holds, tells the node nothing
/// new, and the table that results records nothing about any wallet.
///
/// So nothing a wallet holds, resolved, sent or looked at is ever written
/// here. A holding's descriptor copied in would record — app-wide, and past
/// the wallet's deletion — that some wallet on this phone held that token.
///
/// Descriptors keep their evidence, as the per-wallet table does. Names are
/// issuer text, sanitised on the way out (`TokenBalance`, `issuerText`), and
/// never identity: verified and impersonation checks key on the token id.
class PublicTokenCatalog {
  PublicTokenCatalog({
    Future<String?> Function(String tokenId, String provider)? inspect,
    VoidCallback? onChanged,
  }) : _inspect = inspect,
       _onChanged = onChanged;

  static const storageKey = 'argus_public_token_descriptors_v1';

  /// Where earlier builds kept Spectrum pool-token names. Read once into
  /// this catalog, then removed.
  static const legacyAmmKey = 'argus_amm_tokens_v1';

  /// Room for every token of a capped pool list — two discovery calls of at
  /// most 1,000 pools each — without growing without bound.
  static const maxEntries = 2000;

  /// Lookups per pass, as for a wallet sync: a first visit to Swap must not
  /// become hundreds of sequential requests. The rest resolve on later
  /// pool loads.
  static const maxPerPass = 40;

  /// A run of not-founds ends a pass without a verdict on the node: unknown
  /// tokens and a missing index look alike.
  static const notFoundRunEndsPass = 8;

  /// Consecutive failures-to-answer before a pass gives up on a node that
  /// is simply not answering.
  static const maxConsecutiveRetryable = 3;

  /// Runs one node lookup, or returns null when the metadata job is wanted
  /// elsewhere. Wallet work always comes first; see
  /// `WalletService.inspectForCatalog`.
  final Future<String?> Function(String tokenId, String provider)? _inspect;
  final VoidCallback? _onChanged;

  final Map<String, CachedDescriptor> _entries = {};
  Future<void>? _loading;

  /// Bumped by [clear]. A load, pass or write that started before a clear
  /// must not land after it.
  int _generation = 0;
  bool _passRunning = false;

  // Capability and miss state belong to one provider; a new node gets a
  // fresh chance.
  String? _provider;
  bool _unsupported = false;
  final Set<String> _misses = {};
  int _cursor = 0;

  CachedDescriptor? lookup(String id) => _entries[id];

  int get length => _entries.length;

  /// True when the node that served the pool list proved unable to resolve
  /// issuance data (no extraIndex, or not HTTPS).
  bool get lookupUnsupported => _unsupported;

  /// Loads the stored table once. Lookups before it lands miss, they do not
  /// wait; [onChanged] fires when it does.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final generation = _generation;
    final loaded = <String, CachedDescriptor>{};
    String? legacy;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in map.entries.take(maxEntries)) {
          final d = TokenDescriptorStore.decode(e.key, e.value);
          if (d != null) loaded[e.key] = d;
        }
      }
      legacy = prefs.getString(legacyAmmKey);
      if (legacy != null) {
        for (final e in legacyAmmEntries(legacy).entries) {
          loaded.putIfAbsent(e.key, () => e.value);
        }
      }
    } catch (_) {
      // A corrupt table costs a refetch, not the pool list.
    }
    if (generation != _generation) return;
    // Whatever a pass learned while this was reading is newer than disk.
    for (final e in loaded.entries) {
      if (_entries.length >= maxEntries) break;
      _entries.putIfAbsent(e.key, () => e.value);
    }
    if (legacy != null && prefs != null) {
      // Written before the old key is removed, so a crash in between costs
      // nothing.
      await _persist(generation);
      if (generation == _generation) await prefs.remove(legacyAmmKey);
    }
    if (loaded.isNotEmpty) _changed();
  }

  /// The real names in the old AMM table, without its placeholders.
  ///
  /// Once pool discovery stopped asking the node, it padded every token it
  /// had not been told about with the first eight characters of the id and
  /// "…", at zero decimals, and that placeholder was saved as if it were the
  /// name. A placeholder is not knowledge — and its zero scale would show a
  /// six-decimal token's reserves a million times too large — so it is
  /// dropped. What remains was read from a node for a pool token, which is
  /// exactly what this catalog holds. It has no provenance, so it is marked
  /// incomplete: shown at once, and upgraded by a later pass.
  @visibleForTesting
  static Map<String, CachedDescriptor> legacyAmmEntries(String raw) {
    final out = <String, CachedDescriptor>{};
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return out;
      for (final e in map.entries.take(maxEntries)) {
        final id = e.key;
        final v = e.value;
        if (id is! String || !isTokenId(id) || v is! Map) continue;
        final name = v['name'];
        if (name is! String || name.isEmpty || isPlaceholderName(id, name)) {
          continue;
        }
        final decimals = (v['decimals'] as num?)?.toInt() ?? 0;
        if (decimals < 0 || decimals > 255) continue;
        out[id] = CachedDescriptor(
          id: id,
          name: name,
          decimals: decimals,
          metadataState: MetadataState.partial,
          incomplete: true,
        );
      }
    } catch (_) {}
    return out;
  }

  /// The label pool discovery invented for a token it had no metadata for.
  static bool isPlaceholderName(String id, String name) =>
      id.length >= 8 && name == '${id.substring(0, 8)}…';

  static final _tokenIdPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  static bool isTokenId(String id) => _tokenIdPattern.hasMatch(id);

  /// Resolves the ids of one public list that the catalog does not know yet,
  /// from [servedBy]: the node that served that list, never the explorer or
  /// a fallback. [ids] must come in the list's own order. Ordering them by
  /// anything a wallet holds would let the request sequence say what it is.
  ///
  /// One pass at a time; a second call while one runs returns at once.
  Future<void> resolve(Iterable<String> ids, {required String servedBy}) async {
    final inspect = _inspect;
    if (inspect == null || servedBy.isEmpty || _passRunning) return;
    _passRunning = true;
    final generation = _generation;
    var attempted = 0;
    var learned = false;
    String? provider;
    try {
      await ensureLoaded();
      if (generation != _generation) return;
      if (_provider != servedBy) {
        _provider = servedBy;
        _unsupported = false;
        _misses.clear();
        _cursor = 0;
      }
      provider = servedBy;
      if (_unsupported) return;

      // Unknown tokens first; descriptors still missing their registers
      // after them, since those already have a name to show.
      final seen = <String>{};
      final unknown = <String>[];
      final unfinished = <String>[];
      for (final id in ids) {
        if (!isTokenId(id) || !seen.add(id) || _misses.contains(id)) continue;
        final known = _entries[id];
        if (known == null) {
          unknown.add(id);
        } else if (known.incomplete) {
          unfinished.add(id);
        }
      }
      final wanted = [...unknown, ...unfinished];
      if (wanted.isEmpty) return;
      // Rotate, so a run of tokens that never answer cannot hold the head of
      // every pass and starve the ones behind it.
      final start = _cursor % wanted.length;
      final ordered = [...wanted.skip(start), ...wanted.take(start)];

      var consecutiveRetryable = 0;
      var consecutiveNotFound = 0;
      for (final id in ordered) {
        if (generation != _generation || attempted >= maxPerPass) break;
        final String? raw;
        try {
          raw = await inspect(id, servedBy);
        } catch (e) {
          attempted++;
          if (generation != _generation) break;
          final text = e.toString().toLowerCase();
          // Another job holds the slot, or this one was cancelled (lock,
          // backgrounding): neither says anything about the token.
          if (text.contains('already running') ||
              text.contains('cancelled') ||
              text.contains('canceled')) {
            break;
          }
          if (!DescriptorLookupFailure.durableNegative(e)) {
            if (++consecutiveRetryable >= maxConsecutiveRetryable) break;
            continue;
          }
          consecutiveRetryable = 0;
          _misses.add(id);
          if (DescriptorLookupFailure.unsupported(e)) {
            _unsupported = true;
            break;
          }
          if (DescriptorLookupFailure.notFound(e)) {
            if (++consecutiveNotFound >= notFoundRunEndsPass) break;
          } else {
            consecutiveNotFound = 0;
          }
          continue;
        }
        // The wallet wants the job. Give way; a later pool load carries on.
        if (raw == null) break;
        attempted++;
        if (generation != _generation) break;
        consecutiveRetryable = 0;
        consecutiveNotFound = 0;
        final Map<String, dynamic> m;
        try {
          m = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        if (m['id'] != id) continue;
        final d = CachedDescriptor.fromInspection(m, source: servedBy);
        // The per-wallet table's bound: an issuer cannot make one entry
        // large enough to crowd out the rest of the store.
        if (utf8.encode('${d.name ?? ''}${d.iconUrl ?? ''}').length > 16384) {
          continue;
        }
        _remember(d);
        learned = true;
        _changed();
      }
    } finally {
      if (provider != null && _provider == provider) {
        _cursor += attempted == 0 ? 1 : attempted;
      }
      if (learned && generation == _generation) await _persist(generation);
      _passRunning = false;
    }
  }

  void _remember(CachedDescriptor d) {
    _entries.remove(d.id);
    while (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[d.id] = d;
  }

  Future<void> _persist(int generation) async {
    // Serialized before suspending: a pass may add entries meanwhile.
    final payload = jsonEncode({
      for (final e in _entries.entries)
        e.key: TokenDescriptorStore.encode(e.value),
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      if (generation != _generation) return;
      await prefs.setString(storageKey, payload);
    } catch (_) {
      // A table that cannot be written is rebuilt by later passes.
    }
  }

  /// Part of "Clear collectible cache": the table, the old AMM table it was
  /// seeded from, and every verdict about providers.
  Future<void> clear() async {
    _generation++;
    _entries.clear();
    _misses.clear();
    _provider = null;
    _unsupported = false;
    _cursor = 0;
    // Storage is emptied below; nothing is left to load.
    _loading = Future<void>.value();
    _changed();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
    await prefs.remove(legacyAmmKey);
  }

  /// Puts entries straight into memory, as a finished pass would.
  @visibleForTesting
  void debugSeed(Iterable<CachedDescriptor> entries) {
    _loading ??= Future<void>.value();
    for (final d in entries) {
      _remember(d);
    }
    _changed();
  }

  /// Forgets everything in memory, so each test starts from storage.
  @visibleForTesting
  void debugReset() {
    _generation++;
    _entries.clear();
    _misses.clear();
    _provider = null;
    _unsupported = false;
    _cursor = 0;
    _passRunning = false;
    _loading = null;
  }

  void _changed() => _onChanged?.call();
}

/// The app's one catalog. Its lookups run in the wallet's metadata job and
/// always give way to the wallet's own work; what it learns repaints every
/// screen that listens to `walletService.metadataChanges`.
final publicTokenCatalog = PublicTokenCatalog(
  inspect: (id, provider) => walletService.inspectForCatalog(id, provider),
  onChanged: () => walletService.metadataChanges.value++,
);
