package com.argus.argus_wallet

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// What the in-app update flow needs from Android: the certificate(s) this
/// app is signed with (compared with a downloaded APK's signer), the CPU ABIs
/// (to pick the matching APK), a private folder for the download, and the
/// hand-off to the system installer.
object UpdateHandler {
    private const val CHANNEL = "com.argus.wallet/update"
    private const val DOWNLOAD_DIR = "updates"
    private const val APK_MIME = "application/vnd.android.package-archive"

    /// Must match `android:authorities` of the provider in the manifest.
    private fun authority(context: Context) = "${context.packageName}.updates"

    private fun downloadDir(context: Context) = File(context.cacheDir, DOWNLOAD_DIR)

    fun registerWith(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "signingCertificates" -> try {
                    result.success(signingCertificates(context))
                } catch (e: Exception) {
                    result.error("signing", e.message, null)
                }
                "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                // Not created here: nothing needs the folder until a download starts.
                "downloadDirectory" -> result.success(downloadDir(context).absolutePath)
                "canRequestInstall" -> result.success(canRequestInstall(context))
                "openInstallSettings" -> result.success(openInstallSettings(context))
                "installApk" -> result.success(installApk(context, call.argument<String>("path")))
                else -> result.notImplemented()
            }
        }
    }

    /// The DER certificates the installed app is signed with. Dart hashes
    /// them and compares with the signer it reads out of the downloaded APK,
    /// so nothing here is a constant that a rotated key would break.
    @Suppress("DEPRECATION")
    private fun signingCertificates(context: Context): List<ByteArray> {
        val pm = context.packageManager
        val name = context.packageName
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val flags = PackageManager.GET_SIGNING_CERTIFICATES
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(name, PackageManager.PackageInfoFlags.of(flags.toLong()))
            } else {
                pm.getPackageInfo(name, flags)
            }
            // The certificates the APK contents are signed with, as opposed to
            // the rotation history.
            info.signingInfo?.apkContentsSigners
        } else {
            pm.getPackageInfo(name, PackageManager.GET_SIGNATURES).signatures
        }
        return signatures?.map { it.toByteArray() } ?: emptyList()
    }

    /// Android 8+ makes "Install unknown apps" a per-app switch. Before that
    /// it was one system-wide switch the installer itself prompts for.
    private fun canRequestInstall(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()

    private fun openInstallSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /// Opens the system installer on [path]. Only an `.apk` directly inside
    /// the downloads folder is accepted, so this channel cannot be used to
    /// share any other file of the app.
    private fun installApk(context: Context, path: String?): Boolean {
        if (path == null) return false
        return try {
            val dir = downloadDir(context).canonicalFile
            val file = File(path).canonicalFile
            if (file.parentFile != dir || !file.name.endsWith(".apk") || !file.isFile) return false
            val uri = FileProvider.getUriForFile(context, authority(context), file)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, APK_MIME)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
