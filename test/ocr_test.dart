import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:audivoa_core/features/processing/data/ocr_processor.dart';
import 'package:audivoa_core/features/processing/data/ocr_service.dart';
import 'package:audivoa_core/features/processing/domain/processor.dart';
import 'package:audivoa_core/features/recordings/data/media_picker.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._dir);
  final Directory _dir;
  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => <Recording>[];
  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

class _FakePicker implements MediaPicker {
  const _FakePicker(this.media);
  final PickedMedia? media;
  @override
  Future<PickedMedia?> pick(CaptureType type) async => media;
}

class _StubOcr implements OcrService {
  const _StubOcr(this.text);
  final String text;
  @override
  Future<String> extractText(File image) async => text;
}

class _ThrowingOcr implements OcrService {
  const _ThrowingOcr();
  @override
  Future<String> extractText(File image) async => throw Exception('ocr boom');
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
        MethodChannel(name), (MethodCall call) async => null);
  }

  group('OcrProcessor', () {
    test('reads the image via the current service and returns its text',
        () async {
      final OcrProcessor processor = OcrProcessor(() => const _StubOcr('OCR!'));
      final Recording item = Recording(
        id: 'i',
        filePath: '/x/i.jpg',
        createdAt: DateTime.utc(2026),
        durationMs: 0,
        status: RecordingStatus.pendingTranscription,
        type: CaptureType.image,
      );
      expect(await processor.process(item), 'OCR!');
    });
  });

  group('DisabledOcrService', () {
    test('throws ProcessorNotConfiguredException', () {
      expect(
        () => const DisabledOcrService().extractText(File('/x/i.jpg')),
        throwsA(isA<ProcessorNotConfiguredException>()),
      );
    });
  });

  group('TesseractOcrService error paths', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ocr'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('missing image file throws FileSystemException', () {
      expect(
        () => const TesseractOcrService()
            .extractText(File(p.join(tmp.path, 'nope.png'))),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('missing tesseract binary throws ProcessException', () async {
      final File img = File(p.join(tmp.path, 'x.png'));
      await img.writeAsBytes(<int>[1, 2, 3]);
      expect(
        () => const TesseractOcrService(executable: 'tesseract_definitely_absent')
            .extractText(img),
        throwsA(isA<ProcessException>()),
      );
    });
  });

  group('image ingestion routes to OCR (through the real upload path)', () {
    test('a picked image is imported and OCR text lands on the item', () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('ocr_ingest');
      final File src = File(p.join(tmp.path, 'photo.png'));
      await src.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const DisabledTranscriptionService(),
        ocrService: const _StubOcr('rozpoznany tekst'),
        mediaPicker: _FakePicker(
          PickedMedia(file: src, mimeType: 'image/png'),
        ),
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.image);
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.type, CaptureType.image);
      expect(item.status, RecordingStatus.completed);
      expect(item.transcript, 'rozpoznany tekst');
      expect(File(item.filePath).existsSync(), isTrue);
    });

    test('OCR failure leaves the image failed with the source intact',
        () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('ocr_fail');
      final File src = File(p.join(tmp.path, 'photo.png'));
      await src.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const DisabledTranscriptionService(),
        ocrService: const _ThrowingOcr(),
        mediaPicker: _FakePicker(
          PickedMedia(file: src, mimeType: 'image/png'),
        ),
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.image);
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.status, RecordingStatus.failed);
      expect(item.error, isNotNull);
      expect(File(item.filePath).existsSync(), isTrue);
    });

    test('a swapped OCR service only affects the next job', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('ocr_swap');
      final File src = File(p.join(tmp.path, 'photo.png'));
      await src.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const DisabledTranscriptionService(),
        ocrService: const _StubOcr('first engine'),
        mediaPicker: _FakePicker(
          PickedMedia(file: src, mimeType: 'image/png'),
        ),
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.image);
      await controller.waitForProcessing();
      expect(controller.recordings.single.transcript, 'first engine');

      // Models-tab change: the resolver picks the new service up for the
      // retry without rebuilding the registry.
      controller.ocrService = const _StubOcr('second engine');
      await controller.retryTranscription(controller.recordings.single.id);
      await controller.waitForProcessing();

      expect(controller.recordings.single.transcript, 'second engine');
    });
  });
}
