# Testing

How this suite is written and the assumptions it has already been bitten by. `CLAUDE.md`
carries the headline rule — look at the running thing before calling UI work done — and
this is the detail behind it.

## Look at the screen

**Look at the screen before calling UI work done. A green gate only describes what it was asked.** The light theme shipped `flutter analyze` clean, 475 tests green and _two purpose-built source-level guards_ — and half the app still painted the previous theme after a swap, because `MaterialApp.builder` does not rebuild the route it has already pushed. Nothing in the suite could see it: every widget rendered _correctly_ for the palette it held, so there was no wrong pixel to assert against and no exception to catch. One screenshot found it in a second. The guards were not useless, they were aimed one level too low — they caught a single widget going stale, while the failure was a whole subtree that never rebuilt at all.

The order that worked, and the order to repeat:

1. **Run it and look.** `flutter build macos --release` then `open`, or `flutter run`. For a theme, a layout or anything else whose defect is _visual_, this is the only step that can find an unknown failure mode — a test can only assert something you already suspect.
2. **Understand the mechanism** before writing anything. "It looks wrong" is not yet a test; "the route is never rebuilt because `home:` only builds the first one" is.
3. **Then write the regression test**, and **prove it is not vacuous**: break the fix, watch the new test fail, restore it. A test written after the fix that has never been seen red is an assumption, not a check. (`test/theme_test.dart`'s scope group was verified exactly this way.)

Two corollaries this session paid for:

- **Do not `git checkout -- <file>` in a dirty tree to undo a temporary edit.** It reverts to `HEAD`, taking every _other_ uncommitted change in that file with it — during the vacuity check above it deleted the fix under test. Copy the file to the scratchpad first and copy it back.
- **A hung or slow suite is not automatically a defect.** A run that normally takes ~15 s once took over 600 s because another test suite was running on the machine; the same tree passed in 11 s immediately afterwards. Re-run before debugging, and see the `_until` note below — this repo has already been bitten by wall-clock assumptions.

## Widget tests

**Widget tests have their own trap list — `docs/architecture/testing-widgets.md`, read it before writing or debugging a `testWidgets`.** The short version: never `pumpAndSettle` a screen holding a `PulseDot`, a `ScanLine`, a running `CountdownDial` or a focused `TextField` — all four animate forever, so "no frames scheduled" is a state the screen never reaches and the call hangs until the timeout. Pump explicit frames instead. Work started inside the fake-async zone needs `tester.runAsync`, and a file `Stream` never flows there at all.

## A bound that is not a schedule

`waitForProcessing()` is the seam every controller test uses to mean *the background
work has settled*, and it was the cause of the `vault_mirror_test` flake (#77). It polled
the right condition — `_isDraining`, the queue depth, the posters and hashes in flight —
but bounded the poll by **iteration count**, and on expiry simply returned. So on a
machine busy enough that the real IO had not landed within 10,000 microtask turns, the
wait reported success with the work still outstanding, and every assertion after it read
pre-completion state. The note was not missing; it had not been written yet, and nothing
said so.

The rule this generalises: **a backstop must be impossible to mistake for the thing it
guards.** Waiting on the condition alone is right; a bound is still wanted so a genuine
hang ends, but it has to *throw and name what was outstanding* rather than fall through
into the success path. `waitForProcessing` now takes a `timeout` and reports
`draining=…, queued=…, posters=…, hashes=…` when it expires.

## Never sleep for a timer

**Never sleep a fixed span for something a real `Timer` drives — poll for it.** The recording cap (`_onTick`, every 250 ms) is the only wall-clock behaviour in the suite, and `test/recording_limit_test.dart` waited `900 ms` for it. That encodes an assumption about how busy the machine is: running the suite while a platform build was compiling in another terminal made the wait expire _before_ the tick that crosses the cap, and the test failed for being early rather than for being wrong. It passed in isolation every single time, which is the signature. `_until(condition)` in that file is the shape to copy — an idle run stays as fast as the sleep was.

## Shape of the suite

Tests are pure-Dart (JSON round-trip, backward compat, controller behaviour) — no Flutter bindings or mocks needed. The exceptions are `test/copy_button_test.dart` and the suites under `test/widget/`: what `CopyButton` puts on the clipboard travels over a platform channel, so it cannot be asserted without a binding. Keep it the exception rather than the precedent. Fakes are hand-written: `_FakeSettingsRepository` extends the real repository and overrides only the IO methods; `_FakeArchive` implements `LogArchive`; `_FakeRegistrar`/`_CountingPresenter` (`test/shortcuts_coordinator_test.dart`) stand in for the OS hotkey table and the window, which is what keeps the shortcut layer testable without a binding — note it fires actions via `ShortcutsCoordinator.handle`, and asserts `toggleRecording` reached the controller through the _denied microphone_ error rather than a real capture device. When adding fields to any persisted type, extend its round-trip test and confirm the legacy-defaults path still holds.

Two more suites carry a binding without living under `test/widget/`, and both name themselves badly enough to be worth stating: `test/clipboard_history_test.dart` covers the **clipboard feature** (repository, watcher and the history sheet), while `test/clipboard_test.dart` covers the recordings controller's `ClipboardSink` — the hand-off of processor output to the system clipboard, which has nothing to do with the clipboard history. Their fakes follow the house pattern: `_MemoryClipboardRepository` implements `ClipboardRepository` so no test reaches SQLite, `_FakeClipboardGateway` stands in for the pasteboard, and `FakeGamificationRepository` extends the real one and overrides only `load`/`save`. Anything that does touch `AppDatabase` has to call `AppDatabase.resetForTesting()`, or the singleton leaks one test's database into the next.
