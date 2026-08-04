import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/processing/data/video_audio_extractor.dart';
import 'package:augustyniak_capture/features/processing/data/video_transcription_processor.dart';
import 'package:augustyniak_capture/features/recordings/data/media_picker.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

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

class _StubService implements TranscriptionService {
  const _StubService(this.text);
  final String text;
  @override
  Future<String> transcribe(File audioFile) async => text;
}

class _FakeExtractor implements VideoAudioExtractor {
  _FakeExtractor(this.audio);
  final File audio;
  @override
  Future<File> extractAudio(File video) async => audio;
}

class _ThrowingExtractor implements VideoAudioExtractor {
  const _ThrowingExtractor();
  @override
  Future<File> extractAudio(File video) async => throw Exception('ffmpeg boom');
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

  group('VideoTranscriptionProcessor', () {
    test(
      'extracts audio, transcribes it, and deletes the temp audio',
      () async {
        final Directory tmp = await Directory.systemTemp.createTemp('vidproc');
        final File audio = File(p.join(tmp.path, 'audio.m4a'));
        await audio.writeAsBytes(<int>[1, 2, 3]);

        final VideoTranscriptionProcessor processor =
            VideoTranscriptionProcessor(
              () => const _StubService('VIDEO TRANSCRIPT'),
              () => _FakeExtractor(audio),
            );
        final Recording item = Recording(
          id: 'v',
          filePath: '/x/v.mp4',
          createdAt: DateTime.utc(2026),
          durationMs: 0,
          status: RecordingStatus.pendingTranscription,
          type: CaptureType.video,
        );

        expect(await processor.process(item), 'VIDEO TRANSCRIPT');
        expect(tmp.existsSync(), isFalse); // derived temp cleaned up
      },
    );

    test('propagates extractor failure', () async {
      final VideoTranscriptionProcessor processor = VideoTranscriptionProcessor(
        () => const _StubService('x'),
        () => const _ThrowingExtractor(),
      );
      final Recording item = Recording(
        id: 'v',
        filePath: '/x/v.mp4',
        createdAt: DateTime.utc(2026),
        durationMs: 0,
        status: RecordingStatus.pendingTranscription,
        type: CaptureType.video,
      );
      await expectLater(processor.process(item), throwsException);
    });
  });

  group('FfmpegVideoAudioExtractor error paths', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ffmpeg'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('missing video file throws FileSystemException', () {
      expect(
        () => const FfmpegVideoAudioExtractor().extractAudio(
          File(p.join(tmp.path, 'nope.mp4')),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('missing ffmpeg binary throws ProcessException', () async {
      final File vid = File(p.join(tmp.path, 'v.mp4'));
      await vid.writeAsBytes(<int>[1, 2, 3]);
      expect(
        () => const FfmpegVideoAudioExtractor(
          executable: 'ffmpeg_definitely_absent',
        ).extractAudio(vid),
        throwsA(isA<ProcessException>()),
      );
    });

    test('a missing binary leaves no temp directory behind', () async {
      final File vid = File(p.join(tmp.path, 'v.mp4'));
      await vid.writeAsBytes(<int>[1, 2, 3]);

      // The extractor creates its scratch dir before invoking ffmpeg, so a
      // throwing `Process.run` — the normal path on a machine without ffmpeg —
      // must still clean it up rather than leaking one dir per failed video.
      int scratchDirs() => Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where(
            (Directory dir) => p
                .basename(dir.path)
                .startsWith('augustyniak-capture-video-audio'),
          )
          .length;

      final int before = scratchDirs();
      await expectLater(
        const FfmpegVideoAudioExtractor(
          executable: 'ffmpeg_definitely_absent',
        ).extractAudio(vid),
        throwsA(isA<ProcessException>()),
      );

      expect(scratchDirs(), before);
    });
  });

  group('video ingestion routes to extract+transcribe (real upload path)', () {
    test(
      'a picked video is imported and its transcript lands on the item',
      () async {
        final Directory tmp = await Directory.systemTemp.createTemp(
          'vid_ingest',
        );
        final File src = File(p.join(tmp.path, 'clip.mp4'));
        await src.writeAsBytes(<int>[0, 0, 0, 0x18, 1, 2, 3]);
        final Directory audioDir = await Directory.systemTemp.createTemp(
          'vid_audio',
        );
        final File extracted = File(p.join(audioDir.path, 'audio.m4a'));
        await extracted.writeAsBytes(<int>[9, 9, 9]);

        final RecordingsController controller = RecordingsController(
          repository: _FakeRepo(tmp),
          transcriptionService: const _StubService('napisy z wideo'),
          videoAudioExtractor: _FakeExtractor(extracted),
          mediaPicker: _FakePicker(
            PickedMedia(file: src, mimeType: 'video/mp4'),
          ),
        );
        addTearDown(controller.dispose);

        await controller.addUpload(CaptureType.video);
        await controller.waitForProcessing();

        final Recording item = controller.recordings.single;
        expect(item.type, CaptureType.video);
        expect(item.status, RecordingStatus.completed);
        expect(item.transcript, 'napisy z wideo');
        expect(File(item.filePath).existsSync(), isTrue);
      },
    );

    test(
      'extraction failure leaves the video failed with the source intact',
      () async {
        final Directory tmp = await Directory.systemTemp.createTemp('vid_fail');
        final File src = File(p.join(tmp.path, 'clip.mp4'));
        await src.writeAsBytes(<int>[0, 0, 0, 0x18, 1, 2, 3]);

        final RecordingsController controller = RecordingsController(
          repository: _FakeRepo(tmp),
          transcriptionService: const _StubService('x'),
          videoAudioExtractor: const _ThrowingExtractor(),
          mediaPicker: _FakePicker(
            PickedMedia(file: src, mimeType: 'video/mp4'),
          ),
        );
        addTearDown(controller.dispose);

        await controller.addUpload(CaptureType.video);
        await controller.waitForProcessing();

        final Recording item = controller.recordings.single;
        expect(item.status, RecordingStatus.failed);
        expect(item.error, isNotNull);
        expect(File(item.filePath).existsSync(), isTrue);
      },
    );
  });
}
