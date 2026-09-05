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

  static const _loanChannel = AndroidNotificationChannel(
    'argus_loans',
    'Loan health',
    description: 'A Duckpools loan of yours is close to its liquidation line or its deadline.',
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
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_channel);
      await android?.createNotificationChannel(_loanChannel);
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

  /// Progress of a mix: a round done, or the money delivered.
  Future<void> mixProgress({required String title, required String body}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: (title + body).hashCode & 0x7fffffff,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
      );
    } catch (e) {
      debugPrint('argus: notification failed: $e');
    }
  }

  /// A loan's health crossed a line, or its forced liquidation is near.
  /// One notification per loan and level: the id is the loan's.
  Future<void> loanHealth({required String loanId, required String title, required String body}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: loanId.hashCode & 0x7fffffff,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _loanChannel.id,
            _loanChannel.name,
            channelDescription: _loanChannel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('argus: notification failed: $e');
    }
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
