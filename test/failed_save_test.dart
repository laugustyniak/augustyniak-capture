import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

import 'support/harness.dart';

/// What happens after a capture fails to save.
///
/// The three cases here share one property: the capture screen has already
/// closed by the time anything goes wrong, so whatever the app does next is the
/// user's only account of where their audio went.
void main() {
  late Directory appDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('failed_save_');
  });
  tearDown(() {
    if (appDir.existsSync()) appDir.deleteSync(recursive: true);
  });

  RecordingsController build(_StoppingRecorder recorder) {
    final RecordingsController controller = RecordingsController(
      repository: RecordingsRepository(directoryProvider: () async => appDir),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: recorder,
      player: FakePlayer(),
      // Short enough to keep the suite fast; the production default is what
      // decides how long a user stares at a frozen capture screen.
      recorderTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('a recorder that throws on stop still indexes the bytes on disk', () async {
    // The file is written as the capture runs, so a throw from `stop()` says
    // nothing about whether there is audio to keep. `recoverOrphans()` already
    // re-adopts it — on the next launch, which is a whole restart later than
    // the user needs to hear about it.
    final RecordingsController controller =
        build(_StoppingRecorder(_StopBehaviour.throws));
    await controller.startRecording();
    await controller.stopRecording();
    await controller.waitForProcessing();

    expect(controller.recordings, hasLength(1));
    final Recording saved = controller.recordings.single;
    expect(File(saved.filePath).existsSync(), isTrue);
    expect(saved.sizeBytes, greaterThan(0));
    expect(
      controller.error,
      isNull,
      reason: 'the take survived, so there is nothing to report',
    );
  });

  test('an empty capture reports the failure and leaves no file behind', () async {
    // Nothing was ever written, so there is no take to salvage. The file that
    // proves it must not outlive the failure: `findOrphans` skips zero-length
    // files, so anything left here is never looked at again by anyone.
    final _StoppingRecorder recorder = _StoppingRecorder(
      _StopBehaviour.emptyFile,
    );
    final RecordingsController controller = build(recorder);
    await controller.startRecording();
    final String path = recorder.path!;
    await controller.stopRecording();
    await controller.waitForProcessing();

    expect(controller.recordings, isEmpty);
    expect(controller.error, isNotNull);
    expect(File(path).existsSync(), isFalse);
  });

  test('a recorder that never returns from stop still indexes the bytes', () async {
    // The incident this fixes: `stop()` neither returns nor throws, so the
    // salvage path built for a throwing recorder never runs, `finally` never
    // runs either, and a complete take sits on disk with no row pointing at it
    // until the next launch re-adopts it as an orphan.
    final RecordingsController controller = build(
      _StoppingRecorder(_StopBehaviour.hangs),
    );
    await controller.startRecording();
    await controller.stopRecording();
    await controller.waitForProcessing();

    expect(controller.recordings, hasLength(1));
    final Recording saved = controller.recordings.single;
    expect(File(saved.filePath).existsSync(), isTrue);
    expect(saved.sizeBytes, greaterThan(0));
  });

  test('a hung stop still closes the capture screen', () async {
    // `_isBusy` is what the capture screen and DISCARD both read. Left true it
    // takes the screen hostage *and* silently disables the one control the user
    // has left, which is what made the freeze unrecoverable without a kill.
    final RecordingsController controller = build(
      _StoppingRecorder(_StopBehaviour.hangs),
    );
    await controller.startRecording();
    await controller.stopRecording();

    expect(controller.isBusy, isFalse);
    expect(controller.isRecording, isFalse);
  });

  test('a recorder wedged by a hung stop reports instead of hanging', () async {
    // After a timed-out stop the platform recorder is wedged — `record_linux`
    // never nulls its controller and never kills `parecord`, and its `start()`
    // begins by awaiting that same `stop()`. Without a bound here the next
    // capture hangs with no spinner and no error: a dead RECORD button.
    final RecordingsController controller = build(
      _StoppingRecorder(_StopBehaviour.hangs),
    );
    await controller.startRecording();
    await controller.stopRecording();

    await controller.startRecording();

    expect(controller.isRecording, isFalse);
    expect(controller.error, isNotNull);
  });

  test('every RECORD button reveals the queue before it starts', () {
    // A source guard rather than a widget test, on the same rule as
    // `theme_test.dart`'s scope group: `RecordingsPage` builds its own
    // repositories, database and platform channels in `_bootstrap()`, so it
    // cannot be pumped, and the defect is invisible to a test of any smaller
    // piece — every widget renders correctly, the banner just renders in an
    // `IndexedStack` layer nobody is looking at.
    //
    // The break this catches: a fourth record affordance (or an edit to one of
    // the three) wired straight to `startRecording`, leaving a failed save with
    // nowhere to report itself again.
    final String source = File(
      'lib/features/recordings/presentation/recordings_page.dart',
    ).readAsStringSync();

    expect(
      RegExp(r'onRecord:\s*controller\.startRecording').allMatches(source),
      isEmpty,
      reason:
          'the Queue is the only tab that renders `controller.error`, so every '
          'record affordance has to reveal it the way the hotkey path does',
    );
  });
}

enum _StopBehaviour { throws, emptyFile, hangs }

/// Writes what the behaviour under test needs on `start`, so `stopRecording`
/// meets a real file rather than a fake's opinion of one.
class _StoppingRecorder implements AudioRecorder {
  _StoppingRecorder(this.behaviour);

  final _StopBehaviour behaviour;

  /// Where `start` wrote, so a test can assert on the file after the controller
  /// has cleared its own reference to it.
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  /// Set once `stop()` has been asked to hang, so `start` can model what the
  /// platform plugin does next: its own `start()` opens by awaiting that same
  /// unfinished `stop()`, so the wedge outlives the capture that caused it.
  bool _wedged = false;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    if (_wedged) return Completer<void>().future;
    this.path = path;
    await File(path).writeAsString(
      behaviour == _StopBehaviour.emptyFile ? '' : 'audio',
    );
  }

  @override
  Future<String?> stop() {
    if (behaviour == _StopBehaviour.throws) {
      throw const FileSystemException('input disconnected');
    }
    // Never completes, and never throws either — what `record_linux` does when
    // the encoder stops draining the pipe its `stop()` awaits.
    if (behaviour == _StopBehaviour.hangs) {
      _wedged = true;
      return Completer<String?>().future;
    }
    return Future<String?>.value(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}
