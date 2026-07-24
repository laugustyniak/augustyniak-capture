# Multi-modal capture — images, text, uploads, video

Status: proposed 2026-07-25. Branch `feat/multimodal-capture` (suggested).

## Goal

Extend the offline-first recorder so the Queue holds not just microphone recordings but also **images, text notes, uploaded audio files, and video** — each an item in the same list, each processed by a type-appropriate step. The core guarantee is unchanged and generalized: the source artifact is durably persisted to disk **before** any processing (transcription/OCR/audio-extraction) is attempted, and a processing failure never deletes the source. This ordering invariant in `RecordingsController.stopRecording()` is the reason the app exists — every new capture path must mirror it.

Non-goals: cloud sync/export, on-device inference, editing captured media, multi-file items. The Models tab still manages remote provider profiles only.

## Decision: extend `Recording`, do not introduce a parallel `CaptureItem`

**Recommendation: add a `type` field to the existing `Recording` and generalize its semantics, rather than introducing a new `CaptureItem`/`Attachment` model.**

Reasoning, tied to the code:

- The entire persistence + pipeline stack is keyed on one list type: `RecordingsRepository.loadAll/saveAll(List<Recording>)`, `RecordingsController._recordings`, `_update()`, `QueueTab._filter()`, `RecordingFilter`. A second model would fork all of it (a second index file, a second controller, a merged/sorted view) for zero domain benefit — every item shares `id`, `filePath`, `createdAt`, `status`, `transcript`/extracted-text, `error`, and the two independent state axes (`RecordingStatus` + `isProcessedByUser`/`processedAt`).
- The back-compat rule ("new fields default when absent") already exists and is tested (`test/recording_test.dart` "legacy JSON defaults to not reviewed"). Adding `type` with a default is the same well-worn pattern, not a migration.
- `status` (`saved` → `pendingTranscription` → `transcribing` → `completed`/`failed`) maps cleanly onto *any* processor: "queued", "running", "done", "failed". Only the labels differ, which is a presentation concern (`_statusVisual`), not a domain one.

Tradeoff accepted: the name `Recording` and the enum value `pendingTranscription` become slight misnomers for a text note. We keep the class name (renaming ripples through 30+ references and the `voice_notes_phase1` package path for no functional gain) and treat `RecordingStatus` as a generic processing-state enum. A doc comment on the class records this. If a future phase needs multi-attachment items, revisit then — but do not pay that cost now.

### `CaptureType` enum

New file `lib/features/recordings/domain/capture_type.dart`:

```dart
enum CaptureType {
  audioRecording, // mic capture, .m4a — the legacy default
  audioUpload,    // user-picked audio file, original extension
  image,          // photo/picked image, .jpg/.png
  text,           // typed note, .txt (body is the source artifact)
  video,          // captured/picked video, .mp4/.mov
}
```

`CaptureType.fromName(String?)` returns `audioRecording` for `null` or any unknown value — this is the legacy defaulting point, mirrored on the JSON boundary.

## Domain model changes (`domain/recording.dart`)

Add three fields, all with defaults so old JSON loads unchanged:

- `CaptureType type` — default `CaptureType.audioRecording`.
- `String? sourceMimeType` — recorded at ingestion so uploads keep their identity (e.g. `image/png`, `audio/mpeg`); nullable, absent on legacy rows.
- Reuse `transcript` as the **generic extracted-text field** for every processor (OCR text, caption, transcript). No new column — the field is already nullable and already what the Queue searches (`QueueTab._filter` haystack). A doc comment renames its meaning to "processor output text".

`durationMs` stays required but is `0` for image/text (harmless; `formatDuration(0)` renders `00:00`, and cards suppress it per type — see UX).

### JSON shape

Legacy row (loads today, must keep loading — no `type` key):

```json
{ "id": "…", "filePath": "…/x.m4a", "createdAt": "…", "durationMs": 1500,
  "status": "completed", "transcript": "…", "error": null,
  "isProcessedByUser": false, "processedAt": null }
```

New row:

```json
{ "id": "…", "filePath": "…/x.jpg", "createdAt": "…", "durationMs": 0,
  "status": "completed", "transcript": "OCR text…", "error": null,
  "isProcessedByUser": false, "processedAt": null,
  "type": "image", "sourceMimeType": "image/jpeg" }
```

### `fromJson` defaulting (same rule as `isProcessedByUser`)

```dart
type: CaptureType.fromName(json['type'] as String?),          // null → audioRecording
sourceMimeType: json['sourceMimeType'] as String?,            // null on legacy
```

`toJson` always emits both new keys; `copyWith` gains `type`/`sourceMimeType` passthroughs (immutable identity like `id`/`filePath` — set at construction, never mutated by the pipeline).

## Storage

Everything stays in the app-documents `recordings/` subfolder, one artifact per item keyed by `<uuid>.<ext>`, alongside `recordings.json`. Generalize `RecordingsRepository.createAudioFile` (which hardcodes `.m4a`) into an extension-aware helper:

```dart
Future<File> createSourceFile(String id, String extension); // '$id.$extension'
String extensionFor(CaptureType type, {String? sourceMimeType}); // policy
```

Extension policy:

| Type | Extension | Notes |
| --- | --- | --- |
| audioRecording | `m4a` | unchanged; encoder/container still fixed (CLAUDE.md) |
| audioUpload | original (mp3/wav/m4a/…) | preserved from picked file so the file plays back |
| image | jpg / png | from picked file's extension |
| text | txt | the note body is written to disk as the source artifact |
| video | mp4 / mov | from picked file |

Keep `createAudioFile` as a thin wrapper (`createSourceFile(id, 'm4a')`) so the live recording path is untouched while a concurrent process edits `lib/`.

**Important:** `id` derivation. `stopRecording()` today re-derives `id` from the filename by `replaceAll('.m4a', '')`. That must become extension-agnostic — derive `id` by stripping the last extension (`p.basenameWithoutExtension(path)`), or simpler, **stop re-deriving**: pass the already-generated `id` through the pipeline instead of parsing it back out of the path. The plan recommends passing `id` through, removing the fragile filename↔id coupling for all new paths.

### The critical invariant, generalized

For every type the order is identical to `stopRecording()` steps 1–4:

1. Produce/obtain the source bytes (recorder stop, picked file, typed text).
2. **Persist the source artifact to `recordings/<uuid>.<ext>` and verify it exists with length > 0** (throw `FileSystemException` otherwise). For text, "verify" = the `.txt` exists and byte length > 0.
3. Build the `Recording` with `status: saved`, prepend, `repository.saveAll()` (atomic `.tmp`+`rename`). The item is now durable and visible.
4. **Only then** dispatch processing (`_markAndProcess`). On processor failure the item stays `failed` with an `error` string, source file untouched, retryable. There is intentionally no delete anywhere — the same "no delete in MVP" rule.

A processor must never write to or delete the source file; it only reads it and returns text (or throws). This is the single most important rule for reviewers to enforce.

## Per-type processing: the `Processor` abstraction

Mirror `TranscriptionService` exactly. New file `lib/features/processing/domain/processor.dart`:

```dart
abstract interface class Processor {
  /// Reads [item]'s source file, returns extracted text. Must never mutate or
  /// delete the source. Throws on failure (caught by the controller → status failed).
  Future<String> process(Recording item);
}

class NoopProcessor implements Processor {          // text passthrough
  const NoopProcessor();
  Future<String> process(Recording item) async =>
      File(item.filePath).readAsString();           // note body is already the text
}

class ProcessorNotConfiguredException implements Exception { … }  // analogue of TranscriptionNotConfigured
```

Concrete processors (each its own file under `features/processing/data/`):

| Type | Processor | Behaviour | Needs new dep? |
| --- | --- | --- | --- |
| audioRecording | `TranscriptionProcessor` | wraps existing `TranscriptionService.transcribe(File)` | no — reuse |
| audioUpload | `TranscriptionProcessor` | same service, same file | no — reuse |
| text | `NoopProcessor` | returns the note body; item goes straight to `completed` | no |
| image | `OcrProcessor` | OCR (and/or caption) → text | **yes** (see deps) |
| video | `VideoTranscriptionProcessor` | extract audio track → temp `.m4a` → delegate to `TranscriptionService` | **yes** (ffmpeg) |

Dispatch: a `ProcessorRegistry` (plain map, constructor-injected into the controller, swappable like `transcriptionService`) resolves `CaptureType → Processor`. The controller's `_markAndTranscribe` becomes `_markAndProcess(id)`: identical state machine (`pendingTranscription`→`transcribing`→`completed`/`failed`), but instead of calling `_transcriptionService.transcribe(file)` directly it calls `registry.forType(item.type).process(item)`. Log strings become type-neutral ("Processing started/ready/failed"). The `_isBusy` serialization, `_update()`-through-`saveAll()`, and log-never-throws rules all carry over verbatim.

Because audio processors need the live `TranscriptionService` (which is runtime-swappable from the Models tab), the registry holds a getter/callback to the current service rather than a snapshot, preserving the "swap affects only subsequent work" rule.

### Offline-first tension (flag explicitly)

- Transcription is already cloud-by-default (`HttpWhisperTranscriptionService`) or local (`whisper.cpp` preset) — no change to the offline story.
- **OCR** can be fully on-device: `google_mlkit_text_recognition` (Android/iOS) runs offline with no token. This keeps images consistent with the app's local-first promise. **Captioning** (describe-the-image) is inherently a cloud LLM call and should be an *optional* profile-driven processor, not the default — default image processing is offline OCR; captioning is opt-in like a provider profile.
- **Video** transcription reuses the audio provider (cloud or local whisper), so it inherits whatever the user configured.
- Any cloud-only processor with no active/valid config must degrade gracefully to `ProcessorNotConfiguredException` (the OCR/caption analogue of `DisabledTranscriptionService`) so an unconfigured item fails cleanly and stays retryable — never crashes capture.

## Ingestion for uploads (mirror `stopRecording`'s verify-then-persist)

New controller entry points, each `_isBusy`-serialized exactly like `startRecording`/`stopRecording`:

- `addTextNote(String body)`
- `addImageFromPicker()` / `addImageFromCamera()`
- `addAudioUpload()` / `addVideoUpload()`

Ingestion algorithm (uploads), matching the invariant ordering:

1. Generate `id = uuid.v4()`, pick the source file via `image_picker`/`file_picker` (returns a path in a cache/temp dir, *not* the app dir).
2. Resolve extension + mime from the picked file.
3. **Copy** the picked bytes into `recordings/<id>.<ext>` (`await source.copy(dest.path)`), then **verify** `dest.exists() && dest.length() > 0` — throw `FileSystemException` otherwise. Copy-before-index is the exact analogue of "recorder writes file, then we verify length > 0."
4. Build `Recording(type: …, status: saved, filePath: dest.path, sourceMimeType: …)`, prepend, `repository.saveAll()`.
5. `_markAndProcess(id)`.

Text notes skip the picker: write the body to `recordings/<id>.txt` (flush: true), verify length > 0, then index, then `_markAndProcess` (which is `NoopProcessor` → immediate `completed`). Never index a note whose file didn't persist.

The picker's temp file is left to the OS to reclaim; we never treat it as the source of truth once copied.

## Capture / add UX

Replace the single mic FAB with a **capture menu**. Keep `RecordButton` behaviour for mic (start/stop with live timer) but present it as one option among several.

- **FAB → speed-dial / bottom sheet** (gated to the Queue tab exactly as today via `navigationIndex == queueIndex`). Options: Record audio (existing flow), Add photo (camera), Pick image, Pick audio file, Pick video, New text note. Recording stays a distinct in-place mode (the FAB still morphs to "SAVE mm:ss"); the other five open a picker or a small compose sheet, then return to the list.
- **Text note**: a `TextField` bottom sheet ("Nowa notatka"), Save writes the `.txt` and indexes.
- **Type-specific list cards** — generalize `_RecordingCard` by `recording.type` (leading icon + body):
  - audioRecording/audioUpload: current card (waveform icon, play button via `togglePlayback`, duration). Upload badge distinguishes picked audio.
  - image: leading **thumbnail** (`Image.file(File(filePath))` in the 40×40 slot, tap → full-screen), OCR text in the transcript slot, no play button, suppress duration.
  - text: document icon, the note body as preview text, no play/duration.
  - video: **poster/thumbnail** (frame extracted once, cached as `<id>.thumb.jpg` alongside — a derived file, not the source), play → external/inline video, duration shown.
  - The `LOCAL FILE VERIFIED` pill and `StatusPill(_statusVisual)` stay for all; `_statusVisual` labels become type-aware ("OCR RUNNING", "TRANSCRIBING", "NOTE SAVED").
- `RecordingFilter` labels are already status-based, so they work unchanged; optionally add a type facet later.

Playback: `togglePlayback` currently assumes audio via `audioplayers`. Guard it to audio types only; image/text tap opens a viewer instead. Video uses a separate player (or opens externally in the first slice).

## New dependencies

| Package | For | Justification | Platform caveats |
| --- | --- | --- | --- |
| `image_picker` | camera + gallery images, camera video | Flutter-first standard; returns a temp path we copy | Android/iOS solid. **Linux: no implementation** — camera/gallery unavailable on desktop; fall back to `file_picker` there. |
| `file_picker` | pick audio/image/video/any file from storage | needed for "upload existing file"; works where `image_picker` doesn't | Android/iOS/Linux supported; Linux uses native dialogs. |
| `google_mlkit_text_recognition` | offline image OCR | keeps images local-first, no token | **Android/iOS only.** No Linux/desktop. OCR processor must be feature-detected and degrade to "not configured" on desktop. |
| `ffmpeg_kit_flutter_*` (audio-extraction variant) | video → audio track for transcription | reuse existing transcription pipeline instead of a video API | Large binary; **mobile-only**, licensing variants matter; on Linux rely on a system `ffmpeg` via `Process.run` or defer video. |
| `video_thumbnail` (optional) | video poster frame | card thumbnail | mobile-only. |
| `mime` (optional, tiny) | resolve `sourceMimeType` from extension | avoids hand-rolled maps | pure Dart, all platforms. |

Per CLAUDE.md, `android/` and `ios/` are partial and regenerated with `flutter create --platforms=…` before running — new plugins' native registration is picked up by that regeneration, so no manual native edits belong in `lib/`. Because platform support is uneven, **processor/picker availability must be capability-gated at runtime** (e.g. hide unsupported capture options, and have the corresponding `Processor` throw `ProcessorNotConfiguredException` on unsupported platforms) rather than assumed.

## Phasing (independent vertical slices, each shippable)

Each slice is: domain field/enum + storage ext + one processor + one capture entry + one card variant + pure-Dart tests. Ordered by value/risk:

1. **Slice 0 — domain generalization (foundation, no user-visible feature).** Add `CaptureType`, `type`/`sourceMimeType` fields, `fromName` defaulting, extension-aware `createSourceFile`, id-passthrough in the pipeline, `Processor` abstraction + `ProcessorRegistry` + `TranscriptionProcessor` wrapping today's behaviour. All existing tests still pass; audio recording behaves identically. Ships as a pure refactor.
2. **Slice 1 — text notes (recommended first user-facing slice).** Smallest, fully offline, no new plugin, exercises the whole generalized path (new type, `.txt` source, `NoopProcessor`, capture sheet, text card). Proves the invariant end-to-end with zero platform risk. **Recommended first.**
3. **Slice 2 — audio upload.** `file_picker`, copy-then-index, reuse `TranscriptionProcessor`. High value (users have existing recordings), reuses all audio UI.
4. **Slice 3 — images + offline OCR.** `image_picker`/`file_picker` + `google_mlkit_text_recognition`, thumbnail card. First genuinely new processor; mobile-only OCR with graceful desktop degradation.
5. **Slice 4 — video.** Highest complexity (ffmpeg, thumbnails, size). Extract audio → existing transcription. Ship last, behind capability gating.

## Testing (pure Dart, no bindings — matches existing style)

Extend `test/recording_test.dart` and add `test/capture_type_test.dart`, `test/processor_test.dart`:

- **Type round-trip**: a `Recording` of each `CaptureType` with `sourceMimeType` survives `toJson`→`fromJson`.
- **Legacy defaulting**: JSON with no `type`/`sourceMimeType` key restores as `audioRecording`, `sourceMimeType == null` (extends the existing "legacy JSON defaults" test).
- **Unknown type degrades**: `CaptureType.fromName('hologram')` and `fromName(null)` → `audioRecording` (same pattern as `LogEvent` unknown-level → `info`).
- **Per-type storage keys**: `extensionFor(image, mime:'image/png') == 'png'`, `audioRecording == 'm4a'`, `text == 'txt'`; `createSourceFile(id, ext)` yields `<id>.<ext>` in the recordings dir.
- **id no longer coupled to `.m4a`**: deriving/roundtripping `id` for a `.jpg`/`.mp4` item keeps `id` intact.
- **Processor dispatch**: a fake `ProcessorRegistry` returns a recording `_FakeProcessor`; controller test (hand-written fakes, like `_FakeSettingsRepository`) verifies dispatch by `type`, and that a throwing processor lands the item in `status: failed` with `error` set **and the source file untouched** (assert file still exists) — the generalized invariant.
- **Text `NoopProcessor`**: reads back the exact note body; item reaches `completed` without a network service.
- **Ingestion ordering**: a fake repository asserts `saveAll` (index write) happens only after the source `File.exists() && length > 0`; a processor failure never triggers a delete.

## Risks and open questions

- **Naming debt.** `Recording`/`pendingTranscription` become generic. Accepted; documented in code. Revisit only if multi-attachment items appear.
- **Platform matrix.** OCR and ffmpeg are mobile-only; Linux desktop (a live target per CLAUDE.md) can capture text/uploads but not OCR/video. Requires runtime capability gating and graceful "not configured" degradation — must not crash or silently drop items.
- **`togglePlayback` assumes audio.** Must be type-guarded before Slice 1 lands cards for non-audio types.
- **Large binaries.** `ffmpeg_kit` and ML Kit inflate app size significantly; confirm this is acceptable before Slice 3/4, and prefer the smallest ffmpeg variant.
- **Derived files vs source.** Video thumbnails (`<id>.thumb.jpg`) are derived, not the source — deleting/regenerating them is safe, but they must never be confused with the source in the invariant. Document and keep them out of the "must persist before processing" rule.
- **Open: captioning provider.** Should image captioning reuse `ProviderProfile` (a second "vision" endpoint) or wait? Recommend deferring; ship offline OCR first.
- **Open: `durationMs` for non-audio.** Keep `0` and suppress in UI, or make nullable? Recommend `0` to avoid another back-compat field.
- **Concurrency with the in-flight `lib/` writer.** This plan deliberately keeps `createAudioFile` and the mic path as untouched wrappers so the concurrent process editing `lib/` and this design don't collide on the audio-recording flow.

## Critical files for implementation

- `lib/features/recordings/domain/recording.dart`
- `lib/features/recordings/data/recordings_repository.dart`
- `lib/features/recordings/presentation/recordings_controller.dart`
- `lib/features/recordings/presentation/queue_tab.dart`
- `lib/features/transcription/data/transcription_service.dart`
