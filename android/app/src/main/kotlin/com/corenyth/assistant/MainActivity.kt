package com.corenyth.assistant

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

open class MainActivity : FlutterActivity() {
    companion object {
        /// Alpha feedback goes to the developer's inbox through the user's mail app.
        const val FEEDBACK_EMAIL = "souvikdas8426@gmail.com"
    }

    /**
     * Android 11+: "All files access" (the model is a file other apps put there, so scoped
     * storage can't see it). Android 6-10: legacy WRITE_EXTERNAL_STORAGE runtime permission.
     */
    private fun storageGranted(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else packageManager.checkPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE, packageName) ==
            PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION") // still the right call for the shared Documents path
    private fun modelsDir() =
        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS), "localmodels")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "assistant/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "refreshWidget" -> { WidgetProvider.refreshAll(this); result.success(null) }
                    "widgetCount" -> result.success(WidgetProvider.count(this))
                    "pinWidget" -> result.success(WidgetProvider.requestPin(this, call.argument<Boolean>("compact") == true))
                    "modelsDir" -> {
                        val dir = modelsDir()
                        val granted = storageGranted()
                        if (granted) dir.mkdirs()
                        result.success(mapOf("path" to dir.absolutePath, "granted" to granted))
                    }
                    "requestStorageAccess" -> {
                        if (Build.VERSION.SDK_INT >= 30) {
                            startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")))
                        } else if (Build.VERSION.SDK_INT >= 23) {
                            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 1)
                        }
                        result.success(null) // Dart re-checks when the app resumes
                    }
                    "openUrl" -> {
                        val url = call.arguments as? String
                        if (url == null || !url.startsWith("https://huggingface.co/")) {
                            result.error("bad_url", "only https://huggingface.co/ links are opened", null)
                        } else try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_browser", "no browser installed", null)
                        }
                    }
                    "sendFeedback" -> {
                        // The user's own mail app via mailto: (no INTERNET needed). The
                        // recipient is fixed here; Dart only supplies the subject.
                        val version = try {
                            packageManager.getPackageInfo(packageName, 0).versionName
                        } catch (e: Exception) { "?" }
                        val body = "\n\n---\nCorenyth $version (alpha)\n" +
                            "Android ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT}), " +
                            "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}\n" +
                            "Model: ${call.argument<String>("model") ?: "none"}"
                        val mail = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:"))
                            .putExtra(Intent.EXTRA_EMAIL, arrayOf(FEEDBACK_EMAIL))
                            .putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "Corenyth feedback")
                            .putExtra(Intent.EXTRA_TEXT, body)
                        try {
                            startActivity(mail)
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_mail_app", "no mail app installed", FEEDBACK_EMAIL)
                        }
                    }
                    "openExternalLink" -> {
                        // Chat links: any https URL with a host. Strict java.net.URI parse
                        // rejects malformed input; javascript/file/intent/content/custom fail the scheme check.
                        val url = call.arguments as? String
                        val uri = try { java.net.URI(url ?: "") } catch (e: Exception) { null }
                        if (uri == null || !"https".equals(uri.scheme, true) || uri.host.isNullOrBlank()) {
                            result.error("bad_url", "only https links are opened", null)
                        } else try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri.toString()))
                                .addCategory(Intent.CATEGORY_BROWSABLE))
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_browser", "no browser installed", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        val llm = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "assistant/llm")
        llm.setMethodCallHandler { call, result -> LlamaBridge.handle(llm, call, result) }
        // Alarms/notifications: jobs run in this engine while it lives (see Proactive).
        intent?.getStringExtra(Proactive.EXTRA_TARGET)?.let {
            Proactive.launchTarget = it
            intent.removeExtra(Proactive.EXTRA_TARGET)
        }
        proactive = Proactive.channel(this, flutterEngine.dartExecutor.binaryMessenger)
            .also { Proactive.appChannels.add(it) }
    }

    private var proactive: MethodChannel? = null

    /** A notification tapped while the app is open: Dart navigates to its task or chat. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val target = intent.getStringExtra(Proactive.EXTRA_TARGET) ?: return
        intent.removeExtra(Proactive.EXTRA_TARGET)
        proactive?.invokeMethod("open", target)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        proactive?.let { Proactive.appChannels.remove(it) }
        proactive = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
