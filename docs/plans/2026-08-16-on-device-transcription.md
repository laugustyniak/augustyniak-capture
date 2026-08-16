# Plan: transcribe on the device, with no network at all

Status: **proposed** · Owner: laugustyniak · Scope: a capture can be transcribed
by a model on this machine, chosen and managed from the Models tab, with the
remote providers untouched beside it.

Implements #4.

## Motivation

Every transcription this app has ever done left the machine. That is a real
cost and it is three separate ones:

- **Privacy.** A dictated note is the most personal thing this app holds, and
  the whole design otherwise refuses to send data anywhere it need not go —
  `inbox.md` beat a tracker API for exactly this reason, and there is
  deliberately no GitHub token in the app at all.
- **Availability.** Offline-first is the premise, and today it holds only until
  the queue reaches `pendingTranscription`. A capture on a train is durable,
  verified and unreadable.
- **Money.** The Costs feature exists because the per-minute price is real
  enough to want counted.

None of those is an argument for *replacing* the remote providers. A hosted
`gpt-4o-transcribe` is better than anything that fits on a phone, and a user
who has paid for it should keep it. This adds a third answer, not a migration.

## What does not change

Stated first, because this touches the path the app exists for.

- **The seven capture steps are untouched.** `stopRecording()` and
  `addTextNote()` keep create → finish → verify → persist → queue → process.
  This work lives entirely behind `TranscriptionService`, which is reached from
  the drain loop, minutes after a capture is already on disk. The invariant #4
  names is preserved by construction rather than by care.
- **`TranscriptionService` keeps its signature.** One method, a file in, text
  out. A third implementation beside `DisabledTranscriptionService` and
  `HttpWhisperTranscriptionService` needs no new architecture, which is the
  same thing that made `CommandRouter` cheap behind `CaptureRouter`.
- **Remote profiles keep working exactly as they do**, including the chunking
  decorator, the usage accounting and the failure messages.
- **No model is downloaded without being asked for.** An install that never
  opens the local section pays nothing — not a byte of disk, not a background
  fetch.

## Design

### The engine is a seam, and the FFI is one implementation of it

```
RecordingsController
        │  transcribe(File)
        ▼
  TranscriptionService  ◀── the existing seam, unchanged
        ├── HttpWhisperTranscriptionService   (today)
        ├── DisabledTranscriptionService      (today)
        └── LocalTranscriptionService         (new)
                    │  transcribe(pcm, model)
                    ▼
          LocalTranscriptionEngine  ◀── new seam
                    ├── WhisperFfiEngine       (native, per platform)
                    └── UnavailableLocalEngine (default)
```

The second seam is not ceremony. It is what lets every slice below the engine
be written and tested in pure Dart against a fake, on the same rule that keeps
`AudioSplitter`, `VideoPosterExtractor` and `CommandClient` testable — and it
is what stops a platform without a native build from being a broken app rather
than an app without a feature.

### A local model is a profile, not a second kind of thing

`ProfileKind` gains `localWhisper`. The Models tab already manages a list of
named things with an active selection per kind, and a local model has the same
questions asked of it: what is it called, which one is active, and what
language should it assume.

The cost is stated rather than hidden, because there are two:

- **`ProviderProfile.toService` degrades a blank or schemeless endpoint to the
  disabled service.** That guard is deliberate and documented — a half-filled
  profile must not fail at capture time. A local profile has no endpoint at
  all, so the guard has to key on `kind` before it looks at the URL. That is a
  change to a rule this repo went out of its way to write down, and it needs
  its own test rather than a passing mention.
- **An older build reading a `localWhisper` profile defaults it to
  `transcription`** — `ProfileKind.fromName` falls back rather than dropping,
  which is right for every existing row and wrong here. It would then try to
  POST to a blank endpoint and degrade to disabled: a local profile read by an
  old build is inert, not destructive. Acceptable, and worth writing down
  before somebody discovers it.

The alternative — a separate "local engine" setting beside the profile list —
was rejected for the reason this repo rejects most second copies: it would make
two sources of truth about which transcriber is active, and the bug that
follows is a user who switched one and is still being charged by the other.

### The model files live in Application Support, never in documents

Same rule as `app_database.sqlite`, and for the same reason: the recordings
directory is scanned by `recoverOrphans()` and everything in it that is not an
index or a poster is treated as a capture to re-adopt. A 1.5 GB model beside
the sources would be adopted as a capture on the next launch.

Downloads are streamed to `<id>.part` and renamed only after the SHA-256
matches the catalog — the atomic discipline every index in this app already
uses, with a stronger reason: a truncated model does not fail loudly, it
produces worse text. `crypto` is already a dependency (#33), so verification
costs nothing new.

### Audio has to be decoded first, and the seams for it already exist

whisper.cpp takes 16 kHz mono 32-bit float PCM. Captures are AAC in `.m4a` at
16 kHz mono, and uploads are whatever the user picked. Decoding is therefore
not optional, and it is **not new work**: `FfmpegAudioSplitter` already shells
out on desktop and `NativeMobileMediaProcessor` already drives MediaExtractor
and AVFoundation on mobile. This adds a `decodeToPcm` alongside the existing
split, on the same implementations.

That places a hard prerequisite on the local path: **a platform with no media
processor cannot transcribe locally**, and the profile must say so rather than
failing per capture. Same shape as the OCR rule that a missing enrichment
profile hides nothing and fails readably.

### The chunking decorator does not wrap the local engine

`ChunkedTranscriptionService` exists for two hosted ceilings — a 25 MB upload
cap and a 2000-token output limit that answers HTTP 200 with truncated text.
Neither applies to a model running here. What does apply is memory and time,
which are different limits with a different right answer, so wrapping the local
engine in a decorator built for the remote ones would be borrowing a solution
for a problem it does not have. Long-audio behaviour on the local path is its
own question and is deliberately deferred to a slice of its own.

### Nothing is billed, and the Costs feature is left alone

`UsageSink` records what a call consumed so the Costs tab can price it. A local
run consumes electricity, and pricing that would be a fiction. Local
transcription emits no usage, and the tab's totals stay a truthful answer to
"what have the providers charged me".

## Slices

Each ships alone and leaves the app working with no model anywhere.

### Slice 0 — the seam, with no inference and no download

- New: `transcription/domain/local_transcription_engine.dart` — the seam plus
  `UnavailableLocalEngine`, which names the platform rather than throwing a
  bare error.
- New: `transcription/data/local_transcription_service.dart` implementing
  `TranscriptionService` over the engine.
- Changed: `ProfileKind.localWhisper`, and `toService` keyed on kind.
- Tests: a local profile builds the local service; an old build reads it inert;
  a profile whose engine is unavailable fails readably and leaves the capture
  retryable.

Value alone: none to the user, and that is correct for a slice that adds no
capability. It is the one that makes the next three testable.

### Slice 1 — the model catalog and the store

- New: `transcription/domain/whisper_model.dart` (id, label, bytes, sha-256,
  URL) and `transcription/data/whisper_model_store.dart` (list installed,
  download with progress, verify, delete, resolve a path).
- Streamed to `.part`, verified, renamed. Cancellable.
- Tests: a truncated download never becomes an installed model; a hash mismatch
  is refused and the partial file removed; delete reclaims the bytes; the store
  answers "installed" from disk rather than from a remembered list, so a file
  removed by hand is not still offered.

Value alone: none visible yet — the next slice is what shows it.

### Slice 2 — the Models tab section

- Changed: a third section listing the catalog with size, install state, a
  progress bar while downloading, delete, and the active-model selection.
- Tests: widget tests over a fake store, in the house style.

Value alone: the whole feature is now visible and manageable, with the engine
still unavailable — which is the honest state of it until Slice 4.

### Slice 3 — decode to PCM

- Changed: `AudioSplitter` implementations gain `decodeToPcm`.
- Tests: desktop against a fake process runner; mobile against a fake channel.

Value alone: nothing user-visible, and it is the last thing that can be tested
without a native build.

### Slice 4 — the FFI engine and the native builds

- New: `transcription/data/whisper_ffi_engine.dart` and the per-platform build
  configuration (CMake for Linux/macOS/Windows, NDK for Android, an
  `.xcframework` for iOS).
- **This slice cannot be verified from a session without the toolchains**, and
  it must not be reported as done on the strength of code that compiles
  nowhere. It ends with the acceptance #4 actually asks for: a downloaded model
  transcribing a real capture with the network off, checked by looking.

## Not in scope

- **Replacing the remote providers**, or defaulting to local. A hosted model is
  better and a user who configured one keeps it.
- **Local enrichment or local OCR.** Both ride an OpenAI-compatible chat
  endpoint today and neither is what #4 asks for.
- **Speaker diarisation, timestamps, word-level alignment.** whisper.cpp can do
  some of it; `Recording.transcript` is one string and giving it structure is a
  separate change to a persisted type.
- **Long-audio strategy on the local path.** Named in the design above and
  deliberately deferred: the hosted ceilings do not apply, and the local ones
  have not been measured.
