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

Dart SDK `>=3.10.0 <4.0.0`. Runtime deps: `record` (capture), `path_provider` (app docs dir), `uuid` (id = audio filename), `http` (Whisper adapter). No state-mgmt/DI package.

## Architecture

Feature-first layout under `lib/features/<feature>/{domain,data,presentation}`. Four features: `recordings`, `transcription`, `settings`, `logs`. No state-management or DI package — plain `ChangeNotifier` + constructor injection.

**Navigation** — four bottom-nav tabs, one file per body, all hosted by the `RecordingsPage` shell (`features/recordings/presentation/recordings_page.dart`) inside an `IndexedStack` so tab state survives switching:

| Index | Tab | Body | Backed by |
| --- | --- | --- | --- |
| 0 | Queue | `recordings/presentation/queue_tab.dart` | `RecordingsController` |
| 1 | Models | `settings/presentation/models_tab.dart` | `SettingsController` |
| 2 | Logs | `logs/presentation/logs_tab.dart` | `LogStore` |
| 3 | Config | `settings/presentation/config_tab.dart` | `SettingsController` |

The shell owns all three controllers, merges them into one `Listenable`, and on every settings change pushes `settings.transcriptionService` and `settings.audio` into the recordings controller. The capture FAB is gated to index 0.

**Recording lifecycle** — the ordered pipeline lives entirely in `RecordingsController.stopRecording()` (`lib/features/recordings/presentation/recordings_controller.dart`). Do not reorder these steps:
1. `recorder.stop()` → get file path
2. verify file exists **and** length > 0 (throw `FileSystemException` otherwise)
3. build `Recording` with status `saved`, prepend to in-memory list
4. `repository.saveAll()` — atomic persist (write `.tmp`, then `rename`)
5. only then `_markAndTranscribe()` sets `pendingTranscription` → `transcribing` → `completed`/`failed`

Transcription runs as a separate step; on error the recording stays with status `failed` and an `error` string, retryable via `retryTranscription()`. There is intentionally **no delete** in the MVP.

**Controller invariants** (`recordings_controller.dart`) — beyond the pipeline order:
- Every state mutation goes through `_update()`, which calls `repository.saveAll(_recordings)` — the **entire** `recordings.json` index is atomically rewritten on each status transition, toggle, and retry. There is no partial/incremental write.
- A single `_isBusy` flag serializes all work: `startRecording`, `stopRecording`, and `retryTranscription` early-return if busy. No two operations run concurrently.
- `startRecording()` gates on `recorder.hasPermission()` and sets a Polish mic-permission error on denial before any file is created.
- `id` is generated (`uuid.v4()`) at record start and used as the audio filename; on stop the `id` is re-derived from the filename, so the two must stay in sync.
- `transcriptionService` and `audioConfig` are **settable at runtime** (from the Models/Config tabs). A swap only affects work started afterwards — it must never mutate an in-flight pipeline or a file already on disk.
- An optional `LogSink` (default `NoopLogSink`) receives one event per transition. Logging must never throw into the pipeline; keep emissions side-effect free.

**Two independent state axes on `Recording`** (`domain/recording.dart`), keep them separate:
- AI processing: `RecordingStatus` enum (`saved`/`pendingTranscription`/`transcribing`/`completed`/`failed`)
- User review: `isProcessedByUser` bool + `processedAt` — set via `toggleProcessed()`, never touched by transcription

**Persistence** — three JSON files, all in the app documents `recordings/` subfolder, all written with the same atomic `.tmp` + `rename`:
- `recordings.json` (`recordings/data/recordings_repository.dart`) — the index; audio as `<uuid>.m4a` alongside it. `id` is derived from the audio filename, so filename and `id` must match.
- `settings.json` (`settings/data/settings_repository.dart`) — provider profiles, active profile id, audio params.
- `logs.json` (`logs/data/log_store.dart` → `FileLogArchive`) — capped at 500 events, coalesced single-flight writes.

Every `fromJson` must stay backward-compatible: new fields default when absent (see the "legacy JSON" tests).

**Transcription** (`features/transcription/data/transcription_service.dart`): `TranscriptionService` interface with two impls. `DisabledTranscriptionService` throws `TranscriptionNotConfiguredException`; it is the fallback whenever no provider profile is active. `HttpWhisperTranscriptionService` POSTs `multipart/form-data` field `file` to a configurable endpoint, optional bearer token, expects `{"text": ...}` (falls back to `transcript`).

**Settings** (`features/settings/`): `ProviderProfile` is a named endpoint (name, endpoint, model, language, bearerToken) and knows how to build its own service via `toService()` — a blank or schemeless endpoint degrades to the disabled service instead of throwing at capture time. `AppSettings.activeProfile` returns null for a dangling id. `--dart-define` values (`TRANSCRIPTION_ENDPOINT`/`TOKEN`/`MODEL`/`LANGUAGE`) seed the first profile on first run only; `settings.json` wins afterwards. Tokens are stored in plaintext — surfaced as a warning in the UI, encryption is a later phase.

**Logs** (`features/logs/`): `LogStore` is a `ChangeNotifier` ring buffer implementing `LogSink`, newest-first, capacity 500. The `LogArchive` interface keeps the store pure-Dart testable; `FileLogArchive` is the platform impl. Read-only view — nothing in the Logs tab mutates recordings.

**UI** — "Processing Console" dark theme (navy + cyan accent) in `lib/app/app.dart`; shared palette and widgets (`Console`, `StatusPill`, `ErrorBanner`, `SectionHeader`, `ConsoleCard`, `EmptyPanel`, `InfoRow`, formatters) in `lib/app/ui_kit.dart` — use these rather than re-declaring colors in a tab. Queue filters recordings by `RecordingFilter` (queue/ready/failed/raw) plus a separate reviewed counter.

**Audio format**: AAC-LC `.m4a`, defaults 16 kHz mono 64 kbps. Sample rate, channels and bitrate are user-editable in the Config tab; the **encoder and container are deliberately fixed**, because `RecordingsRepository` hardcodes the `.m4a` extension.

## Testing

Tests are pure-Dart (JSON round-trip, backward compat, controller behaviour) — no Flutter bindings or mocks needed. Fakes are hand-written: `_FakeSettingsRepository` extends the real repository and overrides only the IO methods; `_FakeArchive` implements `LogArchive`. When adding fields to any persisted type, extend its round-trip test and confirm the legacy-defaults path still holds.
