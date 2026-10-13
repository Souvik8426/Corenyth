package com.corenyth.assistant

import android.os.Handler
import android.os.Looper
import androidx.annotation.Keep
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * "assistant/llm" handler backed by libllama_jni.so (src/main/cpp). Process-wide, so
 * MainActivity and VoiceSessionActivity share one model and one worker thread, which runs
 * load/generate/unload in order. cancel{id} runs inline: a queued request is rejected when
 * it reaches the worker, a running one is aborted natively; other requests are untouched.
 * While streaming, cumulative raw output goes back as text{id,text} on the caller's channel.
 * If the native lib is missing (e.g. 32-bit ABI, not built), load/generate return
 * `llama_unavailable` and the Dart side falls back to RuleEngine.
 */
object LlamaBridge {
    // Guarded by `jobs`: only a started job may nativeCancel, so cancelling a queued job never
    // overwrites the running job's native cancel id; a queued one is rejected via `cancelled`.
    private class Job(val nativeId: Long) {
        var cancelled = false
        var started = false
    }

    private val available = runCatching { System.loadLibrary("llama_jni") }.isSuccess
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val seq = AtomicLong()
    private val jobs = ConcurrentHashMap<String, Job>() // pending/running, keyed per channel
    private var loaded: String? = null // "path:contextSize", worker thread only
    private var sink: ((String) -> Unit)? = null // worker thread only

    private external fun nativeLoad(path: String, contextSize: Int): Boolean
    private external fun nativeGenerate(
        id: Long, prompts: Array<ByteArray>, maxTokens: Int, grammar: String?, stream: Boolean
    ): ByteArray
    private external fun nativeCancel(id: Long)
    private external fun nativeUnload()

    /** Called from nativeGenerate on the worker thread with complete UTF-8 only. */
    @Keep
    @Suppress("unused")
    private fun onNativeText(bytes: ByteArray) {
        sink?.invoke(String(bytes, Charsets.UTF_8))
    }

    private fun code(e: Throwable) = when (e.message) {
        "llama_cancelled", "prompt_too_long" -> e.message!!
        else -> "llama_error"
    }

    fun handle(channel: MethodChannel, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load", "generate", "unload", "cancel" -> {}
            else -> return result.notImplemented()
        }
        if (!available) {
            return if (call.method == "cancel" || call.method == "unload") result.success(null)
            else result.error("llama_unavailable", "llama.cpp native library not available on this device", null)
        }
        // Dart ids are unique per isolate only; the channel identifies the isolate.
        val key = "${System.identityHashCode(channel)}:${call.argument<Number>("id")}"
        if (call.method == "cancel") {
            synchronized(jobs) {
                jobs[key]?.let { it.cancelled = true; if (it.started) nativeCancel(it.nativeId) }
            }
            return result.success(null)
        }
        val job = if (call.method == "generate") Job(seq.incrementAndGet()).also { jobs[key] = it } else null
        worker.execute {
            val r = runCatching {
                when (call.method) {
                    "load" -> {
                        val path = requireNotNull(call.argument<String>("path")) { "path required" }
                        val ctx = call.argument<Int>("contextSize") ?: 2048
                        if ("$path:$ctx" == loaded) true
                        else {
                            loaded = null
                            nativeLoad(path, ctx).also { if (it) loaded = "$path:$ctx" }
                        }
                    }
                    "generate" -> try {
                        val job = job!!
                        // After this, a cancel goes native: nativeGenerate sees g_cancel_id == id
                        // even if it was written before the native start.
                        synchronized(jobs) { check(!job.cancelled) { "llama_cancelled" }; job.started = true }
                        val prompts = requireNotNull(call.argument<List<String>>("prompts")) { "prompts required" }
                        val id = call.argument<Number>("id")
                        if (call.argument<Boolean>("stream") == true) {
                            sink = { text -> main.post { channel.invokeMethod("text", mapOf("id" to id, "text" to text)) } }
                        }
                        String(nativeGenerate(job.nativeId, prompts.map { it.toByteArray(Charsets.UTF_8) }.toTypedArray(),
                            call.argument<Int>("maxTokens") ?: 160, call.argument<String>("grammar"),
                            sink != null), Charsets.UTF_8)
                    } finally {
                        sink = null
                        synchronized(jobs) { jobs.remove(key, job) }
                    }
                    else -> { nativeUnload(); loaded = null; null } // unload
                }
            }
            // Posted after every text event of this request, so Dart sees them first.
            main.post {
                r.fold({ result.success(it) }, { result.error(code(it), it.message, null) })
            }
        }
    }
}
