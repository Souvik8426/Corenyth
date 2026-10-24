package com.corenyth.assistant

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/** Document grants are used only while copying; no broad storage access is needed. */
class DocumentFiles(private val activity: Activity, private val channel: MethodChannel) {
    companion object {
        private const val PICK_DOCUMENT = 4812
        private const val MAX_BACKUP_BYTES = 64L * 1024 * 1024
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var modelName: String? = null
    @Volatile private var closed = false

    @Suppress("DEPRECATION") // FlutterActivity forwards this callback to plugins too.
    fun pick(fileName: String?, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("read_failed", "A file import is already running.", null)
            return
        }
        if (fileName != null && (!fileName.endsWith(".gguf") ||
                fileName.contains('/') || fileName.contains('\\') || fileName.contains(".."))) {
            result.error("read_failed", "Invalid model file name.", null)
            return
        }
        pending = result
        modelName = fileName
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, PICK_DOCUMENT)
        } catch (e: ActivityNotFoundException) {
            finish { it.error("no_picker", "No file picker is available on this device.", null) }
        } catch (e: Exception) {
            finish { it.error("read_failed", "The file picker could not be opened.", null) }
        }
    }

    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_DOCUMENT) return false
        if (pending == null) return true
        if (resultCode != Activity.RESULT_OK) {
            finish { it.success(null) }
            return true
        }
        val uri = data?.data
        if (uri == null) {
            finish { it.error("read_failed", "The picker returned no document.", null) }
            return true
        }
        val name = modelName
        worker.execute { copy(uri, name) }
        return true
    }

    private fun copy(uri: Uri, name: String?) {
        var partial: File? = null
        try {
            if (name != null) {
                val pickedName = activity.contentResolver.query(uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
                if (pickedName != name) {
                    main.post { finish { it.error("wrong_file",
                        "Choose $name. The selected file is ${pickedName ?: "unnamed"}.", null) } }
                    return
                }
            }
            val dir = File(if (name == null) activity.cacheDir else activity.filesDir,
                if (name == null) "backup-imports" else "models")
            if (!dir.isDirectory && !dir.mkdirs()) throw IOException("Cannot create import folder")
            // Remove abandoned imports, including a .part left by a killed process.
            if (name == null) dir.listFiles()?.forEach { it.delete() }
            val target = if (name == null) File.createTempFile("incoming-", ".corenyth", dir)
                else File(dir, name)
            partial = if (name == null) target else File(dir, "$name.part")
            var total = 0L
            var lastProgress = 0L
            val input = activity.contentResolver.openInputStream(uri) ?: throw IOException("No stream")
            input.use { source ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        if (closed || Thread.currentThread().isInterrupted) throw IOException("Import closed")
                        val count = source.read(buffer)
                        if (count < 0) break
                        total += count
                        if (name == null && total > MAX_BACKUP_BYTES) throw IOException("Backup exceeds 64 MiB")
                        output.write(buffer, 0, count)
                        val now = SystemClock.elapsedRealtime()
                        if (name != null && now - lastProgress >= 100) {
                            progress(total)
                            lastProgress = now
                        }
                    }
                    output.fd.sync()
                }
            }
            // Same-filesystem POSIX rename replaces the old model only after copying succeeds.
            if (name != null) Os.rename(partial.absolutePath, target.absolutePath)
            partial = null
            if (name != null) progress(total)
            main.post { finish { it.success(target.absolutePath) } }
        } catch (e: Exception) {
            partial?.delete()
            val noSpace = generateSequence<Throwable>(e) { it.cause }
                .any { it is ErrnoException && it.errno == OsConstants.ENOSPC }
            main.post { finish { it.error(if (noSpace) "no_space" else "read_failed",
                if (noSpace) "Not enough space to copy this file." else "The selected file could not be copied.", null) } }
        }
    }

    private fun progress(bytes: Long) {
        main.post {
            if (!closed) channel.invokeMethod("importProgress", mapOf("bytesCopied" to bytes))
        }
    }

    private fun finish(reply: (MethodChannel.Result) -> Unit) {
        val result = pending
        pending = null
        modelName = null
        if (!closed && result != null) reply(result)
    }

    fun share(path: String?, result: MethodChannel.Result) {
        val file = try { path?.let { File(it).canonicalFile } } catch (e: IOException) { null }
        val folder = File(activity.filesDir, "backups").canonicalFile
        if (file == null || !file.isFile || file.parentFile != folder || !file.name.endsWith(".corenyth")) {
            result.error("bad_path", "The backup file is gone or outside the backups folder.", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.backups", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/octet-stream"
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newRawUri("Corenyth backup", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(send, "Share Corenyth backup"))
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.error("no_app", "No app can receive the backup.", null)
        } catch (e: Exception) {
            result.error("bad_path", "The backup could not be shared.", null)
        }
    }

    fun close() {
        finish { it.error("read_failed", "The activity was closed during import.", null) }
        closed = true
        worker.shutdownNow()
    }
}
