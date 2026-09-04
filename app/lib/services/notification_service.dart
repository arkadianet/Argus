import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../format.dart';

/// Local notifications for incoming payments. Nothing leaves the device.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _permissionAsked = false;

  static const _channel = AndroidNotificationChannel(
    'argus_payments',
    'Incoming payments',
    description: 'A payment to one of your addresses was seen on the network.',
    importance: Importance.high,
  );

  Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);
      _ready = true;
    } catch (e) {
      debugPrint('argus: notifications unavailable: $e');
    }
  }

  /// Asks once per launch, after the wallet is unlocked (Android 13+).
  Future<void> requestPermission() async {
    if (!_ready || _permissionAsked) return;
    _permissionAsked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  Future<void> incomingPayment({
    required int nanoErg,
    required String walletName,
    required bool pending,
    bool stealth = false,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: nanoErg.hashCode & 0x7fffffff,
        title: incomingTitle(pending: pending, stealth: stealth),
        body: '${formatErg(nanoErg, maxFrac: 4)} to $walletName',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('argus: notification failed: $e');
    }
  }
}

final notificationService = NotificationService();

/// A stealth receipt is always confirmed by the time it is detected: it is
/// found in the unspent set, not the mempool, so it is never "on the way".
String incomingTitle({required bool pending, required bool stealth}) {
  if (stealth) return 'Stealth payment received';
  return pending ? 'Payment on the way' : 'Payment received';
}
