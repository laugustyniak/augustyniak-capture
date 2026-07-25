# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Offline-first Flutter voice recorder ("Voice Notes — Phase 1"). Core guarantee: audio is durably persisted to disk **before** transcription is ever attempted, and a transcription failure never deletes a recording. This ordering invariant is the reason the app exists — preserve it in any change.

The `pubspec.yaml` name is `voice_notes_phase1`; the runtime app title is `Audivoa Core`. README is in Polish; user-facing strings in code are Polish, code identifiers/comments are English.

## Commands

Platform directories (`android/`, `ios/`) are partial. Generate the full native scaffolding with the local Flutter SDK before running — this keeps `lib/` intact:

```bash
flutter create --platforms=android,ios .
flutter pub get
```

- Run: `flutter run`
- Run with transcription token: `flutter run --dart-define=TRANSCRIPTION_TOKEN=secret`
- All tests: `flutter test`
- Single test file: `flutter test test/recording_test.dart`
- Single test by name: `flutter test --plain-name "legacy JSON defaults to not reviewed"`
- Analyze/lint: `flutter analyze` (config in `analysis_options.yaml`: `flutter_lints` + `avoid_print`, `prefer_final_locals`)

Dart SDK `>=3.10.0 <4.0.0`. Runtime deps: `record` (capture), `audioplayers` (playback), `path_provider` (app docs dir), `uuid` (id = source filename), `http` (Whisper adapter), `file_picker` (upload picker). No state-mgmt/DI package.

## Architecture

Feature-first layout under `lib/features/<feature>/{domain,data,presentation}`. Five features: `recordings`, `transcription`, `processing`, `settings`, `logs`. No state-management or DI package — plain `ChangeNotifier` + constructor injection.

**Capture types** — the queue is multi-modal. `CaptureType` (`recordings/domain/capture_type.dart`) is `audioRecording` / `audioUpload` / `image` / `text` / `video`. `CaptureType.fromName(null | unknown)` returns `audioRecording`, which is the legacy-defaulting point for rows written before the field existed. Shipped today: mic recordings, text notes, and **file upload for all types** (audio/image/video) via the `+` capture menu → `file_picker`. Every capture type has a real processor: audio (recorded or uploaded) transcribes, text passes through, **image runs OCR** and **video extracts its audio track then transcribes**. Image/video processing is **desktop-first**, via system binaries (`tesseract` for OCR, `ffmpeg` for video audio-extraction) shelled out the same way `record_linux` uses `parecord`/`ffmpeg`. On mobile (no tesseract/ffmpeg wired yet) those two degrade to unavailable, so an image/video item is still ingested and listed but its processing lands `failed` (retryable, source intact). Missing desktop binaries degrade the same clean way.

**Navigation** — four bottom-nav tabs, one file per body, all hosted by the `RecordingsPage` shell (`features/recordings/presentation/recordings_page.dart`) inside an `IndexedStack` so tab state survives switching:

| Index | Tab | Body | Backed by |
| --- | --- | --- | --- |
| 0 | Queue | `recordings/presentation/queue_tab.dart` | `RecordingsController` |
| 1 | Models | `settings/presentation/models_tab.dart` | `SettingsController` |
| 2 | Logs | `logs/presentation/logs_tab.dart` | `LogStore` |
| 3 | Config | `settings/presentation/config_tab.dart` | `SettingsController` |

The shell owns all three controllers, merges them into one `Listenable`, and on every settings change pushes `settings.transcriptionService` and `settings.audio` into the recordings controller. The capture FAB is gated to index 0.

**Capture lifecycle** — the ordered pipeline. Every capture entry point follows the identical order; `RecordingsController.stopRecording()` is the reference implementation and `addTextNote()` mirrors it. Do not reorder these steps:
1. obtain the source bytes (`recorder.stop()` → file path; for a note, write the `.txt`)
2. verify the file exists **and** length > 0 (throw `FileSystemException` otherwise)
3. build `Recording` with status `saved`, prepend to in-memory list
4. `repository.saveAll()` — atomic persist (write `.tmp`, then `rename`)
5. only then `_markAndProcess()` sets `pendingTranscription` → `transcribing` → `completed`/`failed`

Any new capture path (upload, image, video) must mirror steps 1–5 exactly. Uploads do so via `MediaImporter` (`recordings/data/media_importer.dart`): it copies the picked file into the recordings dir as `<id>.<ext>` and verifies length > 0 (steps 1–2) before `addUpload` indexes it — the file source comes from the injectable `MediaPicker` seam (`FilePickerMediaPicker` in production, a fake in tests). Processing runs as a separate step; on error the item stays with status `failed` and an `error` string, retryable via `retryTranscription()`. There is intentionally **no delete** in the MVP.

**Controller invariants** (`recordings_controller.dart`) — beyond the pipeline order:
- Every state mutation goes through `_update()`, which calls `repository.saveAll(_recordings)` — the **entire** `recordings.json` index is atomically rewritten on each status transition, toggle, and retry. There is no partial/incremental write.
- A single `_isBusy` flag serializes all work: `startRecording`, `stopRecording`, `addTextNote`, `addUpload`, and `retryTranscription` early-return if busy. No two operations run concurrently. `addUpload` holds the lock across the whole pick→copy→process, including the file-dialog await.
- `startRecording()` gates on `recorder.hasPermission()` and sets a Polish mic-permission error on denial before any file is created.
- `id` is generated (`uuid.v4()`) at capture start and used as the source filename. It is **passed through** the pipeline (`_activeId`), not parsed back out of the path — extensions vary per capture type, so the old `replaceAll('.m4a', '')` round-trip is gone.
- `transcriptionService` and `audioConfig` are **settable at runtime** (from the Models/Config tabs). A swap only affects work started afterwards — it must never mutate an in-flight pipeline or a file already on disk.
- An optional `LogSink` (default `NoopLogSink`) receives one event per transition. Logging must never throw into the pipeline; keep emissions side-effect free.

**Two independent state axes on `Recording`** (`domain/recording.dart`), keep them separate:
- AI processing: `RecordingStatus` enum (`saved`/`pendingTranscription`/`transcribing`/`completed`/`failed`). Despite the names this is **generic** processing state — "queued"/"running" for whichever processor the item's type resolves to. The names are kept because they are persisted in JSON.
- User review: `isProcessedByUser` bool + `processedAt` — set via `toggleProcessed()`, never touched by processing

`Recording` covers every capture type, not just audio: `type` (defaults to `audioRecording`), `sourceMimeType` (null on legacy rows and mic captures), and `transcript` — which is the **generic processor-output text** (transcript, OCR result, or note body), and what Queue search matches on. `durationMs` is `0` for images and text; the card suppresses it via `CaptureType.hasDuration`.

**Persistence** — three JSON files, all in the app documents `recordings/` subfolder, all written with the same atomic `.tmp` + `rename`:
- `recordings.json` (`recordings/data/recordings_repository.dart`) — the index; source artifacts as `<uuid>.<ext>` alongside it, one per item. The extension comes from `RecordingsRepository.extensionFor(type, sourceMimeType:)`, which delegates to the single policy definition in `capture_type.dart`: `m4a` for mic captures, `txt` for notes, mime-derived (with a per-type fallback) for uploads.
- `settings.json` (`settings/data/settings_repository.dart`) — provider profiles, active profile id, audio params.
- `logs.json` (`logs/data/log_store.dart` → `FileLogArchive`) — capped at 500 events, coalesced single-flight writes.

Every `fromJson` must stay backward-compatible: new fields default when absent (see the "legacy JSON" tests).

**Transcription** (`features/transcription/data/transcription_service.dart`): `TranscriptionService` interface with two impls. `DisabledTranscriptionService` throws `TranscriptionNotConfiguredException`; it is the fallback whenever no provider profile is active. `HttpWhisperTranscriptionService` POSTs `multipart/form-data` field `file` to a configurable endpoint, optional bearer token, expects `{"text": ...}` (falls back to `transcript`).

**Processing** (`features/processing/`): `Processor` turns an item's source file into text. **The rule to enforce in review: a processor only ever reads the source — never writes, moves or deletes it.** On failure it throws; the controller catches, marks the item `failed`, and the source stays on disk, retryable. `ProcessorRegistry` maps `CaptureType → Processor` and is constructor-injectable for tests; `ProcessorRegistry.standard()` wires `TranscriptionProcessor` for both audio types, `TextPassthroughProcessor` for notes, `OcrProcessor` for images, and `VideoTranscriptionProcessor` for video. Each of the latter two holds a *resolver* (like `TranscriptionProcessor`) so a Models/Config swap only affects subsequent jobs. Two swappable engine seams sit behind them, mirroring `TranscriptionService`:
- `OcrService` (`processing/data/ocr_service.dart`) — `DisabledOcrService` default (throws `ProcessorNotConfiguredException`); `TesseractOcrService` shells out to system `tesseract` (`pol+eng`).
- `VideoAudioExtractor` (`processing/data/video_audio_extractor.dart`) — `UnavailableVideoAudioExtractor` default; `FfmpegVideoAudioExtractor` pulls a 16 kHz mono AAC track via system `ffmpeg` into a temp dir. `VideoTranscriptionProcessor` transcribes that track then deletes the derived temp audio — the source video is never touched.

The shell picks the desktop impls (`Tesseract`/`Ffmpeg`) on Linux/macOS/Windows and the disabled/unavailable impls on mobile (`RecordingsPage._buildOcrService` / `_buildVideoAudioExtractor`); a missing binary throws from `Process.run` and the item fails cleanly, retryable.

**Settings** (`features/settings/`): `ProviderProfile` is a named endpoint (name, endpoint, model, language, bearerToken) and knows how to build its own service via `toService()` — a blank or schemeless endpoint degrades to the disabled service instead of throwing at capture time. `AppSettings.activeProfile` returns null for a dangling id. `--dart-define` values (`TRANSCRIPTION_ENDPOINT`/`TOKEN`/`MODEL`/`LANGUAGE`) seed the first profile on first run only; `settings.json` wins afterwards. Tokens are stored in plaintext — surfaced as a warning in the UI, encryption is a later phase.

**Logs** (`features/logs/`): `LogStore` is a `ChangeNotifier` ring buffer implementing `LogSink`, newest-first, capacity 500. The `LogArchive` interface keeps the store pure-Dart testable; `FileLogArchive` is the platform impl. Read-only view — nothing in the Logs tab mutates recordings.

**UI** — "Processing Console" dark theme (navy + cyan accent) in `lib/app/app.dart`; shared palette and widgets (`Console`, `StatusPill`, `ErrorBanner`, `SectionHeader`, `ConsoleCard`, `EmptyPanel`, `InfoRow`, formatters) in `lib/app/ui_kit.dart` — use these rather than re-declaring colors in a tab. Queue filters recordings by `RecordingFilter` (queue/ready/failed/raw) plus a separate reviewed counter.

**Audio format**: AAC-LC `.m4a`, defaults 16 kHz mono 64 kbps. Sample rate, channels and bitrate are user-editable in the Config tab; the **encoder and container are deliberately fixed for mic capture**, so `extensionFor(audioRecording)` is always `m4a`. Uploads keep their own extension — that path does not re-encode.

## Testing

Tests are pure-Dart (JSON round-trip, backward compat, controller behaviour) — no Flutter bindings or mocks needed. Fakes are hand-written: `_FakeSettingsRepository` extends the real repository and overrides only the IO methods; `_FakeArchive` implements `LogArchive`. When adding fields to any persisted type, extend its round-trip test and confirm the legacy-defaults path still holds.
