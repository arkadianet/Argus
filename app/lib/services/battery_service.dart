import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether Android will throttle Argus in the background, and the ways to
/// lift that. Only background mixing cares; nothing else in Argus runs
/// with the app closed.
class BatteryService {
  static const _channel = MethodChannel('com.argus.wallet/battery');

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True when the app is exempt from battery optimisation ("Unrestricted"
  /// in the app's battery settings). Null when it cannot be known.
  static Future<bool?> isUnrestricted() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<bool>('isUnrestricted');
    } catch (_) {
      return null;
    }
  }

  /// Show the system dialog that exempts Argus. Returns false when the
  /// dialog could not be opened; [openBatterySettings] is the fallback.
  static Future<bool> requestUnrestricted() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('requestUnrestricted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Open the app's own settings page, where Battery lives.
  static Future<bool> openBatterySettings() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The phone's maker, lower-cased, for pointing at brand-specific steps.
  static Future<String> manufacturer() async {
    if (!supported) return '';
    try {
      return (await _channel.invokeMethod<String>('manufacturer') ?? '').toLowerCase();
    } catch (_) {
      return '';
    }
  }
}

/// Makers known to ship their own background killer on top of Android's,
/// where the system exemption alone is often not enough.
const aggressiveBatteryMakers = {'samsung', 'xiaomi', 'huawei', 'oneplus', 'oppo', 'vivo', 'realme', 'honor'};

/// What to tell the user about background mixing on this phone.
String batteryAdvice({required bool? unrestricted, required String manufacturer}) {
  final maker = manufacturer.toLowerCase();
  final extra = aggressiveBatteryMakers.contains(maker)
      ? ' This phone\'s maker adds its own limits; dontkillmyapp.com has the steps for it.'
      : '';
  return switch (unrestricted) {
    true => 'Battery use is unrestricted, so the background job runs on time.$extra',
    false => 'Battery use is optimised: Android will delay the background job, sometimes for hours. '
        'Set Argus to Unrestricted to keep rounds on time.$extra',
    null => 'Could not read the battery setting.$extra',
  };
}
