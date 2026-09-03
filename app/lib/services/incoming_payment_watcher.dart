/// Spots incoming transactions that appear between two refreshes of the
/// activity list, so the app can announce a payment once.
///
/// The first observation after construction or [reset] only primes the
/// known set: a wallet being opened must not announce its whole history.
class IncomingPaymentWatcher {
  final Set<String> _seen = {};
  bool _primed = false;

  /// Returns the incoming transactions not seen before, oldest last.
  List<Map<String, dynamic>> observe(List<Map<String, dynamic>> txs) {
    final fresh = <Map<String, dynamic>>[];
    for (final tx in txs) {
      final id = tx['tx_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final isNew = _seen.add(id);
      if (!isNew || !_primed) continue;
      final nano = (tx['value_nano_erg'] as num?)?.toInt() ?? 0;
      if (nano > 0) fresh.add(tx);
    }
    _primed = true;
    return fresh;
  }

  void reset() {
    _seen.clear();
    _primed = false;
  }
}
