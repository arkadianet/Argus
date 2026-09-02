package com.argus.argus_wallet

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Hands `ergopay:` VIEW intents to Flutter. The link that launched the
/// activity is answered from `getInitialLink`; links arriving while the
/// app is open are pushed through `onLink`.
object DeepLinkHandler {
    private const val CHANNEL = "argus/deeplink"
    private var channel: MethodChannel? = null
    private var initialLink: String? = null

    fun registerWith(engine: FlutterEngine, launchIntent: Intent?) {
        initialLink = linkFrom(launchIntent)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        result.success(initialLink)
                        initialLink = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun onNewIntent(intent: Intent?) {
        val link = linkFrom(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("onLink", link) else initialLink = link
    }

    private fun linkFrom(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.dataString ?: return null
        return if (data.startsWith("ergopay:", ignoreCase = true)) data else null
    }
}
