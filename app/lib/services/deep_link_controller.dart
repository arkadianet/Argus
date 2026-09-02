import 'package:flutter/foundation.dart';

/// Parks an incoming deep link (ErgoPay today) until a screen that can act
/// on it is ready, e.g. after the wallet unlocks.
class DeepLinkController extends ChangeNotifier {
  String? _pending;

  String? get pending => _pending;

  void push(String link) {
    final clean = link.trim();
    if (clean.isEmpty) return;
    _pending = clean;
    notifyListeners();
  }

  /// Returns and clears the parked link.
  String? take() {
    final link = _pending;
    _pending = null;
    return link;
  }
}

final deepLinkController = DeepLinkController();
