import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_session.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

import 'support/harness.dart';

/// Both halves of the platform contract, asserted where they can be:
///
/// * **the order** — Android grants a foreground service the microphone only if
///   the service is already running, so `begin()` has to land before the
///   recorder opens the input. A test is the only place that stays true; the
///   device only tells you by silently ending the capture.
/// * **the release** — every way a capture can end has to take the hold off,
///   including the ones that end badly. A notification left standing over a
///   finished recording claims the mic is open when it is not.
void main() {
  late Directory appDir;
  late List<String> events;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('capture_session_');
    events = <String>[];
  });
  tearDown(() {
    if (appDir.existsSync()) appDir.deleteSync(recursive: true);
  });

  /// Writes into the shared log so the recorder and the session can be ordered
  /// against each other — which is the whole question here.
  RecordingsController build({
    Object? sessionFailsWith,
    bool recorderFailsOnStop = false,
  }) {
    final RecordingsController controller = RecordingsController(
      repository: RecordingsRepository(directoryProvider: () async => appDir),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _LoggingRecorder(
        events,
        appDir,
        failOnStop: recorderFailsOnStop,
      ),
      // The default `AudioPlayer` subscribes to an event channel on
      // construction, which needs a binding this suite deliberately does not
      // have. Same reason every other pure-Dart controller test injects one.
      player: FakePlayer(),
      captureSession: _LoggingSession(events, failsWith: sessionFailsWith),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('the hold is taken before the recorder opens the input', () async {
    final RecordingsController controller = build();
    await controller.startRecording();

    expect(
      events,
      <String>['session.begin', 'recorder.start'],
      reason:
          'Android checks that the service is already running when the mic is '
          'opened; the other order is silently refused.',
    );
    await controller.stopRecording();
    await controller.waitForProcessing();
  });

  test('saving a capture releases the hold', () async {
    final RecordingsController controller = build();
    await controller.startRecording();
    await controller.stopRecording();
    await controller.waitForProcessing();

    expect(events, contains('session.end'));
    expect(controller.recordings, hasLength(1));
  });

  test('discarding a capture releases the hold', () async {
    final RecordingsController controller = build();
    await controller.startRecording();
    await controller.discardRecording();

    expect(events, contains('session.end'));
    expect(
      controller.recordings,
      isEmpty,
      reason: 'a discard still indexes nothing',
    );
  });

  test('a recorder that throws on stop still releases the hold', () async {
    // The failure mode the teardown-in-finally rule was written for. The
    // capture is no longer lost with it — the bytes were on disk before `stop()`
    // was ever called, so it is salvaged — but the hold is the question here,
    // and it has to come off on the way through either way.
    final RecordingsController controller = build(recorderFailsOnStop: true);
    await controller.startRecording();
    await controller.stopRecording();
    await controller.waitForProcessing();

    expect(events, contains('session.end'));
    expect(controller.recordings, hasLength(1));
  });

  test('a session that cannot start never costs the recording', () async {
    // A phone that refuses the foreground service loses the background
    // guarantee, not the capture. Recording only while the app is on screen is
    // strictly better than not recording at all.
    final RecordingsController controller = build(
      sessionFailsWith: Exception('service refused'),
    );
    await controller.startRecording();

    expect(events, contains('recorder.start'));
    expect(controller.isRecording, isTrue);

    await controller.stopRecording();
    await controller.waitForProcessing();
    expect(controller.recordings, hasLength(1));
    // Asserted on the file and the row rather than on `status`: with no
    // transcription profile the item legitimately ends `failed`, which is the
    // app working and says nothing about the session. What the session must not
    // be able to affect is whether the capture exists at all.
    final Recording saved = controller.recordings.single;
    expect(File(saved.filePath).existsSync(), isTrue);
    expect(saved.sizeBytes, greaterThan(0));
  });
}

class _LoggingSession implements CaptureSession {
  _LoggingSession(this.events, {this.failsWith});

  final List<String> events;
  final Object? failsWith;

  @override
  Future<void> begin() async {
    events.add('session.begin');
    if (failsWith != null) throw failsWith!;
  }

  @override
  Future<void> end() async {
    events.add('session.end');
    if (failsWith != null) throw failsWith!;
  }
}

/// Writes a real (tiny) file on start so the capture pipeline's non-empty check
/// passes and `stopRecording` reaches its persist step.
class _LoggingRecorder implements AudioRecorder {
  _LoggingRecorder(this.events, this.directory, {this.failOnStop = false});

  final List<String> events;
  final Directory directory;
  final bool failOnStop;
  String? _path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    events.add('recorder.start');
    _path = path;
    await File(path).writeAsString('audio');
  }

  @override
  Future<String?> stop() async {
    if (failOnStop) throw const FileSystemException('input disconnected');
    events.add('recorder.stop');
    return _path ?? p.join(directory.path, 'missing.m4a');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}
