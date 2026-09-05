import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'mix_service.dart';
import 'network_controller.dart';
import 'notification_service.dart';
import 'wallet_service.dart';

/// The periodic job that keeps mixes moving with the app closed.
///
/// Android only. WorkManager runs it about every fifteen minutes when the
/// device is online, in a fresh isolate with no wallet unlocked; the mix
/// keys in the keystore do the signing. Registered while background
/// mixing is on and at least one mix is in the pool, cancelled otherwise.
class MixBackground {
  static const taskName = 'argus-mix-advance';

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Call once at start-up, before the first [schedule].
  static Future<void> init() async {
    if (!supported) return;
    try {
      await Workmanager().initialize(mixBackgroundDispatcher);
    } catch (e) {
      debugPrint('argus: background mixing unavailable: $e');
    }
  }

  /// Register or cancel the job to match [wanted].
  static Future<void> schedule(bool wanted) async {
    if (!supported) return;
    try {
      if (wanted) {
        await Workmanager().registerPeriodicTask(
          taskName,
          taskName,
          frequency: const Duration(minutes: 15),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
          backoffPolicy: BackoffPolicy.linear,
          backoffPolicyDelay: const Duration(minutes: 5),
        );
      } else {
        await Workmanager().cancelByUniqueName(taskName);
      }
    } catch (e) {
      debugPrint('argus: could not ${wanted ? 'schedule' : 'cancel'} background mixing: $e');
    }
  }
}

/// Entry point WorkManager calls in its own isolate.
@pragma('vm:entry-point')
void mixBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // The native library, the node and explorer choice, and the
      // notification channel, all from scratch: nothing from the app's
      // isolate exists here.
      await walletService.init();
      await networkController.load();
      await notificationService.init();
      await mixService.tickHeadless();
    } catch (e) {
      debugPrint('argus: background mix tick failed: $e');
    }
    return true;
  });
}
