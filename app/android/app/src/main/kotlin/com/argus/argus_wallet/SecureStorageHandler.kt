package com.argus.argus_wallet

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Secure storage method channel handler for Android Keystore. */
class SecureStorageHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "com.argus.wallet/secure_storage"
        private const val PREFS_NAME = "argus_secure_prefs"
        private const val SEED_KEY = "encrypted_seed"

        fun registerWith(engine: FlutterEngine, context: Context) {
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger, CHANNEL
            )
            channel.setMethodCallHandler(SecureStorageHandler(context))
        }
    }

    private var prefs: SharedPreferences? = null

    private fun getPrefs(): SharedPreferences {
        if (prefs == null) {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .setRequestStrongBoxBacked(true)
                .build()

            prefs = EncryptedSharedPreferences.create(
                context,
                PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        }
        return prefs!!
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "saveEncryptedSeed" -> {
                    val json = call.argument<String>("encryptedSeedJson")
                    getPrefs().edit().putString(SEED_KEY, json).apply()
                    result.success(true)
                }
                "loadEncryptedSeed" -> {
                    val stored = getPrefs().getString(SEED_KEY, null)
                    result.success(stored)
                }
                "deleteEncryptedSeed" -> {
                    getPrefs().edit().remove(SEED_KEY).apply()
                    result.success(null)
                }
                "hasEncryptedSeed" -> {
                    result.success(getPrefs().contains(SEED_KEY))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            if (e.message?.contains("KeyStore") == true) {
                result.error("KEY_INVALIDATED", e.message, null)
            } else {
                result.error("STORAGE_ERROR", e.message, null)
            }
        }
    }
}