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

**Linux builds need `keybinder-3.0` installed first.** `hotkey_manager` (global
shortcuts) links against it, and without it `flutter build linux` aborts at
*"Unable to generate build files"* — this is a **build-time** failure, not a
runtime degradation, so nothing runs at all:

```bash
sudo apt-get install keybinder-3.0   # resolves to libkeybinder-3.0-dev
```

- Run: `flutter run`
- Run with transcription token: `flutter run --dart-define=TRANSCRIPTION_TOKEN=secret`
- All tests: `flutter test`
- Single test file: `flutter test test/recording_test.dart`
- Single test by name: `flutter test --plain-name "legacy JSON defaults to not reviewed"`
- Analyze/lint: `flutter analyze` (config in `analysis_options.yaml`: `flutter_lints` + `avoid_print`, `prefer_final_locals`)

There is **no CI** — `.github/workflows/ci.yml.disabled` is a commented-out template (Actions is metered on this private repo and the budget blocked every job). `flutter analyze && flutter test` locally is therefore a hard gate, not a nicety; nothing else will catch a compile error. Re-enable by renaming the file to `ci.yml` and uncommenting.

Global shortcuts on **Linux** additionally need `sudo apt-get install keybinder-3.0` (`hotkey_manager`'s system dependency). Without it the registrar fails at runtime and the shortcuts degrade to unavailable — everything else still works.

Dart SDK `>=3.10.0 <4.0.0`. Runtime deps: `record` (capture), `audioplayers` (playback), `path_provider` (app docs dir), `uuid` (id = source filename), `http` (Whisper adapter), `file_picker` (upload picker), `hotkey_manager` + `window_manager` (desktop global shortcuts). No state-mgmt/DI package.

## Architecture

Feature-first layout under `lib/features/<feature>/{domain,data,presentation}`. Six features: `recordings`, `transcription`, `processing`, `settings`, `logs`, `shortcuts`. No state-management or DI package — plain `ChangeNotifier` + constructor injection.

**Capture types** — the queue is multi-modal. `CaptureType` (`recordings/domain/capture_type.dart`) is `audioRecording` / `audioUpload` / `image` / `text` / `video`. `CaptureType.fromName(null | unknown)` returns `audioRecording`, which is the legacy-defaulting point for rows written before the field existed. Shipped today: mic recordings, text notes, and **file upload for all types** (audio/image/video) via the `+` capture menu → `file_picker`. Every capture type has a real processor: audio (recorded or uploaded) transcribes, text passes through, **image runs OCR** and **video extracts its audio track then transcribes**. Image/video processing is **desktop-first**, via system binaries (`tesseract` for OCR, `ffmpeg` for video audio-extraction) shelled out the same way `record_linux` uses `parecord`/`ffmpeg`. On mobile (no tesseract/ffmpeg wired yet) those two degrade to unavailable, so an image/video item is still ingested and listed but its processing lands `failed` (retryable, source intact). Missing desktop binaries degrade the same clean way.

**Navigation** — four bottom-nav tabs, one file per body, all hosted by the `RecordingsPage` shell (`features/recordings/presentation/recordings_page.dart`) inside an `IndexedStack` so tab state survives switching:

| Index | Tab | Body | Backed by |
| --- | --- | --- | --- |
| 0 | Queue | `recordings/presentation/queue_tab.dart` | `RecordingsController` |
| 1 | Models | `settings/presentation/models_tab.dart` | `SettingsController` |
| 2 | Logs | `logs/presentation/logs_tab.dart` | `LogStore` |
| 3 | Config | `settings/presentation/config_tab.dart` | `SettingsController` |

The shell owns the three controllers plus the `ShortcutsCoordinator`, merges the controllers into one `Listenable`, and on every settings change pushes `settings.transcriptionService` and `settings.audio` into the recordings controller — plus `settings.shortcuts` into the `ShortcutsCoordinator` it also owns. The capture FAB is gated to index 0.

**Capture lifecycle** — the ordered pipeline. Every capture entry point follows the identical order; `RecordingsController.stopRecording()` is the reference implementation and `addTextNote()` mirrors it. Do not reorder these steps:
1. obtain the source bytes (`recorder.stop()` → file path; for a note, write the `.txt`)
2. verify the file exists **and** length > 0 (throw `FileSystemException` otherwise)
3. build `Recording` with status `saved`, prepend to in-memory list
4. `repository.saveAll()` — atomic persist (write `.tmp`, then `rename`)
5. only then `_enqueueProcessing()` marks the item `pendingTranscription` and adds it to the background processing queue; capture returns immediately. A separate drain loop (`_drainProcessingQueue`) later runs the item `transcribing` → `completed`/`failed`.

**Processing is asynchronous.** Capture no longer awaits the processor — it enqueues and returns, so a long job never blocks the next capture. `_drainProcessingQueue` runs jobs **one at a time** off the `_isBusy` lock (single-flight via `_isDraining`). Because processing is off the capture path, tests that assert a `completed` status must first `await controller.waitForProcessing()`.

Any new capture path (upload, image, video) must mirror steps 1–5 exactly. Uploads do so via `MediaImporter` (`recordings/data/media_importer.dart`): it copies the picked file into the recordings dir as `<id>.<ext>` and verifies length > 0 (steps 1–2) before `addUpload` indexes it — the file source comes from the injectable `MediaPicker` seam (`FilePickerMediaPicker` in production, a fake in tests). Processing runs as a separate step; on error the item stays with status `failed` and an `error` string, retryable via `retryTranscription()`. There is intentionally **no delete** in the MVP.

**Controller invariants** (`recordings_controller.dart`) — beyond the pipeline order:
- Every state mutation goes through `_update()`, which calls `repository.saveAll(_recordings)` — the **entire** `recordings.json` index is atomically rewritten on each status transition, toggle, and retry. There is no partial/incremental write.
- `_isBusy` serializes only the **capture** entry points: `startRecording`, `stopRecording`, `addTextNote`, `addUpload` early-return if busy, so no two captures run at once. `addUpload` holds the lock across the whole pick→copy→enqueue, including the file-dialog await, then releases before processing runs. Processing is **not** covered by `_isBusy` — it lives in the background queue, so a capture can start while an earlier item is still processing.
- Processing runs in a background queue, not inline: `_enqueueProcessing(id)` adds an already-persisted item and kicks `_drainProcessingQueue`, which processes one job at a time (`_isDraining` keeps it single-flight). `retryTranscription(id)` just re-enqueues — it no longer holds `_isBusy`. A failing job never stalls the queue; the drain moves on. `dispose()` sets `_disposed` so an in-flight drain exits at the next await boundary.
- `startRecording()` gates on `recorder.hasPermission()` and sets a Polish mic-permission error on denial before any file is created.
- `id` is generated (`uuid.v4()`) at capture start and used as the source filename. It is **passed through** the pipeline (`_activeId`), not parsed back out of the path — extensions vary per capture type, so the old `replaceAll('.m4a', '')` round-trip is gone.
- `transcriptionService` and `audioConfig` are **settable at runtime** (from the Models/Config tabs). A swap only affects work started afterwards — it must never mutate an in-flight pipeline or a file already on disk.
- An optional `LogSink` (default `NoopLogSink`) receives one event per transition. Logging must never throw into the pipeline; keep emissions side-effect free.
- An optional `ClipboardSink` (`recordings/domain/clipboard_sink.dart`, default `NoopClipboardSink`) receives the processor output once a job reaches `completed`, so a clipboard manager picks it up as a history entry. Same rules as `LogSink`: it is invoked **after** the item is persisted, it swallows every error, and it must never fail a capture. Text notes are skipped — their output is the body the user just typed. `SystemClipboardSink` (`recordings/data/`) is the real impl, wired by the shell; the interface lives in `domain/` so that layer stays free of platform channels and the tests stay pure-Dart.

**Two independent state axes on `Recording`** (`domain/recording.dart`), keep them separate:
- AI processing: `RecordingStatus` enum (`saved`/`pendingTranscription`/`transcribing`/`completed`/`failed`). Despite the names this is **generic** processing state — "queued"/"running" for whichever processor the item's type resolves to. The names are kept because they are persisted in JSON.
- User review: `isProcessedByUser` bool + `processedAt` — set via `toggleProcessed()`, never touched by processing

`Recording` covers every capture type, not just audio: `type` (defaults to `audioRecording`), `sourceMimeType` (null on legacy rows and mic captures), and `transcript` — which is the **generic processor-output text** (transcript, OCR result, or note body), and what Queue search matches on. `durationMs` is `0` for images and text; the card suppresses it via `CaptureType.hasDuration`.

**Persistence** — three JSON files, all in the app documents `recordings/` subfolder, all written with the same atomic `.tmp` + `rename`:
- `recordings.json` (`recordings/data/recordings_repository.dart`) — the index; source artifacts as `<uuid>.<ext>` alongside it, one per item. The extension comes from `RecordingsRepository.extensionFor(type, sourceMimeType:)`, which delegates to the single policy definition in `capture_type.dart`: `m4a` for mic captures, `txt` for notes, mime-derived (with a per-type fallback) for uploads.
- `settings.json` (`settings/data/settings_repository.dart`) — provider profiles, active profile id, audio params, global shortcut bindings.
- `logs.json` (`logs/data/log_store.dart` → `FileLogArchive`) — capped at 500 events, coalesced single-flight writes.

Every `fromJson` must stay backward-compatible: new fields default when absent (see the "legacy JSON" tests).

**Transcription** (`features/transcription/data/transcription_service.dart`): `TranscriptionService` interface with two impls. `DisabledTranscriptionService` throws `TranscriptionNotConfiguredException`; it is the fallback whenever no provider profile is active. `HttpWhisperTranscriptionService` POSTs `multipart/form-data` field `file` to a configurable endpoint, optional bearer token, expects `{"text": ...}` (falls back to `transcript`).

**Processing** (`features/processing/`): `Processor` turns an item's source file into text. **The rule to enforce in review: a processor only ever reads the source — never writes, moves or deletes it.** On failure it throws; the controller catches, marks the item `failed`, and the source stays on disk, retryable. `ProcessorRegistry` maps `CaptureType → Processor` and is constructor-injectable for tests; `ProcessorRegistry.standard()` wires `TranscriptionProcessor` for both audio types, `TextPassthroughProcessor` for notes, `OcrProcessor` for images, and `VideoTranscriptionProcessor` for video. Each of the latter two holds a *resolver* (like `TranscriptionProcessor`) so a Models/Config swap only affects subsequent jobs. Two swappable engine seams sit behind them, mirroring `TranscriptionService`:
- `OcrService` (`processing/data/ocr_service.dart`) — `DisabledOcrService` default (throws `ProcessorNotConfiguredException`); `TesseractOcrService` shells out to system `tesseract` (`pol+eng`).
- `VideoAudioExtractor` (`processing/data/video_audio_extractor.dart`) — `UnavailableVideoAudioExtractor` default; `FfmpegVideoAudioExtractor` pulls a 16 kHz mono AAC track via system `ffmpeg` into a temp dir. `VideoTranscriptionProcessor` transcribes that track then deletes the derived temp audio — the source video is never touched.

The shell picks the desktop impls (`Tesseract`/`Ffmpeg`) on Linux/macOS/Windows and the disabled/unavailable impls on mobile (`RecordingsPage._buildOcrService` / `_buildVideoAudioExtractor`); a missing binary throws from `Process.run` and the item fails cleanly, retryable.

**Settings** (`features/settings/`): `ProviderProfile` is a named endpoint (name, endpoint, model, language, bearerToken) and knows how to build its own service via `toService()` — a blank or schemeless endpoint degrades to the disabled service instead of throwing at capture time. `AppSettings.activeProfile` returns null for a dangling id. `--dart-define` values (`TRANSCRIPTION_ENDPOINT`/`TOKEN`/`MODEL`/`LANGUAGE`) seed the first profile on first run only; `settings.json` wins afterwards. Tokens are stored in plaintext — surfaced as a warning in the UI, encryption is a later phase.

**Global shortcuts** (`features/shortcuts/`) — **desktop-only**, system-wide hotkeys that work while the window is minimised or unfocused. `ShortcutAction` is `showWindow`/`toggleRecording`/`newTextNote`/`uploadAudio`/`uploadImage`/`uploadVideo`. Unlike `CaptureType.fromName`, `ShortcutAction.fromName(unknown)` returns **null** — there is no legacy action to default to, so an unrecognised entry is dropped along with its binding.

- `HotkeyBinding` (`domain/hotkey_binding.dart`) stores `usbHidUsage` (physical key — what is registered, so the hotkey survives a keyboard-layout switch) plus `logicalKeyId` (used **only** to draw the label). Equality and `hashCode` deliberately ignore `logicalKeyId`: to the OS two bindings on the same physical key with the same modifiers are one hotkey. A binding with **no modifier is invalid** and is refused both on save and on load — it would swallow a bare key system-wide.
- `ShortcutDefaults.bindings` binds only `showWindow`/`toggleRecording`/`newTextNote`, all on **Alt+Shift**. Not Ctrl+Alt: Windows reports AltGr as Ctrl+Alt, and AltGr is how the Polish layout types ą/ć/ę/ł/ń/ó/ś/ź/ż. The upload actions ship unbound because every plausible default already means something in a browser or editor.
- Two swappable seams, same shape as `OcrService`: `HotkeyRegistrar` (`NoopHotkeyRegistrar` default, `SystemHotkeyRegistrar` on desktop) and `WindowPresenter` (`NoopWindowPresenter` / `SystemWindowPresenter`). `apply()` replaces the **whole** registration set and **returns** the actions the OS refused rather than throwing — one unavailable combination must not cost the user the others; the shell surfaces them in the Config tab.
- `ShortcutsCoordinator` (`presentation/`) owns dispatch and holds **no capture logic**: every action calls the same `RecordingsController` entry point the FAB calls, so a shortcut can never become a second capture path. Two rules to preserve: `toggleRecording` **must not raise the window** (the point of a global record hotkey is not leaving the app you are in), while every other action must, because it opens a sheet or a file dialog. The note action takes its re-entrancy flag **before the first `await`**, not after presenting the window. Errors are swallowed and logged, like `ClipboardSink`.
- Persisted in `settings.json` under `shortcuts`. **Absent** = never configured → defaults (so a later build can still ship a default for a new action). **Present** = authoritative: an action missing from a stored map is deliberately unbound, which is what makes "clear this shortcut" survive a restart. `AppSettings._shortcuts` is private and nullable precisely to encode that difference.
- **Registrations are suspended while the key-capture sheet is open.** A `HotKeyScope.system` hotkey is consumed by the OS *before* the focused window sees the event, so with them live the user could never rebind a combination that is already bound — pressing Alt+Shift+R to change it would start a recording instead. `ConfigTab`/`ShortcutsSection` receive a `runWithHotkeysSuspended` callback; the shell pairs `coordinator.suspend()`/`resume()` around it. An `apply()` arriving while suspended records the map but registers nothing; `resume()` picks it up.
- **Every registrar call is serialized** through an internal queue in the coordinator. `SystemHotkeyRegistrar.apply` starts by unregistering everything, so two overlapping applies could otherwise wipe each other mid-loop. A registrar failure clears `_applied` — leaving it set would make every later identical apply short-circuit and wedge the feature off for the session.
- `dispose()` sets a `_disposed` flag **synchronously** and `handle()` checks it first. The shell cannot await the unregister before disposing the controller, so that flag is the only thing stopping a press in that window from reaching a disposed controller.
- `main.dart` calls `windowManager.ensureInitialized()` and `hotKeyManager.unregisterAll()` on desktop before `runApp` — the latter clears registrations a hot restart would otherwise leave firing into a dead isolate.
- Two caveats worth knowing. **`rejected` may always be empty**: it depends on `hotKeyManager.register` throwing when the OS refuses a combination, which the plugin does not document — the amber "combination taken" row is unverified. And `Platform.isMacOS` is branched on in `main.dart` and the shell, but there is no `macos/` target in the repo, so that path is currently unreachable.
- Layering note: `hotkey_binding.dart` imports `package:flutter/services.dart` for `PhysicalKeyboardKey`/`LogicalKeyboardKey`. These are pure key-identity constants, not a platform channel, so the domain layer stays test-friendly and the `ClipboardSink` rule above is not violated in spirit — but it is the one place `domain/` touches `services.dart`.

**Logs** (`features/logs/`): `LogStore` is a `ChangeNotifier` ring buffer implementing `LogSink`, newest-first, capacity 500. The `LogArchive` interface keeps the store pure-Dart testable; `FileLogArchive` is the platform impl. Read-only view — nothing in the Logs tab mutates recordings.

**UI** — "Processing Console" dark theme (navy + cyan accent) in `lib/app/app.dart`; shared palette and widgets (`Console`, `StatusPill`, `ErrorBanner`, `SectionHeader`, `ConsoleCard`, `EmptyPanel`, `InfoRow`, `CopyButton`, formatters) in `lib/app/ui_kit.dart` — use these rather than re-declaring colors in a tab. `CopyButton` is the clipboard affordance: it copies the **full** string it is given even when the caller renders it truncated, and confirms inline by morphing its icon — the app uses no snackbars or dialogs anywhere, so keep new feedback inline too. Queue filters recordings by `RecordingFilter` (queue/ready/failed/raw) plus a separate reviewed counter.

**Audio format**: AAC-LC `.m4a`, defaults 16 kHz mono 64 kbps. Sample rate, channels and bitrate are user-editable in the Config tab; the **encoder and container are deliberately fixed for mic capture**, so `extensionFor(audioRecording)` is always `m4a`. Uploads keep their own extension — that path does not re-encode.

## Testing

Tests are pure-Dart (JSON round-trip, backward compat, controller behaviour) — no Flutter bindings or mocks needed. The single exception is `test/copy_button_test.dart`, a `testWidgets` suite: what `CopyButton` puts on the clipboard travels over a platform channel, so it cannot be asserted without a binding. Keep it the exception rather than the precedent. Fakes are hand-written: `_FakeSettingsRepository` extends the real repository and overrides only the IO methods; `_FakeArchive` implements `LogArchive`; `_FakeRegistrar`/`_CountingPresenter` (`test/shortcuts_coordinator_test.dart`) stand in for the OS hotkey table and the window, which is what keeps the shortcut layer testable without a binding — note it fires actions via `ShortcutsCoordinator.handle`, and asserts `toggleRecording` reached the controller through the *denied microphone* error rather than a real capture device. When adding fields to any persisted type, extend its round-trip test and confirm the legacy-defaults path still holds.
