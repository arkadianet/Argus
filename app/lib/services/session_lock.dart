import 'dart:async';

import 'package:flutter/widgets.dart';

import 'wallet_service.dart';

/// Locks the wallet after the app backgrounds, but not for system overlays.
///
/// Biometric sheets, share sheets, and the camera pause the activity. A short
/// grace window plus an explicit suppress count keep those from wiping the
/// in-memory handle mid-unlock.
class SessionLock {
  SessionLock({
    required this.onLock,
    this.grace = const Duration(milliseconds: 1500),
  });

  final VoidCallback onLock;
  final Duration grace;

  Timer? _pending;
  int _suppress = 0;
  bool _backgrounded = false;

  void suppress() => _suppress++;

  void release() {
    if (_suppress == 0) return;
    _suppress--;
    if (_suppress == 0 && _backgrounded) {
      _scheduleLock();
    }
  }

  Future<T> run<T>(Future<T> Function() body) async {
    suppress();
    try {
      return await body();
    } finally {
      release();
    }
  }

  void onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      _pending?.cancel();
      _pending = null;
      return;
    }
    if (state != AppLifecycleState.paused && state != AppLifecycleState.hidden) {
      return;
    }
    _backgrounded = true;
    if (_suppress > 0) return;
    _scheduleLock();
  }

  void _scheduleLock() {
    _pending?.cancel();
    _pending = Timer(grace, () {
      _pending = null;
      if (_suppress > 0 || !_backgrounded) return;
      onLock();
    });
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
  }
}

final sessionLock = SessionLock(
  onLock: () {
    walletService.lock().catchError((Object e, StackTrace st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
    });
  },
);
