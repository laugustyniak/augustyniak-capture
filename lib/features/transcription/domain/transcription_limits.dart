import '../../settings/domain/audio_config.dart';

/// One ceiling on how much audio a single `/audio/transcriptions` request will
/// carry, plus the reason it exists — the reason is shown to the user, so it has
/// to name the thing that would otherwise bite them.
class TranscriptionCeiling {
  const TranscriptionCeiling(this.limit, this.reason);

  final Duration limit;
  final String reason;
}

/// How long one recording may be before the transcription endpoint stops
/// returning all of it.
///
/// Three independent ceilings apply to a single request and only the lowest
/// matters. They are kept apart rather than collapsed into one constant because
/// they **fail differently**, and exactly one of them fails silently:
///
/// * **upload size** — 25 MB, answered with a 400. Loud: the item lands
///   `failed` with the message on the card, and the source is still on disk.
/// * **model duration** — 1500 s on the `gpt-4o` transcribe family, also a 400
///   (`audio duration … is longer than 1500 seconds`). Equally loud.
/// * **output tokens** — 2000 on that same family, answered with **HTTP 200 and
///   a truncated `text`**. Nothing downstream can tell: `_processOne` sees a
///   success, writes `completed`, hands the fragment to the clipboard, and
///   enrichment titles the capture from half a meeting. The other two ceilings
///   report themselves; this one is the reason a cap exists at all.
///
/// Where the audio can be split before sending — desktop, via `AudioSplitter` —
/// none of this binds and [forRequest] is simply not consulted. A recording is
/// only capped where the whole file has to travel in one request.
class TranscriptionLimits {
  const TranscriptionLimits._();

  /// Shared by every hosted OpenAI-compatible endpoint this app ships a preset
  /// for (OpenAI, Groq). Decimal megabytes, which is the conservative reading —
  /// if the host meant MiB the cap is merely 5% early.
  static const int maxUploadBytes = 25 * 1000 * 1000;

  /// The `gpt-4o` transcribe family stops emitting at its 2000-token output
  /// ceiling, which reproduces around the nine-minute mark.
  ///
  /// Eight is that figure with the margin Polish costs: those measurements come
  /// from English, and Polish tokenizes denser (inflection, diacritics), so the
  /// real ceiling here sits lower than the observed one. By how much is
  /// **unmeasured** — this is a deliberately cautious estimate, not a reading.
  static const Duration outputTokenCeiling = Duration(minutes: 8);

  /// Hard limit on the same family, reported as a 400.
  static const Duration modelDurationCeiling = Duration(seconds: 1500);

  /// The binding ceiling for one unsplit request, or null when nothing here
  /// applies.
  ///
  /// The size ceiling is applied to every model, because a 25 MB upload cap is
  /// what every hosted endpoint in the presets enforces. The two `gpt-4o`
  /// ceilings are applied only to that family: capping a local whisper.cpp at
  /// eight minutes would end recordings for a server that has no such limit,
  /// and stopping a recording early is not a mistake worth making on a guess.
  static TranscriptionCeiling? forRequest({
    required String? model,
    required AudioConfig audio,
  }) {
    final int bytesPerSecond = audio.bitRate ~/ 8;
    final List<TranscriptionCeiling> ceilings = <TranscriptionCeiling>[
      if (bytesPerSecond > 0)
        TranscriptionCeiling(
          Duration(seconds: maxUploadBytes ~/ bytesPerSecond),
          '25 MB upload limit at ${audio.bitRate ~/ 1000} kbps',
        ),
      if (truncatesLongOutput(model)) ...<TranscriptionCeiling>[
        TranscriptionCeiling(
          outputTokenCeiling,
          '$model stops transcribing past ~2000 output tokens',
        ),
        TranscriptionCeiling(
          modelDurationCeiling,
          '$model rejects audio longer than 1500 s',
        ),
      ],
    ];

    if (ceilings.isEmpty) return null;
    return ceilings.reduce(
      (TranscriptionCeiling a, TranscriptionCeiling b) =>
          a.limit <= b.limit ? a : b,
    );
  }

  /// Whether this model silently truncates long transcripts.
  ///
  /// Matched on the name rather than an enum because the model field is free
  /// text: the user can type any string the endpoint accepts, and a closed list
  /// would answer "no limit" for the one model that has it. Covers
  /// `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` and `gpt-4o-transcribe-diarize`.
  static bool truncatesLongOutput(String? model) {
    if (model == null) return false;
    final String name = model.toLowerCase();
    return name.contains('gpt-4o') && name.contains('transcribe');
  }
}
