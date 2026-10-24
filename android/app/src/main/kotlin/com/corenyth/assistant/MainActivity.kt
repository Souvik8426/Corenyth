package com.corenyth.assistant

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

open class MainActivity : FlutterActivity() {
    companion object {
        /// Alpha feedback goes to the developer's inbox through the user's mail app.
        const val FEEDBACK_EMAIL = "souvikdas8426@gmail.com"
        /// Hosts the model download link may point at (the app itself stays offline).
        val OPEN_URL_PREFIXES = listOf(
            "https://huggingface.co/",
            "https://github.com/Souvik8426/Corenyth/releases/",
        )
    }

    /** Models are private to the app; importing a document needs no storage permission. */
    private fun modelsDir() = File(filesDir, "models").apply { mkdirs() }

    private var documents: DocumentFiles? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val native = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "assistant/native")
        val files = DocumentFiles(this, native)
        documents = files
        native.setMethodCallHandler { call, result ->
            when (call.method) {
                "refreshWidget" -> { WidgetProvider.refreshAll(this); result.success(null) }
                "widgetCount" -> result.success(WidgetProvider.count(this))
                "pinWidget" -> result.success(WidgetProvider.requestPin(this, call.argument<Boolean>("compact") == true))
                "modelsDir" -> {
                    val dir = modelsDir()
                    result.success(mapOf("path" to dir.absolutePath, "granted" to true))
                }
                "importModel" -> {
                    val fileName = call.argument<String>("fileName")
                    if (fileName == null) result.error("read_failed", "A model file name is required.", null)
                    else files.pick(fileName, result)
                }
                "pickBackup" -> files.pick(null, result)
                "shareBackup" -> files.share(call.argument<String>("path"), result)
                "openUrl" -> {
                    val url = call.arguments as? String
                    if (url == null || OPEN_URL_PREFIXES.none { url.startsWith(it) }) {
                        result.error("bad_url", "only model download links are opened", null)
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

    @Deprecated("Uses the document picker request code for FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (documents?.onResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
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
        documents?.close()
        documents = null
        proactive?.let { Proactive.appChannels.remove(it) }
        proactive = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
