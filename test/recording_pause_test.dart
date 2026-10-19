import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  File? source;
  int saveCalls = 0;

  @override
  Future<File> createSourceFile(String id, String extension) async {
    source = File(p.join(directory.path, '$id.$extension'));
    await source!.writeAsString('audio');
    return source!;
  }

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCalls++;
  }
}

class _ControllableRecorder implements AudioRecorder {
  Future<void> Function()? onPause;
  Future<void> Function()? onResume;
  Future<void> Function()? onDispose;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  final List<String> calls = <String>[];

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<void> pause() async {
    pauseCalls++;
    calls.add('pause');
    await onPause?.call();
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    calls.add('resume');
    await onResume?.call();
  }

  @override
  Future<String?> stop() async {
    stopCalls++;
    calls.add('stop');
    return null;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    calls.add('dispose');
    await onDispose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!condition()) {
    fail('Condition was not met within $timeout.');
  }
}

void main() {
  late Directory appDir;
  late _FakeRepository repository;
  late _ControllableRecorder recorder;
  late RecordingsController controller;
  bool controllerDisposed = false;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak_capture_pause_');
    repository = _FakeRepository(appDir);
    recorder = _ControllableRecorder();
    controller = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      recorder: recorder,
      player: _FakePlayer(),
      recorderTimeout: const Duration(milliseconds: 100),
    );
  });

  tearDown(() {
    if (!controllerDisposed) controller.dispose();
    appDir.deleteSync(recursive: true);
  });

  void disposeController() {
    controllerDisposed = true;
    controller.dispose();
  }

  test('pause toggle is inert while no recording is active', () async {
    await controller.toggleRecordingPause();

    expect(controller.isRecording, isFalse);
    expect(controller.isRecordingPaused, isFalse);
    expect(recorder.pauseCalls, 0);
    expect(recorder.resumeCalls, 0);
  });

  test(
    'pause freezes elapsed time and resume continues the same capture',
    () async {
      await controller.startRecording();
      await _until(
        () => controller.elapsed >= const Duration(milliseconds: 100),
      );

      await controller.toggleRecordingPause();
      final Duration pausedAt = controller.elapsed;
      final Stopwatch wallClock = Stopwatch()..start();
      await _until(
        () => wallClock.elapsed >= const Duration(milliseconds: 350),
      );

      expect(controller.isRecording, isTrue);
      expect(controller.isRecordingPaused, isTrue);
      expect(controller.elapsed, pausedAt);
      expect(recorder.pauseCalls, 1);
      expect(repository.saveCalls, 0);
      expect(await repository.source!.readAsString(), 'audio');

      await controller.toggleRecordingPause();
      await _until(
        () =>
            controller.elapsed >= pausedAt + const Duration(milliseconds: 100),
      );

      expect(controller.isRecording, isTrue);
      expect(controller.isRecordingPaused, isFalse);
      expect(recorder.resumeCalls, 1);
    },
  );

  test(
    'a failed pause keeps the recording running and reports the error',
    () async {
      recorder.onPause = () async => throw Exception('pause failed');
      await controller.startRecording();
      final Duration before = controller.elapsed;

      await controller.toggleRecordingPause();

      expect(controller.isRecording, isTrue);
      expect(controller.isRecordingPaused, isFalse);
      expect(controller.error, contains('pause failed'));
      await _until(
        () => controller.elapsed > before + const Duration(milliseconds: 50),
      );
    },
  );

  test(
    'a failed resume keeps the recording paused and reports the error',
    () async {
      await controller.startRecording();
      await controller.toggleRecordingPause();
      final Duration pausedAt = controller.elapsed;
      recorder.onResume = () async => throw Exception('resume failed');

      await controller.toggleRecordingPause();

      expect(controller.isRecording, isTrue);
      expect(controller.isRecordingPaused, isTrue);
      expect(controller.elapsed, pausedAt);
      expect(controller.error, contains('resume failed'));
    },
  );

  test('a timed out pause keeps the prior state', () async {
    final Completer<void> neverCompletes = Completer<void>();
    recorder.onPause = () => neverCompletes.future;
    await controller.startRecording();

    await controller.toggleRecordingPause();

    expect(controller.isRecording, isTrue);
    expect(controller.isRecordingPaused, isFalse);
    expect(controller.error, contains('pause'));
    expect(controller.error, contains('TimeoutException'));
  });

  test('a pending pause gates concurrent capture operations', () async {
    final Completer<void> pauseGate = Completer<void>();
    recorder.onPause = () => pauseGate.future;
    await controller.startRecording();

    final Future<void> pendingPause = controller.toggleRecordingPause();
    await Future<void>.delayed(Duration.zero);
    await controller.toggleRecordingPause();
    await controller.stopRecording();
    await controller.discardRecording();

    expect(recorder.pauseCalls, 1);
    expect(recorder.resumeCalls, 0);
    expect(recorder.stopCalls, 0);
    expect(controller.isRecording, isTrue);

    pauseGate.complete();
    await pendingPause;
    expect(controller.isRecordingPaused, isTrue);
  });

  test(
    'saving directly from pause persists the take and resets pause state',
    () async {
      await controller.startRecording();
      await controller.toggleRecordingPause();

      await controller.stopRecording();

      expect(recorder.stopCalls, 1);
      expect(controller.isRecording, isFalse);
      expect(controller.isRecordingPaused, isFalse);
      expect(controller.recordings, hasLength(1));
      expect(repository.saveCalls, greaterThan(0));
      expect(await repository.source!.exists(), isTrue);
      if (Platform.isLinux) {
        expect(recorder.calls, <String>['pause', 'resume', 'stop']);
      } else {
        expect(recorder.calls, <String>['pause', 'stop']);
      }
    },
  );

  test('saving still stops and salvages when releasing pause fails', () async {
    await controller.startRecording();
    await controller.toggleRecordingPause();
    recorder.onResume = () async =>
        throw Exception('resume before stop failed');

    await controller.stopRecording();

    expect(recorder.stopCalls, 1);
    expect(controller.isRecording, isFalse);
    expect(controller.isRecordingPaused, isFalse);
    expect(controller.recordings, hasLength(1));
    expect(await repository.source!.exists(), isTrue);
    if (Platform.isLinux) {
      expect(recorder.calls, <String>['pause', 'resume', 'stop']);
    } else {
      expect(recorder.calls, <String>['pause', 'stop']);
    }
  });

  test(
    'discarding directly from pause deletes the take and resets pause state',
    () async {
      await controller.startRecording();
      await controller.toggleRecordingPause();
      final File source = repository.source!;

      await controller.discardRecording();

      expect(recorder.stopCalls, 1);
      expect(controller.isRecording, isFalse);
      expect(controller.isRecordingPaused, isFalse);
      expect(controller.recordings, isEmpty);
      expect(repository.saveCalls, 0);
      expect(await source.exists(), isFalse);
      if (Platform.isLinux) {
        expect(recorder.calls, <String>['pause', 'resume', 'stop']);
      } else {
        expect(recorder.calls, <String>['pause', 'stop']);
      }
    },
  );

  test(
    'disposing a paused Linux recorder resumes it before disposal',
    () async {
      await controller.startRecording();
      await controller.toggleRecordingPause();

      disposeController();
      await _until(() => recorder.disposeCalls == 1);

      if (Platform.isLinux) {
        expect(recorder.calls, <String>['pause', 'resume', 'dispose']);
      } else {
        expect(recorder.calls, <String>['pause', 'dispose']);
      }
    },
  );

  test('dispose continues when releasing a paused recorder fails', () async {
    await controller.startRecording();
    await controller.toggleRecordingPause();
    recorder.onResume = () async =>
        throw Exception('resume before dispose failed');

    disposeController();
    await _until(() => recorder.disposeCalls == 1);

    if (Platform.isLinux) {
      expect(recorder.calls, <String>['pause', 'resume', 'dispose']);
    } else {
      expect(recorder.calls, <String>['pause', 'dispose']);
    }
  });

  test(
    'dispose during pending pause completes without notifying after disposal',
    () async {
      final Completer<void> pauseGate = Completer<void>();
      recorder.onPause = () => pauseGate.future;
      await controller.startRecording();

      final Future<void> pendingPause = controller.toggleRecordingPause();
      await _until(() => recorder.pauseCalls == 1);
      disposeController();
      pauseGate.complete();

      await pendingPause;
      await _until(() => recorder.disposeCalls == 1);
      if (Platform.isLinux) {
        expect(recorder.calls, <String>['pause', 'resume', 'dispose']);
      } else {
        expect(recorder.calls, <String>['pause', 'dispose']);
      }
    },
  );
}
