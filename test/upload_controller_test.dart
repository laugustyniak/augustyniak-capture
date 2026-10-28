import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/media_picker.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/source_content_hasher.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

/// Repository that keeps the index in memory and points source files at a temp
/// dir — no path_provider, no real recordings.json.
class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory, {this.throwOnSaveCall});

  final Directory directory;
  final int? throwOnSaveCall;
  List<Recording> saved = <Recording>[];
  int saveCalls = 0;
  final List<List<Recording>> saves = <List<Recording>>[];

  /// Status of the newest item at each `saveAll` — pins that the first write
  /// is `saved`, not already queued for processing.
  final List<RecordingStatus> statusAtSave = <RecordingStatus>[];

  /// One entry per `saveAll`: was the newest item's source file already on disk
  /// when the index was written? This is what pins the ordering invariant —
  /// asserting the end state alone cannot tell copy-then-index apart from
  /// index-then-copy.
  final List<bool> sourcePresentAtSave = <bool>[];
  final List<int> sourceBytesAtSave = <int>[];

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCalls++;
    final List<Recording> snapshot = List<Recording>.unmodifiable(recordings);
    saves.add(snapshot);
    if (recordings.isNotEmpty) {
      statusAtSave.add(recordings.first.status);
      final File source = File(recordings.first.filePath);
      sourcePresentAtSave.add(source.existsSync());
      sourceBytesAtSave.add(source.existsSync() ? source.lengthSync() : 0);
    }
    if (saveCalls == throwOnSaveCall) {
      throw StateError('forced save failure');
    }
    saved = snapshot;
  }
}

class _RecordingHasher extends SourceContentHasher {
  final List<String> paths = <String>[];

  @override
  Future<String> hash(File source) async {
    paths.add(source.path);
    return 'a' * 64;
  }
}

/// Returns a fixed transcript so the success path can be exercised without a
/// network service. Every other test here uses the disabled service.
class _StubTranscriptionService implements TranscriptionService {
  const _StubTranscriptionService(this.text);

  final String text;

  @override
  Future<String> transcribe(File audioFile) async => text;
}

/// Hangs until [gate] is completed, so a test can park a job mid-flight and
/// dispose the controller underneath it.
class _GatedTranscriptionService implements TranscriptionService {
  final Completer<void> gate = Completer<void>();

  @override
  Future<String> transcribe(File audioFile) async {
    await gate.future;
    return 'LATE TRANSCRIPT';
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

RecordingsController buildController(
  RecordingsRepository repo, {
  PickedMedia? picked,
  TranscriptionService service = const DisabledTranscriptionService(),
  SourceContentHasher contentHasher = const SourceContentHasher(),
}) {
  return RecordingsController(
    repository: repo,
    transcriptionService: service,
    contentHasher: contentHasher,
    mediaPicker: _FakePicker(picked),
    recorder: _FakeRecorder(),
    player: _FakePlayer(),
  );
}

void main() {
  late Directory appDir;
  late Directory pickDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_ctl_app_',
    );
    pickDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_ctl_pick_',
    );
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    pickDir.deleteSync(recursive: true);
  });

  test(
    'addUpload before initialize writes nothing and sets the loading error',
    () async {
      final File source = File(p.join(pickDir.path, 'original.mp3'))
        ..writeAsStringSync('SOUND');
      final _FakeRepository repo = _FakeRepository(appDir);
      final RecordingsController controller = buildController(
        repo,
        picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
      );
      int notified = 0;
      controller.addListener(() => notified++);

      await controller.addUpload(CaptureType.audioUpload);

      expect(repo.saveCalls, 0);
      expect(controller.recordings, isEmpty);
      expect(controller.error, contains('still loading'));
      expect(notified, 1);
      controller.dispose();
    },
  );

  test(
    'addImportedFile before initialize writes nothing and sets the loading error',
    () async {
      final File source = File(p.join(pickDir.path, 'dropped.txt'))
        ..writeAsStringSync('TEXT');
      final _FakeRepository repo = _FakeRepository(appDir);
      final RecordingsController controller = buildController(repo);

      await controller.addImportedFile(source, CaptureType.text);

      expect(repo.saveCalls, 0);
      expect(controller.recordings, isEmpty);
      expect(controller.error, contains('still loading'));
      controller.dispose();
    },
  );

  test('cancelled pick indexes nothing and releases the busy lock', () async {
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo, picked: null);
    await controller.initialize();

    await controller.addUpload(CaptureType.image);
    await controller.waitForProcessing();
    expect(controller.recordings, isEmpty);
    expect(repo.saved, isEmpty);
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });

  test('image upload is indexed then fails cleanly, source preserved', () async {
    final File source = File(p.join(pickDir.path, 'photo.png'))
      ..writeAsStringSync('PNGDATA');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(
      repo,
      picked: PickedMedia(file: source, mimeType: 'image/png'),
    );
    await controller.initialize();

    await controller.addUpload(CaptureType.image);
    await controller.waitForProcessing();
    expect(controller.recordings, hasLength(1));
    final Recording item = controller.recordings.single;
    expect(item.type, CaptureType.image);
    // No OCR engine on this build → UnavailableProcessor → failed, retryable.
    expect(item.status, RecordingStatus.failed);
    expect(item.error, isNotNull);
    // The imported copy exists in the app dir, and the picked source survives.
    expect(File(item.filePath).existsSync(), isTrue);
    expect(p.basename(item.filePath), '${item.id}.png');
    expect(source.existsSync(), isTrue);
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });

  test('pasted image bytes keep PNG identity without a filename', () async {
    final File source = File(p.join(pickDir.path, 'clipboard-image'))
      ..writeAsStringSync('PNGDATA');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    await controller.addImportedFile(source, CaptureType.image,
        mimeType: 'image/png');
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.sourceMimeType, 'image/png');
    expect(p.basename(item.filePath), '${item.id}.png');
    expect(repo.sourcePresentAtSave, isNotEmpty);
    expect(repo.sourcePresentAtSave, everyElement(isTrue));
    controller.dispose();
  });

  test('pasted PDF is retained as a named attachment without transcription',
      () async {
    final File source = File(p.join(pickDir.path, 'Research.PDF'))
      ..writeAsStringSync('%PDF-1.7');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    await controller.addImportedFile(source, CaptureType.file);
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.type, CaptureType.file);
    expect(item.title, 'Research.PDF');
    expect(item.status, RecordingStatus.completed);
    expect(item.transcript, isEmpty);
    expect(p.basename(item.filePath), '${item.id}.pdf');
    expect(File(item.filePath).readAsStringSync(), '%PDF-1.7');
    expect(repo.sourcePresentAtSave, everyElement(isTrue));
    controller.dispose();
  });

  test('orphan recovery finds attachment files but ignores index JSON', () async {
    const String id = '123e4567-e89b-42d3-a456-426614174000';
    File(p.join(appDir.path, '$id.pdf')).writeAsStringSync('%PDF-1.7');
    File(p.join(appDir.path, 'recordings.json')).writeAsStringSync('[]');
    final RecordingsRepository repository = RecordingsRepository(
      directoryProvider: () async => appDir,
    );

    final List<Recording> found = await repository.findOrphans(<Recording>[]);
    expect(found, hasLength(1));
    expect(found.single.id, id);
    expect(found.single.type, CaptureType.file);
  });

  test(
    'audio upload with no active provider fails as not-configured',
    () async {
      final File source = File(p.join(pickDir.path, 'clip.mp3'))
        ..writeAsStringSync('SOUND');
      final _FakeRepository repo = _FakeRepository(appDir);
      final RecordingsController controller = buildController(
        repo,
        picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
      );
      await controller.initialize();

      await controller.addUpload(CaptureType.audioUpload);
      await controller.waitForProcessing();
      final Recording item = controller.recordings.single;
      expect(item.type, CaptureType.audioUpload);
      expect(item.status, RecordingStatus.failed);
      expect(File(item.filePath).existsSync(), isTrue);
      controller.dispose();
    },
  );

  test(
    'disposing mid-processing does not throw from the unawaited drain',
    () async {
      final File source = File(p.join(pickDir.path, 'original.mp3'))
        ..writeAsStringSync('SOUND');
      final _FakeRepository repo = _FakeRepository(appDir);
      final _GatedTranscriptionService gated = _GatedTranscriptionService();
      final RecordingsController controller = buildController(
        repo,
        picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
        service: gated,
      );
      await controller.initialize();

      // Processing is enqueued and drained unawaited, so the job is parked inside
      // the processor when the page tears the controller down.
      await controller.addUpload(CaptureType.audioUpload);
      controller.dispose();
      gated.gate.complete();

      // The drain now resumes against a disposed controller. Its status write
      // must still land on disk without notifying a dead ChangeNotifier — an
      // unhandled async error here fails the test.
      await pumpEventQueue();

      expect(repo.saved, isNotEmpty);
    },
  );

  test('index write follows the copy — the ordering invariant', () async {
    final File source = File(p.join(pickDir.path, 'original.mp3'))
      ..writeAsStringSync('SOUND');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(
      repo,
      picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
      service: const _StubTranscriptionService('UPLOADED TRANSCRIPT'),
    );
    await controller.initialize();

    await controller.addUpload(CaptureType.audioUpload);
    // Processing is queued, so `addUpload` returns before the drain finishes;
    // disposing without waiting would leave it writing to a dead controller.
    await controller.waitForProcessing();

    // The very first index write must already have seen the copied source on
    // disk. Without this, copy-then-index and index-then-copy look identical.
    expect(repo.sourcePresentAtSave, isNotEmpty);
    expect(repo.sourcePresentAtSave.first, isTrue);
    expect(repo.statusAtSave.first, RecordingStatus.saved);
    controller.dispose();
  });

  test('direct import first save follows verified copy as saved', () async {
    final File source = File(p.join(pickDir.path, 'direct.pdf'))
      ..writeAsStringSync('%PDF-1.7');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo);
    await controller.initialize();

    await controller.addImportedFile(source, CaptureType.file);
    await controller.waitForProcessing();

    final Recording firstSaved = repo.saves.first.single;
    expect(firstSaved.status, RecordingStatus.saved);
    expect(repo.sourcePresentAtSave.first, isTrue);
    expect(repo.sourceBytesAtSave.first, greaterThan(0));
    controller.dispose();
  });

  test(
    'both non-append import paths stamp the active project before first save',
    () async {
      final File source = File(p.join(pickDir.path, 'project.pdf'))
        ..writeAsStringSync('%PDF-1.7');

      for (final bool pickedUpload in <bool>[true, false]) {
        final _FakeRepository repo = _FakeRepository(appDir);
        final RecordingsController controller = buildController(
          repo,
          picked: PickedMedia(file: source, mimeType: 'application/pdf'),
        )..activeProjectId = 'project-362';
        await controller.initialize();

        if (pickedUpload) {
          await controller.addUpload(CaptureType.file);
        } else {
          await controller.addImportedFile(source, CaptureType.file);
        }
        await controller.waitForProcessing();

        expect(repo.saves.first.single.projectId, 'project-362');
        expect(repo.saves.first.single.projectAuto, isTrue);
        controller.dispose();
      }
    },
  );

  test(
    'persist failure keeps the saved row in memory and skips processing',
    () async {
      final File source = File(p.join(pickDir.path, 'persist-failure.pdf'))
        ..writeAsStringSync('%PDF-1.7');

      for (final bool pickedUpload in <bool>[true, false]) {
        final _FakeRepository repo = _FakeRepository(
          appDir,
          throwOnSaveCall: 1,
        );
        final RecordingsController controller = buildController(
          repo,
          picked: PickedMedia(file: source, mimeType: 'application/pdf'),
        );
        await controller.initialize();

        if (pickedUpload) {
          await controller.addUpload(CaptureType.file);
        } else {
          await controller.addImportedFile(source, CaptureType.file);
        }
        await controller.waitForProcessing();

        final Recording admitted = controller.recordings.single;
        expect(repo.saveCalls, 1);
        expect(admitted.status, RecordingStatus.saved);
        expect(
          controller.recordings.map((Recording item) => item.status),
          isNot(contains(RecordingStatus.pendingTranscription)),
        );
        expect(File(admitted.filePath).existsSync(), isTrue);
        expect(File(admitted.filePath).lengthSync(), greaterThan(0));
        expect(source.existsSync(), isTrue);
        expect(controller.error, contains('forced save failure'));
        expect(controller.isBusy, isFalse);
        controller.dispose();
      }
    },
  );

  test('only picked upload schedules immediate content hashing', () async {
    final File source = File(p.join(pickDir.path, 'hash.pdf'))
      ..writeAsStringSync('%PDF-1.7');
    final _RecordingHasher uploadHasher = _RecordingHasher();
    final _FakeRepository uploadRepo = _FakeRepository(appDir);
    final RecordingsController uploadController = buildController(
      uploadRepo,
      picked: PickedMedia(file: source, mimeType: 'application/pdf'),
      contentHasher: uploadHasher,
    );
    await uploadController.initialize();

    await uploadController.addUpload(CaptureType.file);
    await uploadController.waitForProcessing();

    final _RecordingHasher directHasher = _RecordingHasher();
    final _FakeRepository directRepo = _FakeRepository(appDir);
    final RecordingsController directController = buildController(
      directRepo,
      contentHasher: directHasher,
    );
    await directController.initialize();

    await directController.addImportedFile(source, CaptureType.file);
    await directController.waitForProcessing();

    expect(uploadHasher.paths, hasLength(1));
    expect(directHasher.paths, isEmpty);
    uploadController.dispose();
    directController.dispose();
  });

  test('successful audio upload completes with a transcript', () async {
    final File source = File(p.join(pickDir.path, 'original.mp3'))
      ..writeAsStringSync('SOUND');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(
      repo,
      picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
      service: const _StubTranscriptionService('UPLOADED TRANSCRIPT'),
    );
    await controller.initialize();

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();

    final Recording item = controller.recordings.single;
    expect(item.status, RecordingStatus.completed);
    expect(item.transcript, 'UPLOADED TRANSCRIPT');
    expect(item.error, isNull);
    expect(item.type, CaptureType.audioUpload);
    expect(item.sourceMimeType, 'audio/mpeg');
    // Extension comes from the mime type, not the fixed mic-capture `.m4a`.
    expect(p.extension(item.filePath), '.mp3');
    expect(File(item.filePath).existsSync(), isTrue);
    // The import is a copy: the picked file is never moved or deleted.
    expect(source.existsSync(), isTrue);
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });
}
