package com.argus.argus_wallet

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Whether Android will throttle the app's background work, and the two
/// ways a user can lift that: the system's own exemption dialog, or the
/// app's battery settings page.
object BatteryHandler {
    private const val CHANNEL = "com.argus.wallet/battery"

    fun registerWith(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isUnrestricted" -> {
                    val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(context.packageName))
                }
                "requestUnrestricted" -> {
                    // The system dialog that exempts one app. Needs the
                    // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission.
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            .setData(Uri.parse("package:${context.packageName}"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "openBatterySettings" -> {
                    // The app's own details page, where "Battery" lives on
                    // every Android; the exemption list as a fallback.
                    val attempts = listOf(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(Uri.parse("package:${context.packageName}")),
                        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                    )
                    var opened = false
                    for (intent in attempts) {
                        try {
                            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            opened = true
                            break
                        } catch (_: Exception) {
                        }
                    }
                    result.success(opened)
                }
                "manufacturer" -> result.success(Build.MANUFACTURER ?: "")
                else -> result.notImplemented()
            }
        }
    }
}
