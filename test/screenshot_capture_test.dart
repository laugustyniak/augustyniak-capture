import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:augustyniak_capture/features/processing/data/ocr_service.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_router.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:augustyniak_capture/features/recordings/domain/screenshot_taker.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  int saveCount = 0;

  /// The status of every row at the moment of each `saveAll`, so a test can
  /// read back what was on disk before processing ever ran.
  final List<List<RecordingStatus>> statusesAtSave = <List<RecordingStatus>>[];
  List<Recording> saved = <Recording>[];

  @override
  Future<Directory> recordingsDirectory() async => directory;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  /// When set, every `saveAll` from this count on throws — a disk that fills
  /// up after the capture's own row is already written.
  int? failFromSave;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCount++;
    if (failFromSave != null && saveCount >= failFromSave!) {
      throw const FileSystemException('No space left on device');
    }
    statusesAtSave.add(<RecordingStatus>[
      for (final Recording r in recordings) r.status,
    ]);
    saved = List<Recording>.from(recordings);
  }
}

/// Stands in for `screencapture -i` and friends: the platform tool writes the
/// PNG straight to the path it is handed, or writes nothing when the user
/// presses Escape.
class _FakeTaker implements ScreenshotTaker {
  _FakeTaker(this.behaviour);

  /// `bytes` writes them, `null` writes nothing (a cancelled selection).
  List<int>? Function()? behaviour;
  bool throws = false;
  String? requestedPath;

  @override
  bool get isAvailable => true;

  @override
  Future<void> capture(File destination) async {
    requestedPath = destination.path;
    await Future<void>.delayed(Duration.zero);
    if (throws) throw const ProcessException('screencapture', <String>[]);
    final List<int>? bytes = behaviour?.call();
    if (bytes != null) await destination.writeAsBytes(bytes);
  }
}

class _ThrowingOcr implements OcrService {
  @override
  Future<String> extractText(File image) async =>
      throw StateError('vision endpoint is down');
}

class _TextOcr implements OcrService {
  @override
  Future<String> extractText(File image) async => 'Error 500 on /checkout';
}

/// Holds OCR open until the test releases it, so a voice comment can be
/// attached while segment 0 is still being read.
class _GatedOcr implements OcrService {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<String> extractText(File image) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return 'Error 500 on /checkout';
  }
}

/// Records what the controller hands a destination.
class _CapturingRouter implements CaptureRouter {
  RoutedCapture? routed;

  @override
  bool canRoute(String? projectId) => true;

  @override
  RouteKind? resolvedKind(RoutedCapture capture) => RouteKind.command;

  @override
  Future<RouteRecord> route(RoutedCapture capture) async {
    routed = capture;
    return RouteRecord(
      at: DateTime.now(),
      kind: RouteKind.command,
      target: 'test',
    );
  }
}

class _RecordingLog implements LogSink {
  final List<(String, LogLevel)> lines = <(String, LogLevel)>[];

  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) {
    lines.add((message, level));
  }
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

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

class _FakeTranscription implements TranscriptionService {
  @override
  Future<String> transcribe(File audioFile) async => 'look at the red banner';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const List<int> _png = <int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4];

void main() {
  late Directory appDir;
  late _FakeRepository repository;
  late _FakeTaker taker;
  late _RecordingLog log;
  late RecordingsController controller;

  RecordingsController build({OcrService? ocr, CaptureRouter? router}) =>
      RecordingsController(
        repository: repository,
        captureRouter: router ?? const DisabledCaptureRouter(),
        transcriptionService: _FakeTranscription(),
        ocrService: ocr ?? _TextOcr(),
        screenshotTaker: taker,
        recorder: _GrantingRecorder(),
        player: _FakePlayer(),
        logSink: log,
      );

  setUp(() async {
    appDir = Directory.systemTemp.createTempSync('augustyniak_capture_shot_');
    repository = _FakeRepository(appDir);
    taker = _FakeTaker(() => _png);
    log = _RecordingLog();
    controller = build();
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
    appDir.deleteSync(recursive: true);
  });

  test('a screenshot is written into the media directory and persisted '
      'as saved before OCR runs', () async {
    final String? id = await controller.captureScreenshot();

    expect(id, isNotNull);
    final Recording item = controller.recordings.single;
    expect(item.id, id);
    expect(item.type, CaptureType.image);
    expect(item.sourceMimeType, 'image/png');
    expect(item.filePath, p.join(appDir.path, '$id.png'));
    expect(taker.requestedPath, item.filePath);
    expect(item.sizeBytes, _png.length);
    // Persist before process: the first write of this row says `saved`.
    expect(repository.statusesAtSave.first, <RecordingStatus>[
      RecordingStatus.saved,
    ]);

    await controller.waitForProcessing();
    final Recording done = controller.recordings.single;
    expect(done.status, RecordingStatus.completed);
    expect(done.transcript, contains('Error 500 on /checkout'));
  });

  test(
    'a cancelled selection leaves the queue unchanged and logs no error',
    () async {
      taker.behaviour = () => null;

      final String? id = await controller.captureScreenshot();

      expect(id, isNull);
      expect(controller.recordings, isEmpty);
      expect(repository.saveCount, 0);
      expect(controller.error, isNull);
      expect(log.lines.where((line) => line.$2 == LogLevel.error), isEmpty);
      expect(appDir.listSync(), isEmpty);
    },
  );

  test('an empty file is a cancelled selection and is removed', () async {
    taker.behaviour = () => <int>[];

    final String? id = await controller.captureScreenshot();

    expect(id, isNull);
    expect(controller.recordings, isEmpty);
    expect(repository.saveCount, 0);
    expect(controller.error, isNull);
    // Left behind, the zero-byte PNG would be an orphan nobody accepted.
    expect(appDir.listSync(), isEmpty);
  });

  test(
    'a missing screenshot tool reports an error and indexes nothing',
    () async {
      taker.throws = true;

      final String? id = await controller.captureScreenshot();

      expect(id, isNull);
      expect(controller.recordings, isEmpty);
      expect(repository.saveCount, 0);
      expect(controller.error, isNotNull);
      expect(controller.isBusy, isFalse);
    },
  );

  test('an OCR failure never removes the image capture', () async {
    controller.dispose();
    controller = build(ocr: _ThrowingOcr());
    await controller.initialize();

    final String? id = await controller.captureScreenshot();
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.id, id);
    expect(item.status, RecordingStatus.failed);
    expect(File(item.filePath).existsSync(), isTrue);
    expect(repository.saved.single.id, id);
  });

  test(
    'a voice comment is recorded as a second segment of the same capture',
    () async {
      final String? id = await controller.captureScreenshot(
        withVoiceComment: true,
      );

      expect(id, isNotNull);
      expect(controller.isRecording, isTrue);
      expect(controller.recordings, hasLength(1));

      await controller.stopRecording();
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.id, id);
      expect(item.segments, hasLength(2));
      expect(item.segments[0].type, CaptureType.image);
      expect(item.segments[1].filePath, p.join(appDir.path, '$id-1.m4a'));
      expect(item.transcript, contains('Error 500 on /checkout'));
      expect(item.transcript, contains('look at the red banner'));
    },
  );

  test('a voice comment stopped while OCR is still running is transcribed '
      'too', () async {
    // The comment is attached while segment 0 is mid-OCR. The drain had
    // already listed that job's pending segments, and the enqueue for the new
    // one was dropped as a duplicate of the running id — so the capture
    // completed with the comment's audio never transcribed.
    final _GatedOcr ocr = _GatedOcr();
    controller.dispose();
    controller = build(ocr: ocr);
    await controller.initialize();

    final String? id = await controller.captureScreenshot(
      withVoiceComment: true,
    );
    await ocr.started.future;
    await controller.stopRecording();
    ocr.release.complete();
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.id, id);
    expect(item.segments, hasLength(2));
    expect(item.segments.every((segment) => !segment.isPending), isTrue);
    expect(item.status, RecordingStatus.completed);
    expect(item.transcript, contains('Error 500 on /checkout'));
    expect(item.transcript, contains('look at the red banner'));
  });

  test('a routed screenshot hands its destination the image path', () async {
    final _CapturingRouter router = _CapturingRouter();
    controller.dispose();
    controller = build(router: router);
    await controller.initialize();

    final String? id = await controller.captureScreenshot();
    await controller.waitForProcessing();
    await controller.route(id!);

    expect(router.routed!.sourceFiles, <String>[
      p.join(appDir.path, '$id.png'),
    ]);
  });

  test('a queuing failure after the row is persisted is not reported as a '
      'failed screenshot', () async {
    // Save 1 is the image row; save 2 is the `pendingTranscription` write.
    repository.failFromSave = repository.saveCount + 2;

    final String? id = await controller.captureScreenshot();

    expect(id, isNotNull);
    expect(controller.recordings.single.id, id);
    expect(File(p.join(appDir.path, '$id.png')).existsSync(), isTrue);
    expect(
      log.lines.where((line) => line.$1.startsWith('Screenshot failed')),
      isEmpty,
    );
    expect(controller.error, contains('Screenshot saved'));
  });

  test('a cancelled selection never opens the microphone', () async {
    taker.behaviour = () => null;

    await controller.captureScreenshot(withVoiceComment: true);

    expect(controller.isRecording, isFalse);
    expect(controller.recordings, isEmpty);
  });
}
