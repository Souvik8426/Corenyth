package com.corenyth.assistant

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * "assistant/llm" handler backed by libllama_jni.so (src/main/cpp). Process-wide, so
 * MainActivity and VoiceSessionActivity share one model. load/generate/unload run on a
 * single worker thread; cancel runs inline so it can interrupt a generate in progress.
 * If the native lib is missing (e.g. 32-bit ABI, not built), load/generate return
 * `llama_unavailable` and the Dart side falls back to RuleEngine.
 */
object LlamaBridge {
    private val available = runCatching { System.loadLibrary("llama_jni") }.isSuccess
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var loadedPath: String? = null // worker thread only

    private external fun nativeLoad(path: String, contextSize: Int): Boolean
    private external fun nativeGenerate(prompt: ByteArray, maxTokens: Int, grammar: String?): ByteArray
    private external fun nativeCancel()
    private external fun nativeUnload()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load", "generate", "unload", "cancel" -> {}
            else -> return result.notImplemented()
        }
        if (!available) {
            return if (call.method == "cancel" || call.method == "unload") result.success(null)
            else result.error("llama_unavailable", "llama.cpp native library not available on this device", null)
        }
        if (call.method == "cancel") {
            nativeCancel()
            return result.success(null)
        }
        worker.execute {
            val r = runCatching {
                when (call.method) {
                    "load" -> {
                        val path = requireNotNull(call.argument<String>("path")) { "path required" }
                        if (path == loadedPath) true
                        else {
                            loadedPath = null
                            nativeLoad(path, call.argument<Int>("contextSize") ?: 2048)
                                .also { if (it) loadedPath = path }
                        }
                    }
                    "generate" -> {
                        val prompt = requireNotNull(call.argument<String>("prompt")) { "prompt required" }
                        String(nativeGenerate(prompt.toByteArray(Charsets.UTF_8),
                            call.argument<Int>("maxTokens") ?: 160, call.argument<String>("grammar")),
                            Charsets.UTF_8)
                    }
                    else -> { nativeUnload(); loadedPath = null; null } // unload
                }
            }
            main.post {
                r.fold({ result.success(it) }, { result.error("llama_error", it.message, null) })
            }
        }
    }
}
