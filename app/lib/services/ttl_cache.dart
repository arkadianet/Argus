/// Small time-to-live cache with stale-on-error and single-flight fetches,
/// for protocol state that every DeFi screen and the token router read.
class TtlCache<K, V> {
  TtlCache({required this.ttl, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  final Map<K, (V, DateTime)> _entries = {};
  final Map<K, Future<V>> _inFlight = {};

  Future<V> get(K key, Future<V> Function() fetch, {bool fresh = false}) {
    final hit = _entries[key];
    if (!fresh && hit != null && _clock().difference(hit.$2) < ttl) {
      return Future.value(hit.$1);
    }
    final running = _inFlight[key];
    if (running != null) return running;
    final op = fetch().then((v) {
      _entries[key] = (v, _clock());
      return v;
    }).catchError((Object e) {
      final stale = _entries[key];
      if (stale != null) return stale.$1;
      throw e;
    }).whenComplete(() {
      // Return nothing: a returned future would make whenComplete wait on it.
      _inFlight.remove(key);
    });
    _inFlight[key] = op;
    return op;
  }

  void invalidate([K? key]) {
    if (key == null) {
      _entries.clear();
    } else {
      _entries.remove(key);
    }
  }
}
