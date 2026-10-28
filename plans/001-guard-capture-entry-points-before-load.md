# 001 — Refuse `startRecording`, `addUpload`, `addImportedFile` and cloud sync before the index has loaded

| Field | Value |
| --- | --- |
| Status | IMPLEMENTED — branch `fix/349-pre-load-guard` @ `ecd0b5b` in `.worktrees/fix-349-pre-load-guard`, issue #349, advisor-reviewed 2026-10-22, PR #350 merged as `d55330c` 2026-10-22 |
| Written against | commit `294976b` (branch `main`), 2026-10-21 |
| Finding | correctness, high leverage (S effort, catastrophic impact, low fix risk) |
| Effort | S (2–4 h including tests) |
| Fix risk | low — adds early returns that mirror two guards already in the same file |
| Depends on | nothing |
| Blocks | nothing (004 touches the same file; land this first to keep diffs small) |

## Why this matters

`CLAUDE.md` names two durability invariants. The second one is: **the index survives a bad read**. `recordings.json` and the SQLite mirror are rewritten *whole* on every save (`RecordingsRepository.saveAll` does `DELETE FROM recordings` then inserts the in-memory list, then rewrites the JSON). So whatever the in-memory list contains at save time becomes the only history on disk.

Before `RecordingsController.initialize()` finishes, the in-memory list is `[]`. Two capture entry points already know this and refuse to write until the load completes:

```dart
// lib/features/recordings/presentation/recordings_controller.dart:2401-2412 (addTextNote)
    // Before the first load the list is empty, not right: persisting now would
    // overwrite recordings.json with just this note.
    if (!_initialized) {
      // Callers that ignore the result still show `error`, so say why nothing
      // was saved. An unreadable-index message already explains more; keep it.
      if (!_indexUnreadable) {
        _error = 'Captures are still loading — try again.';
        notifyListeners();
      }
      return false;
    }
```

```dart
// lib/features/recordings/presentation/recordings_controller.dart:2512-2518 (addAudioFile)
    if (!_initialized) {
      if (!_indexUnreadable) {
        _error = 'Captures are still loading — try again.';
        notifyListeners();
      }
      return false;
    }
```

Three other entry points have **no such guard**. Each of them prepends a row to `_recordings` and calls `_persistAll()`:

- `startRecording` / `stopRecording` (`recordings_controller.dart:1760`, `:1936`) — the record FAB and the global hotkey (`shortcuts_coordinator.dart:219`).
- `addUpload` (`recordings_controller.dart:2569`) — the upload button (`recordings_page.dart:1104`).
- `addImportedFile` (`recordings_controller.dart:2634`) — drag-and-drop and clipboard "TO CAPTURE" (`clipboard_history_sheet.dart:306`).

If any of them completes during the window between app start and the end of `initialize()` (a slow disk, a large library, a hotkey pressed as the window appears), `saveAll` writes a one-row index over the user's whole history. The shrink backup does not fire, because the repository's known row count is only set by a successful `loadAll`.

`_performCloudSync` (`recordings_controller.dart:1303-1325`) has the same shape: its gate checks `!_indexUnreadable` but not `_initialized`, so a SYNC NOW pressed before the load pushes an empty snapshot. The engine's empty-outbox fuse refuses an empty `recordings` table, but it is a backstop; the gate is the right place.

Nothing today is known to have lost data this way. The fix is cheap and the failure is unrecoverable, which is why this is plan 001.

## Current state — exact excerpts (verify these before editing; see Drift check)

```dart
// recordings_controller.dart:1760-1762
  Future<void> startRecording({String? appendTo}) async {
    if (_isRecording || _isBusy) return;
    _error = null;
```

```dart
// recordings_controller.dart:2569-2573
  Future<void> addUpload(CaptureType type, {String? appendTo}) async {
    if (_isRecording || _isBusy) return;
    _isBusy = true;
    _error = null;
    notifyListeners();
```

```dart
// recordings_controller.dart:2634-2643
  Future<void> addImportedFile(
    File file,
    CaptureType type, {
    String? appendTo,
    String? mimeType,
  }) async {
    if (_isRecording || _isBusy) return;
    _isBusy = true;
    _error = null;
    notifyListeners();
```

```dart
// recordings_controller.dart:1315-1324
    final String? ownerId = _authGateway?.currentIdentity?.id;
    final bool hasSupabase =
        !_indexUnreadable &&
        ownerId != null &&
        _syncTransportResolver != null &&
        _projectsRepository != null &&
        _clipboardRepository != null &&
        _syncDeviceId != null &&
        _applySyncedProjects != null &&
        _applySyncedProjectDelete != null;
```

Relevant state fields (same file):

```dart
// recordings_controller.dart:502, 507, 1099
  bool _initialized = false;
  bool get isInitialized => _initialized;
  ...
    _initialized = true;   // set at the end of the success path of initialize()
```

## Target state

- `startRecording`, `addUpload` and `addImportedFile` each begin with the **same guard block** `addTextNote` uses: when `!_initialized`, set `_error = 'Captures are still loading — try again.'` (only if `!_indexUnreadable`, because the unreadable-index error is already on screen and says more), `notifyListeners()`, and return. They return `void`, so just `return;`.
- The `hasSupabase` gate in `_performCloudSync` also requires `_initialized`.
- `stopRecording` needs no change: it cannot run unless `startRecording` succeeded (`if (!_isRecording || _isBusy) return;`).
- New tests prove each guard refuses with no `saveAll` call and the right error, and that `stopRecording`'s existing persist-before-process test for uploads also pins the status at first save (see Step 6 — a gap the audit found in the same test file).

## Conventions to follow

- **Match the existing guard verbatim** (message text included). Do not introduce a helper method unless you also replace the two existing inline guards with it — a half-shared helper is worse than three copies. Either is acceptable; the smaller diff is the three copies.
- English user-facing strings only. No Polish.
- Tests are pure Dart: hand-written fakes extending the real class, overriding only IO. Follow `test/add_audio_file_test.dart` and `test/add_text_note_id_test.dart`, which already test the pre-load refusal for the two guarded entry points. Exemplar:

```dart
// test/add_audio_file_test.dart:124-135
  test(
    'before initialize it returns false, writes nothing, sets error',
    () async {
      final File source = car('$id.m4a', 'AAC-BYTES');
      final _FakeRepository repo = _FakeRepository(appDir);
      final RecordingsController controller = buildController(repo);

      expect(await controller.addAudioFile(id, source), isFalse);
      expect(controller.error, contains('still loading'));
      expect(repo.saveCalls, 0);
      controller.dispose();
    },
  );
```

- The upload test file already has the fakes you need (`_FakeRepository`, `_FakePicker`, `_FakeRecorder`, `_FakePlayer`, `buildController`) at `test/upload_controller_test.dart:14-100`. Note that its `_FakeRepository.saveAll` records `sourcePresentAtSave`; you will add a `saveCalls` counter and a `statusAtSave` list to it (Step 6).
- Do **not** run `dart format` on existing files. Format only lines you write, by hand, to match neighbours.
- Commit style: Conventional Commits, imperative, lowercase, ≤72 chars, footer `Refs #<issue>`. No AI attribution lines of any kind.

## Scope boundaries

In scope:
- `lib/features/recordings/presentation/recordings_controller.dart` — the four spots above only.
- `test/upload_controller_test.dart` — new tests, fake counters.
- `test/elapsed_ticker_test.dart` or a new `test/pre_load_capture_guard_test.dart` for `startRecording` (your choice; a new file is cleaner).
- A new test for `_performCloudSync` **only if** `test/sync/` already has a controller-level harness you can reuse (look at `test/sync/null_device_id_gate_test.dart`, which tests the same gate for a missing device id). If reusing it takes more than ~30 lines, skip the sync test and say so in the PR.

Out of scope — do not touch:
- `stopRecording`, `addTextNote`, `addAudioFile` (already correct).
- `RecordingsRepository`, `saveAll`, the shrink backup, `_persistAll`.
- Any UI file. The UI already renders `controller.error` as a banner.
- The 500 ms processing ticker a few hundred lines below (that is plan 004).

## Steps

### Step 0 — Drift check

```bash
cd <repo>
git rev-parse --short HEAD          # note it; plan was written at 294976b
grep -n "if (!_initialized) {" lib/features/recordings/presentation/recordings_controller.dart
```

Expected: exactly **2** hits (around lines 2403 and 2512). If you see 5 or more, this plan was already executed — STOP and report. If the excerpts in "Current state" do not match (different line numbers are fine; different code is not), STOP and report.

### Step 1 — Worktree and branch

An issue number is mandatory in this repo's branch names. Create one:

```bash
gh issue create --title "Capture entry points can overwrite the index before it has loaded" \
  --body "startRecording, addUpload and addImportedFile persist before initialize() completes; addTextNote and addAudioFile already refuse. Plan: plans/001-guard-capture-entry-points-before-load.md"
```

If `gh` is not authenticated, STOP and ask the maintainer for an issue number. Then:

```bash
git fetch origin
git worktree add .worktrees/fix-<N>-pre-load-guard -b fix/<N>-pre-load-guard origin/main
cd .worktrees/fix-<N>-pre-load-guard
flutter pub get
```

Verify baseline before any edit:

```bash
flutter analyze    # expected: "No issues found!"
flutter test       # expected: "All tests passed!" (2300 passed, 4 skipped at 294976b; ~35 s)
```

### Step 2 — Write the failing tests first

In `test/upload_controller_test.dart`:

1. Extend `_FakeRepository` with:
   ```dart
   int saveCalls = 0;
   final List<RecordingStatus> statusAtSave = <RecordingStatus>[];
   ```
   and in `saveAll`, before the existing body: `saveCalls++;` and, when `recordings.isNotEmpty`, `statusAtSave.add(recordings.first.status);`.
2. Add two tests. Note that none of the existing tests in that file calls `controller.initialize()` — the fake's `loadAll` returns `[]`, and the controller still persists because nobody set `_initialized`. That is the bug, visible in the test suite: those tests pass today **only because the guard is missing**. After this change every existing test in the file that expects a save must call `await controller.initialize();` first. Do that as part of this step (search the file for `buildController(` and add the call right after each construction that is expected to save).

   ```dart
   test('addUpload before initialize writes nothing and sets the loading error', () async {
     final File source = File(p.join(pickDir.path, 'original.mp3'))..writeAsStringSync('SOUND');
     final _FakeRepository repo = _FakeRepository(appDir);
     final RecordingsController controller = buildController(
       repo,
       picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
     );
     int notified = 0;
     controller.addListener(() => notified++);

     await controller.addUpload(CaptureType.audioUpload);

     expect(repo.saveCalls, 0);
     expect(controller.recordings, isEmpty);
     expect(controller.error, contains('still loading'));
     expect(notified, 1);
     controller.dispose();
   });

   test('addImportedFile before initialize writes nothing and sets the loading error', () async {
     final File source = File(p.join(pickDir.path, 'dropped.txt'))..writeAsStringSync('TEXT');
     final _FakeRepository repo = _FakeRepository(appDir);
     final RecordingsController controller = buildController(repo);

     await controller.addImportedFile(source, CaptureType.textNote);

     expect(repo.saveCalls, 0);
     expect(controller.recordings, isEmpty);
     expect(controller.error, contains('still loading'));
     controller.dispose();
   });
   ```
   If `CaptureType.textNote` is not the enum member for a text file, open `lib/features/recordings/domain/capture_type.dart` and use the member that `extensionFor` maps to `txt`.

3. For `startRecording`, create `test/pre_load_capture_guard_test.dart` modelled on `test/elapsed_ticker_test.dart` (copy its `_FakeRepository`, `_GrantingRecorder`, `_FakePlayer`), add a `saveCalls` counter to the fake, and assert:
   ```dart
   await controller.startRecording();
   expect(controller.isRecording, isFalse);
   expect(controller.error, contains('still loading'));
   expect(repo.saveCalls, 0);
   ```

Run only these files:

```bash
flutter test test/upload_controller_test.dart test/pre_load_capture_guard_test.dart
```

Expected: the three new tests **fail** (`isRecording` is true; `saveCalls` is 1; `error` is null). The existing tests you patched with `initialize()` still pass. If a new test passes before the fix, it is vacuous — fix the test, not the code.

### Step 3 — Add the guards

In `recordings_controller.dart`, insert the guard as the **first statement** of `startRecording`, `addUpload` and `addImportedFile`, before the `_isRecording || _isBusy` check:

```dart
    // Before the first load the list is empty, not right: persisting now would
    // overwrite recordings.json with just this capture (see addTextNote).
    if (!_initialized) {
      if (!_indexUnreadable) {
        _error = 'Captures are still loading — try again.';
        notifyListeners();
      }
      return;
    }
```

### Step 4 — Gate cloud sync

In `_performCloudSync`, change the first line of the `hasSupabase` expression from `!_indexUnreadable &&` to `_initialized && !_indexUnreadable &&`. Extend the comment above it by one sentence: a snapshot taken before `initialize()` is `[]` for the same reason an unreadable index is, and the fuse in the engine covers `recordings` only.

### Step 5 — Run the gates

```bash
flutter analyze                                  # expected: No issues found!
flutter test test/upload_controller_test.dart test/pre_load_capture_guard_test.dart   # expected: all pass
flutter test                                     # expected: All tests passed!
```

If any **other** test now fails with `still loading`, it constructed a controller and captured without `initialize()`. Add `await controller.initialize();` after construction in that test — that is the test relying on the bug, not a regression. List every such file in the PR description. If more than ~10 files need it, STOP and report before continuing: the maintainer may prefer a different fix shape.

### Step 6 — Close the test gap in the upload ordering test

`test/upload_controller_test.dart:261-283` ("index write follows the copy — the ordering invariant") asserts only `sourcePresentAtSave.first`. It cannot see whether the first save had status `saved` or already `pendingTranscription`. Add, after the existing expects:

```dart
    expect(repo.statusAtSave.first, RecordingStatus.saved);
```

mirroring `test/add_audio_file_test.dart:102`. Prove it is not vacuous: temporarily swap the order in `addUpload` so `_enqueueProcessing` runs before `_persistAll` (or set the status to `pendingTranscription` before the first save), run the file, watch this expect go red, then revert the sabotage.

### Step 7 — Commit

Two commits are fine; one is fine. Suggested:

```
fix(recordings): refuse capture before the index has loaded

startRecording, addUpload and addImportedFile persisted a one-row list
over the whole history when invoked before initialize() finished; the
cloud sync gate had the same gap. All three now refuse the way
addTextNote and addAudioFile already did.

Refs #<N>
```

```
test(recordings): pin the saved status at first write for uploads

Refs #<N>
```

## Done criteria (all must hold)

```bash
grep -c "if (!_initialized) {" lib/features/recordings/presentation/recordings_controller.dart   # prints 5
grep -n "_initialized && !_indexUnreadable" lib/features/recordings/presentation/recordings_controller.dart   # 1 hit, inside _performCloudSync
flutter analyze        # No issues found!
flutter test           # All tests passed!
flutter test --plain-name "before initialize"   # ≥ 5 tests run, all pass (2 existing + 3 new)
git diff origin/main --stat   # only recordings_controller.dart and files under test/
```

## Test plan summary

| Test | File | Pattern copied from |
| --- | --- | --- |
| addUpload refuses pre-load, no save, error, one notify | `test/upload_controller_test.dart` | `test/add_text_note_id_test.dart:178-189` |
| addImportedFile refuses pre-load | `test/upload_controller_test.dart` | same |
| startRecording refuses pre-load, `isRecording` stays false | `test/pre_load_capture_guard_test.dart` | `test/elapsed_ticker_test.dart` fakes |
| upload first save has status `saved` | `test/upload_controller_test.dart:261` | `test/add_audio_file_test.dart:102` |
| (optional) sync gate requires `_initialized` | `test/sync/` | `test/sync/null_device_id_gate_test.dart` |

## Maintenance note

Every future capture entry point must start with this guard — put that in the PR description and, if you touch `docs/architecture/capture-pipeline.md`, add one sentence under the entry-point rules: "step 0: refuse while `!_initialized`". Reviewers should grep for new `_recordings = <Recording>[` sites and check the guard is above them. Plan 004 edits the same file further down; rebase it on this.

## Escape hatches — STOP and report instead of improvising if

- The drift check finds the guards already present, or the entry points have been restructured so the excerpts no longer match.
- More than ~10 existing test files need `initialize()` added (Step 5).
- A widget test under `test/widget/` starts failing: those pump the real shell, and the shell may call an entry point during bootstrap in a way this plan did not anticipate. Report which test and which call.
- `stopRecording` turns out to be reachable without `startRecording` (grep `_isRecording = true` — expected exactly one assignment, inside `startRecording`).

## Execution record (2026-10-22)

- Executor: `coder` subagent in `.worktrees/fix-349-pre-load-guard`; two commits `6feecd7`, `ecd0b5b`, footer `Refs #349`, no attribution lines.
- Drift check matched. All three new tests seen red before the fix; Step 6 assertion seen red under sabotage (`Actual: RecordingStatus.pendingTranscription`) then green.
- **Escape hatch fired:** the plan estimated ≤10 test files would need `initialize()`; the real count was 14 files, 56 call sites (one widget file, `test/widget/capture_test.dart`, 7 sites). Maintainer chose the mechanical fix. Lesson for future plans: grep `buildController(\|RecordingsController(` across `test/` and count files lacking `initialize()` *before* estimating fallout.
- Advisor review: every `lib/` hunk traces to Steps 3–4; every mechanical test hunk is exactly `await <controller>.initialize();`; done criteria re-run independently — guards = 5, sync gate present, `flutter analyze` clean, `flutter test` 2303 passed / 4 skipped, `--plain-name "before initialize"` 5 passed, no merge conflicts with `origin/main` at `f361eb7`.
- Not done (optional in plan): controller-level test for the sync gate.
- Next: maintainer merges `origin/main` into the branch, pushes, opens the PR (`--no-ff` merge per repo rules), then `git worktree remove .worktrees/fix-349-pre-load-guard`.
