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

enum _StopBehaviour { throws, emptyFile }

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

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    this.path = path;
    await File(path).writeAsString(
      behaviour == _StopBehaviour.emptyFile ? '' : 'audio',
    );
  }

  @override
  Future<String?> stop() async {
    if (behaviour == _StopBehaviour.throws) {
      throw const FileSystemException('input disconnected');
    }
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}
