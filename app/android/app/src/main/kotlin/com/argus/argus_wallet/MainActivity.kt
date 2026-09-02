package com.argus.argus_wallet

import android.content.Intent
import android.view.WindowManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    init {
        System.loadLibrary("wallet_ffi")
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Balances, addresses and tx history stay out of recents thumbnails
        // and screen recordings. The mnemonic screens arm the same flag with
        // per-screen control; this keeps it on everywhere else.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SecureStorageHandler.registerWith(flutterEngine, this)
        DeepLinkHandler.registerWith(flutterEngine, intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        DeepLinkHandler.onNewIntent(intent)
    }

    override fun onDestroy() {
        if (SecureStorageHandler.host === this) {
            SecureStorageHandler.host = null
        }
        super.onDestroy()
    }
}
