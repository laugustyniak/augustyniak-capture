import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/media_picker.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

/// Hangs until [gate] is completed, so the job stays in `transcribing`.
class _GatedTranscriptionService implements TranscriptionService {
  final Completer<void> gate = Completer<void>();

  @override
  Future<String> transcribe(File audioFile) async {
    await gate.future;
    return 'TRANSCRIPT';
  }
}

class _FakePicker implements MediaPicker {
  _FakePicker(this._result);
  final PickedMedia? _result;
  @override
  Future<PickedMedia?> pick(CaptureType type) async => _result;
}

class _FakeRecorder implements AudioRecorder {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

/// Polls rather than sleeping a fixed span: the ticks are driven by a real
/// `Timer`, and a fixed wait encodes an assumption about how busy the machine is.
Future<void> _until(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!ready()) {
    if (sw.elapsed > timeout) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory appDir;
  late Directory pickDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak_capture_ptick_');
    pickDir = Directory.systemTemp.createTempSync('augustyniak_capture_pick_');
  });
  tearDown(() {
    appDir.deleteSync(recursive: true);
    pickDir.deleteSync(recursive: true);
  });

  test(
    'the processing tick drives processingTicker, not the whole controller',
    () async {
      final File source = File(p.join(pickDir.path, 'original.mp3'))
        ..writeAsStringSync('SOUND');
      final _GatedTranscriptionService gate = _GatedTranscriptionService();
      final RecordingsController controller = RecordingsController(
        repository: _FakeRepository(appDir),
        transcriptionService: gate,
        mediaPicker: _FakePicker(
          PickedMedia(file: source, mimeType: 'audio/mpeg'),
        ),
        recorder: _FakeRecorder(),
        player: _FakePlayer(),
      );
      await controller.initialize();
      await controller.addUpload(CaptureType.audioUpload);

      // Wait until the job is parked inside the transcriber.
      await _until(
        () =>
            controller.recordings.isNotEmpty &&
            controller.recordings.first.status ==
                RecordingStatus.transcribing &&
            controller.processingElapsedFor(controller.recordings.first.id) !=
                null,
      );

      int controllerNotifications = 0;
      int tickerNotifications = 0;
      controller.addListener(() => controllerNotifications++);
      controller.processingTicker.addListener(() => tickerNotifications++);

      await _until(() => tickerNotifications >= 2);

      // The ticks moved the ticker and did NOT rebuild the page.
      expect(
        controllerNotifications,
        0,
        reason: 'the tick must not rebuild the page',
      );
      expect(controller.processingTicker.value, greaterThan(Duration.zero));

      gate.gate.complete();
      await controller.waitForProcessing();
      controller.dispose();
    },
  );
}
