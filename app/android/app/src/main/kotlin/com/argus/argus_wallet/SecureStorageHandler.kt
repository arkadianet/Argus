package com.argus.argus_wallet

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
        private const val WALLET_REGISTRY_KEY = "wallet_registry"

        @Volatile
        var host: FragmentActivity? = null

        fun registerWith(engine: FlutterEngine, context: Context) {
            if (context is FragmentActivity) host = context
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger, CHANNEL
            )
            channel.setMethodCallHandler(SecureStorageHandler(context.applicationContext))
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

    private fun seedKey(walletId: String?) =
        if (walletId != null) "seed_${walletId}" else "encrypted_seed"

    private fun wrapKey(walletId: String?) =
        if (walletId != null) "wrap_${walletId}" else "wrap_key"

    private fun pinWrapKey(walletId: String?) =
        if (walletId != null) "pin_${walletId}" else "pin_wrap"

    private fun getWalletIds(): Set<String> {
        val reg = getPrefs().getStringSet(WALLET_REGISTRY_KEY, emptySet()) ?: emptySet()
        return reg.toMutableSet()
    }

    private fun saveWalletIds(ids: Set<String>): Boolean =
        getPrefs().edit().putStringSet(WALLET_REGISTRY_KEY, ids).commit()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val walletId = call.argument<String>("walletId")
            when (call.method) {
                "saveEncryptedSeed" -> {
                    val json = call.argument<String>("encryptedSeedJson")
                    if (json.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "Missing encryptedSeedJson", null)
                        return
                    }
                    if (!getPrefs().edit().putString(seedKey(walletId), json).commit()) {
                        result.error("STORAGE_ERROR", "Failed to persist seed", null)
                        return
                    }
                    if (walletId != null) {
                        val ids = getWalletIds().toMutableSet()
                        ids.add(walletId)
                        if (!saveWalletIds(ids)) {
                            result.error("STORAGE_ERROR", "Failed to update wallet registry", null)
                            return
                        }
                    }
                    result.success(true)
                }
                "loadEncryptedSeed" -> result.success(getPrefs().getString(seedKey(walletId), null))
                "saveWrapKey" -> {
                    val key = call.argument<String>("wrapKey")
                    if (key.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "Missing wrapKey", null)
                        return
                    }
                    if (!getPrefs().edit().putString(wrapKey(walletId), key).commit()) {
                        result.error("STORAGE_ERROR", "Failed to persist wrap key", null)
                        return
                    }
                    result.success(true)
                }
                "loadWrapKey" -> result.success(getPrefs().getString(wrapKey(walletId), null))
                "savePinWrap" -> {
                    val json = call.argument<String>("pinWrapJson")
                    if (json.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "Missing pinWrapJson", null)
                        return
                    }
                    if (!getPrefs().edit().putString(pinWrapKey(walletId), json).commit()) {
                        result.error("STORAGE_ERROR", "Failed to persist PIN wrap", null)
                        return
                    }
                    result.success(true)
                }
                "loadPinWrap" -> result.success(getPrefs().getString(pinWrapKey(walletId), null))
                "deleteWrapKey" -> {
                    if (!getPrefs().edit().remove(wrapKey(walletId)).commit()) {
                        result.error("STORAGE_ERROR", "Failed to delete wrap key", null)
                        return
                    }
                    result.success(null)
                }
                "deleteEncryptedSeed" -> {
                    val committed = getPrefs().edit()
                        .remove(seedKey(walletId))
                        .remove(wrapKey(walletId))
                        .remove(pinWrapKey(walletId))
                        .commit()
                    if (!committed) {
                        result.error("STORAGE_ERROR", "Failed to delete wallet secrets", null)
                        return
                    }
                    if (walletId != null) {
                        val ids = getWalletIds().toMutableSet()
                        ids.remove(walletId)
                        if (!saveWalletIds(ids)) {
                            result.error("STORAGE_ERROR", "Failed to update wallet registry", null)
                            return
                        }
                    }
                    result.success(null)
                }
                "deleteWallet" -> {
                    val wid = call.argument<String>("walletId")
                    if (wid == null) {
                        result.error("INVALID_ARGS", "Missing walletId", null)
                        return
                    }
                    if (!getPrefs().edit()
                        .remove(seedKey(wid))
                        .remove(wrapKey(wid))
                        .remove(pinWrapKey(wid))
                        .commit()
                    ) {
                        result.error("STORAGE_ERROR", "Failed to delete wallet secrets", null)
                        return
                    }
                    val ids = getWalletIds().toMutableSet()
                    ids.remove(wid)
                    if (!saveWalletIds(ids)) {
                        result.error("STORAGE_ERROR", "Failed to update wallet registry", null)
                        return
                    }
                    result.success(null)
                }
                "hasEncryptedSeed" -> {
                    if (walletId != null) {
                        result.success(getPrefs().contains(seedKey(walletId)))
                    } else {
                        result.success(
                            getPrefs().contains("encrypted_seed") ||
                            getPrefs().contains(WALLET_REGISTRY_KEY)
                        )
                    }
                }
                "hasPinWrap" -> result.success(getPrefs().contains(pinWrapKey(walletId)))
                "hasWrapKey" -> result.success(getPrefs().contains(wrapKey(walletId)))
                "listWalletIds" -> {
                    val ids = getWalletIds().toMutableList()
                    // Migration: if legacy single-wallet seed exists, add a migration ID
                    if (getPrefs().contains("encrypted_seed") && !ids.contains("legacy")) {
                        ids.add("legacy")
                    }
                    result.success(ids)
                }
                "loadPinGate" -> {
                    val prefs = getPrefs()
                    result.success(
                        mapOf(
                            "count" to prefs.getInt("pin_fail_count", 0),
                            "until" to prefs.getLong("pin_lock_until", 0L),
                        )
                    )
                }
                "savePinGate" -> {
                    val count = call.argument<Int>("count") ?: 0
                    val until = (call.argument<Number>("until") ?: 0).toLong()
                    if (!getPrefs().edit()
                        .putInt("pin_fail_count", count)
                        .putLong("pin_lock_until", until)
                        .commit()
                    ) {
                        result.error("STORAGE_ERROR", "Failed to persist PIN gate", null)
                        return
                    }
                    result.success(null)
                }
                "hasBiometric" -> {
                    val can = BiometricManager.from(context).canAuthenticate(
                        BiometricManager.Authenticators.BIOMETRIC_STRONG or
                            BiometricManager.Authenticators.BIOMETRIC_WEAK
                    )
                    result.success(can == BiometricManager.BIOMETRIC_SUCCESS)
                }
                "authenticateBiometric" -> authenticate(result, walletId)
                "setSecureFlag" -> {
                    val enable = call.argument<Boolean>("enable") ?: true
                    val activity = host
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
                "migrateLegacyWallet" -> {
                    val newWalletId = call.argument<String>("newWalletId")
                    if (newWalletId == null) {
                        result.error("INVALID_ARGS", "Missing newWalletId", null)
                        return
                    }
                    val legacySeed = getPrefs().getString("encrypted_seed", null)
                    val legacyWrap = getPrefs().getString("wrap_key", null)
                    val legacyPin = getPrefs().getString("pin_wrap", null)
                    if (legacySeed == null) {
                        result.success(false)
                        return
                    }
                    val editor = getPrefs().edit()
                    editor.putString("seed_${newWalletId}", legacySeed)
                    if (legacyWrap != null) editor.putString("wrap_${newWalletId}", legacyWrap)
                    if (legacyPin != null) editor.putString("pin_${newWalletId}", legacyPin)
                    editor.remove("encrypted_seed")
                    editor.remove("wrap_key")
                    editor.remove("pin_wrap")
                    if (!editor.commit()) {
                        result.error("STORAGE_ERROR", "Failed to migrate wallet", null)
                        return
                    }
                    val ids = getWalletIds().toMutableSet()
                    ids.add(newWalletId)
                    if (!saveWalletIds(ids)) {
                        result.error("STORAGE_ERROR", "Failed to update wallet registry", null)
                        return
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

    private fun authenticate(result: MethodChannel.Result, walletId: String?) {
        val activity = host
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
                        val wrap = getPrefs().getString(wrapKey(walletId), null)
                        result.success(wrap)
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
