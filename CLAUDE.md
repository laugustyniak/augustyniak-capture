# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Offline-first Flutter voice recorder ("Augustyniak Capture"). Core guarantee: audio is durably persisted to disk **before** transcription is ever attempted, and a transcription failure never deletes a recording. This ordering invariant is the reason the app exists — preserve it in any change.

The `pubspec.yaml` name, the runtime app title and the platform display names are all `augustyniak_capture` / `Augustyniak Capture`. The **application identifier is `ai.augustyniak.capture` on every platform** — Android `namespace`/`applicationId` (and therefore the Kotlin package `ai/augustyniak/capture/`), the iOS/macOS `PRODUCT_BUNDLE_IDENTIFIER`, and the Linux GTK `APPLICATION_ID` and icon name. On macOS the _binary_ is `augustyniak_capture` (`EXECUTABLE_NAME`) while the bundle keeps the display name, because a product name containing a space would otherwise reach every path that names the executable.

**The identifier was changed once, and that change was a migration rather than a rename** — see `docs/plans/2026-08-04-augustyniak-capture-rebrand.md`. A new identifier publishes a _different_ app: existing installs never upgrade, the signing key stops matching, and on Android and iOS the old container — with the recordings in it — is left behind under the old id. That cost was paid once, deliberately. **Treat the identifier as immutable again from here**: the next change costs every install a second time. `test/rebrand_test.dart` pins the current values so a half-finished rename fails instead of shipping. README is in English; **user-facing strings in code are English** (they were Polish until the design pass — do not reintroduce Polish), and so are identifiers and comments. Strings already stored on disk (a provider profile the user named) keep whatever they were saved as; only code literals were translated.

## Commands

Platform directories (`android/`, `ios/`) are partial. Generate the full native scaffolding with the local Flutter SDK before running — this keeps `lib/` intact:

```bash
flutter create --platforms=android,ios .
flutter pub get
```

(`macos/` is checked in like `linux/` and `windows/`, so it needs no regeneration
— see `docs/platform-setup.md` for what in it is hand-tuned and must not be clobbered.)

It leaves every existing file alone (`AndroidManifest.xml` with `RECORD_AUDIO` /
`INTERNET`, `ios/Runner/Info.plist`) but **adds `test/widget_test.dart`** — the
counter-app template, which imports a `MyApp` this project does not have. Delete
it, or `flutter analyze` and `flutter test` both fail on a file nobody wrote.

**Platform pins, signing and CI live in `docs/platform-setup.md`** — read it before the first build of any platform. It carries the two mobile-toolchain pins that are not optional (AGP 8.x, JDK 21), the hand-maintained `ios/Runner/Info.plist`, the background-recording declarations both phones need, Android release signing, the macOS sandbox/entitlement/signing decisions, the Linux system packages, and what the CI jobs actually gate.

The `pre-push` hook still runs `flutter analyze` + `flutter test` locally, and
is worth keeping — it is what stops a branch that does not compile from
reaching review at all. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

`git push --no-verify` skips it when that is genuinely what you want.

The same setting enables a `pre-commit` hook that refuses to commit captured
content — `.agent-tasks/` and `inbox.md`. The app writes the user's own
dictated notes into the repository it is developed in, **and this repository is
public**. Both paths are gitignored, but `git add -f`, a tool staging on your
behalf, or an ignore rule added after a file was already tracked all get past
that. One brief with notes about a prospective client reached a public commit
that way, and clearing it took a history rewrite — after which `refs/pull/*`
still held the blob. Before the commit exists is the only reliable place to stop
it. `git commit --no-verify` overrides, if a file there ever genuinely belongs
in the repo.

- Run: `flutter run`
- Run with transcription token: `flutter run --dart-define=TRANSCRIPTION_TOKEN=secret`
- Run pre-paired to your own cloud sync (all optional, and **never** committed — see `SyncDefaults` below):

  ```bash
  flutter run \
    --dart-define=TURSO_DB_URL=libsql://your-db.turso.io \
    --dart-define=TURSO_AUTH_TOKEN=… \
    --dart-define=R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com \
    --dart-define=R2_BUCKET=your-bucket \
    --dart-define=R2_ACCESS_KEY_ID=… \
    --dart-define=R2_SECRET_ACCESS_KEY=…
  ```

  Omit them and sync is simply unconfigured until the Config tab or a QR pairing fills it in — that is the normal state, not a degraded one. `TURSO_DB_URL` and `TURSO_AUTH_TOKEN` only count as a pair (`SyncDefaults.hasTurso`); either alone reaches nothing. Passing a secret on the command line puts it in your shell history, so prefer the Config tab or QR pairing for anything you intend to keep.
- All tests: `flutter test`
- Single test file: `flutter test test/recording_test.dart`
- Single test by name: `flutter test --plain-name "legacy JSON defaults to not reviewed"`
- Analyze/lint: `flutter analyze` (config in `analysis_options.yaml`: `flutter_lints` + `avoid_print`, `prefer_final_locals`)

CI is **live** (`.github/workflows/ci.yml`) and runs `flutter analyze` + `flutter test` on every push to `main` and every pull request, alongside Android, Windows, macOS and iOS builds. Run it locally before pushing anyway — the same two commands are what the `pre-push` hook uses, and they answer in seconds rather than minutes.


## Architecture

Feature-first layout under `lib/features/<feature>/{domain,data,presentation}`. Fifteen features: `recordings`, `projects`, `transcription`, `processing`, `enrichment`, `settings`, `costs`, `logs`, `shortcuts`, `timer`, `clipboard`, `gamification`, `momentum`, `backup`, `command`. No state-management or DI package — plain `ChangeNotifier` + constructor injection. The one thing that is not feature-scoped is `core/database/app_database.dart` — see Persistence.

**Deep reference lives under `docs/`, one file per area.** This file carries the invariants — the ordering rules, the durability rules and the seams. Open the matching reference before changing anything in its area; each is written to be read whole.

| File | Read it before touching |
| --- | --- |
| `docs/platform-setup.md` | `android/`, `ios/`, `macos/`, signing, entitlements, Linux packages, `.github/workflows/ci.yml`, or the first build on a new machine |
| `docs/architecture/ui.md` | `lib/app/`, any tab body, the queue's cards/editor/filters/keyboard layer, the palette or the theme, video posters |
| `docs/architecture/enrichment.md` | `features/enrichment/`, the enrichment prompt or context, `NoteVault`, the markdown mirror |
| `docs/architecture/agent-handoff.md` | `CaptureRouter`, `AgentHandoff`, `features/command/`, `renderCaptureBrief`, `RouteRecord`, a project's Command binding |
| `docs/architecture/backup.md` | `features/backup/`, the archive format, import/merge |
| `docs/architecture/transcription.md` | the local engine or model store, `ChunkedTranscriptionService`, `AudioSplitter`, `AudioDecoder`, `TranscriptionLimits` |
| `docs/architecture/settings-security.md` | `TokenCipher`, a master-key store, the endpoint transport guard, `core/sync/` |
| `docs/architecture/shortcuts.md` | `features/shortcuts/`, a registrar, `WindowPresenter` |
| `docs/architecture/timer-momentum.md` | `features/timer/`, `features/momentum/`, `features/gamification/`, `focus-sessions.jsonl`, `closures.jsonl` |
| `docs/architecture/clipboard.md` | `features/clipboard/`, `ClipboardWatcherService`, a `ClipboardRepository` |
| `docs/architecture/costs.md` | `features/costs/`, `UsageSink`, `PriceBook`, `usage_events`, the editor's COST panel or the Config tab's PRICING section |
| `docs/architecture/revisions.md` | `RecordingRevision`, `RevisionsRepository`, `revisions.jsonl`, the editor's HISTORY section |
| `docs/architecture/testing-widgets.md` | writing or debugging anything under `test/widget/`, or any `testWidgets` that hangs |
| `docs/architecture/capture-pipeline.md` | `recordings_controller.dart`, a capture entry point, `CaptureSegment`, `MediaImporter`, the removal paths |
| `docs/architecture/persistence.md` | `recordings_repository.dart`, `app_database.dart`, any `*_repository.dart`, the JSON indexes or the SQLite mirror |
| `docs/architecture/processing.md` | `features/processing/`, a `Processor`, `OcrService`, a video extractor, `provider_failure.dart` |
| `docs/architecture/testing.md` | writing or debugging any test, before trusting a green run |

`docs/plans/` and `docs/superpowers/specs/` hold the design documents those files cite.

## Conventions

Five patterns recur across every feature. They are stated once here and cited by the
reference docs rather than re-explained per feature.

- **The seam shape.** An interface in `domain/`, a default that degrades (`Disabled…`, `Unavailable…`, `Noop…`), the real implementation in `data/`. The default never throws at wiring time — it throws or no-ops at use, so an unconfigured install still captures. Anything swappable at runtime holds a **resolver**, not a snapshot, so a Models/Config change only affects work started afterwards and never redirects a job already in flight.
- **The best-effort sink contract**, named after `ClipboardSink` and applied identically by `LogSink`, `UsageSink`, `GamificationController`, `NoteVault` and `CaptureSession.end()`. Invoked **after** the item is persisted, swallows every error, and must never fail a capture. On a teardown path it is `unawaited` as well, because teardown must not gain a new way to block.
- **Atomic write.** Every JSON index is written `.tmp` then `rename`. It guarantees a write is not torn; it does **not** guarantee the contents are right, which is what the second durability rule below exists for.
- **Degrade on load, never throw.** `fromName(unknown)` returns the legacy default; an unreadable *row* is dropped one at a time rather than costing the file; a new field defaults when absent. Every `fromJson` must stay backward-compatible — see the "legacy JSON" tests.
- **Absent and empty are different facts.** A nullable field encodes three states, not two, wherever the difference is real: `Recording.segments` absent means "never gained a fragment" (and the key stays out of the JSON, so the row serialises byte for byte as before), `category` null means "enrichment never ran" while `capture` means "the model looked and could not place it". Collapsing them makes an unconfigured install indistinguishable from a failing one.

## The two durability invariants

Everything else in this repository is negotiable. These are not.

**1. Persist before process.** Audio is durably on disk before transcription is ever attempted, and a processing failure never deletes a recording. Every capture entry point follows the identical order — `RecordingsController.stopRecording()` is the reference implementation:

1. obtain the source bytes (`recorder.stop()` → file path; for a note, write the `.txt`)
2. verify the file exists **and** length > 0 (throw `FileSystemException` otherwise)
3. build `Recording` with status `saved`, prepend to in-memory list
4. `repository.saveAll()` — atomic persist
5. only then `_enqueueProcessing()` marks the item `pendingTranscription` and returns; a separate drain loop later runs it `transcribing` → `completed`/`failed`

Any new capture path must mirror those five steps exactly. **A capture may hold more than one source artifact**, and the segment is the unit of processing and of retry; the append path adds exactly one rule — the parent row is not touched until the new fragment's file is verified. Top-level `filePath`/`sizeBytes`/`contentHash` describe segment 0 exactly (the archive's deduplication contract), `transcript` accumulates and is never recomputed from the segments, and `findOrphans` claims files by **name**, never by id. Details, the removal paths and every controller invariant: `docs/architecture/capture-pipeline.md`.

**2. The index survives a bad read.** `saveAll` rewrites the *whole* `recordings.json`, so anything that makes the in-memory list wrong makes it permanently wrong on disk — which is how history was lost before, when `loadAll` answered `[]` to both "no index yet" and "could not read the index". `loadAll` therefore has **three** outcomes, not two; `_indexUnreadable` refuses every write for the rest of the session; a shrink nobody announced is backed up first; and orphaned sources are re-adopted. Details, the SQLite mirror in front of it and the `recordings.db-stale` marker: `docs/architecture/persistence.md`.

Neither rule is weakened by the two removal paths (`discardRecording`, `deleteRecording`): they govern a capture the app has *accepted*, and both of those are the user saying it should not have been.

## The features

Fifteen, each a line and a pointer. Read the pointer before changing anything in its area.

- **`recordings`** — the queue, the capture screen, the editor, the controller that owns the pipeline. `docs/architecture/capture-pipeline.md`, `docs/architecture/ui.md`.
- **`processing`** — `Processor` turns a segment's source into text. **The rule to enforce in review: a processor only ever reads the source — never writes, moves or deletes it.** `docs/architecture/processing.md`.
- **`transcription`** — `TranscriptionService` and the on-device engine behind `ProfileKind.localWhisper`. Long audio has three ceilings and only one of them tells you. `docs/architecture/transcription.md`.
- **`enrichment`** — the optional second AI stage: processor output becomes `title`, `category`, `summary`, `tags`. Best-effort and last, after the item is already persisted `completed`; it respects field ownership and never touches `status`. `docs/architecture/enrichment.md`.
- **`settings`** — provider profiles, and tokens encrypted at rest under a master key in the OS keyring. Transport is **reported, not enforced**. `docs/architecture/settings-security.md`.
- **`backup`** — the only answer to a mobile reinstall, which deletes the container the recordings live in. A zip merged back in additively; import never overwrites a source. `docs/architecture/backup.md`.
- **`projects`** — a versioned project list plus the active id, and the three destinations that take a capture off the desk. `docs/architecture/agent-handoff.md`.
- **`command`** — files a brief with a Command host. `docs/architecture/agent-handoff.md`.
- **`costs`** — cost accounting rides a **write-only sink, never a return type**. `docs/architecture/costs.md`.
- **`clipboard`** — a polled system-clipboard history. **Not** part of the capture pipeline and must not become one: `TO CAPTURE` hands off through the same locked entry points as everything else. `docs/architecture/clipboard.md`.
- **`shortcuts`** — desktop-only system-wide hotkeys. `ShortcutsCoordinator` holds **no capture logic**: every action calls the same controller entry point the FAB calls. `docs/architecture/shortcuts.md`.
- **`timer`** / **`momentum`** — a Pomodoro countdown, and append-only logs of the sessions that reached zero and the captures that left the desk. Time is read from the clock, never accumulated. `docs/architecture/timer-momentum.md`.
- **`gamification`** — entirely cosmetic by construction: a nullable seam, every call site `unawaited`, and nothing it does can reach `status`, a source file or the index. Treat any change that gives it a say in the pipeline as a bug. `docs/architecture/timer-momentum.md`.
- **`logs`** — a `ChangeNotifier` ring buffer, newest-first, capacity 500. Read-only view; nothing in the Logs tab mutates recordings.

Not feature-scoped: `core/database/app_database.dart` (see Persistence), `core/http/provider_failure.dart`, `core/sync/`.

## UI

"Processing Console", in **two themes**, built in `lib/app/app.dart` from `consoleTheme(palette)`. Shared palette, type scale and widgets live in `lib/app/ui_kit.dart` — use these rather than re-declaring colors or re-writing a chip/tile/dialog in a tab. Every raw hex belongs in `ConsolePalette`, `app.dart` included.

**`Console`'s colours are getters over mutable global state, which costs one rule that is not optional: a widget that paints a palette colour must not have a `const` constructor.** Flutter skips rebuilding a child `identical` to the previous one, so a `const` widget keeps painting the old theme after a swap — a stale frame no widget test can see. `test/theme_test.dart` scans `lib/` for the residual case, and `prefer_const_constructors_in_immutables` is off in `analysis_options.yaml` for that reason and only that reason.

**Audio format**: AAC-LC `.m4a`, defaults 16 kHz mono 64 kbps. Sample rate, channels and bitrate are user-editable in the Config tab; the **encoder and container are deliberately fixed for mic capture**, so `extensionFor(audioRecording)` is always `m4a`. Uploads keep their own extension — that path does not re-encode.

The themes, the shell's forms and breakpoints, the navigation tabs, the queue's filters, cards, inline editor and keyboard layer are in `docs/architecture/ui.md`.

## Testing

**Look at the screen before calling UI work done. A green gate only describes what it was asked.** The light theme once shipped analyze-clean, 475 tests green and two purpose-built guards — and half the app still painted the previous theme after a swap. Nothing in the suite could see it; one screenshot found it in a second.

The order that worked, and the order to repeat: **run it and look**, then **understand the mechanism**, then **write the regression test and prove it is not vacuous** by breaking the fix and watching the new test fail. A test written after the fix that has never been seen red is an assumption, not a check.

**Never sleep a fixed span for something a real `Timer` drives — poll for it.** A wait encodes an assumption about how busy the machine is, and this repo has already been bitten by it twice.

Tests are pure-Dart by default — no bindings or mocks. Fakes are hand-written, extending the real class and overriding only its IO. When adding a field to any persisted type, extend its round-trip test and confirm the legacy-defaults path still holds.

The full trap list, the fake conventions and the suites that need a binding are in `docs/architecture/testing.md`; the widget-specific traps are in `docs/architecture/testing-widgets.md` — read that one before writing or debugging any `testWidgets`.
