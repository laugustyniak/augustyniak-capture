import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:audivoa_core/features/processing/data/video_audio_extractor.dart';
import 'package:audivoa_core/features/processing/data/video_poster_extractor.dart';
import 'package:audivoa_core/features/recordings/data/media_picker.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/media_opener.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

class _FakeRepo extends RecordingsRepository {
  _FakeRepo(this._dir, [this._seed = const <Recording>[]]);
  final Directory _dir;

  /// What a previous session left in `recordings.json`.
  final List<Recording> _seed;

  /// The last index written, so a test can assert the backfill persisted.
  List<Recording> saved = <Recording>[];

  @override
  Future<Directory> recordingsDirectory() async => _dir;
  @override
  Future<List<Recording>> loadAll() async => List<Recording>.of(_seed);
  @override
  Future<void> saveAll(List<Recording> recordings) async =>
      saved = List<Recording>.of(recordings);
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

class _FakeAudioExtractor implements VideoAudioExtractor {
  _FakeAudioExtractor(this.audio);
  final File audio;
  @override
  Future<File> extractAudio(File video) async => audio;
}

class _ThrowingAudioExtractor implements VideoAudioExtractor {
  const _ThrowingAudioExtractor();
  @override
  Future<File> extractAudio(File video) async => throw Exception('ffmpeg boom');
}

/// Writes a real (tiny) file at the destination so the "already has a poster"
/// short-circuit has something to find on disk, and counts its invocations.
class _FakePosterExtractor implements VideoPosterExtractor {
  int calls = 0;
  @override
  Future<File> extractPoster(File video, File destination) async {
    calls++;
    await destination.writeAsBytes(<int>[0xFF, 0xD8, 0xFF]);
    return destination;
  }
}

class _ThrowingPosterExtractor implements VideoPosterExtractor {
  const _ThrowingPosterExtractor();
  @override
  Future<File> extractPoster(File video, File destination) async =>
      throw Exception('no ffmpeg');
}

class _FakeOpener implements MediaOpener {
  final List<String> opened = <String>[];
  @override
  Future<void> open(String path) async => opened.add(path);
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

  /// A recordings directory holding a fake video source, plus the "extracted"
  /// audio the transcription half of the video pipeline expects.
  ///
  /// The audio deliberately lives in a **separate** directory:
  /// `VideoTranscriptionProcessor` deletes the parent of whatever the audio
  /// extractor hands it, so putting it next to the source would take the source
  /// and the poster down with it.
  Future<(Directory, File, File)> videoFixture(String prefix) async {
    final Directory tmp = await Directory.systemTemp.createTemp(prefix);
    final File src = File(p.join(tmp.path, 'clip.mp4'));
    await src.writeAsBytes(<int>[0, 0, 0, 0x18, 1, 2, 3]);
    final Directory audioDir =
        await Directory.systemTemp.createTemp('${prefix}_audio');
    final File audio = File(p.join(audioDir.path, 'audio.m4a'));
    await audio.writeAsBytes(<int>[9, 9, 9]);
    return (tmp, src, audio);
  }

  group('poster extraction during processing', () {
    test('a processed video ends with a poster on the item', () async {
      final (Directory tmp, File src, File audio) =
          await videoFixture('poster_ok');
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const _StubService('transcript'),
        videoAudioExtractor: _FakeAudioExtractor(audio),
        videoPosterExtractor: poster,
        mediaPicker: _FakePicker(PickedMedia(file: src, mimeType: 'video/mp4')),
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.video);
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.status, RecordingStatus.completed);
      expect(item.thumbPath, isNotNull);
      expect(File(item.thumbPath!).existsSync(), isTrue);
      expect(poster.calls, 1);
    });

    test('a failing poster extractor still leaves the item completed',
        () async {
      // The core invariant: the poster is derived, best-effort and last in
      // importance. Nothing about it may reach `status`.
      final (Directory tmp, File src, File audio) =
          await videoFixture('poster_throws');

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const _StubService('transcript'),
        videoAudioExtractor: _FakeAudioExtractor(audio),
        videoPosterExtractor: const _ThrowingPosterExtractor(),
        mediaPicker: _FakePicker(PickedMedia(file: src, mimeType: 'video/mp4')),
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.video);
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.status, RecordingStatus.completed);
      expect(item.transcript, 'transcript');
      expect(item.thumbPath, isNull);
      expect(item.error, isNull);
    });

    test('a video whose processor fails still gets its poster', () async {
      // The other half of the same rule: a video that could not be transcribed
      // is exactly the one the user needs to recognise in the queue.
      final (Directory tmp, File src, File _) =
          await videoFixture('poster_proc_fails');
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const _StubService('x'),
        videoAudioExtractor: const _ThrowingAudioExtractor(),
        videoPosterExtractor: poster,
        mediaPicker: _FakePicker(PickedMedia(file: src, mimeType: 'video/mp4')),
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.video);
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.status, RecordingStatus.failed);
      expect(item.error, isNotNull);
      expect(item.thumbPath, isNotNull);
      expect(File(item.thumbPath!).existsSync(), isTrue);
      expect(poster.calls, 1);
    });

    test('a retry does not re-extract a poster that is still on disk',
        () async {
      final (Directory tmp, File src, File audio) =
          await videoFixture('poster_retry');
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const _StubService('transcript'),
        videoAudioExtractor: _FakeAudioExtractor(audio),
        videoPosterExtractor: poster,
        mediaPicker: _FakePicker(PickedMedia(file: src, mimeType: 'video/mp4')),
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.video);
      await controller.waitForProcessing();
      expect(poster.calls, 1);

      await controller.retryTranscription(controller.recordings.single.id);
      await controller.waitForProcessing();

      expect(poster.calls, 1); // ffmpeg is not re-shelled for the same frame
      expect(controller.recordings.single.thumbPath, isNotNull);
    });

    test('a non-video item never touches the extractor', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('poster_note');
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const _StubService('unused'),
        videoPosterExtractor: poster,
      );
      addTearDown(controller.dispose);

      await controller.addTextNote('a note');
      await controller.waitForProcessing();

      expect(poster.calls, 0);
      expect(controller.recordings.single.thumbPath, isNull);
    });
  });

  group('poster backfill on startup', () {
    /// A recordings directory holding an already-ingested video source, as a
    /// previous session would have left it.
    Future<(Directory, Recording)> settled(
      String prefix, {
      RecordingStatus status = RecordingStatus.completed,
      String? thumbPath,
    }) async {
      final Directory tmp = await Directory.systemTemp.createTemp(prefix);
      final File src = File(p.join(tmp.path, 'old.mp4'));
      await src.writeAsBytes(<int>[0, 0, 0, 0x18, 1, 2, 3]);
      return (
        tmp,
        Recording(
          id: 'old',
          filePath: src.path,
          createdAt: DateTime(2024),
          durationMs: 1000,
          status: status,
          type: CaptureType.video,
          sourceMimeType: 'video/mp4',
          transcript: 'from a previous session',
          thumbPath: thumbPath,
        ),
      );
    }

    test('a video completed before posters existed gets one at startup',
        () async {
      // The acceptance criterion is "video cards show a poster", and an item
      // that already succeeded never re-enters the processing queue — so
      // without the backfill it would show the movie glyph forever.
      final (Directory tmp, Recording old) = await settled('backfill_old');
      final _FakeRepo repo = _FakeRepo(tmp, <Recording>[old]);
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: repo,
        transcriptionService: const _StubService('unused'),
        videoPosterExtractor: poster,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(poster.calls, 1);
      expect(item.thumbPath, isNotNull);
      expect(File(item.thumbPath!).existsSync(), isTrue);
      // Best-effort means best-effort: the status axis is untouched.
      expect(item.status, RecordingStatus.completed);
      expect(item.transcript, 'from a previous session');
      // And the claim is durable, or the next launch would extract it again.
      expect(repo.saved.single.thumbPath, item.thumbPath);
    });

    test('a poster file deleted since the last run is re-extracted', () async {
      final (Directory tmp, Recording old) = await settled(
        'backfill_gone',
        thumbPath: p.join(Directory.systemTemp.path, 'not-here.thumb.jpg'),
      );
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp, <Recording>[old]),
        transcriptionService: const _StubService('unused'),
        videoPosterExtractor: poster,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      expect(poster.calls, 1);
      expect(File(controller.recordings.single.thumbPath!).existsSync(), isTrue);
    });

    test('a poster still on disk is left alone', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('backfill_ok');
      final File src = File(p.join(tmp.path, 'old.mp4'));
      await src.writeAsBytes(<int>[0, 0, 0, 0x18, 1, 2, 3]);
      final File existing = File(p.join(tmp.path, 'old.thumb.jpg'));
      await existing.writeAsBytes(<int>[0xFF, 0xD8, 0xFF]);
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp, <Recording>[
          Recording(
            id: 'old',
            filePath: src.path,
            createdAt: DateTime(2024),
            durationMs: 1000,
            status: RecordingStatus.completed,
            type: CaptureType.video,
            thumbPath: existing.path,
          ),
        ]),
        transcriptionService: const _StubService('unused'),
        videoPosterExtractor: poster,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      expect(poster.calls, 0); // one stat, no ffmpeg
    });

    test('the backfill and the resumed drain never both shell ffmpeg',
        () async {
      // A video left mid-processing is re-enqueued by `initialize`, so both the
      // drain loop and the backfill reach for the same `<id>.thumb.jpg`. Two
      // concurrent ffmpeg runs onto one destination is exactly what the
      // in-flight mutex exists to prevent.
      final (Directory tmp, Recording old) = await settled(
        'backfill_stuck',
        status: RecordingStatus.transcribing,
      );
      final Directory audioDir =
          await Directory.systemTemp.createTemp('backfill_stuck_audio');
      final File audio = File(p.join(audioDir.path, 'audio.m4a'));
      await audio.writeAsBytes(<int>[9, 9, 9]);
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp, <Recording>[old]),
        transcriptionService: const _StubService('transcript'),
        videoAudioExtractor: _FakeAudioExtractor(audio),
        videoPosterExtractor: poster,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      expect(poster.calls, 1);
      final Recording item = controller.recordings.single;
      expect(item.status, RecordingStatus.completed);
      expect(item.thumbPath, isNotNull);
    });

    test('a non-video item is never backfilled', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('backfill_txt');
      final File src = File(p.join(tmp.path, 'note.txt'));
      await src.writeAsString('body');
      final _FakePosterExtractor poster = _FakePosterExtractor();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp, <Recording>[
          Recording(
            id: 'note',
            filePath: src.path,
            createdAt: DateTime(2024),
            durationMs: 0,
            status: RecordingStatus.completed,
            type: CaptureType.text,
          ),
        ]),
        transcriptionService: const _StubService('unused'),
        videoPosterExtractor: poster,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      expect(poster.calls, 0);
    });
  });

  group('FfmpegVideoPosterExtractor error paths', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ffposter'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a missing video file throws FileSystemException', () {
      expect(
        () => const FfmpegVideoPosterExtractor().extractPoster(
          File(p.join(tmp.path, 'nope.mp4')),
          File(p.join(tmp.path, 'nope.thumb.jpg')),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a missing binary throws and leaves no partial poster behind',
        () async {
      final File video = File(p.join(tmp.path, 'v.mp4'));
      await video.writeAsBytes(<int>[1, 2, 3]);
      final File destination = File(p.join(tmp.path, 'v.thumb.jpg'));

      await expectLater(
        const FfmpegVideoPosterExtractor(
          executable: 'ffmpeg_definitely_absent',
        ).extractPoster(video, destination),
        throwsA(isA<ProcessException>()),
      );

      // A zero-length poster would be persisted as `thumbPath` and render as a
      // permanently broken image, so a failure must leave nothing at all.
      expect(destination.existsSync(), isFalse);
    });
  });

  group('openSource', () {
    test('hands the item source path to the opener', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('open_ok');
      final File src = File(p.join(tmp.path, 'clip.mp4'));
      await src.writeAsBytes(<int>[0, 0, 0, 0x18, 1, 2, 3]);
      final _FakeOpener opener = _FakeOpener();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const _StubService('x'),
        videoAudioExtractor: const _ThrowingAudioExtractor(),
        mediaPicker: _FakePicker(PickedMedia(file: src, mimeType: 'video/mp4')),
        mediaOpener: opener,
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.video);
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      await controller.openSource(item.id);

      expect(opener.opened, <String>[item.filePath]);
      expect(controller.error, isNull);
    });

    test('a missing source sets the error and never reaches the opener',
        () async {
      final Directory tmp = await Directory.systemTemp.createTemp('open_gone');
      final File src = File(p.join(tmp.path, 'clip.mp4'));
      await src.writeAsBytes(<int>[0, 0, 0, 0x18, 1, 2, 3]);
      final _FakeOpener opener = _FakeOpener();

      final RecordingsController controller = RecordingsController(
        repository: _FakeRepo(tmp),
        transcriptionService: const _StubService('x'),
        videoAudioExtractor: const _ThrowingAudioExtractor(),
        mediaPicker: _FakePicker(PickedMedia(file: src, mimeType: 'video/mp4')),
        mediaOpener: opener,
      );
      addTearDown(controller.dispose);

      await controller.addUpload(CaptureType.video);
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      await File(item.filePath).delete();
      await controller.openSource(item.id);

      expect(opener.opened, isEmpty);
      expect(controller.error, contains('Source file is missing'));
    });
  });
}
