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

Feature-first layout under `lib/features/<feature>/{domain,data,presentation}`. Two features: `recordings` and `transcription`. No state-management or DI package — plain `ChangeNotifier` + constructor injection.

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

**Two independent state axes on `Recording`** (`domain/recording.dart`), keep them separate:
- AI processing: `RecordingStatus` enum (`saved`/`pendingTranscription`/`transcribing`/`completed`/`failed`)
- User review: `isProcessedByUser` bool + `processedAt` — set via `toggleProcessed()`, never touched by transcription

**Persistence** (`data/recordings_repository.dart`): single JSON index `recordings.json` in the app documents dir (`recordings/` subfolder), audio as `<uuid>.m4a` alongside it. `saveAll` is atomic via temp-file rename. `Recording.fromJson` must stay backward-compatible — new fields default when absent (see the "legacy JSON" test); `id` is derived from the audio filename, so filename and `id` must match.

**Transcription** (`features/transcription/data/transcription_service.dart`): `TranscriptionService` interface with two impls. `DisabledTranscriptionService` (default, wired in `recordings_page.dart` `initState`) throws `TranscriptionNotConfiguredException`. `HttpWhisperTranscriptionService` POSTs `multipart/form-data` field `file` to a configurable endpoint, optional bearer token, expects `{"text": ...}` (falls back to `transcript`). Swap the impl in `RecordingsPage.initState` to enable a real endpoint.

**UI** — "Processing Console" dark theme (navy + cyan accent) defined in `lib/app/app.dart`. `RecordingsPage` rebuilds via `AnimatedBuilder` on the controller; filters recordings by `RecordingFilter` (queue/ready/failed/raw) plus a separate reviewed counter.

**Audio format**: AAC-LC, 16 kHz mono, 64 kbps, `.m4a` (`RecordConfig` in the controller).

## Testing

Tests are pure-Dart domain tests (JSON round-trip, backward compat) — no Flutter bindings or mocks needed. When adding fields to `Recording`, extend the round-trip test and confirm the legacy-defaults path still holds.
