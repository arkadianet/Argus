import 'package:flutter/services.dart';

import 'deep_link_controller.dart';

/// Receives `ergopay:` links from the Android side (cold start via
/// `getInitialLink`, warm start via `onLink`) and parks them in
/// [deepLinkController].
class DeepLinkChannel {
  static const _channel = MethodChannel('argus/deeplink');
  static bool _started = false;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink' && call.arguments is String) {
        deepLinkController.push(call.arguments as String);
      }
    });
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null) deepLinkController.push(initial);
    } on MissingPluginException {
      // Desktop / test hosts have no native side.
    } on PlatformException {
      // Nothing to open.
    }
  }
}
