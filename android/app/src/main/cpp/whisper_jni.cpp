// JNI bridge to whisper.cpp: load a model, transcribe 16 kHz mono float audio, free it.
#include <jni.h>
#include <string>
#include <thread>
#include <android/log.h>
#include "whisper.h"

#define TAG "PVWhisper"

extern "C" JNIEXPORT jlong JNICALL
Java_tv_mikehobbs_prosperityvoice_Whisper_nativeInit(JNIEnv *env, jclass, jstring path) {
    const char *p = env->GetStringUTFChars(path, nullptr);
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(p, cparams);
    env->ReleaseStringUTFChars(path, p);
    if (!ctx) __android_log_print(ANDROID_LOG_ERROR, TAG, "model failed to load");
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_tv_mikehobbs_prosperityvoice_Whisper_nativeFree(JNIEnv *, jclass, jlong handle) {
    if (handle) whisper_free(reinterpret_cast<whisper_context *>(handle));
}

// Returns the segments joined by "\n". Noise markers are filtered on the Kotlin side.
extern "C" JNIEXPORT jstring JNICALL
Java_tv_mikehobbs_prosperityvoice_Whisper_nativeTranscribe(JNIEnv *env, jclass, jlong handle,
                                                           jfloatArray audio, jstring prompt, jint threads) {
    auto *ctx = reinterpret_cast<whisper_context *>(handle);
    if (!ctx) return env->NewStringUTF("");
    jsize n = env->GetArrayLength(audio);
    jfloat *samples = env->GetFloatArrayElements(audio, nullptr);
    const char *promptChars = prompt ? env->GetStringUTFChars(prompt, nullptr) : nullptr;

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language = "en";
    params.n_threads = threads > 0 ? threads : 4;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.no_timestamps = true;
    params.no_speech_thold = 0.6f;
    params.suppress_blank = true;
    if (promptChars && promptChars[0]) params.initial_prompt = promptChars;

    std::string out;
    if (whisper_full(ctx, params, samples, n) == 0) {
        int segments = whisper_full_n_segments(ctx);
        for (int i = 0; i < segments; i++) {
            if (!out.empty()) out += "\n";
            out += whisper_full_get_segment_text(ctx, i);
        }
    } else {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "whisper_full failed");
    }

    if (promptChars) env->ReleaseStringUTFChars(prompt, promptChars);
    env->ReleaseFloatArrayElements(audio, samples, JNI_ABORT);
    return env->NewStringUTF(out.c_str());
}
