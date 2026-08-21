import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wallet_service.dart';

/// Locks the wallet after the app backgrounds, but not for system overlays.
///
/// Biometric sheets, share sheets, and the camera pause the activity. A short
/// grace window plus an explicit suppress count keep those from wiping the
/// in-memory handle mid-unlock.
class SessionLock {
  SessionLock({
    required this.onLock,
    Duration grace = const Duration(seconds: 2),
  }) : _grace = grace;

  final VoidCallback onLock;
  Duration _grace = const Duration(seconds: 2);

  Timer? _pending;
  int _suppress = 0;
  bool _backgrounded = false;

  Duration get grace => _grace;

  Future<void> loadGrace() async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('argus_auto_lock_seconds') ?? 2;
    _grace = Duration(seconds: seconds);
  }

  Future<void> setGrace(Duration value) async {
    _grace = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('argus_auto_lock_seconds', value.inSeconds);
  }

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
    _pending = Timer(_grace, () {
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
