# Audivoa Core

A minimal **offline-first** Flutter app for recording voice notes.

## Ordering guarantee

Every way of adding an item — a microphone recording, a text note and (in
later phases) an audio file, image or video — follows exactly the same
order:

1. creates the source material (recording to `.m4a`, note body to `.txt`),
2. stops the recorder / finishes writing the file,
3. checks that the file exists and has a non-zero size,
4. persists the metadata atomically to `recordings.json`,
5. only then sets the status to "queued",
6. runs the processing appropriate for the type (transcription, text passthrough),
7. a processing failure never deletes the source material.

The processor **only reads** the source file — it never modifies or deletes it.

## Features

- AAC/M4A recording, mono, 16 kHz (parameters editable in the Config tab),
- text notes saved as `.txt` through the same pipeline as recordings,
- local storage in the app documents directory,
- one shared list of all items, with a type-dependent icon and card,
- durable processing statuses,
- retry for failed processing,
- HTTP adapter ready for Whisper/OpenAI/Hugging Face,
- no delete function in the MVP, to limit the risk of data loss.

### Item types

| Type | Extension | Processing | Status |
| --- | --- | --- | --- |
| microphone recording | `.m4a` | transcription via the active profile | works |
| text note | `.txt` | text passthrough (no network) | works |
| audio file | original | transcription via the active profile | planned |
| image | `.jpg`/`.png` | offline OCR | planned |
| video | `.mp4`/`.mov` | audio track → transcription | planned |

Planned types already have their model and on-disk persistence; their
processors report "unavailable" for now, so an item ends with a readable error,
never a crash.

## Getting started

The repo contains the application code, but the platform directories are best
filled in with a local Flutter SDK:

```bash
flutter create --platforms=android,ios .
flutter pub get
flutter run
```

`flutter create .` keeps the files under `lib/` intact while generating the full
Gradle/Xcode files required by your local Flutter version.

### Linux: `keybinder-3.0` required

Global shortcuts (`hotkey_manager`) link against `keybinder-3.0`. Without that
library `flutter build linux` **aborts while generating build files**
("Unable to generate build files") — that is a build error, not a runtime
degradation, so the app will not start at all:

```bash
sudo apt-get install keybinder-3.0
```

### Verification before pushing

There is no server-side CI (GitHub Actions is metered for this private repo, so
the workflow sits at `.github/workflows/ci.yml.disabled`). Instead, a `pre-push`
hook runs `flutter analyze` and `flutter test`. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

## Enabling a Whisper endpoint

In `lib/features/recordings/presentation/recordings_page.dart`, replace:

```dart
transcriptionService: const DisabledTranscriptionService(),
```

with, for example:

```dart
transcriptionService: HttpWhisperTranscriptionService(
  endpoint: Uri.parse('https://your-endpoint.example/transcribe'),
  bearerToken: const String.fromEnvironment('TRANSCRIPTION_TOKEN'),
),
```

Running with a token:

```bash
flutter run --dart-define=TRANSCRIPTION_TOKEN=secret
```

Expected endpoint response:

```json
{"text": "Transcript body"}
```

The endpoint should accept `multipart/form-data` with a `file` field.

## Tabs

The app has four tabs in the bottom navigation:

| Tab | What it is for |
| --- | --- |
| **Queue** | list of all items, status filters, search, record and note buttons, playback |
| **Models** | transcription provider profiles: add, edit, delete, pick the active one |
| **Logs** | stream of pipeline events (persist, queue, transcription, errors), level filter |
| **Config** | recording parameters, active provider summary, file information |

### Models — provider profiles

Instead of editing code, just add a profile in the Models tab. Ready-made
presets: OpenAI Whisper, OpenAI GPT-4o transcribe, Groq, local whisper.cpp
(`http://localhost:8080/inference`) and a custom endpoint.

Exactly one profile is active at a time. No profile = transcription disabled
(recording and local persistence work unchanged). `--dart-define` values seed
the first profile on the first run; after that `settings.json` wins.

> Tokens are stored in plaintext in `settings.json` in the app documents
> directory. Encryption is planned for a later phase.

### Queue — adding items

Above the record button there is a smaller note button. It opens a sheet with a
text field; saving creates a `.txt` file, verifies it, indexes it and only then
processes it (text passthrough, no network). The note button disappears while
recording, so that the "SAVE" action stays unambiguous.

The item card depends on the type: icon, playback button for audio only,
duration hidden for notes and images.

### Config — recording parameters

Editable: sample rate (8/16/22.05/44.1 kHz), bitrate (32–128 kbps), channels
(mono/stereo). The AAC-LC codec and the `.m4a` container are fixed. A change
applies only to subsequent recordings — files already saved stay untouched.

## Files on disk

Everything lives in the `recordings/` subdirectory of the app documents
directory, and every write is atomic (`.tmp` → `rename`):

- `<uuid>.<ext>` — the item's source material (`.m4a` recording, `.txt` note),
- `recordings.json` — the index of all items,
- `settings.json` — provider profiles and audio parameters,
- `logs.json` — event history (ring buffer, max. 500 entries).

## Next phase

- the remaining item types: audio file upload, images with offline OCR, video,
- a background job queue,
- WorkManager on Android and BGTaskScheduler on iOS,
- editing the title and the transcript,
- local on-device models (whisper.cpp via FFI),
- token encryption,
- synchronization with Obsidian/Notion.

Technical design: `docs/superpowers/specs/2026-07-25-multimodal-capture-design.md`.

## Processing Console UI

The Phase 1 interface now uses the **Processing Console** design direction:

- dark navy interface with cyan system accent,
- processing filters: Queue, Ready, Failed, Raw,
- visible local-file verification status,
- processing metrics and transcription state,
- retry action for failed transcription,
- recording remains local-first: stop -> verify file -> persist metadata -> transcribe.

## Reviewed state and micro-animations

Each capture has a durable `isProcessedByUser` flag and optional `processedAt` timestamp. This state is independent from transcription status and persists in `recordings.json`.

The Processing Console includes:

- animated reviewed checkmark, card highlight and status pill,
- selection haptic feedback,
- animated reviewed counter and progress bar,
- full history retention: reviewed items stay visible,
- no "Inbox Zero" celebration or empty-inbox pressure.
