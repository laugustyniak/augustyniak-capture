# Backlog

Local issue tracker (no GitHub remote yet). Move to `gh issue` once a remote exists.

## Open

### On-device models

The Models tab manages *remote* provider profiles only. Local inference
(whisper.cpp via FFI: model catalog, download with progress, local path,
delete, active-model selection) is a separate, much larger piece of work and
needs a native dependency that is not in `pubspec.yaml` today.

**Invariant for any future work here:** must not touch the
source→verify→persist→process ordering that `RecordingsController.stopRecording()`
and `addTextNote()` both implement.

## Done — queue resumption on app launch & resume (#148)

- **Background queue recovery:** exposed `resumeInterruptedProcessing()` on `RecordingsController` to automatically detect and resume non-terminal/stuck captures (`pendingTranscription`, `transcribing`, `awaitsProcessing`) on app startup and in `didChangeAppLifecycleState` upon `AppLifecycleState.resumed`.

## Done — in-app video playback (#120)

- **Inline video player:** implemented `InlineVideoPlayer` and `VideoPlaybackController` for video captures with scrubbing bar, timestamp tracker, volume/mute toggle, poster preview fallback, and focus view integration.

## Done — transcript & custom title editing (#119)

- **Capture editing:** added support for editing transcripts and custom titles in `RecordingsController` and inline `RecordingEditor`. Persisted user revisions with `RevisionSource.user` and synced changes to Obsidian markdown vault notes.

## Done — token encryption (#118)

- **Platform secure storage migration:** migrated provider bearer tokens, Turso auth tokens, R2 secret access keys, and Command tokens from plaintext storage to AES-256-GCM encryption with master key storage via `FlutterSecureStorage` (`SecureStorageMasterKeyStore`).
- **Migration and fallback path:** `MigratingMasterKeyStore` migrates legacy file-based master keys to secure storage and safely retires fallback on confirmed read-back.
- **Plaintext auto-migration:** `SettingsRepository.load()` transparently seals existing plaintext tokens and persists ciphertext with `enc:v1:` prefix.
- **Fail-safe token handling:** unreadable sealed tokens are preserved without overwriting and filtered from request headers via `usableBearerToken` and `usableCommandToken`.

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
