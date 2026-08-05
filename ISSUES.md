# Backlog

Local issue tracker (no GitHub remote yet). Move to `gh issue` once a remote exists.

## Open

### Mobile video processing

**Image OCR is closed**: it runs through `HttpVisionOcrService` off the
enrichment profile, identically on every platform. The `TesseractOcrService`
that once covered desktop has been removed rather than mirrored onto mobile —
it made the same image succeed on desktop and fail on a phone, and it lost to
the vision model already configured for enrichment. An on-device
`MlKitOcrService` is no longer the plan; if it ever returns it is an *offline*
feature, not a platform gap.

Still open: **video**. `FfmpegVideoAudioExtractor` shells out to a system
binary behind the `VideoAudioExtractor` seam, which mobile has not got. Add an
`ffmpeg_kit_flutter_*`-backed impl and select it in `_buildVideoAudioExtractor`
— a large mobile-only binary, left out of `pubspec.yaml` so far to keep the
Linux build green.

Until then mobile video degrades to unavailable (item `failed`, retryable).

### Video poster + in-app playback

Video items show a movie icon, not a poster. Extract a *derived*
`<id>.thumb.jpg` (ffmpeg on desktop / `video_thumbnail` on mobile) — never
confused with the source — and add an in-app or external video player.

### Background transcription queue — job persistence across app suspension

The in-process decoupling is **done**: processing no longer runs inline under
`_isBusy`. Capture enqueues an already-persisted item and returns; a background
drain loop (`_drainProcessingQueue`) runs jobs one at a time off the capture
lock, so a long job never blocks the next capture (`_enqueueProcessing` /
`_isDraining`).

Remaining (mobile-only, deferred): the queue lives only in memory, so jobs
don't survive the app being killed/suspended. Add WorkManager (Android) /
BGTaskScheduler (iOS) so a `pendingTranscription`/`transcribing` item resumes
after suspension. On resume, re-enqueue any item left non-terminal in
`recordings.json`.

### On-device models

The Models tab manages *remote* provider profiles only. Local inference
(whisper.cpp via FFI: model catalog, download with progress, local path,
delete, active-model selection) is a separate, much larger piece of work and
needs a native dependency that is not in `pubspec.yaml` today.

**Invariant for any future work here:** must not touch the
source→verify→persist→process ordering that `RecordingsController.stopRecording()`
and `addTextNote()` both implement.

### Token encryption

`settings.json` stores bearer tokens in plaintext in the app documents
directory. The Models tab warns about this. Move to platform secure storage.

### Transcript editing

No way to fix a bad transcript or set a title. Read-only today.

## Done — multi-modal slices 0–1 (`3e3edae`)

- **Slice 0, domain generalization.** `CaptureType` enum with `fromName`
  defaulting (null/unknown → `audioRecording`), `type` + `sourceMimeType` on
  `Recording` with legacy defaults, extension policy (`extensionFor`) plus
  `createSourceFile`/`createSourceFileFor` on the repository, `id` passed
  through the pipeline instead of parsed back out of the filename, and the
  `Processor` / `ProcessorRegistry` abstraction. `_markAndTranscribe` became
  `_markAndProcess`; logs are type-neutral. Audio behaviour unchanged.
- **Slice 1, text notes.** `addTextNote()` mirrors `stopRecording()` step for
  step: write `.txt` → verify length > 0 → index → process via
  `TextPassthroughProcessor`. Note FAB above the record button, type-aware
  cards (icon per type, playback only for audio, duration hidden where there
  is none).

## Done — nav tabs (branch `feat/nav-tabs-search-scaffold`)

- **Scaffold:** tabs routed, record FAB gated to Queue, live search over
  transcript + filename + id on top of the status filter.
- **Models tab** (`features/settings`): `ProviderProfile` domain type,
  `AppSettings` + `SettingsRepository` (`settings.json`, atomic write),
  `SettingsController`, profile list with add/edit/delete, active selection,
  five presets, plaintext-token warning. The active profile's service is pushed
  into `RecordingsController` on every change; `--dart-define` values seed the
  first profile on first run only.
- **Logs tab** (`features/logs`): `LogEvent` + `LogStore` — newest-first ring
  buffer, capacity 500, coalesced single-flight persistence behind the
  `LogArchive` interface (`FileLogArchive` → `logs.json`).
  `RecordingsController` takes an optional `LogSink` and emits one event per
  pipeline transition. Level filter, copy-on-long-press, clear with confirm.
- **Config tab**: editable sample rate / bitrate / channels (encoder and `.m4a`
  container stay fixed), estimated size per hour, reset to defaults,
  active-provider summary, storage paths and file inventory.
- **Refactor:** queue body extracted from the 988-line `recordings_page.dart`
  into `queue_tab.dart`; shared palette and widgets moved to
  `lib/app/ui_kit.dart`; the page is now a shell hosting four tabs in an
  `IndexedStack` so tab state survives switching.
- Design doc: `docs/superpowers/specs/2026-07-25-nav-tabs-design.md`.
