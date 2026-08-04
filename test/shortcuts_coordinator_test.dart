import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:audivoa_core/features/recordings/data/media_picker.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/shortcuts/domain/hotkey_binding.dart';
import 'package:audivoa_core/features/shortcuts/domain/hotkey_registrar.dart';
import 'package:audivoa_core/features/shortcuts/domain/shortcut_action.dart';
import 'package:audivoa_core/features/shortcuts/domain/window_presenter.dart';
import 'package:audivoa_core/features/shortcuts/presentation/shortcuts_coordinator.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  List<Recording> saved = <Recording>[];

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saved = List<Recording>.from(recordings);
  }
}

class _FakePicker implements MediaPicker {
  CaptureType? requested;

  @override
  Future<PickedMedia?> pick(CaptureType type) async {
    requested = type;
    return null; // Cancelled — the capture path itself is covered elsewhere.
  }
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

/// Denies the microphone, which is enough to prove the hotkey reached
/// `startRecording` without needing a real capture device.
class _DenyingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

/// Grants the microphone, so `startRecording` runs to completion and leaves the
/// controller in the recording state a second press has to toggle back off.
///
/// [start]/[stop] are written out rather than left to `noSuchMethod`: the stop
/// path has to hand back a file that exists with length > 0, or the capture
/// fails on the persistence invariant and the toggle never completes.
class _GrantingRecorder implements AudioRecorder {
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    this.path = path;
    File(path).writeAsBytesSync(<int>[0, 1, 2, 3]);
  }

  @override
  Future<String?> stop() async => path;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakeRegistrar implements HotkeyRegistrar {
  int applyCount = 0;
  int unregisterCount = 0;
  bool throwOnApply = false;
  Completer<void>? gate;
  Set<ShortcutAction> refuse = const <ShortcutAction>{};
  Map<ShortcutAction, HotkeyBinding> applied =
      const <ShortcutAction, HotkeyBinding>{};

  @override
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
    ShortcutTrigger onTriggered,
  ) async {
    applyCount++;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    if (throwOnApply) throw StateError('platform channel unavailable');
    applied = bindings;
    return refuse;
  }

  @override
  Future<void> unregisterAll() async {
    unregisterCount++;
  }
}

class _CountingPresenter implements WindowPresenter {
  int presents = 0;

  @override
  Future<void> present() async {
    // A real suspension point. Raising a window is an OS round-trip; a guard
    // that only holds when this completes synchronously is a false pass.
    await Future<void>.delayed(Duration.zero);
    presents++;
  }
}

void main() {
  late Directory appDir;
  late _FakeRepository repository;
  late _FakePicker picker;
  late RecordingsController recordings;
  late _FakeRegistrar registrar;
  late _CountingPresenter presenter;
  late int noteCalls;
  late int queueReveals;
  late Completer<void>? noteGate;
  late bool noteThrows;

  ShortcutsCoordinator build() => ShortcutsCoordinator(
    recordings: recordings,
    composeTextNote: () async {
      noteCalls++;
      final Completer<void>? gate = noteGate;
      if (gate != null) await gate.future;
      if (noteThrows) throw StateError('sheet blew up');
    },
    revealQueue: () async {
      // A real suspension point, like the presenter: the shell's version
      // calls setState behind an await.
      await Future<void>.delayed(Duration.zero);
      queueReveals++;
    },
    registrar: registrar,
    windowPresenter: presenter,
  );

  /// A binding that is not in the defaults, for "did the map actually change"
  /// assertions.
  HotkeyBinding altF9() => HotkeyBinding.fromKeys(
    physical: PhysicalKeyboardKey.f9,
    logical: LogicalKeyboardKey.f9,
    modifiers: const <HotkeyModifier>{HotkeyModifier.control},
  );

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('audivoa_shortcuts_');
    repository = _FakeRepository(appDir);
    picker = _FakePicker();
    recordings = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      mediaPicker: picker,
      recorder: _DenyingRecorder(),
      player: _FakePlayer(),
    );
    registrar = _FakeRegistrar();
    presenter = _CountingPresenter();
    noteCalls = 0;
    queueReveals = 0;
    noteGate = null;
    noteThrows = false;
  });

  tearDown(() {
    recordings.dispose();
    appDir.deleteSync(recursive: true);
  });

  group('dispatch', () {
    test('showWindow raises the window and does nothing else', () async {
      final ShortcutsCoordinator coordinator = build();

      await coordinator.handle(ShortcutAction.showWindow);

      expect(presenter.presents, 1);
      expect(recordings.recordings, isEmpty);
      expect(noteCalls, 0);
    });

    test(
      'toggleRecording captures first, then surfaces the Queue tab',
      () async {
        final ShortcutsCoordinator coordinator = build();

        await coordinator.handle(ShortcutAction.toggleRecording);

        // The denied microphone proves `startRecording` actually ran.
        expect(recordings.error, 'Microphone permission denied.');
        // A recording started from a global hotkey is invisible otherwise: both
        // the running timer and this error are drawn on the Queue tab only.
        expect(presenter.presents, 1);
        expect(queueReveals, 1);
      },
    );

    test('stopping a recording leaves the window where it was', () async {
      // Not symmetry for its own sake: the capture is already persisted by then,
      // and raising the window would yank the user out of whatever they went
      // back to — which is the reason a global record hotkey exists.
      recordings.dispose();
      recordings = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
        mediaPicker: picker,
        recorder: _GrantingRecorder(),
        player: _FakePlayer(),
      );
      final ShortcutsCoordinator coordinator = build();

      await coordinator.handle(ShortcutAction.toggleRecording);
      // Asserted rather than merely recorded: without it this test would still
      // pass if the start branch had silently stopped raising the window too.
      expect(recordings.isRecording, isTrue);
      expect(presenter.presents, 1);
      expect(queueReveals, 1);

      await coordinator.handle(ShortcutAction.toggleRecording);

      expect(recordings.isRecording, isFalse);
      expect(presenter.presents, 1);
      expect(queueReveals, 1);
    });

    test('newTextNote raises the window before opening the sheet', () async {
      final ShortcutsCoordinator coordinator = build();

      await coordinator.handle(ShortcutAction.newTextNote);

      expect(presenter.presents, 1);
      expect(noteCalls, 1);
    });

    test('upload shortcuts route to the matching capture type', () async {
      final ShortcutsCoordinator coordinator = build();

      await coordinator.handle(ShortcutAction.uploadImage);
      expect(picker.requested, CaptureType.image);
      expect(presenter.presents, 1, reason: 'the file dialog needs the window');

      await coordinator.handle(ShortcutAction.uploadVideo);
      expect(picker.requested, CaptureType.video);

      await coordinator.handle(ShortcutAction.uploadAudio);
      expect(picker.requested, CaptureType.audioUpload);
    });

    test('a second note hotkey while the sheet is open is ignored', () async {
      final ShortcutsCoordinator coordinator = build();
      noteGate = Completer<void>();

      final Future<void> first = coordinator.handle(ShortcutAction.newTextNote);
      // Let the first press travel all the way to the sheet, so the second one
      // is genuinely blocked by the guard rather than by scheduling order.
      await pumpEventQueue();
      expect(noteCalls, 1);

      await coordinator.handle(ShortcutAction.newTextNote);
      await pumpEventQueue();
      expect(noteCalls, 1, reason: 'the sheet must not stack on itself');

      noteGate!.complete();
      await first;

      // Once the sheet closes the shortcut works again.
      noteGate = null;
      await coordinator.handle(ShortcutAction.newTextNote);
      expect(noteCalls, 2);
    });

    test(
      'a throwing sheet is swallowed and still releases the note guard',
      () async {
        final ShortcutsCoordinator coordinator = build();
        noteThrows = true;

        // Must complete normally: a shortcut may never surface an exception.
        await coordinator.handle(ShortcutAction.newTextNote);
        expect(noteCalls, 1);

        noteThrows = false;
        await coordinator.handle(ShortcutAction.newTextNote);
        expect(noteCalls, 2, reason: 'the guard must be released in `finally`');
      },
    );

    test('a press landing after dispose is refused', () async {
      final ShortcutsCoordinator coordinator = build();

      // Not awaited on purpose: this is the window the shell disposes the
      // controller in, and the synchronous `_disposed` flag has to cover it.
      unawaited(coordinator.dispose());
      await coordinator.handle(ShortcutAction.showWindow);

      expect(presenter.presents, 0);
    });
  });

  group('registration', () {
    test(
      're-applying an unchanged map leaves the OS hotkey table alone',
      () async {
        final ShortcutsCoordinator coordinator = build();
        final Map<ShortcutAction, HotkeyBinding> bindings =
            Map<ShortcutAction, HotkeyBinding>.from(ShortcutDefaults.bindings);

        await coordinator.apply(bindings);
        await coordinator.apply(
          Map<ShortcutAction, HotkeyBinding>.from(bindings),
        );

        expect(registrar.applyCount, 1);

        await coordinator.apply(<ShortcutAction, HotkeyBinding>{
          ...bindings,
          ShortcutAction.showWindow: altF9(),
        });
        expect(registrar.applyCount, 2);
      },
    );

    test('overlapping applies are serialized, not interleaved', () async {
      final ShortcutsCoordinator coordinator = build();
      registrar.gate = Completer<void>();

      final Future<Set<ShortcutAction>> first = coordinator.apply(
        ShortcutDefaults.bindings,
      );
      final Future<Set<ShortcutAction>> second = coordinator.apply(
        <ShortcutAction, HotkeyBinding>{
          ...ShortcutDefaults.bindings,
          ShortcutAction.showWindow: altF9(),
        },
      );
      await pumpEventQueue();

      // The registrar unregisters everything before it registers, so a second
      // apply running concurrently could wipe the first one's work mid-loop.
      expect(registrar.applyCount, 1);

      registrar.gate!.complete();
      registrar.gate = null;
      await Future.wait<Set<ShortcutAction>>(<Future<Set<ShortcutAction>>>[
        first,
        second,
      ]);

      expect(registrar.applyCount, 2);
      expect(registrar.applied[ShortcutAction.showWindow], altF9());
    });

    test(
      'a failing registration is logged, not thrown, and stays retryable',
      () async {
        final ShortcutsCoordinator coordinator = build();
        registrar.throwOnApply = true;

        await coordinator.apply(ShortcutDefaults.bindings);
        expect(coordinator.rejected, isEmpty);

        // The retry must not short-circuit on "same map as last time" — a
        // transient platform failure would otherwise wedge the feature off for
        // the rest of the session.
        registrar.throwOnApply = false;
        await coordinator.apply(ShortcutDefaults.bindings);
        expect(registrar.applyCount, 2);
        expect(registrar.applied, isNotEmpty);
      },
    );

    test('refused combinations are reported instead of thrown', () async {
      registrar.refuse = <ShortcutAction>{ShortcutAction.showWindow};
      final ShortcutsCoordinator coordinator = build();

      final Set<ShortcutAction> rejected = await coordinator.apply(
        ShortcutDefaults.bindings,
      );

      expect(rejected, <ShortcutAction>{ShortcutAction.showWindow});
      expect(coordinator.rejected, rejected);
    });

    test(
      'suspend releases everything and resume restores the newest map',
      () async {
        final ShortcutsCoordinator coordinator = build();
        await coordinator.apply(ShortcutDefaults.bindings);
        expect(registrar.applyCount, 1);

        await coordinator.suspend();
        expect(registrar.unregisterCount, greaterThan(0));

        // A rebind saved while the capture sheet is open must not register yet —
        // the OS would swallow the very keys the sheet is trying to read.
        final Map<ShortcutAction, HotkeyBinding> rebound =
            <ShortcutAction, HotkeyBinding>{
              ...ShortcutDefaults.bindings,
              ShortcutAction.toggleRecording: altF9(),
            };
        await coordinator.apply(rebound);
        expect(registrar.applyCount, 1);

        // ...but closing the sheet must pick it up.
        await coordinator.resume();
        expect(registrar.applyCount, 2);
        expect(registrar.applied[ShortcutAction.toggleRecording], altF9());
      },
    );

    test('dispose releases the OS registrations', () async {
      final ShortcutsCoordinator coordinator = build();
      await coordinator.apply(ShortcutDefaults.bindings);

      await coordinator.dispose();

      expect(registrar.unregisterCount, greaterThan(0));
    });
  });
}
