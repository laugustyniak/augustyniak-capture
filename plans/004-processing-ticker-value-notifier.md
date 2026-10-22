# 004 — Stop rebuilding the whole shell twice a second while a capture is processing

| Field | Value |
| --- | --- |
| Status | IN REVIEW — PR #359, branch `fix/354-processing-ticker` @ `25e307e`, issue #354, advisor-reviewed 2026-10-22, manual screen check pending |
| Written against | commit `294976b` (branch `main`), 2026-10-21 |
| Finding | performance, high confidence on mechanism (not profiled) |
| Effort | M (half a day; the controller change is 10 lines, the consumers and tests are the work) |
| Fix risk | low — the same pattern already exists in the same class for the recording timer, with a test |
| Depends on | land **after** 001 (same file; 001 is smaller and more urgent) |

## Why this matters

While any capture is being transcribed, the controller runs this:

```dart
// lib/features/recordings/presentation/recordings_controller.dart:3940-3949 (inside _processOne)
    _processingStartTime = DateTime.now();
    _processingTickerTimer?.cancel();
    _processingTickerTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (!_disposed && _processingId != null) {
          notifyListeners();
        }
      },
    );
```

Its only purpose is to refresh an elapsed-time label (`TRANSCRIBING · 01:23`). But `notifyListeners()` on the controller rebuilds the **whole shell**: `recordings_page.dart:603` merges the controller with five other notifiers into one `Listenable` and wraps the page in a single `AnimatedBuilder` (`:1176`). The `IndexedStack` builds all eight tabs. The Queue tab then re-filters, re-sorts and re-counts every capture on each build (`queue_tab.dart:432`, `:466-481`, and the search haystack at `:940-967`). A long transcription (minutes for long audio, local whisper on a laptop) means hundreds of full-app rebuilds, worse with a search query active, worse with a large library.

The same class already solved the same problem for the *recording* timer and documented why:

```dart
// recordings_controller.dart:1870-1876
    _elapsedTicker.value = Duration.zero;
    // Ticks into `elapsedTicker` rather than notifyListeners(): the elapsed time
    // is read in exactly one place (the capture FAB's mm:ss label), but a
    // controller-wide notification rebuilds the whole page — and the shell's
    // IndexedStack builds all four tabs, so Logs would re-scan its 500-event
    // buffer four times a second while nobody is looking at it.
    _timer = Timer.periodic(const Duration(milliseconds: 250), _onTick);
```

```dart
// recordings_controller.dart:354-356, 536-539
  final ValueNotifier<Duration> _elapsedTicker = ValueNotifier<Duration>(
    Duration.zero,
  );
  ...
  /// Ticks every 250 ms while recording. Listen to this instead of the
  /// controller when all you render is the running time — it repaints one label
  /// rather than the whole page.
  ValueListenable<Duration> get elapsedTicker => _elapsedTicker;
```

`test/elapsed_ticker_test.dart` pins that the recording tick does not notify the controller. This plan applies the identical pattern to the processing tick.

## Current state — the consumers (verify before editing)

Where the elapsed value is read today (all via `controller.processingElapsedFor(id)`, which computes `DateTime.now() - _processingStartTime` for the in-flight id, `recordings_controller.dart:3544-3549`):

| File:line | Passes it to |
| --- | --- |
| `lib/features/recordings/presentation/queue_tab.dart:1010` | `RecordingCard(processingElapsed: ...)` |
| `lib/features/projects/presentation/project_captures_sheet.dart:283-285` | `RecordingCard(processingElapsed: ...)` |
| `lib/features/recordings/presentation/capture_focus_view.dart:186` | a header widget's `elapsed:` |
| `lib/features/recordings/presentation/capture_focus_view.dart:1230` | `ProcessingStrip(elapsed: ...)` |

Consumers' parameters:

```dart
// lib/features/recordings/presentation/recording_card.dart:54, 194, 222-230
    this.processingElapsed,
  ...
  final Duration? processingElapsed;
  ...
    final String? transcribingLabel = isTranscribing
        ? (processingElapsed != null
            ? '$baseTranscribing · ${formatDuration(processingElapsed!)}'
            : baseTranscribing)
        : null;
```

```dart
// lib/features/recordings/presentation/card_parts.dart:261-267
class ProcessingStrip extends StatelessWidget {
  ProcessingStrip({
    super.key,
    required this.enriching,
    this.type = CaptureType.audioRecording,
    this.elapsed,
  });
```

Tests that pass `processingElapsed:` or build a `ProcessingStrip`: `test/widget/cancel_processing_ui_test.dart`, `test/widget/recording_row_test.dart`, `test/cancel_processing_test.dart` (grep to confirm).

Lifecycle sites for the timer: `:3573-3575` (cancel path), `:4161-4163` (finally of `_processOne`), `:5035-5036` (dispose).

## Target state

- Controller exposes `ValueListenable<Duration> get processingTicker` (a `ValueNotifier<Duration>`), set to `Duration.zero` when a job starts and updated every 500 ms with the elapsed time of the in-flight job. The periodic timer **no longer calls `notifyListeners()`**.
- `processingElapsedFor(id)` stays as a non-reactive read (used to decide *whether* to show a label).
- `RecordingCard` and `ProcessingStrip` take `ValueListenable<Duration>? processingTicker` **instead of** `Duration? processingElapsed` / `Duration? elapsed`, and render the time inside a `ValueListenableBuilder<Duration>` so only the label repaints. Call sites pass `controller.processingTicker` when `controller.processingElapsedFor(recording.id) != null`, else `null`.
- A pure-Dart test proves: processing ticks move `processingTicker` and do **not** notify the controller. Widget tests still pass.

Alternative considered and rejected: keeping `Duration?` params and wrapping the four call sites in `ValueListenableBuilder`. It would rebuild whole cards instead of one label and leave the API lying about what it needs.

## Conventions to follow

- Mirror `elapsedTicker` exactly: field name `_processingTicker`, getter doc in the same voice, disposed in `dispose()` right after `_elapsedTicker.dispose()`.
- **Widgets that paint a palette colour must not have `const` constructors** (`CLAUDE.md`, `test/theme_test.dart` scans for it). `ProcessingStrip` and `RecordingCard` already have non-const constructors; keep them so.
- Tests: pure Dart for the controller (copy `test/elapsed_ticker_test.dart`'s fakes). **Never sleep a fixed span for a `Timer`-driven thing — poll for it** (`CLAUDE.md`). `elapsed_ticker_test.dart:77` does sleep 800 ms; do not copy that part. Poll like `recording_limit_test.dart` does (grep `_until(` or `Future.doWhile` there).
- Widget tests: read `docs/architecture/testing-widgets.md` before touching `test/widget/`. Pump with explicit durations; `pumpAndSettle` hangs on the `PulseDot` animation.
- English strings; no `dart format` on existing files; Conventional Commits with `Refs #<N>`; no AI attribution.

## Scope boundaries

In scope:
- `recordings_controller.dart`: the field, getter, the timer callback at `:3942-3949`, reset at job start, the three cancel/finally/dispose sites (clear the value to `Duration.zero` where the timer is cancelled — optional but tidy), and `dispose()`.
- `recording_card.dart`, `card_parts.dart` (`ProcessingStrip`), the four call sites, the header widget at `capture_focus_view.dart:186` (follow `elapsed:` into its class in the same file).
- Tests listed above + one new `test/processing_ticker_test.dart`.

Out of scope — do not touch:
- `_elapsedTicker` / `_levelTicker` (recording-time tickers, already correct).
- `Listenable.merge` in `recordings_page.dart`, the queue's filter/sort memoization (separate perf finding, not planned).
- Any other `notifyListeners()` in `_processOne` — the status transitions (`transcribing`, `completed`, `failed`) **must** keep notifying; only the periodic tick changes.
- `LogSink` notifications.

## Steps

### Step 0 — Drift check

```bash
git rev-parse --short HEAD
grep -n "_processingTickerTimer = Timer.periodic" lib/features/recordings/presentation/recordings_controller.dart   # 1 hit
grep -n "processingTicker" lib -r      # expected: 0 hits
grep -rn "processingElapsed" lib | wc -l   # expected: ~8
```

If `processingTicker` already exists, STOP.

### Step 1 — Issue, worktree, baseline

```bash
gh issue create --title "Processing elapsed-time tick rebuilds the whole shell twice a second" \
  --body "The 500 ms timer in _processOne calls notifyListeners(); the recording timer already uses a ValueNotifier for the same reason. Plan: plans/004-processing-ticker-value-notifier.md"
git fetch origin
git worktree add .worktrees/perf-<N>-processing-ticker -b perf/<N>-processing-ticker origin/main
cd .worktrees/perf-<N>-processing-ticker && flutter pub get
flutter analyze && flutter test
```

(The branch type list in the repo's conventions is `feat fix chore docs refactor test`; use `fix/` if `perf/` is refused by a hook.)

### Step 2 — Failing controller test

Create `test/processing_ticker_test.dart`. Copy the fakes from `test/elapsed_ticker_test.dart` and the `_GatedTranscriptionService` from `test/upload_controller_test.dart:55-64` (a service whose `transcribe` hangs until a `Completer` completes). Test:

```dart
  test('the processing tick drives processingTicker, not the whole controller', () async {
    final _GatedTranscriptionService gate = _GatedTranscriptionService();
    final RecordingsController controller = RecordingsController(
      repository: _FakeRepository(appDir),
      transcriptionService: gate,
      recorder: _FakeRecorder(),
      player: _FakePlayer(),
    );
    await controller.initialize();
    await controller.addTextNote('hello');   // goes through the processor; see note below
    // Wait until the job is in flight.
    await _until(() => controller.processingElapsedFor(controller.recordings.single.id) != null);

    int controllerNotifications = 0;
    int tickerNotifications = 0;
    controller.addListener(() => controllerNotifications++);
    controller.processingTicker.addListener(() => tickerNotifications++);

    // Poll for ≥ 2 ticker ticks (500 ms period) rather than sleeping a fixed span.
    await _until(() => tickerNotifications >= 2, timeout: const Duration(seconds: 5));

    expect(controllerNotifications, 0, reason: 'the tick must not rebuild the page');
    expect(controller.processingTicker.value, greaterThan(Duration.zero));

    gate.gate.complete();
    await controller.waitForProcessing();
    controller.dispose();
  });
```

Note: `addTextNote` uses `TextPassthroughProcessor`, which may not call the transcription service at all. If the job completes instantly, use an **audio** capture instead: create an `.m4a` file in the fake repo dir and call `addAudioFile(id, file)` (see `test/add_audio_file_test.dart` for the `car(...)` helper and the controller builder). The gated service then holds the job in `transcribing`.

`_until` helper (copy from `test/recording_limit_test.dart` if it has one, else):

```dart
Future<void> _until(bool Function() ready, {Duration timeout = const Duration(seconds: 5)}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!ready()) {
    if (sw.elapsed > timeout) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
```

Run it: expected **compile failure** (`processingTicker` does not exist). That is the red state for this step.

### Step 3 — Controller

1. Field, next to `_elapsedTicker` (`:354`):
   ```dart
   final ValueNotifier<Duration> _processingTicker = ValueNotifier<Duration>(Duration.zero);
   ```
2. Getter, next to `elapsedTicker` (`:539`), with a doc comment in the same voice: ticks every 500 ms while a job is in flight; listen to this, not the controller, when all you render is the running time.
3. In `_processOne` (`:3940-3949`): set `_processingTicker.value = Duration.zero;` right after `_processingStartTime = DateTime.now();`, and change the callback body to
   ```dart
        if (!_disposed && _processingId != null && _processingStartTime != null) {
          _processingTicker.value = DateTime.now().difference(_processingStartTime!);
        }
   ```
   Update the surrounding comment: the periodic tick repaints one label, not the page (the status transitions above and below still notify).
4. `dispose()` (`:5038`): add `_processingTicker.dispose();` after `_elapsedTicker.dispose();`.
5. Optional tidy at the two cancel sites (`:3573`, `:4161`): `_processingTicker.value = Duration.zero;` — harmless; skip if you want the smallest diff.

Run `flutter test test/processing_ticker_test.dart`: expected **pass**. Prove non-vacuity: temporarily put `notifyListeners();` back into the callback, run, watch `controllerNotifications == 0` fail, revert.

### Step 4 — Consumers

1. `ProcessingStrip` (`card_parts.dart:261`): replace `this.elapsed` / `final Duration? elapsed;` with `this.processingTicker` / `final ValueListenable<Duration>? processingTicker;`. Where the label is built from `elapsed`, wrap that `Text` in
   ```dart
   ValueListenableBuilder<Duration>(
     valueListenable: processingTicker!,
     builder: (BuildContext _, Duration elapsed, Widget? __) => Text(...same as before...),
   )
   ```
   when `processingTicker != null`, else the label without time (same as the current `null` branch). Import `package:flutter/foundation.dart` for `ValueListenable` if not already imported via material.
2. `RecordingCard` (`recording_card.dart:54,194,222-230`): same replacement, `processingElapsed` → `processingTicker`. The `transcribingLabel` string is computed in `build` today; move the `· mm:ss` suffix into a `ValueListenableBuilder` around the status-label widget, keeping the `baseTranscribing` text outside. Read how `transcribingLabel` is consumed further down before restructuring; keep the change local to that label.
3. Call sites: `queue_tab.dart:1010`, `project_captures_sheet.dart:283-285`, `capture_focus_view.dart:186` and `:1230` — pass
   ```dart
   processingTicker: controller.processingElapsedFor(recording.id) != null ? controller.processingTicker : null,
   ```
   (for `:186` follow the `elapsed:` parameter into its widget class in the same file and convert it the same way as `ProcessingStrip`).
4. Fix the three tests that pass `processingElapsed:` / `elapsed:`: pass `ValueNotifier<Duration>(const Duration(seconds: 83))` and assert the rendered `01:23` as before.

```bash
flutter analyze                # No issues found! — the analyzer finds every missed call site
grep -rn "processingElapsed:" lib test    # 0 hits
```

### Step 5 — Gates, look at the screen

```bash
flutter test
```

Then **run the app and look** (`CLAUDE.md`: a green gate only describes what it was asked). On this Linux host: `flutter run -d linux`, record a short capture with a provider configured (or import an audio file), and watch the `TRANSCRIBING · mm:ss` label advance on the card and in the detail panel while the job runs. If no provider is configured the job fails immediately and you will not see a label — that is expected; configure the local whisper profile or a remote one first. Note in the PR that you watched it tick.

### Step 6 — Commit

```
perf(recordings): tick the processing clock into a ValueNotifier

The 500 ms timer behind "TRANSCRIBING · mm:ss" called notifyListeners(),
rebuilding the whole shell and re-filtering the queue twice a second for
the length of every job. It now ticks processingTicker, and the card and
the detail strip repaint one label through ValueListenableBuilder — the
same shape elapsedTicker already uses for the recording clock.

Refs #<N>
```

## Done criteria

```bash
grep -c "notifyListeners" lib/features/recordings/presentation/recordings_controller.dart   # exactly one fewer than on origin/main (compare with: git show origin/main:lib/features/recordings/presentation/recordings_controller.dart | grep -c notifyListeners)
grep -n "ValueListenable<Duration> get processingTicker" lib/features/recordings/presentation/recordings_controller.dart   # 1
grep -rn "processingElapsed:" lib test     # 0
flutter analyze    # No issues found!
flutter test       # All tests passed!
flutter test test/processing_ticker_test.dart test/theme_test.dart   # pass (theme_test guards const constructors)
```

## Maintenance note

Any future "live" value shown during processing (progress %, chunk n/m) belongs on `processingTicker` or a sibling `ValueNotifier`, never on `notifyListeners()`. Reviewers: a new `Timer.periodic` in the controller that calls `notifyListeners()` is a regression of this plan. The remaining whole-shell rebuild sources (every `LogSink.log`, every status transition) are known and acceptable; the queue's per-build filter/sort cost is a separate finding (see `plans/README.md`, unplanned).

## Escape hatches — STOP and report if

- `RecordingCard`'s `transcribingLabel` is used by more than the one status widget (e.g. for semantics labels or a tooltip) and the `ValueListenableBuilder` restructuring grows past ~30 lines — report the shape you found.
- A `test/widget/` test depended on the periodic rebuild to make a frame appear (symptom: a card that used to show `TRANSCRIBING` now shows nothing until a status change). Report the test name; do not add `notifyListeners()` back.
- `_processOne` is no longer the only place the periodic timer is created (`grep -n "_processingTickerTimer = " …` returns more than the one site at `:3942` plus null assignments).

## Execution record (2026-10-22)

- Executor: `coder` in `.worktrees/fix-354-processing-ticker` from `00dcc3e`; one commit `25e307e`, `Refs #354`, no attribution. PR #359.
- Drift: line numbers shifted ~30 (plan 001 landed). **Not in the plan:** `recording_row.dart` (`RecordingRow`, `_CollapsedBadge`) also took `processingElapsed`; converted the same way. Only one test file needed the parameter change (`test/widget/cancel_processing_ui_test.dart`, two sites), not three.
- Red evidence: new test failed to compile (`getter 'processingTicker' isn't defined`); sabotage with `notifyListeners()` restored failed `Expected: <0> Actual: <2>`, reverted. `notifyListeners` count in the controller 82 → 81.
- Advisor review: controller mirrors `elapsedTicker`; every consumer hunk is the `ValueListenableBuilder` wrap; the card's switcher key stays on the base label (incidental improvement: no cross-fade per tick). Gates re-run: analyze clean, 2316 passed / 4 skipped, `processing_ticker_test` + `theme_test` 20 pass, `grep processingElapsed:` 0.
- **Step 5 skipped** (run it and look): the desktop app on this host runs against the real library and a launch triggers sync and backfills, so the advisor did not start it. Maintainer to watch `TRANSCRIBING · mm:ss` advance on the next local run.
