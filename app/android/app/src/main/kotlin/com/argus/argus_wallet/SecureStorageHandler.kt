package com.argus.argus_wallet

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
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
        private const val WRAP_KEY = "wrap_key"
        private const val PIN_WRAP_KEY = "pin_wrap"
        private const val PIN_FAIL_KEY = "pin_fail_count"
        private const val PIN_LOCK_KEY = "pin_lock_until"

        @Volatile
        var host: FragmentActivity? = null

        fun registerWith(engine: FlutterEngine, context: Context) {
            if (context is FragmentActivity) host = context
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger, CHANNEL
            )
            channel.setMethodCallHandler(SecureStorageHandler(context))
        }
    }

    private fun isKeyInvalidated(e: Throwable): Boolean {
        var cur: Throwable? = e
        while (cur != null) {
            if (cur is android.security.keystore.KeyPermanentlyInvalidatedException) {
                return true
            }
            cur = cur.cause
        }
        return false
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

    private fun resetInvalidatedStorage() {
        prefs = null
        deletePrefsFile()
        deleteMasterKey()
    }

    private fun deletePrefsFile() {
        if (android.os.Build.VERSION.SDK_INT >= 24) {
            context.deleteSharedPreferences(PREFS_NAME)
        } else {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .commit()
            val dir = java.io.File(context.applicationInfo.dataDir, "shared_prefs")
            java.io.File(dir, "$PREFS_NAME.xml").delete()
        }
    }

    private fun deleteMasterKey() {
        try {
            val ks = java.security.KeyStore.getInstance("AndroidKeyStore")
            ks.load(null)
            ks.deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
        } catch (_: Exception) {
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "saveEncryptedSeed" -> {
                    val json = call.argument<String>("encryptedSeedJson")
                    if (json.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "Missing encryptedSeedJson", null)
                        return
                    }
                    if (!getPrefs().edit().putString(SEED_KEY, json).commit()) {
                        result.error("STORAGE_ERROR", "Failed to persist seed", null)
                        return
                    }
                    result.success(true)
                }
                "loadEncryptedSeed" -> result.success(getPrefs().getString(SEED_KEY, null))
                "saveWrapKey" -> {
                    val key = call.argument<String>("wrapKey")
                    if (key.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "Missing wrapKey", null)
                        return
                    }
                    if (!getPrefs().edit().putString(WRAP_KEY, key).commit()) {
                        result.error("STORAGE_ERROR", "Failed to persist wrap key", null)
                        return
                    }
                    result.success(true)
                }
                "loadWrapKey" -> result.success(getPrefs().getString(WRAP_KEY, null))
                "savePinWrap" -> {
                    val json = call.argument<String>("pinWrapJson")
                    if (json.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "Missing pinWrapJson", null)
                        return
                    }
                    if (!getPrefs().edit().putString(PIN_WRAP_KEY, json).commit()) {
                        result.error("STORAGE_ERROR", "Failed to persist PIN wrap", null)
                        return
                    }
                    result.success(true)
                }
                "loadPinWrap" -> result.success(getPrefs().getString(PIN_WRAP_KEY, null))
                "deleteWrapKey" -> {
                    if (!getPrefs().edit().remove(WRAP_KEY).commit()) {
                        result.error("STORAGE_ERROR", "Failed to delete wrap key", null)
                        return
                    }
                    result.success(null)
                }
                "deleteEncryptedSeed" -> {
                    if (!getPrefs().edit()
                        .remove(SEED_KEY)
                        .remove(WRAP_KEY)
                        .remove(PIN_WRAP_KEY)
                        .commit()
                    ) {
                        result.error("STORAGE_ERROR", "Failed to delete wallet secrets", null)
                        return
                    }
                    result.success(null)
                }
                "loadPinGate" -> {
                    val prefs = getPrefs()
                    result.success(
                        mapOf(
                            "count" to prefs.getInt(PIN_FAIL_KEY, 0),
                            "until" to prefs.getLong(PIN_LOCK_KEY, 0L),
                        )
                    )
                }
                "savePinGate" -> {
                    val count = call.argument<Int>("count") ?: 0
                    val until = (call.argument<Number>("until") ?: 0).toLong()
                    if (!getPrefs().edit()
                        .putInt(PIN_FAIL_KEY, count)
                        .putLong(PIN_LOCK_KEY, until)
                        .commit()
                    ) {
                        result.error("STORAGE_ERROR", "Failed to persist PIN gate", null)
                        return
                    }
                    result.success(null)
                }
                "hasEncryptedSeed" -> result.success(getPrefs().contains(SEED_KEY))
                "hasPinWrap" -> result.success(getPrefs().contains(PIN_WRAP_KEY))
                "hasWrapKey" -> result.success(getPrefs().contains(WRAP_KEY))
                "hasBiometric" -> {
                    val can = BiometricManager.from(context).canAuthenticate(
                        BiometricManager.Authenticators.BIOMETRIC_STRONG or
                            BiometricManager.Authenticators.BIOMETRIC_WEAK
                    )
                    result.success(can == BiometricManager.BIOMETRIC_SUCCESS)
                }
                "authenticateBiometric" -> authenticate(result)
                "setSecureFlag" -> {
                    val enable = call.argument<Boolean>("enable") ?: true
                    val activity = host ?: context as? Activity
                    if (activity == null) {
                        result.success(false)
                        return
                    }
                    activity.runOnUiThread {
                        if (enable) {
                            activity.window.setFlags(
                                WindowManager.LayoutParams.FLAG_SECURE,
                                WindowManager.LayoutParams.FLAG_SECURE
                            )
                        } else {
                            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            if (isKeyInvalidated(e)) {
                resetInvalidatedStorage()
                result.error("KEY_INVALIDATED", e.message, null)
            } else {
                result.error("STORAGE_ERROR", e.message, null)
            }
        }
    }

    private fun authenticate(result: MethodChannel.Result) {
        val activity = host ?: context as? FragmentActivity
        if (activity == null) {
            result.error("NO_ACTIVITY", "Biometric requires an activity", null)
            return
        }
        val executor = ContextCompat.getMainExecutor(activity)
        val prompt = BiometricPrompt(
            activity,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult) {
                    try {
                        result.success(getPrefs().getString(WRAP_KEY, null))
                    } catch (e: Exception) {
                        if (isKeyInvalidated(e)) {
                            resetInvalidatedStorage()
                            result.error("KEY_INVALIDATED", e.message, null)
                        } else {
                            result.error("STORAGE_ERROR", e.message, null)
                        }
                    }
                }

                override fun onAuthenticationError(code: Int, errString: CharSequence) {
                    if (code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                        code == BiometricPrompt.ERROR_USER_CANCELED ||
                        code == BiometricPrompt.ERROR_CANCELED
                    ) {
                        result.success(null)
                    } else {
                        result.error("BIOMETRIC", errString.toString(), null)
                    }
                }
            }
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Argus")
            .setNegativeButtonText("Use PIN")
            .build()
        activity.runOnUiThread { prompt.authenticate(info) }
    }
}
