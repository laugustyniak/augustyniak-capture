<div align="center">

<img src="assets/icon/app_icon_1024.png" width="120" alt="Augustyniak Capture" />

# Augustyniak Capture

**Offline-first capture queue for voice, text, images and video.**
Your thought lands on disk *before* anything clever is attempted with it.

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-%E2%89%A53.10-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Linux%20%C2%B7%20Windows%20%C2%B7%20Android%20%C2%B7%20iOS-555)](#-build--deploy)
[![Offline first](https://img.shields.io/badge/offline-first-1056C6)](#-the-one-guarantee)
[![License](https://img.shields.io/badge/license-see%20LICENSE-lightgrey)](LICENSE)

[Quick start](#-quick-start) ·
[What it captures](#-what-it-captures) ·
[Note vault](#-note-vault--obsidian-and-friends) ·
[Build & deploy](#-build--deploy) ·
[Providers](#-connect-a-provider) ·
[Architecture](#-architecture)

</div>

---

## 💡 What is this?

Press a global hotkey, talk, forget about it. The recording is saved and verified
on disk immediately; transcription, OCR and AI titling happen **afterwards, in the
background, and are allowed to fail** without ever costing you the capture.

```
   press Ctrl+Alt+R   ->   file on disk, verified   ->   transcribed
   press Ctrl+Alt+N   ->   file on disk, verified   ->   passed through
   upload an image    ->   file on disk, verified   ->   OCR'd
   upload a video     ->   file on disk, verified   ->   audio track transcribed
                              ^                            ^
                              |                            |
                       never negotiable            may fail, retryable
```

Then the enrichment stage gives each capture a title, a summary, a category and
tags. One keypress hands it off to your project's `inbox.md` — where the coding
agent that reads that repo next will find it — and, if you point the app at one,
every capture is also mirrored into your **Obsidian vault** as a markdown note
with proper front matter.

---

## ⚡ Quick start

```bash
git clone <this-repo> && cd augustyniak-capture
flutter pub get
flutter run                       # pick a device when prompted
```

That is genuinely all — the app is fully usable with **no** API key. Recording,
notes, uploads, storage, search, projects and hand-off all work offline. Only
transcription, OCR and AI titling need an endpoint, and you add that in the UI.

<details>
<summary><b>If <code>flutter run</code> complains about the platform scaffolding</b></summary>

All six targets (`android/ ios/ linux/ macos/ windows/`) are checked in, but a
much newer Flutter SDK may want regenerated templates:

```bash
flutter create --platforms=android,ios,linux,macos,windows .
rm test/widget_test.dart     # ⚠️ see below
```

`flutter create` leaves `lib/` alone, but it **adds `test/widget_test.dart`** —
the counter-app template, which imports a `MyApp` this project does not have.
Leave it and both `flutter analyze` and `flutter test` fail on a file nobody
wrote. It also rewrites `.metadata` to list only the platforms you named;
restore the other entries by hand if you regenerate a single platform.

</details>

---

## 🔒 The one guarantee

Every capture path — microphone, text note, audio/image/video upload — runs the
**same seven steps in the same order**. This ordering is the reason the app
exists.

```mermaid
flowchart LR
    A["1 · create source<br/>(.m4a / .txt / copy)"] --> B["2 · finish the write"]
    B --> C["3 · verify<br/>exists & size > 0"]
    C --> D["4 · persist metadata<br/>atomically (.tmp → rename)"]
    D --> E["5 · status: queued<br/><i>capture returns now</i>"]
    E --> F["6 · background queue<br/>one job at a time"]
    F --> G["7 · completed"]
    F --> H["7 · failed<br/><i>source intact, retryable</i>"]

    style C fill:#1056C6,color:#fff
    style D fill:#1056C6,color:#fff
    style H fill:#8a2b2b,color:#fff
```

Two rules fall out of it, and both are enforced in code:

| Rule | Why it matters |
| --- | --- |
| **A processor only ever reads the source file** | It never writes, moves or deletes it. A failed transcription costs you a status, never a recording. |
| **A bad read of the index can never overwrite it** | `recordings.json` is rewritten whole on every change, so an unreadable index freezes *all* writes for the session and says so on screen, instead of quietly writing emptiness over your history. |

Capture never waits on processing. Start a new recording while the previous one
is still being transcribed — the queue simply grows.

---

## 📥 What it captures

| | Type | Stored as | Processing | Where it works |
| --- | --- | --- | --- | --- |
| 🎙 | microphone recording | `.m4a` | transcription | everywhere |
| 📝 | text note | `.txt` | passthrough, no network | everywhere |
| 🎧 | audio upload | original ext | transcription | everywhere |
| 🖼 | image | `.jpg` / `.png` | **OCR** — vision model, or `tesseract` | everywhere with a vision profile; desktop otherwise |
| 🎬 | video | `.mp4` / `.mov` | `ffmpeg` audio track → transcription | desktop |

Image OCR is **LLM-first**: with an enrichment profile configured it sends the
image to that profile's vision endpoint on *every* platform, mobile included.
Without one, it falls back to system `tesseract` on desktop.

```bash
# optional desktop binaries — OCR fallback and all video handling
sudo apt-get install tesseract-ocr tesseract-ocr-pol ffmpeg   # Debian/Ubuntu
brew install tesseract tesseract-lang ffmpeg                  # macOS
winget install Gyan.FFmpeg UB-Mannheim.TesseractOCR           # Windows
```

Missing a binary is not a crash: the item is still ingested, verified and listed,
its processing lands `failed` with a readable error and a retry button, and the
source file is untouched.

---

## 🖥 The five tabs

| Tab | What it is for |
| --- | --- |
| **Queue** | every capture, review progress, search, filters, playback, inline editing |
| **Projects** | repository contexts, active project, per-project captures, one-click coding-agent sessions |
| **Models** | provider profiles — transcription and enrichment, add / edit / activate |
| **Logs** | live pipeline events (persist, queue, transcribe, errors) with a level filter |
| **Config** | appearance, audio parameters, global shortcuts, enrichment profile, note vault, keyring status |

### A queue row, annotated

```
┌────────────────────────────────────────────────────────────────┐
│ [#]  Sprint planning notes                    play  edit  done │  (1)
│      meetingNote    backend-api                                │  (2)
│      We agreed to postpone the migration until the index       │  (3)
│      durability work lands, and to split the router...         │
│      file verified · 6.8 MB · persisted                        │  (4)
└────────────────────────────────────────────────────────────────┘

 (1)  Type icon — replaced by the extracted video poster in the identical
      geometry, so a row's shape never depends on whether a frame was pulled.
      The title comes from enrichment; with no profile it reads "Recording ·
      14:32" — never the filename, because a column of uuids is unscannable.
 (2)  Category and project. Both are *labels*, so both render outlined;
      only the pipeline status ever gets a filled pill.
 (3)  The processor's output — transcript, OCR result, or the note body.
      This is what Queue search matches on.
 (4)  Measured by the very check that proved the file was non-empty at capture
      time. It is never an estimate; captures saved before it was recorded
      simply omit the segment rather than printing "0 B".
```

The action strip is **play / edit / done** — all cheap and reversible. `DELETE`
lives one level deeper, inside the editor, behind a dialog that names the item:
queue rows all look alike, and a destructive control a few pixels from `play` is
the one mis-tap this app cannot undo.

### Filters

Five status chips that **partition** the list, each with a live count:

| Chip | Holds |
| --- | --- |
| `ALL` | everything — the union of the four below |
| `QUEUE` | queued, plus the one currently running |
| `READY` | processing finished |
| `FAILED` | processing failed; source intact, retry offered |
| `RAW` | persisted and verified, not yet handed to a processor |

…intersected with a second, independent axis: `DESK` / `OFF DESK` / `ANY`. That
one is about *you*, not the pipeline — nothing in processing ever sets or clears
it. Counts describe the queue, not the search box.

### Keyboard

The Queue is fully drivable without the mouse. Letters carry no modifier — a
focused text field eats them first, so `e` types an "e" in search and edits a row
everywhere else.

| Key | Action | | Key | Action |
| --- | --- | --- | --- | --- |
| `↑` `↓` / `J` `K` | move selection | | `R` | route / hand off |
| `E` | edit inline | | `Space` | play |
| `D` | mark done | | `Ctrl/⌘+F`, `/` | search |
| `Esc` | clear selection | | | |

### Three layouts, one shell

```
   under 600 px          600 - 900 px            900 px and up
 ┌────────────┐      ┌────────────────┐      ┌──────┬────────────────┐
 │   rows     │      │     cards      │      │ rail │     cards      │
 │ [========] │      │ [============] │      │ logo │ [============] │
 │ [========] │      │ [============] │      │ nav  │ [============] │
 │            │      │        (o)dock │      │ (o)  │                │
 ├────────────┤      ├────────────────┤      └──────┴────────────────┘
 │ nav  (o)   │      │      nav       │
 └────────────┘      └────────────────┘
  nav bar carries     nav bar plus a       a 216 px column carries
  the capture         floating capture     navigation AND capture,
  buttons inline      dock                 so neither bar is drawn
```

Chosen from a `LayoutBuilder`, not `MediaQuery`, so dragging a desktop window
narrow really does fall back through all three.

---

## 🔌 Connect a provider

No code change and no rebuild: open **Models → + profile**, pick a preset, paste
a key. Presets ship for:

| Transcription | Enrichment / vision |
| --- | --- |
| OpenAI transcribe · OpenAI Whisper | OpenAI · Anthropic |
| Groq | Groq chat *(no vision model — images will fail)* |
| Local whisper.cpp (`localhost:8080`) | Local Ollama (`localhost:11434`) |
| Custom endpoint | Custom endpoint |

Exactly one profile is active per kind, and the two are independent. **No profile
= that stage is simply disabled** — recording and persistence carry on unchanged.

<details>
<summary><b>Seeding the first profile from the command line</b></summary>

Read **only on the first run**, when there is no `settings.json` yet. Afterwards
the stored profiles win and these are ignored.

```bash
flutter run \
  --dart-define=TRANSCRIPTION_ENDPOINT=https://api.openai.com/v1/audio/transcriptions \
  --dart-define=TRANSCRIPTION_TOKEN=sk-… \
  --dart-define=TRANSCRIPTION_MODEL=whisper-1 \
  --dart-define=TRANSCRIPTION_LANGUAGE=en
```

</details>

### The transcription contract

Any endpoint that speaks this shape works — that is the whole integration:

```bash
curl -X POST https://your-endpoint.example/v1/audio/transcriptions \
  -H "Authorization: Bearer $TOKEN" \
  -F file=@recording.m4a \
  -F model=whisper-1
```

```jsonc
{ "text": "Transcript body" }     // "transcript" is accepted as a fallback key
```

### The enrichment contract

An OpenAI-compatible `/v1/chat/completions` with `response_format: json_object`,
which is why OpenAI, Groq and a local Ollama all work unmodified. The model
answers:

```json
{
  "title": "Sprint planning — migration postponed",
  "category": "meetingNote",
  "summary": "Migration deferred until index durability lands; router split agreed.",
  "tags": ["backend", "migration", "sprint"]
}
```

`category` is a closed list of **routing destinations, not topics** — which is
what keeps the vocabulary small enough for a small model to classify reliably:

```
note · task · agentTask · idea · meetingNote · researchLead · capture
```

Parsing degrades rather than throws: an unknown category becomes `capture`, a
blank title becomes null, tags are lowercased, de-duplicated and capped at five.
Enrichment writes `title` only when blank and `category` only when null, and
fills `tags` only when the list is empty — so a retry can never overwrite what
you set by hand.

### 🔐 Tokens at rest

Encrypted with **AES-256-GCM** under a master key held in the OS keyring
(Keychain / libsecret / DPAPI), stored as `enc:v1:<base64>`. Legacy plaintext
tokens migrate on the first load with a working keyring. **No keyring → clean
plaintext fallback, said out loud** in the Models and Config tabs rather than
failed silently.

---

## 📤 Hand-off

Pressing `R` on a capture appends it to `inbox.md` in that capture's project
repository, then marks it `OFF DESK`. Delivery happens first, state second: a
throw leaves the item open and retryable.

```markdown
## Sprint planning — migration postponed

*2026-08-05T14:32:11.482 · meetingNote · #backend · #migration*

> Migration deferred until index durability lands; router split agreed.

We agreed to postpone the migration until the index durability work lands…
```

A plain file was chosen over any tracker API deliberately: it needs no token and
no network, so it does not trade away the one property the app is built on, and
the result is readable by every tool you already have.

Each project card carries a `CAPTURES (n)` button that opens everything filed
under it in a sheet — searchable, and editable in place with the same inline
editor the Queue uses, so reviewing one project's thinking does not mean
filtering the whole queue down to it and then losing that filter.

---

## 🗄 Note vault — Obsidian and friends

Point the app at a directory you own — an Obsidian vault, a synced folder, a
plain notes repository — and **every capture is mirrored there as a markdown
file**, with the enriched title, category and tags in YAML front matter.

```
Config -> NOTE VAULT                                   [ MIRRORING ]
  ┌──────────────────────────────────────────────────────────────┐
  │ VAULT DIRECTORY   /Users/you/Obsidian/Second Brain    [ .. ] │
  │ SUBFOLDER         Capture                                    │
  │ SOURCE FILES      ( COPY INTO VAULT )  ( NOTE TEXT ONLY )    │
  │                                                              │
  │ NOTES        /Users/you/Obsidian/Second Brain/Capture        │
  │ ATTACHMENTS  …/Capture/attachments                           │
  │                                                              │
  │                                     [ MIRROR EVERYTHING ]    │
  └──────────────────────────────────────────────────────────────┘
```

An empty directory field is the off switch — deliberately, rather than a
separate "enabled" checkbox, because two fields would allow the state *enabled,
nowhere to write*, which can only ever be reported as an error nobody asked for.
The status pill reads `MIRRORING` or `OFF`, and the two resolved paths are shown
because a subfolder typo and a working vault are otherwise the same screen.

**`MIRROR EVERYTHING` is the backfill, and it is not a convenience.** Mirroring
only *new* captures would leave the queue you already have permanently outside
the vault, with no way in short of re-recording it. The sweep runs sequentially
on purpose — a hundred concurrent writes into a directory your notes application
is watching buys nothing but a stampede of file events — and skips captures with
no text yet. On desktop the directory field carries a browse button behind the
same `DirectoryPicker` seam the project editor uses; the typed field stays
authoritative everywhere.

### What lands in the vault

```
Second Brain/                 ← your vault, your filing system
└── Capture/                  ← notes land in a subfolder, never the root
    ├── 2026-08-05-1432-sprint-planning-migration-postponed-3f2a1c4e.md
    ├── 2026-08-05-0917-notatka-o-wdrozeniu-9d1077ef.md
    └── attachments/          ← Obsidian's own convention
        ├── 3f2a1c4e-….m4a
        └── 9d1077ef-….jpg
```

```
 2026-08-05-1432  -  sprint-planning-migration-postponed  -  3f2a1c4e  .md
 └─ when ────────┘   └─ slug of the title ──────────────┘   └─ id ──┘
    sortable            decoration — may be stale              the only
                        after a re-title                       part that
                                                               identifies
```

```markdown
---
title: "Sprint planning — migration postponed"
created: 2026-08-05T14:32:11.482Z
type: audioRecording
category: meetingNote
project: "augustyniak-capture"
tags: ["backend", "migration"]
duration: 3m 04s
source: "3f2a1c4e-….m4a"
capture-id: 3f2a1c4e-…-c81b
capture-hash: 8f14e45fceea167a5a36dedd4bea2543…
---

# Sprint planning — migration postponed

> Migration deferred until index durability lands; router split agreed.

![[attachments/3f2a1c4e-….m4a]]

We agreed to postpone the migration until the index durability work lands…
```

The two machine fields sit **last** on purpose, so the plumbing lands at the
bottom of the property list your reader shows rather than above your own
metadata.

### When it writes

Three trigger points, and the list is deliberately short:

```mermaid
flowchart LR
    P["processing<br/>completes"] --> E["enrichment<br/><i>title, category, tags</i>"]
    E --> M["mirror"]
    R["enrichment<br/>retried by hand"] --> M
    U["you edit a<br/>mirrored field"] --> M
    S["MIRROR EVERYTHING<br/><i>whole-queue sweep</i>"] --> M

    style M fill:#1056C6,color:#fff
```

**Mirroring runs *after* enrichment, never before — and that ordering is the
load-bearing part.** A note written first would be filed as
`2026-08-05-1432-recording-1432-3f2a1c4e.md` and would have to live with that
name for good, because rule 2 above forbids ever renaming it. Waiting the extra
moment is what buys a file name that says what the capture was. It runs whether
or not enrichment *succeeded*: an install with no profile still wants its
captures copied.

A hand edit reaches the vault only when it changed something a note actually
prints — `title`, `category`, `summary`, `transcript`, `projectId` or `tags`.
Status transitions and poster paths appear nowhere in a note, so mirroring on
them would rewrite every file in the vault on every pipeline tick. Equally, the
processing and enrichment paths mirror explicitly at their own tails rather than
from the shared `_update` funnel — doing both would write the same note two or
three times per capture, and each of those writes lands as a file event in
whatever is watching the directory.

### Mirror, not route — and that distinction is the whole design

| | Hand-off (`CaptureRouter`) | Vault (`NoteVault`) |
| --- | --- | --- |
| **Delivers** | once | the same note, over and over |
| **Write mode** | append-only | rewrite in place |
| **Closes the item** | yes, sets `OFF DESK` | no, it is a copy |
| **Twice** | two entries — both really happened | one file, updated |

A route is a delivery. A vault holds *the same thought over time*: enrichment
names it minutes after it was created, and you may correct a transcript a week
later. Folding the two together would give you either an inbox accumulating
duplicates of one thought, or a mirror that could never record a second delivery
honestly.

### Four rules, because the vault is not ours

The reader does not merely edit these files — their application indexes them,
links them, and reorders lists by modification time. So:

1. **A note is located by id, never by name.** The file name carries the first
   eight characters of the capture id as a suffix; the rest is decoration. That
   is what lets a title arrive from enrichment *after* the file already exists.
2. **The name is then never changed again.** Renaming a file behind your back
   would break every `[[wikilink]]` you had written to it, and nothing in this
   app could repair them. A later title lands in the front matter and the
   heading — the same information, without the cost.
3. **A file is only rewritten while it is still ours.** `capture-hash` is the
   sha-256 of the body beneath the front matter. A mismatch means you edited the
   note, and the mirror steps back. The claim lives *in the file* rather than in
   `recordings.json`, so a vault rebuilt after a reinstall still knows which
   notes it owns.
4. **An unchanged note is not rewritten at all.** A no-op write would still bump
   the mtime and shove the note to the top of your "recently modified" list on
   every unrelated pipeline tick.

Every mirror reports which of these applied, and a sweep over the queue counts
them for the Config tab:

| Outcome | Meaning |
| --- | --- |
| `created` | no file for this capture existed |
| `updated` | still ours, and a mirrored field changed |
| `unchanged` | already identical — no write, on purpose |
| `foreign` | **you edited it.** Left alone, and counted rather than swallowed: this is the one outcome that looks like a failure and is in fact the mirror doing its job |

Mirroring is best-effort under the same contract as the clipboard: it runs after
the capture is already persisted, swallows its errors into the Logs tab, and
**never touches `status`**. A vault on an unmounted drive costs you a copy, never
a capture. Writes are atomic (`.tmp` → `rename`) for a sharper reason than
usual — a torn write would leave a file whose hash no longer matches its body,
which this code would then read back as *your* edit and refuse to touch ever
again.

> **Polish diacritics are transliterated in file names, not dropped.** These
> captures are largely Polish, and `notatka-o-wdroeniu` names nothing. Slugs are
> ASCII, lowercase, hyphenated, capped at 48 characters and cut on a word
> boundary so a shortened name still reads as a title.

> **`Copy sources` is a switch rather than a constant** because the two answers
> differ by gigabytes on a vault that syncs. On, an audio capture is playable
> straight from your reader. Off, the vault stays text-only and the media stays
> where it already lives. Text notes never attach their `.txt` either way — the
> body is already printed above it.

---

## ⌨️ Global shortcuts (desktop)

System-wide, firing while the window is minimised or unfocused. Editable in
Config, stored in `settings.json`.

| Shortcut | Action | |
| --- | --- | --- |
| `Ctrl+Alt+A` | show the window | ✅ ships bound |
| `Ctrl+Alt+R` | start / stop recording | ✅ ships bound |
| `Ctrl+Alt+N` | new text note | ✅ ships bound |
| — | upload audio / image / video | ⚪ bindable, ships unbound |

Recording is the one action that does **not** raise the window first — the point
of a global record hotkey is not leaving whatever you were in. It raises the
window *after* the capture has started, so the microphone is never kept waiting,
and leaves it alone on stop.

> **Linux caveat:** `Shift` + a letter, digit or symbol binds successfully and
> then never fires — `keybinder` grabs the *unshifted* keyval, so X resolves the
> press to a different keysym. `Shift`+`F1`–`F12`, space or Enter are safe, and
> the app refuses the broken combinations up front rather than registering them
> into silence. `Super` is unusable under GNOME regardless.

---

## 💾 Files on disk

Everything lives in the `recordings/` subdirectory of the app documents
directory. Every rewrite is atomic (`.tmp` → `rename`).

```
recordings/
├── 3f2a…-c81b.m4a          ← source material, one file per capture
├── 3f2a…-c81b.thumb.jpg    ← derived video poster (safe to delete)
├── 9d10…-77ef.txt
├── recordings.json         ← the index — every capture, rewritten whole
├── settings.json           ← profiles, audio params, shortcuts, theme, vault path
├── projects.json           ← projects + the active one
├── logs.json               ← ring buffer, max 500 events
└── revisions.jsonl         ← append-only history of overwritten values
```

Three things deliberately live **outside** that directory, because they belong to
you rather than to the app: your project repositories (and the `inbox.md` in
each), your [note vault](#-note-vault--obsidian-and-friends), and the master key
for token encryption, which is in the OS keyring.

<details>
<summary><b>What a row in <code>recordings.json</code> looks like</b></summary>

```json
{
  "id": "3f2a1c4e-…-c81b",
  "type": "audioRecording",
  "createdAt": "2026-08-05T14:32:11.482Z",
  "status": "completed",
  "durationMs": 184000,
  "sizeBytes": 7127040,
  "title": "Sprint planning — migration postponed",
  "category": "meetingNote",
  "summary": "Migration deferred until index durability lands.",
  "tags": ["backend", "migration"],
  "transcript": "We agreed to postpone the migration…",
  "projectId": "b71f…",
  "isProcessedByUser": true,
  "processedAt": "2026-08-05T15:04:02.110Z",
  "routes": [
    { "at": "2026-08-05T15:04:02.100Z", "kind": "file", "target": "inbox.md · capture" }
  ]
}
```

Every `fromJson` is backward compatible: a field absent from an older row gets a
default rather than dropping the row.

</details>

<details>
<summary><b>Why <code>revisions.jsonl</code> is the one append-only store</b></summary>

Enrichment and the inline editor both *replace* text — a title, a summary, a
whole transcript on a re-run. `revisions.jsonl` holds what was overwritten, so it
is the only copy of that text left anywhere.

A file whose job is preserving lost values must not itself be overwritable, so it
appends (`FileMode.writeOnlyAppend`) instead of rewriting like every other store
here. A kill can cost the row being written and nothing else; a torn final line
is skipped on load. Only five fields are tracked (`title`, `category`, `summary`,
`tags`, `transcript`), and a change *out of an empty value* is never recorded —
filling a blank overwrites nothing, which is what keeps the file small.

The history surfaces as a collapsed `HISTORY` section at the bottom of the inline
editor, with a copy button per entry that hands back the **previous** value in
full.

</details>

> ⚠️ **On iOS and Android none of this survives a reinstall.** There, the app
> documents directory lives *inside* the app container, and a new signature, a
> changed `applicationId` or `flutter run` after an uninstall takes the container
> — with the `.m4a` files in it — with it. That is data loss no code in this repo
> can prevent; it needs an export/import path, which is on the roadmap.

---

## 🚀 Build & deploy

`flutter run` covers development on every target. Below is what it takes to
produce something you can hand to a person or a store.

### At a glance

| Target | Release command | Artifact | Prerequisites |
| --- | --- | --- | --- |
| 🍎 **macOS** | `flutter build macos --release` | `.app` bundle | Xcode + CLI tools |
| 🐧 **Linux** | `flutter build linux --release` | bundle directory | `keybinder-3.0`, `libsecret-1-dev`, `clang`, `ninja-build`, `libgtk-3-dev` |
| 🪟 **Windows** | `flutter build windows --release` | `Runner.exe` + DLLs | Visual Studio 2022 (Desktop C++ workload) |
| 🤖 **Android** | `flutter build appbundle --release` | `.aab` for Play | JDK **21**, Android SDK, keystore |
| 📱 **iOS** | `flutter build ipa --release` | `.ipa` | Xcode, CocoaPods, Apple Developer account |

Each target must be built **on** its own OS — Flutter has no cross-compilation.
macOS is the only host that can build all five.

---

### 🍎 macOS

```bash
flutter build macos --release
cp -R "build/macos/Build/Products/Release/Augustyniak Capture.app" /Applications/
```

Recordings land in `~/Documents/recordings/`.

<details>
<summary><b>Why the App Sandbox is deliberately off — read before re-enabling it</b></summary>

Both `macos/Runner/Release.entitlements` and `DebugProfile.entitlements` set
`com.apple.security.app-sandbox` to `false`, and they must stay in agreement or a
debug run cannot reproduce an installed-app bug.

A sandboxed process hands its sandbox to every child it spawns, which breaks all
three of this app's shell-outs at once: `tesseract` and `ffmpeg` could not read
the recordings directory, and `open` could not reach LaunchServices. They break
*the same quiet way a missing binary does* — the item lands `failed` with its
source intact — so the sandbox is invisible as a cause.

Re-enabling it is a **Mac App Store prerequisite, not a security fix**: it needs
`device.audio-input`, `network.client` and `files.user-selected.read-only`, *and*
in-process replacements (Vision, AVFoundation, NSWorkspace) before those three
features work again — *and* a real Team-ID signature, because the sandbox forces
the data-protection keychain that token encryption would then have to use.

One entitlement is required **regardless of the sandbox**:
`com.apple.security.files.user-selected.read-only`, in both files. `file_picker`
checks it against its own task signature, so without it *every* picker call
answers `PlatformException(ENTITLEMENT_NOT_FOUND)` — all three upload types and
the project repository browser. Verify it on the built bundle, not in the file:

```bash
codesign -d --entitlements - "build/macos/Build/Products/Release/Augustyniak Capture.app"
```

</details>

<details>
<summary><b>Signing: ad-hoc by default, notarized for distribution</b></summary>

Local builds are **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`), which needs no
Apple certificate. Two consequences to expect: macOS ties microphone *and*
keychain consent to the code signature, so a rebuild can re-prompt for both; and
a Release build still carries `get-task-allow`, so it is debuggable.

To ship it to other people's Macs without a Gatekeeper warning, you need a
Developer ID certificate and notarization:

```bash
# 1 · sign with a real identity
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  "build/macos/Build/Products/Release/Augustyniak Capture.app"

# 2 · ship it in a container Apple will accept
ditto -c -k --keepParent \
  "build/macos/Build/Products/Release/Augustyniak Capture.app" AugustyniakCapture.zip

# 3 · notarize and staple
xcrun notarytool submit AugustyniakCapture.zip \
  --apple-id you@example.com --team-id TEAMID --password "$APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple "build/macos/Build/Products/Release/Augustyniak Capture.app"
```

</details>

---

### 🐧 Linux

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
                     keybinder-3.0 libsecret-1-dev
flutter build linux --release
./build/linux/x64/release/bundle/augustyniak_capture
```

The whole `bundle/` directory is the artifact — the binary needs the `lib/` and
`data/` next to it. Ship it as a tarball, or wrap it:

```bash
flutter pub global activate flutter_distributor
flutter_distributor package --platform linux --targets deb,appimage
```

> **`keybinder-3.0` and `libsecret-1-dev` are build-time, not runtime.** Without
> the first, `flutter build linux` aborts at *"Unable to generate build files"* —
> nothing runs at all. Without the second, the same. At runtime a keyring daemon
> must additionally be running and unlocked, or token encryption degrades to
> plaintext with a visible warning in the Config tab.

---

### 🪟 Windows

Requires **Visual Studio 2022** with the *Desktop development with C++* workload
(the Build Tools alone are enough).

```powershell
flutter build windows --release
.\build\windows\x64\runner\Release\augustyniak_capture.exe
```

Ship the whole `Release\` folder — the `.exe` needs the DLLs and `data\` beside
it. For an installer:

```powershell
flutter pub global activate flutter_distributor
flutter_distributor package --platform windows --targets msix
```

> ⚠️ **Global shortcut defaults need review here.** Windows reports AltGr as
> `Ctrl+Alt`, and AltGr is how the Polish layout types ą/ć/ę/ł/ń/ó/ś/ź/ż — so the
> shipped `Ctrl+Alt+A/R/N` defaults would collide. On X11 AltGr is
> `ISO_Level3_Shift`, which is why they are safe on Linux. Rebind them in Config
> if you type Polish on Windows.

---

### 🤖 Android

Two pins that are **not optional**. Neither is discoverable from the code, and
both were found by building on a clean machine.

```bash
# 1 · Gradle must run on JDK 21 — Android Studio's bundled JBR is Java 25,
#     and the older Kotlin plugins here cannot parse a two-digit version.
#     The build dies on `IllegalArgumentException: 25.0.2`, never mentioning Java.
brew install --cask temurin@21
flutter config --jdk-dir "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"
```

**2 · AGP must stay on 8.x** in `android/settings.gradle.kts`, even though
`flutter create` generates 9.0.1. Under AGP 9 the plugin set deadlocks and the
first half fails *silently*: Gradle reports `BUILD SUCCESSFUL` and emits an AAR
whose `classes.jar` is 22 bytes, surfacing much later as `cannot find symbol:
class FilePickerPlugin`.

```bash
flutter build apk --release        # sideload / direct download
flutter build appbundle --release  # Google Play
```

<details>
<summary><b>Release signing is opt-in — and unsigned builds look identical</b></summary>

`android/app/build.gradle.kts` reads `android/key.properties` (untracked;
template at `android/key.properties.example`) and signs release builds **only if
that file exists**. Absent it, release falls back to the debug key exactly as the
Flutter template does — deliberate, so a contributor without the keystore can
still check that a release build compiles.

The corollary is the trap: **a release artifact is debug-signed unless you verify
otherwise**, and nothing in the build output says so.

```bash
# create the keystore once, outside the checkout — PKCS12, not the legacy JKS
keytool -genkeypair -v -keystore ~/.android/augustyniak-capture-upload.p12 \
  -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias upload

cp android/key.properties.example android/key.properties   # then fill it in

# ALWAYS check what actually signed the artifact
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
# `CN=Android Debug` means the fallback ran — key.properties was missing.
```

A `key.properties` that exists but is incomplete fails the build with a written
explanation rather than a null-pointer from inside AGP.

> 🔑 **Back the keystore up somewhere that is not this machine.** It is the one
> artifact here that cannot be regenerated: once a build is on Play under
> `ai.augustyniak.capture`, losing the key means no future build can ever update
> it. (Google Play App Signing softens this — enrol, and this becomes only the
> *upload* key, which Google can reset.)

</details>

---

### 📱 iOS

```bash
cd ios && pod install && cd ..
flutter build ipa --release
# → build/ios/ipa/*.ipa, then upload with Transporter or:
xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios \
  -u you@example.com -p "$APP_SPECIFIC_PASSWORD"
```

Signing is configured in Xcode (`open ios/Runner.xcworkspace` → *Signing &
Capabilities* → your team). For a personal device without a paid account,
`flutter run --release` sideloads a build that expires after seven days.

> **`ios/Runner/Info.plist` is hand-maintained and must stay complete.** It is
> not regenerated, so a missing key is invisible until deploy time: without
> `CFBundleIdentifier` the app still builds, `flutter build ios` reports success,
> and `simctl install` then refuses it with *"Missing bundle ID"*. It also
> carries `NSMicrophoneUsageDescription` (the microphone is the whole app) and
> the `UIApplicationSceneManifest` that wires up `SceneDelegate.swift`.

---

### 🆔 One identifier, everywhere, permanently

`ai.augustyniak.capture` — Android `applicationId`, iOS/macOS
`PRODUCT_BUNDLE_IDENTIFIER`, Linux `APPLICATION_ID`. **Treat it as immutable.**

Changing it is a migration, not a rename: a new identifier publishes a
*different* app, so existing installs never upgrade, the signing key stops
matching, and on Android and iOS the old container — with the recordings in it —
is abandoned. `test/rebrand_test.dart` pins the current values so a half-finished
rename fails the suite instead of shipping.

---

## 🎨 The interface

A "Processing Console" direction, in **two themes** (system / dark / light,
picked in Config → Appearance):

- 🎨 the augustyniak.ai design system's semantic tokens resolved to hex, accented
  in house **blue** (`#59A0F8` dark, `#1056C6` light);
- 🔤 **Space Grotesk** for names and headings, **JetBrains Mono** for everything
  factual — statuses, counters, timers, file facts. Both are vendored under
  `assets/fonts` (SIL OFL) rather than fetched at runtime, because an
  offline-first app must not need the network to render its own text;
- 📜 no app bar — each tab draws its own header inside its scroll area, so the
  title scrolls with the content;
- 🔇 no snackbars. Feedback is inline, and dialogs are reserved for confirming
  something destructive;
- ✅ one filled pill per row: the pipeline status, because it is the only *state*
  there. Project and category are labels and render outlined. The resting state
  draws no badge at all — `READY` on twenty-seven rows out of twenty-eight makes
  the one failing row compete with a wall of green saying everything is fine.

---

## 🧱 Architecture

Feature-first, no state-management or DI package — plain `ChangeNotifier` and
constructor injection.

```
lib/
├── app/                    ui_kit.dart · theme · shared console widgets
└── features/
    ├── recordings/         the queue, the controller, the capture pipeline
    ├── projects/           repositories, context readers, agent launchers
    ├── transcription/      TranscriptionService + chunking decorator
    ├── processing/         Processor registry · OCR · video extraction
    ├── enrichment/         the second AI stage: title, category, summary, tags
    ├── settings/           provider profiles, audio config, token encryption
    ├── logs/               ring buffer + file archive
    └── shortcuts/          global hotkeys, window presentation
```

Every feature is `domain/` (pure Dart, no platform channels) + `data/`
(implementations, IO) + `presentation/` (widgets, controllers).

```mermaid
flowchart TD
    UI["RecordingsPage shell<br/><i>owns the controllers</i>"] --> RC["RecordingsController"]
    RC -->|"1 · persist"| REPO[("recordings.json")]
    RC -->|"2 · enqueue"| Q["background queue<br/><i>one job at a time</i>"]
    Q --> REG{"ProcessorRegistry<br/>by CaptureType"}
    REG --> T["TranscriptionProcessor"]
    REG --> O["OcrProcessor"]
    REG --> V["VideoTranscriptionProcessor"]
    REG --> P["TextPassthrough"]
    T & O & V & P --> DONE["status: completed"]
    DONE --> CB["clipboard"]
    DONE --> EN["enrichment<br/><i>best effort, last</i>"]
    EN --> REPO
    EN --> NV["note vault<br/><i>markdown mirror</i>"]
    REPO -.->|"user presses R"| RT["inbox.md<br/><i>append-only route</i>"]

    style REPO fill:#1056C6,color:#fff
    style EN fill:#3a3a5c,color:#fff
    style NV fill:#3a3a5c,color:#fff
```

Everything external sits behind a swappable seam with a disabled default, which
is why the test suite is pure Dart: `TranscriptionService`, `EnrichmentService`,
`OcrService`, `VideoAudioExtractor`, `AudioSplitter`, `ClipboardSink`,
`MediaOpener`, `MediaPicker`, `DirectoryPicker`, `HotkeyRegistrar`,
`WindowPresenter`, `CaptureRouter`, `NoteVault`, `TokenCipher`, `LogSink`.

### Long audio has three ceilings

A single transcription request is bounded by the 25 MB upload cap (a 400), by the
`gpt-4o` family's 1500 s duration limit (also a 400) — and by that family's
**2000-token output limit, which answers HTTP 200 with a truncated transcript**.
The third is the dangerous one: a twenty-minute capture came back as nine minutes
of text, was written `completed`, went to the clipboard, and had its title
enriched from the part that survived.

| Platform | Answer |
| --- | --- |
| **Desktop** | `ChunkedTranscriptionService` splits with `ffmpeg` into 5-minute parts, transcribes sequentially, joins. A file that yields one part is passed through unwrapped. |
| **Mobile** | No `ffmpeg`, so the recording itself is capped — `~8 min` on the `gpt-4o` family, `25 MB ÷ bitrate` otherwise (52 min at 64 kbps). The countdown and its reason are on the capture screen, and reaching it calls the same `stopRecording` the SAVE button calls. **The capture is saved, never discarded.** |

---

## 🧪 Testing & contributing

```bash
flutter analyze                                  # flutter_lints + avoid_print
flutter test                                     # 51 test files, pure Dart + widget
flutter test test/index_durability_test.dart     # one file
flutter test --plain-name "legacy JSON defaults" # one test
```

**There is no server-side CI** — GitHub Actions is metered on this private repo,
so the workflow is parked at `.github/workflows/ci.yml.disabled`. A `pre-push`
hook runs `flutter analyze` + `flutter test` in its place. Enable it once per
clone:

```bash
git config core.hooksPath .githooks
```

`git push --no-verify` skips it when that is genuinely what you want.

<details>
<summary><b>Three traps in the widget suite, all paid for once already</b></summary>

- **Never `pumpAndSettle` a screen containing a `PulseDot`, a `ScanLine` or a
  focused `TextField`.** All three animate forever, so "no frames scheduled" is a
  state that screen never reaches and the call hangs until the timeout. Pump
  explicit frames instead. This is also why the inline editor does not autofocus
  its title field.
- **Work started inside the fake-async zone needs `tester.runAsync`.** A tap that
  starts a capture touches the real filesystem; see `settleIo()` in
  `test/widget/capture_test.dart`. One round lets roughly one awaited IO call
  land, so the loop count has to match the depth of the chain.
- **Never sleep a fixed span for something a real `Timer` drives — poll for it.**
  `test/recording_limit_test.dart` waited 900 ms for a 250 ms tick and failed
  whenever the machine was busy, passing in isolation every single time. `_until`
  in that file is the shape to copy.

And the rule above all of them: **look at the screen before calling UI work
done.** The light theme shipped `flutter analyze` clean, the whole suite green
and two purpose-built source-level guards — and half the app still painted the
previous palette after a swap, because `MaterialApp.builder` does not rebuild a
route it has already pushed. Every widget rendered *correctly* for the palette it
held, so there was no wrong pixel to assert against. One screenshot found it in a
second.

</details>

---

## 🗺 Roadmap

- [x] `inbox.md` hand-off into a project repository
- [x] Markdown [note vault](#-note-vault--obsidian-and-friends) mirror for
      Obsidian and any synced notes folder
- [ ] **Export / import**, so a mobile reinstall stops being data loss
- [ ] OCR and video processing on mobile (ML Kit / `ffmpeg_kit`)
- [ ] `WorkManager` (Android) and `BGTaskScheduler` (iOS), so jobs survive
      backgrounding
- [ ] Local on-device models — whisper.cpp via FFI
- [ ] Notion and tracker destinations behind the same `CaptureRouter` seam

---

## 📚 More reading

| Document | What it covers |
| --- | --- |
| [`CLAUDE.md`](CLAUDE.md) | the full engineering rationale — every invariant, and why it is one |
| [`docs/agent-sessions.md`](docs/agent-sessions.md) | Codex / Claude Code / Antigravity session launchers, with a setup walkthrough |
| [`docs/superpowers/specs/`](docs/superpowers/specs/) | design specs, including the multimodal capture design |
| [`docs/plans/`](docs/plans/) | migration plans, including the identifier rebrand |

<div align="center">

**Capture stays local-first throughout:**
stop → verify the file → persist the metadata → queue → process.

</div>
