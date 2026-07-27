import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:voice_notes_phase1/features/recordings/data/media_picker.dart';
import 'package:voice_notes_phase1/features/recordings/data/recordings_repository.dart';
import 'package:voice_notes_phase1/features/recordings/domain/capture_type.dart';
import 'package:voice_notes_phase1/features/recordings/domain/recording.dart';
import 'package:voice_notes_phase1/features/recordings/presentation/recordings_controller.dart';
import 'package:voice_notes_phase1/features/shortcuts/domain/hotkey_binding.dart';
import 'package:voice_notes_phase1/features/shortcuts/domain/hotkey_registrar.dart';
import 'package:voice_notes_phase1/features/shortcuts/domain/shortcut_action.dart';
import 'package:voice_notes_phase1/features/shortcuts/domain/window_presenter.dart';
import 'package:voice_notes_phase1/features/shortcuts/presentation/shortcuts_coordinator.dart';
import 'package:voice_notes_phase1/features/transcription/data/transcription_service.dart';

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
  Future<bool> hasPermission() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakeRegistrar implements HotkeyRegistrar {
  int applyCount = 0;
  bool unregistered = false;
  Set<ShortcutAction> refuse = const <ShortcutAction>{};
  Map<ShortcutAction, HotkeyBinding> applied =
      const <ShortcutAction, HotkeyBinding>{};

  @override
  Future<Set<ShortcutAction>> apply(
    Map<ShortcutAction, HotkeyBinding> bindings,
    ShortcutTrigger onTriggered,
  ) async {
    applyCount++;
    applied = bindings;
    return refuse;
  }

  @override
  Future<void> unregisterAll() async {
    unregistered = true;
  }
}

class _CountingPresenter implements WindowPresenter {
  int presents = 0;

  @override
  Future<void> present() async {
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
  late Completer<void>? noteGate;

  ShortcutsCoordinator build() => ShortcutsCoordinator(
        recordings: recordings,
        composeTextNote: () async {
          noteCalls++;
          final Completer<void>? gate = noteGate;
          if (gate != null) await gate.future;
        },
        registrar: registrar,
        windowPresenter: presenter,
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
    noteGate = null;
  });

  tearDown(() {
    recordings.dispose();
    appDir.deleteSync(recursive: true);
  });

  test('showWindow raises the window and does nothing else', () async {
    final ShortcutsCoordinator coordinator = build();

    await coordinator.handle(ShortcutAction.showWindow);

    expect(presenter.presents, 1);
    expect(recordings.recordings, isEmpty);
    expect(noteCalls, 0);
  });

  test('toggleRecording reaches the controller without raising the window',
      () async {
    final ShortcutsCoordinator coordinator = build();

    await coordinator.handle(ShortcutAction.toggleRecording);

    // The whole point of a global record hotkey: it must not pull the user out
    // of whatever they were working in.
    expect(presenter.presents, 0);
    // The denied microphone proves `startRecording` actually ran.
    expect(recordings.error, 'Brak uprawnienia do mikrofonu.');
  });

  test('newTextNote raises the window before opening the sheet', () async {
    final ShortcutsCoordinator coordinator = build();

    await coordinator.handle(ShortcutAction.newTextNote);

    expect(presenter.presents, 1);
    expect(noteCalls, 1);
  });

  test('a second note hotkey while the sheet is open is ignored', () async {
    final ShortcutsCoordinator coordinator = build();
    noteGate = Completer<void>();

    final Future<void> first = coordinator.handle(ShortcutAction.newTextNote);
    await coordinator.handle(ShortcutAction.newTextNote);

    expect(noteCalls, 1, reason: 'the sheet must not stack on itself');
    noteGate!.complete();
    await first;

    // Once the sheet closes the shortcut works again.
    noteGate = null;
    await coordinator.handle(ShortcutAction.newTextNote);
    expect(noteCalls, 2);
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

  test('re-applying an unchanged map leaves the OS hotkey table alone',
      () async {
    final ShortcutsCoordinator coordinator = build();
    final Map<ShortcutAction, HotkeyBinding> bindings =
        Map<ShortcutAction, HotkeyBinding>.from(ShortcutDefaults.bindings);

    await coordinator.apply(bindings);
    await coordinator.apply(Map<ShortcutAction, HotkeyBinding>.from(bindings));

    expect(registrar.applyCount, 1);

    // A real change does go through.
    await coordinator.apply(<ShortcutAction, HotkeyBinding>{
      ...bindings,
      ShortcutAction.showWindow: HotkeyBinding.fromKeys(
        physical: PhysicalKeyboardKey.keyZ,
        logical: LogicalKeyboardKey.keyZ,
        modifiers: const <HotkeyModifier>{HotkeyModifier.control},
      ),
    });
    expect(registrar.applyCount, 2);
  });

  test('refused combinations are reported instead of thrown', () async {
    registrar.refuse = <ShortcutAction>{ShortcutAction.showWindow};
    final ShortcutsCoordinator coordinator = build();

    final Set<ShortcutAction> rejected =
        await coordinator.apply(ShortcutDefaults.bindings);

    expect(rejected, <ShortcutAction>{ShortcutAction.showWindow});
    expect(coordinator.rejected, rejected);
  });

  test('dispose releases the OS registrations', () async {
    final ShortcutsCoordinator coordinator = build();
    await coordinator.apply(ShortcutDefaults.bindings);

    await coordinator.dispose();

    expect(registrar.unregistered, isTrue);
  });
}
