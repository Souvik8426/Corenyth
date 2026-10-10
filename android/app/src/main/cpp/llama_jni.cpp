// JNI side of LlamaBridge.kt. One process-wide model/context.
// load/generate/unload are serialized by LlamaBridge's single worker thread;
// only cancel() comes from another thread, so it touches nothing but an atomic.
#include <android/log.h>
#include <jni.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "llama.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "LlamaBridge", __VA_ARGS__)

static long long ms_since(std::chrono::steady_clock::time_point t) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t).count();
}

static llama_model *g_model = nullptr;
static llama_context *g_ctx = nullptr;
static std::atomic<bool> g_cancel{false};

static void free_all() {
    if (g_ctx) llama_free(g_ctx);
    if (g_model) llama_model_free(g_model);
    g_ctx = nullptr;
    g_model = nullptr;
}

static void throw_state(JNIEnv *env, const char *msg) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), msg);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeLoad(JNIEnv *env, jobject, jstring jpath, jint n_ctx) {
    static bool backend_ready = false;
    if (!backend_ready) {
        llama_backend_init();
        // llama.cpp logs to stderr, which Android drops; keep warnings/errors in logcat.
        llama_log_set([](ggml_log_level level, const char *text, void *) {
            if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR)
                __android_log_print(level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN,
                                    "llama.cpp", "%s", text);
        }, nullptr);
        backend_ready = true;
    }
    free_all();
    auto t_load = std::chrono::steady_clock::now();

    // Paths are app-internal ASCII; GetStringUTFChars' modified UTF-8 is fine here.
    const char *path = env->GetStringUTFChars(jpath, nullptr);
    g_model = llama_model_load_from_file(path, llama_model_default_params());
    env->ReleaseStringUTFChars(jpath, path);
    if (!g_model) return JNI_FALSE;

    auto cp = llama_context_default_params();
    cp.n_ctx = (uint32_t) n_ctx;
    cp.n_batch = (uint32_t) n_ctx;  // whole prompt in one llama_decode
    // ponytail: fixed <=4 threads (big cores on most big.LITTLE SoCs); tune from on-device telemetry.
    int threads = (int) std::clamp(std::thread::hardware_concurrency(), 1u, 4u);
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    cp.no_perf = true;
    g_ctx = llama_init_from_model(g_model, cp);
    if (!g_ctx) {
        free_all();
        return JNI_FALSE;
    }
    llama_set_abort_callback(g_ctx, [](void *) { return g_cancel.load(); }, nullptr);
    LOGI("loaded in %lld ms, n_ctx=%d, threads=%d", ms_since(t_load), n_ctx, threads);
    return JNI_TRUE;
}

// Prompt and result are raw UTF-8 bytes: JNI's modified UTF-8 mangles emoji and
// NewStringUTF aborts on the invalid UTF-8 a truncated generation can end with.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeGenerate(JNIEnv *env, jobject, jbyteArray jprompt, jint max_tokens,
                                                       jstring jgrammar) {
    if (!g_ctx) {
        throw_state(env, "model not loaded");
        return nullptr;
    }
    g_cancel = false;
    const llama_vocab *vocab = llama_model_get_vocab(g_model);

    // Optional GBNF grammar (ASCII, from Dart) constrains every sampled token; then greedy.
    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (jgrammar) {
        const char *g = env->GetStringUTFChars(jgrammar, nullptr);
        llama_sampler *gs = llama_sampler_init_grammar(vocab, g, "root");
        env->ReleaseStringUTFChars(jgrammar, g);
        if (!gs) {
            llama_sampler_free(smpl);
            throw_state(env, "invalid grammar");
            return nullptr;
        }
        llama_sampler_chain_add(smpl, gs);
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    std::string prompt(env->GetArrayLength(jprompt), '\0');
    env->GetByteArrayRegion(jprompt, 0, (jsize) prompt.size(), reinterpret_cast<jbyte *>(prompt.data()));

    // parse_special: the Dart side renders the full ChatML prompt (<|im_start|> etc.).
    int n = -llama_tokenize(vocab, prompt.data(), (int32_t) prompt.size(), nullptr, 0, true, true);
    if (n <= 0 || n + max_tokens > (int) llama_n_ctx(g_ctx)) {
        llama_sampler_free(smpl);
        throw_state(env, "prompt too long for context");
        return nullptr;
    }
    std::vector<llama_token> tokens(n);
    llama_tokenize(vocab, prompt.data(), (int32_t) prompt.size(), tokens.data(), n, true, true);

    // Every prompt is self-contained, so start from an empty KV cache.
    llama_memory_clear(llama_get_memory(g_ctx), true);

    std::string out;
    int generated = 0;
    auto t_prompt = std::chrono::steady_clock::now();
    long long prompt_ms = 0;
    bool prompt_ok = llama_decode(g_ctx, llama_batch_get_one(tokens.data(), n)) == 0;
    if (prompt_ok) {
        prompt_ms = ms_since(t_prompt);
        char buf[256];
        for (int i = 0; i < max_tokens && !g_cancel; i++) {
            llama_token tok = llama_sampler_sample(smpl, g_ctx, -1);
            if (llama_vocab_is_eog(vocab, tok)) break;
            int len = llama_token_to_piece(vocab, tok, buf, sizeof buf, 0, false);
            if (len > 0) out.append(buf, len);
            generated++;
            if (llama_decode(g_ctx, llama_batch_get_one(&tok, 1)) != 0) break;
        }
    }
    llama_sampler_free(smpl);
    if (!prompt_ok && !g_cancel) {
        throw_state(env, "llama_decode failed on prompt");
        return nullptr;
    }

    LOGI("prompt %d tok in %lld ms; generated %d tok in %lld ms%s", n, prompt_ms, generated,
         ms_since(t_prompt) - prompt_ms, g_cancel ? " (cancelled)" : "");
    LOGI("output: %.600s", out.c_str());
    jbyteArray res = env->NewByteArray((jsize) out.size());
    env->SetByteArrayRegion(res, 0, (jsize) out.size(), reinterpret_cast<const jbyte *>(out.data()));
    return res;
}

extern "C" JNIEXPORT void JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeCancel(JNIEnv *, jobject) {
    g_cancel = true;
}

extern "C" JNIEXPORT void JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeUnload(JNIEnv *, jobject) {
    free_all();
}
