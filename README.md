# Audivoa Core

A minimal **offline-first** Flutter app for recording voice notes.

## Ordering guarantee

Every way of adding an item — a microphone recording, a text note, or an
uploaded audio file, image or video — follows exactly the same order:

1. creates the source material (recording to `.m4a`, note body to `.txt`, an
   upload copied into the app's own directory),
2. stops the recorder / finishes writing the file,
3. checks that the file exists and has a non-zero size,
4. persists the metadata atomically to `recordings.json`,
5. only then sets the status to "queued" and returns — capture never waits on
   processing,
6. a background queue runs one job at a time, with the processor the item's
   type resolves to (transcription, text passthrough, OCR, video),
7. a processing failure never deletes the source material.

The processor **only reads** the source file — it never modifies or deletes it.

## Features

- AAC/M4A recording, mono, 16 kHz (parameters editable in the Config tab),
- text notes saved as `.txt` through the same pipeline as recordings,
- upload of an existing audio file, image or video through that same pipeline,
- local storage in the app documents directory,
- one shared list of all items, with a type-dependent icon and card,
- search across titles, output text and filenames, plus status filters,
- durable processing statuses and a background job queue — capture returns
  immediately, a long job never blocks the next one,
- retry for failed processing,
- editing an item's title and its output text,
- durable projects with repository paths, per-agent launch settings and one-click
  Codex, Claude Code or Gemini sessions on macOS,
- tags as individual chips: add, remove and reuse the vocabulary already on
  other captures,
- finished output is handed to the system clipboard, so a clipboard manager
  keeps it in history,
- system-wide global shortcuts on desktop,
- HTTP adapter ready for Whisper/OpenAI/Hugging Face,
- no delete function in the MVP, to limit the risk of data loss.

### Item types

| Type | Extension | Processing | Status |
| --- | --- | --- | --- |
| microphone recording | `.m4a` | transcription via the active profile | works |
| text note | `.txt` | text passthrough (no network) | works |
| audio upload | original | transcription via the active profile | works |
| image | `.jpg`/`.png` | OCR via system `tesseract` (`pol+eng`) | works on desktop |
| video | `.mp4`/`.mov` | audio track via system `ffmpeg` → transcription | works on desktop |

Image and video processing shells out to system binaries, the same way
`record_linux` shells out to `parecord`/`ffmpeg`. Install them for those two
types to work:

```bash
sudo apt-get install tesseract-ocr tesseract-ocr-pol ffmpeg   # Debian/Ubuntu
brew install tesseract tesseract-lang ffmpeg                  # macOS
```

On mobile — and on a desktop missing those binaries — the item is still
ingested, verified and listed; only its processing ends `failed`, with a
readable error and a retry button. The source file is untouched either way.

## Getting started

The repo contains the application code, but the platform directories are best
filled in with a local Flutter SDK:

```bash
flutter create --platforms=android,ios,macos .
flutter pub get
flutter run
```

`flutter create .` keeps the files under `lib/` intact while generating the full
Gradle/Xcode files required by your local Flutter version. It does, however,
**add `test/widget_test.dart`** — the counter-app template, which imports a
`MyApp` this project does not have. Delete it, or both `flutter analyze` and
`flutter test` fail on a file nobody wrote. It also rewrites `.metadata` so that
only the platforms named on the command line remain listed; restore the others
if you regenerate a single platform.

### macOS: the App Sandbox is deliberately off

`macos/Runner/{Release,DebugProfile}.entitlements` both set
`com.apple.security.app-sandbox` to `false`. Three shipped features shell out to
system binaries — `tesseract` (OCR), `ffmpeg` (video audio and poster) and
`open` (opening a source file) — and a sandboxed process passes its sandbox down
to everything it spawns, so all three break under it. They break *quietly*: the
item just lands `failed` with its source intact, which reads like a missing
binary rather than a sandbox denial. Re-enabling the sandbox is a Mac App Store
prerequisite and needs in-process replacements for those three first; the
entitlements file lists what else it would require.

Local builds are **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`), which needs no
Apple certificate. The consequence to expect: macOS ties microphone consent to
the code signature, so a rebuild can make the app ask for the microphone again.

Install it as a standalone app with:

```bash
flutter build macos --release
cp -R build/macos/Build/Products/Release/"Audivoa Core.app" /Applications/
```

Recordings land in `~/Documents/recordings/` — without the sandbox that is where
`getApplicationDocumentsDirectory()` points, rather than inside a container.

### Linux: `keybinder-3.0` and `libsecret-1-dev` required

Global shortcuts (`hotkey_manager`) link against `keybinder-3.0`. Without that
library `flutter build linux` **aborts while generating build files**
("Unable to generate build files") — that is a build error, not a runtime
degradation, so the app will not start at all. Token encryption
(`flutter_secure_storage`) links against `libsecret-1-dev` the same way:

```bash
sudo apt-get install keybinder-3.0 libsecret-1-dev
```

Tokens are encrypted with a key in the system keyring; without a keyring the
app stores them plaintext and says so in the Config tab.

### Verification before pushing

There is no server-side CI (GitHub Actions is metered for this private repo, so
the workflow sits at `.github/workflows/ci.yml.disabled`). Instead, a `pre-push`
hook runs `flutter analyze` and `flutter test`. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

## Enabling a Whisper endpoint

Add a profile in the **Models** tab — no code change needed. To seed the first
profile on a fresh install instead, pass the values at build time:

```bash
flutter run \
  --dart-define=TRANSCRIPTION_ENDPOINT=https://your-endpoint.example/transcribe \
  --dart-define=TRANSCRIPTION_TOKEN=secret \
  --dart-define=TRANSCRIPTION_MODEL=whisper-1 \
  --dart-define=TRANSCRIPTION_LANGUAGE=en
```

These are read **only on the first run**, when there is no `settings.json` yet;
after that the stored profiles win and the defines are ignored.

Expected endpoint response:

```json
{"text": "Transcript body"}
```

The endpoint should accept `multipart/form-data` with a `file` field.

## Tabs

The app has five tabs in the bottom navigation:

| Tab | What it is for |
| --- | --- |
| **Queue** | list of all items, review progress, search, status filters, capture buttons, playback, editing |
| **Projects** | repository contexts, active capture project and coding-agent session launchers |
| **Models** | transcription provider profiles: add, edit, delete, pick the active one |
| **Logs** | stream of pipeline events (persist, queue, transcription, errors), level filter |
| **Config** | recording parameters, global shortcuts, active provider summary, file information |

### Models — provider profiles

Instead of editing code, just add a profile in the Models tab. Ready-made
presets: OpenAI Whisper, OpenAI GPT-4o transcribe, Groq, local whisper.cpp
(`http://localhost:8080/inference`) and a custom endpoint.

Exactly one profile is active at a time. No profile = transcription disabled
(recording and local persistence work unchanged). `--dart-define` values seed
the first profile on the first run; after that `settings.json` wins.

> Tokens are encrypted at rest (AES-256-GCM) with a key held in the system
> keyring, never written to `settings.json` in plaintext. Without a working
> keyring the app falls back to plaintext and says so here and in the Config
> tab.

### Queue — adding items

Two buttons float over the bottom of the list. The large cyan one starts a
microphone recording. The smaller one above it opens the capture menu: a text
note, or an upload of an audio file, image or video. Each menu row states which
processor the item will land in, so the choice is not a guess.

Starting a recording replaces the screen with the capture view: the running
time, a live input meter, the ordered pipeline with the current step lit, and a
single full-width **SAVE**. There is deliberately no discard button — no path
in this app throws a capture away. The Queue underneath keeps its search text
and scroll position for when the capture finishes.

A text note opens a sheet with a character counter and a `NO NETWORK` badge:
saving writes a `.txt`, verifies it, indexes it, and only then processes it
(text passthrough, entirely on-device).

The item card depends on the type — icon, playback button for audio only,
duration hidden for notes and images — and every card carries the durability
line underneath: `file verified · 6.8 MB · persisted`. That size is measured by
the same check that proved the file was non-empty at capture time, so it is
never an estimate. Items saved before the size was recorded simply omit it.

### Queue — filters

The five chips **partition** the list, and each carries a live count:

| Chip | What it holds |
| --- | --- |
| **All** | everything — the union of the four below |
| **Queue** | queued plus the one currently running |
| **Ready** | processing finished |
| **Failed** | processing failed; source intact, retry offered |
| **Raw** | persisted and verified, not yet handed to a processor |

The counts describe the queue, not the search box — typing in the search field
narrows the list without changing them.

### Config — recording parameters

Editable: sample rate (8/16/22.05/44.1 kHz), bitrate (32–128 kbps), channels
(mono/stereo). The AAC-LC codec and the `.m4a` container are fixed. A change
applies only to subsequent recordings — files already saved stay untouched.

### Config — global shortcuts (desktop)

System-wide hotkeys that fire while the window is minimised or unfocused.
Bindings are editable in the Config tab and stored in `settings.json`. Three
ship bound:

| Shortcut | Action |
| --- | --- |
| `Ctrl+Alt+A` | show the window |
| `Ctrl+Alt+R` | start / stop recording |
| `Ctrl+Alt+N` | new note |

Uploading audio, an image or a video can be bound too, but ships unbound —
every plausible default already means something in a browser or an editor, and
a global hotkey wins system-wide.

Recording is the one action that does **not** raise the window first: the point
of a global record hotkey is not leaving whatever you are in. It raises the
window after the capture has started, so the microphone is never kept waiting,
and leaves it alone on stop. Every other action raises it first, because it
opens a sheet or a file dialog.

On Linux a Shift combination with a letter, digit or symbol does not work —
Shift changes which key the system listens for. Shift with `F1`–`F12`, space or
Enter is safe.

## Files on disk

Everything lives in the `recordings/` subdirectory of the app documents
directory, and every write is atomic (`.tmp` → `rename`):

- `<uuid>.<ext>` — the item's source material; the extension follows the type
  (`.m4a` recording, `.txt` note, the original extension for an upload),
- `recordings.json` — the index of all items,
- `settings.json` — provider profiles, audio parameters and shortcut bindings,
- `logs.json` — event history (ring buffer, max. 500 entries).

## Next phase

- OCR and video processing on mobile (ML Kit / ffmpeg_kit), which today are
  desktop-only,
- WorkManager on Android and BGTaskScheduler on iOS, so jobs survive the app
  being backgrounded,
- local on-device models (whisper.cpp via FFI),
- synchronization with Obsidian/Notion.

Technical design: `docs/superpowers/specs/2026-07-25-multimodal-capture-design.md`.

## Processing Console UI

The interface implements the **console cards** design direction:

- dark navy surfaces with a cyan system accent, and translucent hairlines so
  one border value reads correctly on the page, on a card and in a sheet,
- **Space Grotesk** for names and headings, **JetBrains Mono** for everything
  factual — statuses, counters, timers, file facts. Both are vendored under
  `assets/fonts` (SIL OFL) rather than fetched at runtime, because an
  offline-first app must not need the network to render its own text,
- no app bar: each tab draws its own header inside its scroll area, so the
  title scrolls with the content,
- a done-progress strip above the list; the per-status counts live on the
  filter chips, where they are actionable,
- the local-file verification line on every card, including failed ones,
- a dedicated capture screen while recording,
- retry on any failed item,
- feedback stays inline — no snackbars, and dialogs only to confirm something
  destructive.

Capture remains local-first throughout: stop → verify the file → persist the
metadata → queue → process.

## Done state and tags

Each capture has a durable `isProcessedByUser` flag and an optional
`processedAt` timestamp. This axis is entirely independent of processing
status: nothing in the pipeline ever sets or clears it, and marking an item
done never touches its transcript. Both persist in `recordings.json`.

- the toggle animates, the card border picks up the accent and a check appears
  next to the name,
- selection haptic feedback on toggle,
- the done counter and its progress bar animate to the new value,
- full history retention: done items stay visible,
- no "Inbox Zero" celebration or empty-inbox pressure.

Tags are one list per capture, with no notion of who wrote them: a value the
model proposed and one typed by hand are the same tag. Values are normalized to
lowercase and de-duplicated, render on the card, and participate in Queue
search. Enrichment fills the list only when it is empty, so a retry cannot
overwrite tags you have set; clearing them asks the next run for a fresh set.

Projects are a separate durable model rather than a naming convention hidden
inside tags. Each project stores a repository path, description, optional
Zellij session name, default agent, and per-agent arguments/prompt. Selecting an
active project assigns subsequent captures automatically; existing captures
can be reassigned or filtered in Queue. On macOS the Projects tab can open a
named Ghostty/Zellij session for Codex, Claude Code or Gemini without invoking a
shell or interpolating a command string.
