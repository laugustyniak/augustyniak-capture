import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_service.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_context.dart';
import 'package:augustyniak_capture/features/enrichment/domain/enrichment_result.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_category.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
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

class _RefusingRepo extends _MemoryRepo {
  _RefusingRepo(super.dir, super.seed);

  @override
  Future<File> createSegmentFile(String id, int index, String extension) async {
    throw const FileSystemException('disk full');
  }
}

class _EchoProcessor implements Processor {
  @override
  Future<String> process(CaptureSegment segment) =>
      File(segment.filePath).readAsString();
}

/// Copied rather than imported across suites — the house pattern for
/// hand-written fakes.
class _FakeEnrichment implements EnrichmentService {
  _FakeEnrichment(this.result);
  EnrichmentResult result;
  int calls = 0;
  String? lastText;

  @override
  Future<EnrichmentResult> enrich(
    String text, {
    EnrichmentContext context = EnrichmentContext.none,
  }) async {
    calls++;
    lastText = text;
    return result;
  }
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
    dir = await Directory.systemTemp.createTemp('capture-append');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Recording> seedNote() async {
    final File file = File(p.join(dir.path, 'abc.txt'));
    await file.writeAsString('first fragment');
    return Recording(
      id: 'abc',
      filePath: file.path,
      createdAt: DateTime.utc(2026, 8, 28),
      durationMs: 0,
      sizeBytes: 14,
      status: RecordingStatus.completed,
      type: CaptureType.text,
      transcript: 'first fragment',
      title: 'Plan Q3',
      summary: 'A plan, as it stood before the addition.',
      tags: const <String>['budget'],
      isProcessedByUser: true,
      processedAt: DateTime.utc(2026, 8, 28),
      routes: <RouteRecord>[
        RouteRecord(
          at: DateTime.utc(2026, 8, 28, 9),
          kind: RouteKind.file,
          target: 'inbox.md',
        ),
      ],
    );
  }

  RecordingsController build(RecordingsRepository repository) {
    return RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.text: _EchoProcessor(),
      }),
    );
  }

  test('appending a note adds a segment and re-opens the capture', () async {
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('second fragment', appendTo: 'abc');
    await controller.waitForProcessing();

    expect(
      controller.recordings,
      hasLength(1),
      reason: 'an append must not create a second row',
    );
    final Recording item = controller.recordings.single;
    expect(item.segments, hasLength(2));
    expect(p.basename(item.segments[1].filePath), 'abc-1.txt');
    expect(item.segments[1].type, CaptureType.text);
    expect(item.transcript, 'first fragment\n\nsecond fragment');
    expect(
      item.isProcessedByUser,
      isFalse,
      reason: 'the text that may already have been routed is now incomplete',
    );
    expect(item.title, 'Plan Q3', reason: 'field ownership is unchanged');
    expect(item.tags, contains('budget'), reason: 'a hand tag survives');
    expect(
      item.routes,
      hasLength(1),
      reason: 'the delivery happened; a fuller text does not un-send it',
    );
    expect(item.routes.single.target, 'inbox.md');
    expect(
      item.filePath,
      endsWith('abc.txt'),
      reason: 'top-level fields still describe segment 0',
    );
    controller.dispose();
  });

  test('enrichment re-runs over the fuller text and keeps the title', () async {
    final _FakeEnrichment enrichment = _FakeEnrichment(
      const EnrichmentResult(
        title: 'A title the model would like to impose',
        summary: 'Both fragments, summarised.',
        category: CaptureCategory.note,
        tags: <String>['plan'],
      ),
    );
    final RecordingsController controller = RecordingsController(
      repository: _MemoryRepo(dir, <Recording>[await seedNote()]),
      transcriptionService: const DisabledTranscriptionService(),
      processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.text: _EchoProcessor(),
      }),
      enrichmentService: enrichment,
    );
    await controller.initialize();

    await controller.addTextNote('second fragment', appendTo: 'abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(enrichment.calls, 1, reason: 'enrichment runs once per drain');
    expect(
      enrichment.lastText,
      'first fragment\n\nsecond fragment',
      reason: 'the model sees the whole capture, not the new fragment alone',
    );
    expect(item.summary, 'Both fragments, summarised.');
    expect(
      item.title,
      'Plan Q3',
      reason: 'title is written only when blank — ownership is unchanged',
    );
    expect(
      item.tags,
      <String>['budget'],
      reason:
          'tags are fill-only, like title: a non-empty list belongs to the '
          'user, and a merge would resurrect tags they had deleted — the '
          'model list is only taken when the list is empty',
    );
    controller.dispose();
  });

  test('a fragment that cannot be written leaves the parent untouched',
      () async {
    final RecordingsController controller = build(
      _RefusingRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('second fragment', appendTo: 'abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.hasStoredSegments, isFalse);
    expect(item.transcript, 'first fragment');
    expect(item.status, RecordingStatus.completed);
    expect(item.isProcessedByUser, isTrue);
    expect(controller.error, isNotNull);
    controller.dispose();
  });

  test('appending to an id that is gone is a no-op, not a new capture',
      () async {
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('orphan', appendTo: 'nope');
    await controller.waitForProcessing();

    expect(controller.recordings, hasLength(1));
    expect(controller.recordings.single.segments, hasLength(1));
    controller.dispose();
  });

  test('a second append lands at index 2', () async {
    final RecordingsController controller = build(
      _MemoryRepo(dir, <Recording>[await seedNote()]),
    );
    await controller.initialize();

    await controller.addTextNote('second', appendTo: 'abc');
    await controller.waitForProcessing();
    await controller.addTextNote('third', appendTo: 'abc');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.segments.map((CaptureSegment s) => s.index), <int>[0, 1, 2]);
    expect(p.basename(item.segments[2].filePath), 'abc-2.txt');
    expect(item.transcript, 'first fragment\n\nsecond\n\nthird');
    controller.dispose();
  });
}
