# Backlog

Local issue tracker (no GitHub remote yet). Move to `gh issue` once a remote exists.

## Nav-tab backends

The bottom-nav tabs Models/Logs/Config are scaffolded with `_PlaceholderTab`
(`lib/features/recordings/presentation/recordings_page.dart`). Each needs a real
backend + screen body. Swap the placeholder for the screen when the feature
lands.

### 1. Models tab — local transcription model management

- **Now:** placeholder. Transcription service is selected once at startup from
  `--dart-define` (`_buildTranscriptionService`); no model concept exists.
- **Build:**
  - Model domain type (id, name, size, download state, local path).
  - Registry/repository listing available + installed models.
  - Download + delete with progress; persist installed set.
  - Screen body: list, download/delete actions, active-model selection.
  - Wire selection into the transcription service the controller uses.
- **Invariant:** must not touch the recording→persist→transcribe ordering in
  `RecordingsController.stopRecording()`.

### 2. Logs tab — processing console / job history

- **Now:** placeholder. No log store; errors surface only per-recording via the
  `error` string + `_ErrorBanner`.
- **Build:**
  - Append-only log/event store (in-memory + optional persisted ring buffer).
  - Emit events from controller transitions (saved → pending → transcribing →
    completed/failed, retries).
  - Screen body: reverse-chronological stream, filter by level/recording.
- **Note:** read-only view; no mutation of recordings.

### 3. Config tab — runtime settings

- **Now:** placeholder. Endpoint + token are compile-time only
  (`TRANSCRIPTION_ENDPOINT`, `TRANSCRIPTION_TOKEN`).
- **Build:**
  - Settings domain + persistence (JSON in app docs dir, same pattern as
    `recordings.json`).
  - Editable: transcription endpoint URL, bearer token, audio format params
    (currently hardcoded AAC-LC 16 kHz mono 64 kbps).
  - Rebuild/replace the transcription service when endpoint/token change.
  - Screen body: form with validation; secure-ish handling of the token field.
- **Migration:** keep `--dart-define` values as defaults when no saved settings.

## Done (scaffold — branch `feat/nav-tabs-search-scaffold`)

- Nav tabs routed: non-zero index renders `_PlaceholderTab`; record FAB gated to
  Queue tab.
- Search field live: filters visible list by transcript + filename + id on top
  of the status filter; clear button.
