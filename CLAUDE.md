# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Offline-first Flutter voice recorder ("Voice Notes — Phase 1"). Core guarantee: audio is durably persisted to disk **before** transcription is ever attempted, and a transcription failure never deletes a recording. This ordering invariant is the reason the app exists — preserve it in any change.

The `pubspec.yaml` name is `voice_notes_phase1`; the runtime app title is `Audivoa Core`. README is in Polish; **user-facing strings in code are English** (they were Polish until the design pass — do not reintroduce Polish), and so are identifiers and comments. Strings already stored on disk (a provider profile the user named) keep whatever they were saved as; only code literals were translated.

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

**There is no server-side CI.** GitHub Actions is metered on this private repo,
so the workflow is parked at `.github/workflows/ci.yml.disabled`. A branch that
does not compile has reached review before because of this. A `pre-push` hook
runs `flutter analyze` + `flutter test` in its place — enable it once per clone:

```bash
git config core.hooksPath .githooks
```

`git push --no-verify` skips it when that is genuinely what you want.

- Run: `flutter run`
- Run with transcription token: `flutter run --dart-define=TRANSCRIPTION_TOKEN=secret`
- All tests: `flutter test`
- Single test file: `flutter test test/recording_test.dart`
- Single test by name: `flutter test --plain-name "legacy JSON defaults to not reviewed"`
- Analyze/lint: `flutter analyze` (config in `analysis_options.yaml`: `flutter_lints` + `avoid_print`, `prefer_final_locals`)

There is **no CI** — `.github/workflows/ci.yml.disabled` is a commented-out template (Actions is metered on this private repo and the budget blocked every job). `flutter analyze && flutter test` locally is therefore a hard gate, not a nicety; nothing else will catch a compile error. Re-enable by renaming the file to `ci.yml` and uncommenting.

Global shortcuts on **Linux** additionally need `sudo apt-get install keybinder-3.0` (`hotkey_manager`'s system dependency). Without it the registrar fails at runtime and the shortcuts degrade to unavailable — everything else still works.

Raising the window from a hotkey on **GNOME/X11** additionally wants `xdotool`
(`sudo apt-get install xdotool`). It is optional: without it a hotkey still
captures, but the window only blinks in the taskbar instead of coming forward —
see `SystemWindowPresenter`.

Dart SDK `>=3.10.0 <4.0.0`. Runtime deps: `record` (capture), `audioplayers` (playback), `path_provider` (app docs dir), `uuid` (id = source filename), `http` (Whisper adapter), `file_picker` (upload picker), `hotkey_manager` + `window_manager` (desktop global shortcuts). No state-mgmt/DI package.

## Architecture

Feature-first layout under `lib/features/<feature>/{domain,data,presentation}`. Six features: `recordings`, `transcription`, `processing`, `settings`, `logs`, `shortcuts`. No state-management or DI package — plain `ChangeNotifier` + constructor injection.

**Capture types** — the queue is multi-modal. `CaptureType` (`recordings/domain/capture_type.dart`) is `audioRecording` / `audioUpload` / `image` / `text` / `video`. `CaptureType.fromName(null | unknown)` returns `audioRecording`, which is the legacy-defaulting point for rows written before the field existed. Shipped today: mic recordings, text notes, and **file upload for all types** (audio/image/video) via the `+` capture menu → `file_picker`. Every capture type has a real processor: audio (recorded or uploaded) transcribes, text passes through, **image runs OCR** and **video extracts its audio track then transcribes**. Image/video processing is **desktop-first**, via system binaries (`tesseract` for OCR, `ffmpeg` for video audio-extraction) shelled out the same way `record_linux` uses `parecord`/`ffmpeg`. On mobile (no tesseract/ffmpeg wired yet) those two degrade to unavailable, so an image/video item is still ingested and listed but its processing lands `failed` (retryable, source intact). Missing desktop binaries degrade the same clean way.

**Navigation** — four bottom-nav tabs, one file per body, all hosted by the `RecordingsPage` shell (`features/recordings/presentation/recordings_page.dart`) inside an `IndexedStack` so tab state survives switching:

| Index | Tab | Body | Backed by |
| --- | --- | --- | --- |
| 0 | Queue | `recordings/presentation/queue_tab.dart` (+ `recording_card.dart`, `edit_sheet.dart`, `queue_metrics.dart`, `capture_dock.dart`, `recording_view.dart`, `text_note_sheet.dart`) | `RecordingsController` |
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
- `startRecording()` gates on `recorder.hasPermission()` and sets a mic-permission error on denial before any file is created. It also subscribes to `recorder.onAmplitudeChanged` to drive `levelTicker` (the capture screen's meter) — inside a `try`, because amplitude reporting is optional and a missing meter must never stop a recording.
- `id` is generated (`uuid.v4()`) at capture start and used as the source filename. It is **passed through** the pipeline (`_activeId`), not parsed back out of the path — extensions vary per capture type, so the old `replaceAll('.m4a', '')` round-trip is gone.
- `transcriptionService` and `audioConfig` are **settable at runtime** (from the Models/Config tabs). A swap only affects work started afterwards — it must never mutate an in-flight pipeline or a file already on disk.
- An optional `LogSink` (default `NoopLogSink`) receives one event per transition. Logging must never throw into the pipeline; keep emissions side-effect free.
- An optional `ClipboardSink` (`recordings/domain/clipboard_sink.dart`, default `NoopClipboardSink`) receives the processor output once a job reaches `completed`, so a clipboard manager picks it up as a history entry. Same rules as `LogSink`: it is invoked **after** the item is persisted, it swallows every error, and it must never fail a capture. Text notes are skipped — their output is the body the user just typed. `SystemClipboardSink` (`recordings/data/`) is the real impl, wired by the shell; the interface lives in `domain/` so that layer stays free of platform channels and the tests stay pure-Dart.

**Two independent state axes on `Recording`** (`domain/recording.dart`), keep them separate:
- AI processing: `RecordingStatus` enum (`saved`/`pendingTranscription`/`transcribing`/`completed`/`failed`). Despite the names this is **generic** processing state — "queued"/"running" for whichever processor the item's type resolves to. The names are kept because they are persisted in JSON.
- User review: `isProcessedByUser` bool + `processedAt` — set via `toggleProcessed()`, never touched by processing

`Recording` covers every capture type, not just audio: `type` (defaults to `audioRecording`), `sourceMimeType` (null on legacy rows and mic captures), and `transcript` — which is the **generic processor-output text** (transcript, OCR result, or note body), and what Queue search matches on. `durationMs` is `0` for images and text; the card suppresses it via `CaptureType.hasDuration`. `sizeBytes` is measured by the very `length()` call that proves the source is non-empty at capture time — the card's `file verified · 6.8 MB · persisted` footer reports a measurement, never an estimate, and legacy rows (`0`) drop the segment instead of printing `0 B`.

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
- **`Shift` + a printable key can never fire on Linux.** `keybinder` grabs the *unshifted* keyval, so holding Shift makes X resolve the keycode to the shifted keysym and keybinder's own comparison misses — while `keybinder_bind` still reports success and the X grab is genuinely taken. The press is swallowed and nothing happens anywhere. Verified against keybinder 0.3.2 with a standalone C harness: `Alt+Shift+A`, `Ctrl+Shift+J`, `Ctrl+Shift+1`, `Ctrl+Shift+,` all bind and never fire; `Alt+Shift+F1..F3`, `Ctrl+Shift+F1`, `Alt+Shift+Space`, `Alt+Shift+Return`, `Ctrl+Alt+A/R/N` and `Alt+A` all fire. (`Super` is unusable under GNOME regardless — it owns the key.) `HotkeyBinding.isUnsupportedOnLinux` encodes this and `LinuxHotkeyRegistrar` refuses such bindings up front rather than registering them into silence.
- `ShortcutDefaults.bindings` binds only `showWindow`/`toggleRecording`/`newTextNote`, all on **Ctrl+Alt** (`A`/`R`/`N`). This used to be Alt+Shift specifically to *avoid* Ctrl+Alt — Windows reports AltGr as Ctrl+Alt, and AltGr is how the Polish layout types ą/ć/ę/ł/ń/ó/ś/ź/ż — but every one of those defaults was in the dead class above, so the feature shipped silently broken on the platform the app actually runs on. On X11 AltGr is `ISO_Level3_Shift` (Mod5), so these three do not touch Polish diacritics here. **Revisit when a Windows target exists.** The upload actions ship unbound because every plausible default already means something in a browser or editor.
- Two swappable seams, same shape as `OcrService`: `HotkeyRegistrar` (`NoopHotkeyRegistrar` default, `LinuxHotkeyRegistrar` on Linux, `SystemHotkeyRegistrar` elsewhere on desktop) and `WindowPresenter` (`NoopWindowPresenter` / `SystemWindowPresenter`). `apply()` replaces the **whole** registration set and **returns** the actions it refused rather than throwing — one unavailable combination must not cost the user the others; the shell surfaces them in the Config tab.
- **`LinuxHotkeyRegistrar` bypasses `hotkey_manager`'s Dart layer** and drives the plugin's method/event channels itself. `hotkey_manager` derives the GDK keyval by reverse-scanning `uni_platform`'s GTK↔logical table and returns the first match, which for Space is `KP_Space` (0xff80) — binding Space produced `Binding '<Primary><Shift>KP_Space' failed!`. The registrar maps `logicalKeyId` → keyval itself (printable ASCII passes through, the rest from an explicit table) and reports an unmapped key as rejected rather than registering a key the user never chose. Because it owns that channel, `main.dart` skips `hotKeyManager.unregisterAll()` on Linux — touching it would construct the package singleton, which subscribes to the same event channel and fights the registrar's listener for it.
- **A refusal is invisible on Linux**: `hotkey_manager_linux_plugin.cc` discards `keybinder_bind`'s return value and always answers success. Everything in `rejected` is therefore decided *before* the call (invalid, unsupported-with-Shift, unmappable key). A combination genuinely owned by another application still fails silently — there is no channel to learn about it.
- `ShortcutsCoordinator` (`presentation/`) owns dispatch and holds **no capture logic**: every action calls the same `RecordingsController` entry point the FAB calls, so a shortcut can never become a second capture path. Rules to preserve: every action except `toggleRecording` raises the window **before** running, because it opens a sheet or a file dialog. `toggleRecording` raises it **after** a start, never before (the window-manager round trip would cost the first word of the recording) and **never on a stop** (the capture is already persisted, and yanking the window forward would pull the user out of whatever they went back to). A start also calls the shell's `revealQueue` to switch to tab 0 — otherwise a hotkey recording is invisible, since the running `SAVE mm:ss` FAB and the microphone-denied banner are both drawn only there. Both run on the denied-microphone path too; the error is on the same tab. The note action takes its re-entrancy flag **before the first `await`**, not after presenting the window. Errors are swallowed and logged, like `ClipboardSink`.
- `SystemWindowPresenter` ends with an `xdotool windowactivate` on Linux. GNOME/X11 refuses a raise carrying no user-interaction timestamp, and `window_manager`'s `focus`/`restore` both call `gtk_window_present` without one — the window keeps `_NET_WM_STATE_HIDDEN` and merely gains `_NET_WM_STATE_DEMANDS_ATTENTION`. `xdotool` sends `_NET_ACTIVE_WINDOW` with the pager source indication, which mutter honours. Same shell-out seam and same clean degradation as `tesseract`/`ffmpeg`. Note `restore()` is called unconditionally: `isMinimized()` was observed returning false for a window the WM had flagged hidden.
- Persisted in `settings.json` under `shortcuts`. **Absent** = never configured → defaults (so a later build can still ship a default for a new action). **Present** = authoritative: an action missing from a stored map is deliberately unbound, which is what makes "clear this shortcut" survive a restart. `AppSettings._shortcuts` is private and nullable precisely to encode that difference.
- **Registrations are suspended while the key-capture sheet is open.** A `HotKeyScope.system` hotkey is consumed by the OS *before* the focused window sees the event, so with them live the user could never rebind a combination that is already bound — pressing Alt+Shift+R to change it would start a recording instead. `ConfigTab`/`ShortcutsSection` receive a `runWithHotkeysSuspended` callback; the shell pairs `coordinator.suspend()`/`resume()` around it. An `apply()` arriving while suspended records the map but registers nothing; `resume()` picks it up.
- **Every registrar call is serialized** through an internal queue in the coordinator. `SystemHotkeyRegistrar.apply` starts by unregistering everything, so two overlapping applies could otherwise wipe each other mid-loop. A registrar failure clears `_applied` — leaving it set would make every later identical apply short-circuit and wedge the feature off for the session.
- `dispose()` sets a `_disposed` flag **synchronously** and `handle()` checks it first. The shell cannot await the unregister before disposing the controller, so that flag is the only thing stopping a press in that window from reaching a disposed controller.
- `main.dart` calls `windowManager.ensureInitialized()` and `hotKeyManager.unregisterAll()` on desktop before `runApp` — the latter clears registrations a hot restart would otherwise leave firing into a dead isolate.
- `Platform.isMacOS` is branched on in `main.dart` and the shell, but there is no `macos/` target in the repo, so that path is currently unreachable. `SystemHotkeyRegistrar` (Windows/macOS) still relies on `hotKeyManager.register` throwing on refusal, which the plugin does not document — on those platforms `rejected` remains unverified.
- Layering note: `hotkey_binding.dart` imports `package:flutter/services.dart` for `PhysicalKeyboardKey`/`LogicalKeyboardKey`. These are pure key-identity constants, not a platform channel, so the domain layer stays test-friendly and the `ClipboardSink` rule above is not violated in spirit — but it is the one place `domain/` touches `services.dart`.

**Logs** (`features/logs/`): `LogStore` is a `ChangeNotifier` ring buffer implementing `LogSink`, newest-first, capacity 500. The `LogArchive` interface keeps the store pure-Dart testable; `FileLogArchive` is the platform impl. Read-only view — nothing in the Logs tab mutates recordings.

**UI** — "Processing Console" dark theme in `lib/app/app.dart`, implementing the approved design (`Audivoa Core.dc.html`, direction 1a "console cards"). Shared palette, type scale and widgets (`Console`, `ConsoleFont`, `ConsoleText`, `ConsoleHeader`, `PulseDot`, `StatusPill`, `ErrorBanner`, `SectionHeader`, `ConsoleCard`, `EmptyPanel`, `InfoRow`, `CopyButton`, `ConsoleChip`, `ConsoleIconTile`, `ConsoleIconButton`, `confirmDestructive()`, formatters) live in `lib/app/ui_kit.dart` — use these rather than re-declaring colors or re-writing a chip/tile/dialog in a tab. Every raw hex belongs in `Console`; `app.dart` included, and the hairline borders stay **translucent** (`Color(0x297E9BC4)`) so one value reads correctly on the page, on a card and in a sheet.

- **Type** — two vendored families under `assets/fonts` (SIL OFL, licences alongside): **Space Grotesk** is the theme default and carries names and headings; **JetBrains Mono** carries every machine-ish label (statuses, counters, timers, file facts) via `ConsoleText`. They are vendored rather than fetched by `google_fonts` because the app is offline-first.
- **No `AppBar`** — each tab draws a `ConsoleHeader` (cyan `AUDIVOA CORE` eyebrow, large title, right-hand counter) as the first item inside its own scroll area.
- **Queue filters** — `RecordingFilter` is `all`/`queue`/`ready`/`failed`/`raw` and they **partition** the list: `queue` is pending+transcribing, `raw` is `saved` (persisted, not yet handed to a processor), and `all` is their union. `_matches()` in `queue_tab.dart` is the single definition, used both to filter the list and to count the chips, so the two cannot disagree. Counts are taken **before** the search filter — the chips describe the queue, not the query.
- **Capture affordances** — `CaptureDock` floats over the bottom of the Queue (gradient scrim, small note/upload disc above the 64 px cyan record disc). Starting a recording swaps the whole screen for `RecordingView`, overlaid on the `IndexedStack` rather than replacing it so the Queue keeps its search text and scroll position; the bottom nav is hidden for the duration. `RecordingView` has one action, `SAVE` — there is deliberately no discard, because no path in this app throws a capture away.
- `CopyButton` is the clipboard affordance: it copies the **full** string it is given even when the caller renders it truncated, and confirms inline by morphing its icon — the app uses **no snackbars**, and reserves dialogs for destructive confirmation only (`confirmDestructive()`), so keep new feedback inline too.

**Audio format**: AAC-LC `.m4a`, defaults 16 kHz mono 64 kbps. Sample rate, channels and bitrate are user-editable in the Config tab; the **encoder and container are deliberately fixed for mic capture**, so `extensionFor(audioRecording)` is always `m4a`. Uploads keep their own extension — that path does not re-encode.

## Testing

Two `testWidgets` rules the design work established, both easy to trip over:

- **Never `pumpAndSettle` a screen containing a `PulseDot`** (a transcribing card, the capture screen). It repeats forever, so "no frames scheduled" is a state that screen never reaches and the call hangs until the timeout. Pump explicit frames instead.
- **Work started from inside the fake-async zone needs `tester.runAsync`.** A tap that starts or stops a capture touches the real filesystem; `settleIo()` in `test/widget/capture_test.dart` alternates `runAsync` with `pump` so that IO lands and the microtasks it queues get flushed. A test that leaves a capture running also has to stop it, or the binding reports the 250 ms elapsed timer as a leak.

Tests are pure-Dart (JSON round-trip, backward compat, controller behaviour) — no Flutter bindings or mocks needed. The exceptions are `test/copy_button_test.dart` and the suites under `test/widget/`: what `CopyButton` puts on the clipboard travels over a platform channel, so it cannot be asserted without a binding. Keep it the exception rather than the precedent. Fakes are hand-written: `_FakeSettingsRepository` extends the real repository and overrides only the IO methods; `_FakeArchive` implements `LogArchive`; `_FakeRegistrar`/`_CountingPresenter` (`test/shortcuts_coordinator_test.dart`) stand in for the OS hotkey table and the window, which is what keeps the shortcut layer testable without a binding — note it fires actions via `ShortcutsCoordinator.handle`, and asserts `toggleRecording` reached the controller through the *denied microphone* error rather than a real capture device. When adding fields to any persisted type, extend its round-trip test and confirm the legacy-defaults path still holds.
