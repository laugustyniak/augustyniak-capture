import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _MemoryRepo extends RecordingsRepository {
  _MemoryRepo(this._dir, this.seed);
  final Directory _dir;
  final List<Recording> seed;

  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => seed;
  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

/// Answers the file's own contents, so each segment produces distinct text and
/// the test can tell which one was processed.
class _EchoProcessor implements Processor {
  final List<String> seen = <String>[];

  @override
  Future<String> process(CaptureSegment segment) async {
    seen.add(p.basename(segment.filePath));
    return File(segment.filePath).readAsString();
  }
}

class _FailingProcessor implements Processor {
  @override
  Future<String> process(CaptureSegment segment) async =>
      throw const ProcessorNotConfiguredException('no vision model');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (MethodCall call) async => null,
    );
  }

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('segment-processing');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> write(String name, String body) async {
    final File file = File(p.join(dir.path, name));
    await file.writeAsString(body);
    return file;
  }

  CaptureSegment segment(int index, String path, {String? text}) =>
      CaptureSegment(
        index: index,
        filePath: path,
        type: CaptureType.text,
        createdAt: DateTime.utc(2026, 8, 28),
        sizeBytes: 8,
        text: text,
      );

  Recording seeded({
    required List<CaptureSegment> segments,
    String? transcript,
  }) {
    return Recording(
      id: 'abc',
      filePath: segments.first.filePath,
      createdAt: DateTime.utc(2026, 8, 28),
      durationMs: 0,
      sizeBytes: segments.first.sizeBytes,
      status: RecordingStatus.saved,
      type: segments.first.type,
      transcript: transcript,
      segments: segments,
    );
  }

  RecordingsController build(
    RecordingsRepository repository,
    Map<CaptureType, Processor> processors,
  ) {
    return RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      processorRegistry: ProcessorRegistry(processors),
    );
  }

  test('only the pending segment is processed and its text is appended',
      () async {
    final File first = await write('abc.txt', 'first fragment');
    final File second = await write('abc-1.txt', 'second fragment');
    final _EchoProcessor processor = _EchoProcessor();
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[
        seeded(
          transcript: 'first fragment',
          segments: <CaptureSegment>[
            segment(0, first.path, text: 'first fragment'),
            segment(1, second.path),
          ],
        ),
      ]),
      <CaptureType, Processor>{CaptureType.text: processor},
    );

    await controller.initialize();
    await controller.retryTranscription('abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(
      processor.seen,
      <String>['abc-1.txt'],
      reason: 'the first fragment already has text and must not be re-sent',
    );
    expect(item.transcript, 'first fragment\n\nsecond fragment');
    expect(item.segments[1].text, 'second fragment');
    expect(item.status, RecordingStatus.completed);
    controller.dispose();
  });

  test('a failing segment keeps the text of the ones that worked', () async {
    final File first = await write('abc.txt', 'first fragment');
    final File second = await write('abc-1.jpg', 'not an image');
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[
        seeded(
          segments: <CaptureSegment>[
            segment(0, first.path),
            CaptureSegment(
              index: 1,
              filePath: second.path,
              type: CaptureType.image,
              createdAt: DateTime.utc(2026, 8, 28),
              sizeBytes: 12,
            ),
          ],
        ),
      ]),
      <CaptureType, Processor>{
        CaptureType.text: _EchoProcessor(),
        CaptureType.image: _FailingProcessor(),
      },
    );

    await controller.initialize();
    await controller.retryTranscription('abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.status, RecordingStatus.failed);
    expect(item.transcript, 'first fragment');
    expect(item.segments[0].text, 'first fragment');
    expect(item.segments[1].text, isNull);
    expect(item.segments[1].error, contains('vision'));
    controller.dispose();
  });

  test('a hand-edited transcript survives the next segment', () async {
    final File first = await write('abc.txt', 'first fragment');
    final File second = await write('abc-1.txt', 'second fragment');
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[
        seeded(
          transcript: 'FIRST FRAGMENT, corrected by hand',
          segments: <CaptureSegment>[
            segment(0, first.path, text: 'first fragment'),
            segment(1, second.path),
          ],
        ),
      ]),
      <CaptureType, Processor>{CaptureType.text: _EchoProcessor()},
    );

    await controller.initialize();
    await controller.retryTranscription('abc');
    await controller.waitForProcessing();

    expect(
      controller.recordings.single.transcript,
      'FIRST FRAGMENT, corrected by hand\n\nsecond fragment',
    );
    controller.dispose();
  });
}
