// A deliberately tiny C ABI over whisper.cpp.
//
// **The reason this shim exists rather than binding whisper.h from Dart
// directly:** `whisper_full_params` is a large struct whose layout changes
// between whisper.cpp releases. Replicating it in `dart:ffi` would make the
// Dart side silently wrong — not fail to compile, but read the wrong fields —
// on any version bump. Everything version-sensitive is therefore resolved in C,
// against the headers the library was actually built with, and only these three
// functions cross into Dart.
#ifndef AUGUSTYNIAK_WHISPER_H
#define AUGUSTYNIAK_WHISPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define AUG_EXPORT __declspec(dllexport)
#else
#define AUG_EXPORT __attribute__((visibility("default")))
#endif

// Transcribes 16 kHz mono 32-bit float PCM.
//
// Returns 0 on success, non-zero on failure. `*out_text` always receives a
// heap-allocated NUL-terminated UTF-8 string owned by the caller — the
// transcript on success, the reason on failure — and must be released with
// `aug_whisper_string_free`. `language` may be NULL for auto-detection.
AUG_EXPORT int32_t aug_whisper_transcribe(const char *model_path,
                                          const float *pcm,
                                          int32_t n_samples,
                                          const char *language,
                                          int32_t n_threads,
                                          char **out_text);

AUG_EXPORT void aug_whisper_string_free(char *text);

// Non-NULL whenever the library loaded, so the Dart side can prove it is
// talking to this shim rather than to something else with the same file name.
AUG_EXPORT const char *aug_whisper_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif  // AUGUSTYNIAK_WHISPER_H
