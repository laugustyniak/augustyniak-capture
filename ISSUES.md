# Backlog

Local issue tracker (no GitHub remote yet). Move to `gh issue` once a remote exists.

## Open

### Background transcription queue

Transcription runs inline under the `_isBusy` lock, so a long job blocks the
next capture. Needs a real job queue plus WorkManager (Android) /
BGTaskScheduler (iOS) so jobs survive app suspension.

### On-device models

The Models tab manages *remote* provider profiles only. Local inference
(whisper.cpp via FFI: model catalog, download with progress, local path,
delete, active-model selection) is a separate, much larger piece of work and
needs a native dependency that is not in `pubspec.yaml` today.

**Invariant for any future work here:** must not touch the
recording→persist→transcribe ordering in `RecordingsController.stopRecording()`.

### Token encryption

`settings.json` stores bearer tokens in plaintext in the app documents
directory. The Models tab warns about this. Move to platform secure storage.

### Transcript editing

No way to fix a bad transcript or set a title. Read-only today.

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
