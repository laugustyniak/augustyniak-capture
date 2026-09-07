import 'dart:async';
import 'dart:io';

import 'package:augustyniak_capture/features/processing/data/ocr_processor.dart';
import 'package:augustyniak_capture/features/processing/data/ocr_service.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _MemoryRepo extends RecordingsRepository {
  _MemoryRepo(this._dir, this.seed);
  final Directory _dir;
  final List<Recording> seed;
  List<Recording> saved = <Recording>[];

  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => List<Recording>.from(seed);
  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saved = List<Recording>.from(recordings);
  }
}

class _GatedTranscriptionService implements TranscriptionService {
  final Completer<void> gate = Completer<void>();
  bool called = false;

  @override
  Future<String> transcribe(File audioFile) async {
    called = true;
    await gate.future;
    return 'LATE TRANSCRIPTION RESULT';
  }
}

class _GatedOcrService implements OcrService {
  final Completer<void> gate = Completer<void>();
  bool called = false;

  @override
  Future<String> extractText(File image) async {
    called = true;
    await gate.future;
    return 'LATE OCR RESULT';
  }
}

class _InstantTranscriptionService implements TranscriptionService {
  const _InstantTranscriptionService(this.text);
  final String text;

  @override
  Future<String> transcribe(File audioFile) async => text;
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
    dir = await Directory.systemTemp.createTemp('cancel-processing-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> writeSource(String name, String content) async {
    final File file = File(p.join(dir.path, name));
    await file.writeAsString(content);
    return file;
  }

  Recording makeItem({
    required String id,
    required File file,
    CaptureType type = CaptureType.audioRecording,
    RecordingStatus status = RecordingStatus.saved,
  }) {
    return Recording(
      id: id,
      filePath: file.path,
      createdAt: DateTime.utc(2026, 9, 7),
      durationMs: 5000,
      sizeBytes: 100,
      status: status,
      type: type,
      segments: <CaptureSegment>[
        CaptureSegment(
          index: 0,
          filePath: file.path,
          type: type,
          createdAt: DateTime.utc(2026, 9, 7),
          sizeBytes: 100,
        ),
      ],
    );
  }

  test('cancelling a queued job removes it from the queue and marks it failed',
      () async {
    final File file = await writeSource('audio.m4a', 'audio-content');
    final Recording recording = makeItem(id: 'rec_queued', file: file);
    final _GatedTranscriptionService gated = _GatedTranscriptionService();
    final RecordingsController controller = RecordingsController(
      repository: _MemoryRepo(dir, <Recording>[recording]),
      transcriptionService: gated,
    );
    await controller.initialize();

    await controller.retryTranscription('rec_queued');

    // Cancel while in-flight or queued
    await controller.cancelProcessing('rec_queued');

    final Recording item =
        controller.recordings.firstWhere((Recording r) => r.id == 'rec_queued');
    expect(item.status, RecordingStatus.failed);
    expect(item.error, 'Cancelled by user');

    // Unblock any gated service and dispose
    gated.gate.complete();
    controller.dispose();
  });

  test('cancelling in-flight transcription marks recording failed and ignores late arrival',
      () async {
    final File file = await writeSource('voice.m4a', 'audio-data');
    final Recording recording = makeItem(id: 'rec_transcribing', file: file);
    final _GatedTranscriptionService gated = _GatedTranscriptionService();
    final RecordingsController controller = RecordingsController(
      repository: _MemoryRepo(dir, <Recording>[recording]),
      transcriptionService: gated,
    );
    await controller.initialize();

    // Trigger processing
    await controller.retryTranscription('rec_transcribing');
    await pumpEventQueue();

    // Wait until gated transcribe is actively called
    expect(gated.called, isTrue);
    expect(controller.isProcessing, isTrue);

    // Elapsed duration should be active
    final Duration? elapsed = controller.processingElapsedFor('rec_transcribing');
    expect(elapsed, isNotNull);

    // Cancel processing while in-flight
    await controller.cancelProcessing('rec_transcribing');

    final Recording cancelledItem = controller.recordings.single;
    expect(cancelledItem.status, RecordingStatus.failed);
    expect(cancelledItem.error, 'Cancelled by user');
    expect(controller.processingElapsedFor('rec_transcribing'), isNull);

    // Let late HTTP / transcription response complete
    gated.gate.complete();
    await pumpEventQueue();

    // Late arrival must not overwrite the failed status or populate transcript
    final Recording afterLate = controller.recordings.single;
    expect(afterLate.status, RecordingStatus.failed);
    expect(afterLate.error, 'Cancelled by user');
    expect(afterLate.transcript, isNull);

    controller.dispose();
  });

  test('cancelling in-flight OCR job marks recording failed and preserves source',
      () async {
    final File imageFile = await writeSource('photo.jpg', 'fake-image-bytes');
    final Recording recording = makeItem(
      id: 'rec_ocr',
      file: imageFile,
      type: CaptureType.image,
    );
    final _GatedOcrService gatedOcr = _GatedOcrService();
    final RecordingsController controller = RecordingsController(
      repository: _MemoryRepo(dir, <Recording>[recording]),
      transcriptionService: const DisabledTranscriptionService(),
      ocrService: gatedOcr,
      processorRegistry: ProcessorRegistry(<CaptureType, Processor>{
        CaptureType.image: OcrProcessor(() => gatedOcr),
      }),
    );
    await controller.initialize();

    // Start OCR processing
    await controller.retryTranscription('rec_ocr');
    await pumpEventQueue();

    expect(gatedOcr.called, isTrue);
    expect(controller.processingElapsedFor('rec_ocr'), isNotNull);

    // Cancel OCR
    await controller.cancelProcessing('rec_ocr');

    final Recording cancelledOcr = controller.recordings.single;
    expect(cancelledOcr.status, RecordingStatus.failed);
    expect(cancelledOcr.error, 'Cancelled by user');

    // Unblock late response
    gatedOcr.gate.complete();
    await pumpEventQueue();

    // Source image file must remain intact on disk
    expect(imageFile.existsSync(), isTrue);
    expect(controller.recordings.single.transcript, isNull);
    expect(controller.recordings.single.status, RecordingStatus.failed);

    controller.dispose();
  });

  test('cancelled capture is fully retryable', () async {
    final File file = await writeSource('retryable.m4a', 'audio-bits');
    final Recording recording = makeItem(id: 'rec_retry', file: file);
    final _GatedTranscriptionService gated = _GatedTranscriptionService();
    final RecordingsController controller = RecordingsController(
      repository: _MemoryRepo(dir, <Recording>[recording]),
      transcriptionService: gated,
    );
    await controller.initialize();

    await controller.retryTranscription('rec_retry');
    await pumpEventQueue();
    await controller.cancelProcessing('rec_retry');
    gated.gate.complete();
    await pumpEventQueue();

    expect(controller.recordings.single.status, RecordingStatus.failed);
    expect(controller.recordings.single.error, 'Cancelled by user');

    // Swap in an instant transcription service and retry
    controller.transcriptionService =
        const _InstantTranscriptionService('SUCCESSFUL RETRY TRANSCRIPT');

    await controller.retryTranscription('rec_retry');
    await controller.waitForProcessing();

    final Recording retriedItem = controller.recordings.single;
    expect(retriedItem.status, RecordingStatus.completed);
    expect(retriedItem.transcript, 'SUCCESSFUL RETRY TRANSCRIPT');
    expect(retriedItem.error, isNull);

    controller.dispose();
  });
}
