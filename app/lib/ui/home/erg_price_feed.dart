import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/erg_price_history.dart';
import '../../services/network_controller.dart';
import '../../services/token_pricer.dart';

/// ERG's price over the last day, for the overview's price strip and the
/// ERG row's 24h change.
///
/// Read from [TokenPricer.ergPriceHistory] (the source picked in Display
/// settings: the SigmaUSD oracle pool, the ERG/SigUSD pool, or CoinGecko)
/// when the home screen first shows, and again whenever what it depends on
/// changes — the source, the currency, the node, whether the chain height
/// or the currency's rate is known — or the answer has aged out. The
/// pricer keeps answers for five minutes (half a minute when history was
/// unavailable), so asking again often costs nothing; nothing polls.
class ErgPriceFeed extends ChangeNotifier {
  ErgPriceFeed({TokenPricer? pricer, NetworkController? network, DateTime Function()? clock})
      : _pricer = pricer ?? tokenPricer,
        _network = network ?? networkController,
        _clock = clock ?? DateTime.now;

  final TokenPricer _pricer;
  final NetworkController _network;
  final DateTime Function() _clock;

  /// The last answer, which may say why there is no history; null until
  /// the first one arrives.
  ErgPriceHistory? history;

  String? _key;
  DateTime? _readAt;
  int _generation = 0;
  bool _attached = false;
  bool _disposed = false;

  /// How long an answer stands before the next change asks again.
  static const _availableFor = TokenPricer.refreshTtl;
  static const _unavailableFor = Duration(seconds: 30);

  void attach() {
    if (_attached || _disposed) return;
    _attached = true;
    _pricer.addListener(_check);
    _network.addListener(_check);
    _check();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_attached) {
      _pricer.removeListener(_check);
      _network.removeListener(_check);
    }
    super.dispose();
  }

  /// Asks again now, as pull-to-refresh does; the pricer still answers
  /// from its cache while that is current.
  Future<void> refresh() => _read();

  void _check() {
    final key = [
      _pricer.source.name,
      _network.fiatCode,
      _network.activeUrl,
      _network.height != null,
      _pricer.displayRateKnown,
    ].join('|');
    final readAt = _readAt;
    final keep = history?.available == true ? _availableFor : _unavailableFor;
    final fresh = readAt != null && _clock().difference(readAt) < keep;
    if (key == _key && fresh) return;
    _key = key;
    unawaited(_read());
  }

  Future<void> _read() async {
    final generation = ++_generation;
    // Marked read at the start, so the notifications a read sets off do
    // not start another one.
    _readAt = _clock();
    final ErgPriceHistory answer;
    try {
      answer = await _pricer.ergPriceHistory(PriceWindow.day);
    } catch (_) {
      // The pricer words its own failures; anything else leaves the last
      // answer standing until the next change asks again.
      return;
    }
    if (_disposed || generation != _generation) return;
    history = answer;
    _readAt = _clock();
    notifyListeners();
  }
}
