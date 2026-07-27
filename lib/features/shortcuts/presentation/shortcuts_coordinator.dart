import 'package:flutter/foundation.dart';

import '../../logs/domain/log_event.dart';
import '../../recordings/domain/capture_type.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../domain/hotkey_binding.dart';
import '../domain/hotkey_registrar.dart';
import '../domain/shortcut_action.dart';
import '../domain/window_presenter.dart';

/// Turns a global hotkey press into exactly one capture action.
///
/// Deliberately thin. It owns no capture logic of its own: every action calls
/// the same `RecordingsController` entry point the FAB calls, so the
/// persist-before-process ordering stays defined in one place and a shortcut can
/// never become a second, divergent capture path.
class ShortcutsCoordinator {
  ShortcutsCoordinator({
    required RecordingsController recordings,
    required Future<void> Function() composeTextNote,
    HotkeyRegistrar registrar = const NoopHotkeyRegistrar(),
    WindowPresenter windowPresenter = const NoopWindowPresenter(),
    LogSink logSink = const NoopLogSink(),
  })  : _recordings = recordings,
        _composeTextNote = composeTextNote,
        _registrar = registrar,
        _windowPresenter = windowPresenter,
        _logSink = logSink;

  final RecordingsController _recordings;
  final Future<void> Function() _composeTextNote;
  final HotkeyRegistrar _registrar;
  final WindowPresenter _windowPresenter;
  final LogSink _logSink;

  Map<ShortcutAction, HotkeyBinding>? _applied;
  bool _composingNote = false;
  bool _disposed = false;

  /// Bindings the OS refused, surfaced in the Config tab so an unavailable
  /// combination is visible rather than mysteriously dead.
  Set<ShortcutAction> rejected = const <ShortcutAction>{};

  /// (Re)registers the whole set. Cheap to call on every settings notification:
  /// an unchanged map short-circuits, so unrelated changes (a provider swap, an
  /// audio parameter) never churn the OS hotkey table.
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
  ) async {
    if (_applied != null && mapEquals(_applied, bindings)) return rejected;
    _applied = Map<ShortcutAction, HotkeyBinding>.from(bindings);

    rejected = await _registrar.apply(_applied!, handle);
    for (final ShortcutAction action in rejected) {
      _logSink.log(
        'Skrót zajęty przez inną aplikację: ${action.label}.',
        level: LogLevel.warn,
      );
    }
    return rejected;
  }

  /// Public so a test can fire an action without going through the OS.
  ///
  /// Swallows every error on the same rule as logging: a shortcut is a
  /// convenience layer and must never surface an exception into the capture
  /// pipeline, which does its own error handling and marks items `failed`.
  Future<void> handle(ShortcutAction action) async {
    // The OS keeps a registration live until `unregisterAll` completes, which
    // `dispose` only *starts*. A press landing in that window would otherwise
    // drive an already-disposed controller — bail before touching anything.
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

    try {
      if (action.needsWindow) {
        await _windowPresenter.present();
      }

      switch (action) {
        case ShortcutAction.showWindow:
          break; // Presenting the window *was* the action.
        case ShortcutAction.toggleRecording:
          if (_recordings.isRecording) {
            await _recordings.stopRecording();
          } else {
            await _recordings.startRecording();
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
      _logSink.log('Skrót globalny: ${action.label}.');
    } catch (exception) {
      _logSink.log(
        'Skrót nieudany (${action.label}): $exception',
        level: LogLevel.error,
      );
    } finally {
      // Scoped to the note action so an upload finishing mid-sheet cannot
      // release a lock it never took.
      if (isNote) _composingNote = false;
    }
  }

  Future<void> dispose() {
    _disposed = true;
    return _registrar.unregisterAll();
  }
}
