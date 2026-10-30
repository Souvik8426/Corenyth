// JNI side of LlamaBridge.kt. One process-wide model/context.
// load/generate/unload are serialized by LlamaBridge's single worker thread;
// only cancel() comes from another thread, so it touches nothing but atomics.
#include <android/log.h>
#include <dlfcn.h>
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
// Cancel targets one request: abort only while the running request's id was cancelled.
// Kotlin calls nativeCancel only for the started job (under its lock), so this is never
// overwritten by a queued request's cancel, and a cancel written just before start still matches.
static std::atomic<long long> g_active_id{0};
static std::atomic<long long> g_cancel_id{-1};
// Tokens actually decoded into seq 0 of the KV cache (worker thread only).
static std::vector<llama_token> g_cached;

static bool cancelled() { return g_cancel_id.load() == g_active_id.load(); }

static void reset_cache() {
    if (g_ctx) llama_memory_clear(llama_get_memory(g_ctx), true);
    g_cached.clear();
}

static void free_all() {
    if (g_ctx) llama_free(g_ctx);
    if (g_model) llama_model_free(g_model);
    g_ctx = nullptr;
    g_model = nullptr;
    g_cached.clear();
}

// Kotlin maps these exact messages to channel error codes.
static void throw_state(JNIEnv *env, const char *msg) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), msg);
}

// Length of the longest prefix that does not end inside a UTF-8 sequence.
static size_t utf8_complete_len(const std::string &s) {
    size_t n = s.size();
    for (size_t back = 1; back <= 4 && back <= n; back++) {
        auto c = (unsigned char) s[n - back];
        if ((c & 0xC0) == 0x80) continue;  // continuation byte
        size_t need = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 1;
        return need > back ? n - back : n;
    }
    return n;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeLoad(JNIEnv *env, jobject, jstring jpath, jint n_ctx) {
    static bool backend_ready = false;
    if (!backend_ready) {
        // Backends are separate libs next to this one; load the best CPU variant for this phone.
        Dl_info info;
        if (dladdr((void *) &Java_com_corenyth_assistant_LlamaBridge_nativeLoad, &info) && info.dli_fname) {
            std::string dir = info.dli_fname;
            dir.resize(dir.find_last_of('/'));
            ggml_backend_load_all_from_path(dir.c_str());
        }
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
    llama_set_abort_callback(g_ctx, [](void *) { return cancelled(); }, nullptr);
    LOGI("loaded in %lld ms, n_ctx=%d, threads=%d", ms_since(t_load), n_ctx, threads);
    return JNI_TRUE;
}

static std::vector<llama_token> tokenize(const llama_vocab *vocab, const std::string &s) {
    // parse_special: the Dart side renders the full ChatML prompt and neutralizes
    // markers inside untrusted text, so only its own <|im_start|> etc. become control tokens.
    int n = -llama_tokenize(vocab, s.data(), (int32_t) s.size(), nullptr, 0, true, true);
    std::vector<llama_token> t(std::max(n, 0));
    if (n > 0) llama_tokenize(vocab, s.data(), (int32_t) s.size(), t.data(), n, true, true);
    return t;
}

// prompts: UTF-8 candidates, fullest first; the first that fits with max_tokens is used.
// Returns raw UTF-8 bytes (JNI's modified UTF-8 mangles emoji). While generating, calls
// thiz.onNativeText(byte[]) with the cumulative complete-UTF-8 output when streaming.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeGenerate(JNIEnv *env, jobject thiz, jlong id, jobjectArray jprompts,
                                                       jint max_tokens, jstring jgrammar, jboolean stream) {
    if (!g_ctx) {
        throw_state(env, "model not loaded");
        return nullptr;
    }
    g_active_id = id;
    if (cancelled()) {
        throw_state(env, "llama_cancelled");
        return nullptr;
    }
    const llama_vocab *vocab = llama_model_get_vocab(g_model);
    const int n_ctx = (int) llama_n_ctx(g_ctx);

    std::vector<llama_token> tokens;
    for (jsize i = 0, c = env->GetArrayLength(jprompts); i < c && tokens.empty(); i++) {
        auto jp = (jbyteArray) env->GetObjectArrayElement(jprompts, i);
        std::string s(env->GetArrayLength(jp), '\0');
        env->GetByteArrayRegion(jp, 0, (jsize) s.size(), reinterpret_cast<jbyte *>(s.data()));
        env->DeleteLocalRef(jp);
        auto t = tokenize(vocab, s);
        if (!t.empty() && (int) t.size() + max_tokens <= n_ctx) tokens = std::move(t);
    }
    if (tokens.empty()) {
        throw_state(env, "prompt_too_long");
        return nullptr;
    }
    const int n = (int) tokens.size();

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

    // KV reuse: keep the longest common token prefix with what is decoded, drop the rest.
    // At least one prompt token is always decoded so the last position has fresh logits.
    llama_memory_t mem = llama_get_memory(g_ctx);
    int reuse = 0;
    while (reuse < (int) g_cached.size() && reuse < n - 1 && g_cached[reuse] == tokens[reuse]) reuse++;
    if (reuse < (int) g_cached.size()) {
        if (llama_memory_seq_rm(mem, 0, reuse, -1)) g_cached.resize(reuse);
        else { reset_cache(); reuse = 0; }
    }

    jmethodID on_text = stream ? env->GetMethodID(env->GetObjectClass(thiz), "onNativeText", "([B)V") : nullptr;
    const char *err = nullptr;
    std::string out;
    size_t sent = 0;
    int generated = 0;
    long long prompt_ms = 0, first_ms = -1;
    auto t0 = std::chrono::steady_clock::now();

    // llama_batch_get_one leaves positions to the memory: they continue after seq_pos_max.
    if (llama_decode(g_ctx, llama_batch_get_one(tokens.data() + reuse, n - reuse)) != 0) {
        err = cancelled() ? "llama_cancelled" : "llama_decode failed on prompt";
    } else {
        g_cached = tokens;
        prompt_ms = ms_since(t0);
        char buf[256];
        for (int i = 0; i < max_tokens; i++) {
            if (cancelled()) { err = "llama_cancelled"; break; }
            llama_token tok = llama_sampler_sample(smpl, g_ctx, -1);
            if (first_ms < 0) first_ms = ms_since(t0);
            if (llama_vocab_is_eog(vocab, tok)) break;
            int len = llama_token_to_piece(vocab, tok, buf, sizeof buf, 0, false);
            if (len > 0) out.append(buf, len);
            generated++;
            size_t ok = utf8_complete_len(out);
            if (on_text && ok > sent) {
                sent = ok;
                jbyteArray chunk = env->NewByteArray((jsize) ok);
                env->SetByteArrayRegion(chunk, 0, (jsize) ok, reinterpret_cast<const jbyte *>(out.data()));
                env->CallVoidMethod(thiz, on_text, chunk);
                env->DeleteLocalRef(chunk);
                if (env->ExceptionCheck()) env->ExceptionClear();  // a UI hiccup must not kill decode
            }
            if (i + 1 == max_tokens) break;  // no need to decode a token nobody samples after
            if (llama_decode(g_ctx, llama_batch_get_one(&tok, 1)) != 0) {
                err = cancelled() ? "llama_cancelled" : "llama_decode failed";
                break;
            }
            g_cached.push_back(tok);
        }
    }
    llama_sampler_free(smpl);

    // Numeric timings only; never the prompt or output text.
    LOGI("prompt %d tok (%d reused) in %lld ms; first token %lld ms; generated %d tok in %lld ms%s", n, reuse,
         prompt_ms, first_ms, generated, ms_since(t0) - prompt_ms, err ? " (failed)" : "");
    if (err) {
        reset_cache();  // partially decoded state is not trustworthy for reuse
        throw_state(env, err);
        return nullptr;
    }
    jbyteArray res = env->NewByteArray((jsize) out.size());
    env->SetByteArrayRegion(res, 0, (jsize) out.size(), reinterpret_cast<const jbyte *>(out.data()));
    return res;
}

extern "C" JNIEXPORT void JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeCancel(JNIEnv *, jobject, jlong id) {
    g_cancel_id = id;
}

extern "C" JNIEXPORT void JNICALL
Java_com_corenyth_assistant_LlamaBridge_nativeUnload(JNIEnv *, jobject) {
    free_all();
}
