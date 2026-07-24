# Navigation tabs — Models, Logs, Config

Status: approved 2026-07-25. Branch `feat/nav-tabs-search-scaffold`.

## Goal

Replace the three `_PlaceholderTab` bodies (Models, Logs, Config) with real
screens backed by real state, without touching the recording ordering
invariant in `RecordingsController.stopRecording()`.

## Tab set (final: 4)

| Tab | Purpose |
| --- | --- |
| Queue | Existing recordings list, filters, search, capture FAB, playback. Unchanged behaviour. |
| Models | Transcription **provider profiles**: list, add, edit, delete, select active. |
| Logs | Append-only event stream of pipeline transitions, newest first, level filter. |
| Config | Audio capture parameters, storage paths, active-profile summary, reset to build-time defaults. |

No fifth tab. Export/sync and on-device model downloads stay out of scope; the
Models tab manages *remote* provider profiles only, because no on-device
inference dependency exists in `pubspec.yaml`.

## New modules

```
lib/features/settings/
  domain/provider_profile.dart     id, name, endpoint, model, language, bearerToken
  domain/audio_config.dart         encoder, sampleRate, numChannels, bitRate
  domain/app_settings.dart         profiles[], activeProfileId, audio
  data/settings_repository.dart    settings.json, atomic .tmp + rename
  presentation/settings_controller.dart
  presentation/models_tab.dart
  presentation/config_tab.dart
lib/features/logs/
  domain/log_event.dart            id, timestamp, level, message, recordingId?
  data/log_store.dart              ChangeNotifier ring buffer + coalesced persist
  presentation/logs_tab.dart
lib/features/recordings/presentation/queue_tab.dart
```

`recordings_page.dart` becomes a shell: AppBar, `NavigationBar`, four-way body
switch, and ownership of the two controllers. The queue body and its private
widgets move to `queue_tab.dart`.

## Domain

**ProviderProfile** — value type, `copyWith`, `toJson`/`fromJson`. `id` is a
uuid. `bearerToken`, `model`, `language` are nullable. `toService()` returns
`HttpWhisperTranscriptionService` built from its own fields.

**AudioConfig** — mirrors `RecordConfig` fields the app actually sets
(`AudioEncoder.aacLc`, 16 kHz, mono, 64 kbps as defaults). `toRecordConfig()`
maps to the `record` package type; the domain type stays free of plugin
imports so tests need no bindings.

**AppSettings** — `List<ProviderProfile> profiles`, `String? activeProfileId`,
`AudioConfig audio`. `activeProfile` getter returns null when the id is missing
or dangling. `fromJson` defaults every field when absent (same
backward-compatibility rule as `Recording.fromJson`).

**LogEvent** — `id`, `timestamp`, `LogLevel` (`info`, `warn`, `error`),
`message`, optional `recordingId`. JSON round-trip, unknown level falls back to
`info`.

## Persistence

`SettingsRepository` writes `settings.json` into the same `recordings/`
app-documents subfolder used by `RecordingsRepository`, via `.tmp` + `rename`.
`LogStore` persists `logs.json` the same way, capped at 500 events (oldest
evicted). Log writes are coalesced: `add()` mutates memory and notifies
synchronously, then schedules one flush; concurrent adds collapse into a single
write.

## Wiring

- `RecordingsController._transcriptionService` and a new `_audioConfig` become
  mutable with setters. Swapping either affects only *subsequent* work; the
  step order inside `stopRecording()` is untouched.
- `RecordingsController` takes an optional `LogSink` (default no-op) so the
  existing pure-Dart tests keep working. Events are emitted for: microphone
  permission denied, capture started, file verified and persisted, each status
  transition, retry requested, playback failure.
- `RecordingsPage` owns `SettingsController` and `LogStore`, and on every
  settings change pushes `activeProfile?.toService() ??
  DisabledTranscriptionService()` and `settings.audio` into the recordings
  controller.
- First run with no `settings.json`: if `--dart-define` values are present they
  seed profile #1 and it becomes active. Otherwise zero profiles and the
  disabled service — identical to today's behaviour.

## Security note

Bearer tokens are stored in plaintext in the app documents directory. The
Models tab obscures the field and labels the storage explicitly. Encryption is
listed as a later phase in the README and stays out of scope here.

## Tests (pure Dart, no bindings)

- `ProviderProfile` / `AudioConfig` / `AppSettings` JSON round-trip.
- `AppSettings.fromJson` on legacy/partial JSON defaults every field.
- `AppSettings.activeProfile` is null for a dangling `activeProfileId`.
- `LogEvent` round-trip; unknown level degrades to `info`.
- `LogStore` evicts oldest beyond the cap and keeps newest-first ordering.
- Active-profile-to-service mapping: profile present yields a configured HTTP
  service, absent yields `DisabledTranscriptionService`.
