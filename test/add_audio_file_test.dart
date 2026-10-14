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

/// Repository that keeps the index in memory and points source files at a temp
/// dir — no path_provider, no real recordings.json.
class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  List<Recording> saved = <Recording>[];
  int saveCalls = 0;

  /// One entry per `saveAll`: was the newest item's source file already on disk
  /// when the index was written, and what status did it carry? This pins the
  /// ordering invariant; the end state alone cannot tell copy-then-index apart
  /// from index-then-copy.
  final List<bool> sourcePresentAtSave = <bool>[];
  final List<RecordingStatus> statusAtSave = <RecordingStatus>[];

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCalls++;
    if (recordings.isNotEmpty) {
      sourcePresentAtSave.add(File(recordings.first.filePath).existsSync());
      statusAtSave.add(recordings.first.status);
    }
    saved = List<Recording>.from(recordings);
  }
}

class _FakePicker implements MediaPicker {
  @override
  Future<PickedMedia?> pick(CaptureType type) async => null;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakeRecorder implements AudioRecorder {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

RecordingsController buildController(RecordingsRepository repo) {
  return RecordingsController(
    repository: repo,
    transcriptionService: const DisabledTranscriptionService(),
    mediaPicker: _FakePicker(),
    recorder: _FakeRecorder(),
    player: _FakePlayer(),
  );
}

void main() {
  const String id = '123e4567-e89b-42d3-a456-426614174000';
  late Directory appDir;
  late Directory inbox;

  File car(String name, String content) =>
      File(p.join(inbox.path, name))..writeAsStringSync(content);

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak_capture_audio_');
    inbox = Directory(p.join(appDir.path, 'inbox'))..createSync();
  });

  tearDown(() => appDir.deleteSync(recursive: true));

  test(
    'the index is written after the copy, as saved, before processing',
    () async {
      final File source = car('$id.m4a', 'AAC-BYTES');
      final _FakeRepository repo = _FakeRepository(appDir);
      final RecordingsController controller = buildController(repo);
      await controller.initialize();

      expect(await controller.addAudioFile(id, source), isTrue);
      await controller.waitForProcessing();

      expect(repo.sourcePresentAtSave.first, isTrue);
      expect(repo.statusAtSave.first, RecordingStatus.saved);
      expect(repo.saved.single.id, id);
      controller.dispose();
    },
  );

  test('an existing id returns true and writes nothing', () async {
    final File source = car('$id.m4a', 'AAC-BYTES');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    expect(await controller.addAudioFile(id, source), isTrue);
    await controller.waitForProcessing();
    final int calls = repo.saveCalls;
    expect(await controller.addAudioFile(id, source), isTrue);
    await controller.waitForProcessing();
    expect(repo.saveCalls, calls);
    expect(controller.recordings, hasLength(1));
    controller.dispose();
  });

  test(
    'before initialize it returns false, writes nothing, sets error',
    () async {
      final File source = car('$id.m4a', 'AAC-BYTES');
      final _FakeRepository repo = _FakeRepository(appDir);
      final RecordingsController controller = buildController(repo);

      expect(await controller.addAudioFile(id, source), isFalse);
      expect(controller.error, contains('still loading'));
      expect(repo.saveCalls, 0);
      controller.dispose();
    },
  );

  test('returns false while another capture holds the busy lock', () async {
    final File source = car('$id.m4a', 'AAC-BYTES');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    final Future<bool> first = controller.addTextNote('one');
    expect(await controller.addAudioFile(id, source), isFalse);
    expect(await first, isTrue);
    await controller.waitForProcessing();
    expect(repo.saved, hasLength(1));
    controller.dispose();
  });

  test('a zero-length source returns false with no index row', () async {
    final File source = car('$id.m4a', '');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    expect(await controller.addAudioFile(id, source), isFalse);
    expect(repo.saved, isEmpty);
    expect(controller.recordings, isEmpty);
    expect(controller.isBusy, isFalse);
    expect(controller.error, isNotNull);
    controller.dispose();
  });

  test('the stored file is .m4a and the type is audioRecording', () async {
    final File source = car('$id.m4a', 'AAC-BYTES');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    await controller.addAudioFile(id, source);
    await controller.waitForProcessing();
    final Recording r = repo.saved.single;
    expect(r.filePath, endsWith('.m4a'));
    expect(r.filePath, isNot(source.path));
    expect(r.type, CaptureType.audioRecording);
    expect(r.sourceMimeType, 'audio/mp4');
    controller.dispose();
  });

  test('the active project is applied', () async {
    final File source = car('$id.m4a', 'AAC-BYTES');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo)
      ..activeProjectId = 'proj-1';
    await controller.initialize();

    await controller.addAudioFile(id, source);
    await controller.waitForProcessing();
    expect(repo.saved.single.projectId, 'proj-1');
    expect(repo.saved.single.projectAuto, isTrue);
    controller.dispose();
  });

  test('the source file is copied, never moved or changed', () async {
    final File source = car('$id.m4a', 'AAC-BYTES');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    await controller.addAudioFile(id, source);
    await controller.waitForProcessing();
    expect(source.existsSync(), isTrue);
    expect(source.readAsStringSync(), 'AAC-BYTES');
    controller.dispose();
  });
}
