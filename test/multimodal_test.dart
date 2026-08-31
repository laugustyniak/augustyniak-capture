import 'package:flutter_test/flutter_test.dart';
import 'package:augustyniak_capture/features/processing/data/ocr_processor.dart';
import 'package:augustyniak_capture/features/processing/data/video_transcription_processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor.dart';
import 'package:augustyniak_capture/features/processing/domain/processor_registry.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

void main() {
  group('CaptureType', () {
    test('fromName resolves every known value', () {
      for (final CaptureType type in CaptureType.values) {
        expect(CaptureType.fromName(type.name), type);
      }
    });

    test('fromName defaults null and unknown values to audioRecording', () {
      expect(CaptureType.fromName(null), CaptureType.audioRecording);
      expect(CaptureType.fromName('hologram'), CaptureType.audioRecording);
      expect(CaptureType.fromName(''), CaptureType.audioRecording);
    });

    test('isPlayableAudio is true only for audio types', () {
      expect(CaptureType.audioRecording.isPlayableAudio, isTrue);
      expect(CaptureType.audioUpload.isPlayableAudio, isTrue);
      expect(CaptureType.text.isPlayableAudio, isFalse);
      expect(CaptureType.image.isPlayableAudio, isFalse);
      expect(CaptureType.video.isPlayableAudio, isFalse);
    });
  });

  group('RecordingsRepository.extensionFor', () {
    test('fixed extensions for recordings and text', () {
      expect(
        RecordingsRepository.extensionFor(CaptureType.audioRecording),
        'm4a',
      );
      expect(RecordingsRepository.extensionFor(CaptureType.text), 'txt');
    });

    test('derives from mime with a per-type fallback', () {
      expect(
        RecordingsRepository.extensionFor(
          CaptureType.image,
          sourceMimeType: 'image/png',
        ),
        'png',
      );
      expect(RecordingsRepository.extensionFor(CaptureType.image), 'jpg');
      expect(
        RecordingsRepository.extensionFor(
          CaptureType.audioUpload,
          sourceMimeType: 'audio/mpeg',
        ),
        'mp3',
      );
      expect(RecordingsRepository.extensionFor(CaptureType.audioUpload), 'm4a');
      expect(
        RecordingsRepository.extensionFor(
          CaptureType.video,
          sourceMimeType: 'video/quicktime',
        ),
        'mov',
      );
      expect(RecordingsRepository.extensionFor(CaptureType.video), 'mp4');
    });
  });

  group('Recording multimodal fields', () {
    test('round-trip preserves type and sourceMimeType', () {
      final Recording original = Recording(
        id: 'img1',
        filePath: '/docs/img1.jpg',
        createdAt: DateTime.utc(2026, 7, 25),
        durationMs: 0,
        status: RecordingStatus.completed,
        transcript: 'OCR text',
        type: CaptureType.image,
        sourceMimeType: 'image/jpeg',
      );

      final Recording restored = Recording.fromJson(original.toJson());

      expect(restored.type, CaptureType.image);
      expect(restored.sourceMimeType, 'image/jpeg');
      expect(restored.transcript, 'OCR text');
    });

    test('legacy JSON with no type defaults to audioRecording', () {
      final Recording restored = Recording.fromJson(<String, dynamic>{
        'id': 'legacy',
        'filePath': '/docs/legacy.m4a',
        'createdAt': DateTime.utc(2026, 7, 20).toIso8601String(),
        'durationMs': 900,
        'status': RecordingStatus.completed.name,
        'transcript': 'hi',
      });

      expect(restored.type, CaptureType.audioRecording);
      expect(restored.sourceMimeType, isNull);
    });

    test(
      'copyWith carries type and sourceMimeType through a status change',
      () {
        final Recording original = Recording(
          id: 't',
          filePath: '/docs/t.txt',
          createdAt: DateTime.utc(2026, 7, 25),
          durationMs: 0,
          status: RecordingStatus.saved,
          type: CaptureType.text,
          sourceMimeType: 'text/plain',
        );
        final Recording updated = original.copyWith(
          status: RecordingStatus.completed,
        );

        expect(updated.type, CaptureType.text);
        expect(updated.sourceMimeType, 'text/plain');
        expect(updated.status, RecordingStatus.completed);
      },
    );
  });

  group('ProcessorRegistry.standard', () {
    ProcessorRegistry build() => ProcessorRegistry.standard(
      transcriptionService: () => const DisabledTranscriptionService(),
    );

    test('dispatches text to the passthrough processor', () {
      expect(
        build().forType(CaptureType.text),
        isA<TextPassthroughProcessor>(),
      );
    });

    test('image routes to OCR, video routes to the video processor', () {
      expect(build().forType(CaptureType.image), isA<OcrProcessor>());
      expect(
        build().forType(CaptureType.video),
        isA<VideoTranscriptionProcessor>(),
      );
    });

    test('default OCR service is disabled and degrades cleanly', () async {
      final Recording item = Recording(
        id: 'i',
        filePath: '/docs/i.jpg',
        createdAt: DateTime.utc(2026),
        durationMs: 0,
        status: RecordingStatus.pendingTranscription,
        type: CaptureType.image,
      );
      await expectLater(
        build().forType(CaptureType.image).process(item.segments.first),
        throwsA(isA<ProcessorNotConfiguredException>()),
      );
    });

    test(
      'default video extractor is unavailable and degrades cleanly',
      () async {
        final Recording item = Recording(
          id: 'v',
          filePath: '/docs/v.mp4',
          createdAt: DateTime.utc(2026),
          durationMs: 0,
          status: RecordingStatus.pendingTranscription,
          type: CaptureType.video,
        );
        await expectLater(
          build().forType(CaptureType.video).process(item.segments.first),
          throwsA(isA<ProcessorNotConfiguredException>()),
        );
      },
    );
  });
}
