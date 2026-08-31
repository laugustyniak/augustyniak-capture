#include "augustyniak_whisper.h"

#include <stdlib.h>
#include <string.h>

#include "ggml.h"
#include "whisper.h"

#define AUG_ABI_VERSION "augustyniak-whisper-1"

static char *aug_strdup(const char *text) {
  const size_t length = strlen(text) + 1;
  char *copy = (char *)malloc(length);
  if (copy != NULL) memcpy(copy, text, length);
  return copy;
}

// Every failure path answers through `out_text` rather than through a code
// alone: the Dart side turns this straight into a capture's `error` field, and
// "local transcription failed (3)" is not something a user can act on.
static int32_t aug_fail(char **out_text, const char *reason) {
  if (out_text != NULL) *out_text = aug_strdup(reason);
  return 1;
}

// whisper.cpp logs model and buffer sizes through this callback, and its
// default writes them to stderr. Inside an app that is the user's terminal on
// Linux and the platform log on a phone — noise from a library, attributed to
// the app, for a job the user asked nothing about. The `print_*` params do not
// cover it: those govern transcript output, this is the loader talking.
static void aug_log_silence(enum ggml_log_level level, const char *text,
                            void *user_data) {
  (void)level;
  (void)text;
  (void)user_data;
}

const char *aug_whisper_abi_version(void) { return AUG_ABI_VERSION; }

void aug_whisper_string_free(char *text) { free(text); }

int32_t aug_whisper_transcribe(const char *model_path, const float *pcm,
                               int32_t n_samples, const char *language,
                               int32_t n_threads, char **out_text) {
  if (out_text == NULL) return 1;
  *out_text = NULL;

  if (model_path == NULL) return aug_fail(out_text, "No model path was given.");
  if (pcm == NULL || n_samples <= 0) {
    return aug_fail(out_text, "The decoded audio was empty.");
  }

  whisper_log_set(aug_log_silence, NULL);

  struct whisper_context_params cparams = whisper_context_default_params();
  struct whisper_context *ctx =
      whisper_init_from_file_with_params(model_path, cparams);
  if (ctx == NULL) {
    return aug_fail(out_text,
                    "The model file could not be loaded. It may be truncated "
                    "or not a ggml model.");
  }

  struct whisper_full_params wparams =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  wparams.n_threads = n_threads > 0 ? n_threads : 4;
  // Nothing may reach stdout: this runs inside the app, and whisper.cpp's
  // progress printing would land in the user's terminal or the platform log.
  wparams.print_realtime = false;
  wparams.print_progress = false;
  wparams.print_timestamps = false;
  wparams.print_special = false;
  wparams.translate = false;
  wparams.no_timestamps = true;
  // NULL means auto-detect. An empty string is not the same thing and would be
  // read as a language named "".
  wparams.language = (language != NULL && language[0] != '\0') ? language : NULL;

  if (whisper_full(ctx, wparams, pcm, n_samples) != 0) {
    whisper_free(ctx);
    return aug_fail(out_text, "The model failed to run on this audio.");
  }

  // Two passes: measure, then fill. A segment count is small and the strings
  // are owned by the context, so this is cheaper than repeated reallocation
  // and it keeps the single allocation the caller frees.
  const int n_segments = whisper_full_n_segments(ctx);
  size_t total = 1;
  for (int i = 0; i < n_segments; i++) {
    const char *segment = whisper_full_get_segment_text(ctx, i);
    if (segment != NULL) total += strlen(segment);
  }

  char *text = (char *)malloc(total);
  if (text == NULL) {
    whisper_free(ctx);
    return aug_fail(out_text, "Out of memory assembling the transcript.");
  }
  text[0] = '\0';
  for (int i = 0; i < n_segments; i++) {
    const char *segment = whisper_full_get_segment_text(ctx, i);
    if (segment != NULL) strcat(text, segment);
  }

  whisper_free(ctx);
  *out_text = text;
  return 0;
}
