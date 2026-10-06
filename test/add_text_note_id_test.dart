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
  bool failSave = false;

  /// One entry per `saveAll`: was the newest item's source file already on disk
  /// when the index was written? This is what pins the ordering invariant —
  /// asserting the end state alone cannot tell copy-then-index apart from
  /// index-then-copy.
  final List<bool> sourcePresentAtSave = <bool>[];

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    if (failSave) throw const FileSystemException('disk full');
    if (recordings.isNotEmpty) {
      sourcePresentAtSave.add(File(recordings.first.filePath).existsSync());
    }
    saved = List<Recording>.from(recordings);
  }
}

class _FakePicker implements MediaPicker {
  _FakePicker(this._result);
  final PickedMedia? _result;
  @override
  Future<PickedMedia?> pick(CaptureType type) async => _result;
}

/// The controller instantiates an AudioPlayer/AudioRecorder unless injected;
/// these no-op stubs keep the test off the platform channels. Only
/// `onPlayerComplete` is used at construction.
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
    mediaPicker: _FakePicker(null),
    recorder: _FakeRecorder(),
    player: _FakePlayer(),
  );
}

void main() {
  const String id = '123e4567-e89b-42d3-a456-426614174000';
  late Directory appDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('augustyniak_capture_note_');
  });

  tearDown(() => appDir.deleteSync(recursive: true));

  test('returns true and persists when idle', () async {
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);

    expect(await controller.addTextNote('hello'), isTrue);
    await controller.waitForProcessing();
    expect(repo.saved, hasLength(1));
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });

  test('uses the given id for the row and the source filename', () async {
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);

    expect(await controller.addTextNote('hello', id: id), isTrue);
    await controller.waitForProcessing();
    expect(repo.saved.single.id, id);
    expect(p.basename(repo.saved.single.filePath), '$id.txt');
    controller.dispose();
  });

  test(
    'an id that is already present returns true without a second row',
    () async {
      final _FakeRepository repo = _FakeRepository(appDir);
      final RecordingsController controller = buildController(repo);

      expect(await controller.addTextNote('hello', id: id), isTrue);
      await controller.waitForProcessing();
      expect(await controller.addTextNote('hello again', id: id), isTrue);
      await controller.waitForProcessing();
      expect(repo.saved, hasLength(1));
      expect(controller.recordings, hasLength(1));
      controller.dispose();
    },
  );

  test('empty body returns false and writes nothing', () async {
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);

    expect(await controller.addTextNote('   ', id: id), isFalse);
    expect(repo.saved, isEmpty);
    controller.dispose();
  });

  test('a failing index write returns false', () async {
    final _FakeRepository repo = _FakeRepository(appDir)..failSave = true;
    final RecordingsController controller = buildController(repo);

    expect(await controller.addTextNote('hello', id: id), isFalse);
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });

  test('returns false while another capture holds the busy lock', () async {
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);

    final Future<bool> first = controller.addTextNote('one');
    final bool second = await controller.addTextNote('two', id: id);
    expect(second, isFalse);
    expect(await first, isTrue);
    await controller.waitForProcessing();
    expect(repo.saved, hasLength(1));
    controller.dispose();
  });
}
