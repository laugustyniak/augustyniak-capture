import 'package:flutter/foundation.dart';

import '../../logs/domain/log_event.dart';
import '../../recordings/domain/capture_type.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/hotkey_binding.dart';
import '../domain/hotkey_registrar.dart';
import '../domain/shortcut_action.dart';
import '../domain/window_presenter.dart';

/// Turns a global hotkey press into exactly one capture action, and owns the
/// lifecycle of the OS registrations.
///
/// Deliberately thin on capture. It has no capture logic of its own: every
/// action calls the same `RecordingsController` entry point the FAB calls, so
/// the persist-before-process ordering stays defined in one place and a shortcut
/// can never become a second, divergent capture path.
class ShortcutsCoordinator {
  ShortcutsCoordinator({
    required RecordingsController recordings,
    required Future<void> Function() composeTextNote,
    Future<void> Function()? revealQueue,
    HotkeyRegistrar registrar = const NoopHotkeyRegistrar(),
    WindowPresenter windowPresenter = const NoopWindowPresenter(),
    LogSink logSink = const NoopLogSink(),
  }) : _recordings = recordings,
       _composeTextNote = composeTextNote,
       _revealQueue = revealQueue,
       _registrar = registrar,
       _windowPresenter = windowPresenter,
       _logSink = logSink;

  final RecordingsController _recordings;
  final Future<void> Function() _composeTextNote;

  /// Switches the shell to the Queue tab. Optional so the pure-Dart tests can
  /// build a coordinator without a navigation shell behind it.
  final Future<void> Function()? _revealQueue;
  final HotkeyRegistrar _registrar;
  final WindowPresenter _windowPresenter;
  final LogSink _logSink;

  Map<ShortcutAction, HotkeyBinding>? _applied;
  Set<ShortcutAction> _rejected = const <ShortcutAction>{};
  bool _composingNote = false;
  bool _suspended = false;
  bool _disposed = false;

  /// Every registrar call is chained onto this so two overlapping operations can
  /// never interleave. `SystemHotkeyRegistrar.apply` starts by unregistering
  /// everything, so a concurrent second apply could otherwise wipe the first
  /// one's registrations halfway through its loop and leave a mixed OS state.
  Future<void> _queue = Future<void>.value();

  /// Bindings the OS refused, surfaced in the Config tab so an unavailable
  /// combination is visible rather than mysteriously dead.
  Set<ShortcutAction> get rejected => _rejected;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final Future<T> next = _queue.then((_) => operation());
    // Swallow here only: the caller still sees the original future's error.
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// (Re)registers the whole set. Cheap to call on every settings notification:
  /// an unchanged map short-circuits, so unrelated changes (a provider swap, an
  /// audio parameter) never churn the OS hotkey table.
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
  ) => _serial(() => _apply(bindings));

  Future<Set<ShortcutAction>> _apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
  ) async {
    if (_disposed) return _rejected;
    if (_applied != null && mapEquals(_applied, bindings)) return _rejected;
    _applied = Map<ShortcutAction, HotkeyBinding>.from(bindings);
    // While the capture sheet is open nothing may be registered; `resume` picks
    // the new map up.
    if (_suspended) return _rejected;
    await _register();
    return _rejected;
  }

  /// Releases every registration until [resume].
  ///
  /// Required while the key-capture sheet is open: a system-scope hotkey is
  /// consumed by the OS *before* the focused window sees the event, so trying to
  /// rebind the combination that is currently bound would fire its action
  /// instead of being captured.
  Future<void> suspend() => _serial(() async {
    if (_disposed || _suspended) return;
    _suspended = true;
    try {
      await _registrar.unregisterAll();
    } catch (exception) {
      _logSink.log(
        'Failed to release shortcuts: $exception',
        level: LogLevel.error,
      );
    }
  });

  Future<void> resume() => _serial(() async {
    if (_disposed || !_suspended) return;
    _suspended = false;
    await _register();
  });

  Future<void> _register() async {
    final Map<ShortcutAction, HotkeyBinding>? bindings = _applied;
    if (bindings == null) return;
    try {
      _rejected = await _registrar.apply(bindings, handle);
      for (final ShortcutAction action in _rejected) {
        _logSink.log(
          'Shortcut taken by another app: ${action.label}.',
          level: LogLevel.warn,
        );
      }
    } catch (exception) {
      // Clearing `_applied` matters: leaving it set would make every later
      // identical apply short-circuit, wedging the feature off permanently
      // after one transient platform failure.
      _applied = null;
      _rejected = const <ShortcutAction>{};
      _logSink.log(
        'Shortcut registration failed: $exception',
        level: LogLevel.error,
      );
    }
  }

  /// Public so a test can fire an action without going through the OS.
  ///
  /// Swallows every error on the same rule as logging: a shortcut is a
  /// convenience layer and must never surface an exception into the capture
  /// pipeline, which does its own error handling and marks items `failed`.
  Future<void> handle(ShortcutAction action) async {
    // Synchronous kill switch. `dispose` cannot await the OS before the shell
    // disposes the controller, so a press landing in that window must stop here
    // rather than reach a disposed controller.
    if (_disposed) return;

    // Only the note sheet needs a re-entrancy guard: the controller's `_isBusy`
    // flag already serialises recording and uploads, but the compose sheet is
    // pure UI and a second press would stack a second sheet on top of it.
    //
    // Claimed here, before the first `await` — checking it after raising the
    // window would leave a gap wide enough for a second press to slip through.
    final bool isNote = action == ShortcutAction.newTextNote;
    if (isNote) {
      if (_composingNote) return;
      _composingNote = true;
    }

    // Logged before dispatch, not after: a cancelled file dialog and a capture
    // that failed inside the controller both return normally, so a trailing
    // "done" line would claim a success that never happened.
    _logSink.log('Global shortcut: ${action.label}.');

    try {
      if (action.needsWindow) {
        await _windowPresenter.present();
      }

      switch (action) {
        case ShortcutAction.showWindow:
          break; // Presenting the window *was* the action.
        case ShortcutAction.toggleRecording:
          if (_recordings.isRecording) {
            // Stopping stays silent on purpose: the capture is already persisted
            // and yanking the window forward would interrupt whatever the user
            // went back to.
            await _recordings.stopRecording();
          } else {
            // Capture first, surface second. Raising the window costs a
            // window-manager round trip, and a record hotkey that spends it
            // before opening the mic loses the first word.
            await _recordings.startRecording();
            // Unconditional, including the microphone-denied path: the Queue tab
            // is where both the running `SAVE mm:ss` timer and the error banner
            // are drawn, so it is the answer either way.
            await _windowPresenter.present();
            await _revealQueue?.call();
          }
        case ShortcutAction.newTextNote:
          await _composeTextNote();
        case ShortcutAction.uploadAudio:
          await _recordings.addUpload(CaptureType.audioUpload);
        case ShortcutAction.uploadImage:
          await _recordings.addUpload(CaptureType.image);
        case ShortcutAction.uploadVideo:
          await _recordings.addUpload(CaptureType.video);
      }
    } catch (exception) {
      _logSink.log(
        'Shortcut failed (${action.label}): $exception',
        level: LogLevel.error,
      );
    } finally {
      // Scoped to the note action so an upload finishing mid-sheet cannot
      // release a lock it never took.
      if (isNote) _composingNote = false;
    }
  }

  Future<void> dispose() {
    // Set synchronously so `handle` starts refusing immediately, before the
    // unregister round-trip completes.
    _disposed = true;
    return _serial(() => _registrar.unregisterAll());
  }
}
