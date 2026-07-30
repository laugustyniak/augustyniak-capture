import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:audivoa_core/features/recordings/data/media_picker.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/capture_type.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

/// Repository that keeps the index in memory and points source files at a temp
/// dir — no path_provider, no real recordings.json.
class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  List<Recording> saved = <Recording>[];

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
    if (recordings.isNotEmpty) {
      sourcePresentAtSave.add(File(recordings.first.filePath).existsSync());
    }
    saved = List<Recording>.from(recordings);
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
}) {
  return RecordingsController(
    repository: repo,
    transcriptionService: service,
    mediaPicker: _FakePicker(picked),
    recorder: _FakeRecorder(),
    player: _FakePlayer(),
  );
}

void main() {
  late Directory appDir;
  late Directory pickDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('audivoa_ctl_app_');
    pickDir = Directory.systemTemp.createTempSync('audivoa_ctl_pick_');
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    pickDir.deleteSync(recursive: true);
  });

  test('cancelled pick indexes nothing and releases the busy lock', () async {
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(repo, picked: null);

    await controller.addUpload(CaptureType.image);
    await controller.waitForProcessing();
    expect(controller.recordings, isEmpty);
    expect(repo.saved, isEmpty);
    expect(controller.isBusy, isFalse);
    controller.dispose();
  });

  test('image upload is indexed then fails cleanly, source preserved',
      () async {
    final File source = File(p.join(pickDir.path, 'photo.png'))
      ..writeAsStringSync('PNGDATA');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(
      repo,
      picked: PickedMedia(file: source, mimeType: 'image/png'),
    );

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

  test('audio upload with no active provider fails as not-configured',
      () async {
    final File source = File(p.join(pickDir.path, 'clip.mp3'))
      ..writeAsStringSync('SOUND');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(
      repo,
      picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();
    final Recording item = controller.recordings.single;
    expect(item.type, CaptureType.audioUpload);
    expect(item.status, RecordingStatus.failed);
    expect(File(item.filePath).existsSync(), isTrue);
    controller.dispose();
  });

  test('disposing mid-processing does not throw from the unawaited drain',
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
  });

  test('index write follows the copy — the ordering invariant', () async {
    final File source = File(p.join(pickDir.path, 'original.mp3'))
      ..writeAsStringSync('SOUND');
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = buildController(
      repo,
      picked: PickedMedia(file: source, mimeType: 'audio/mpeg'),
      service: const _StubTranscriptionService('UPLOADED TRANSCRIPT'),
    );

    await controller.addUpload(CaptureType.audioUpload);
    // Processing is queued, so `addUpload` returns before the drain finishes;
    // disposing without waiting would leave it writing to a dead controller.
    await controller.waitForProcessing();

    // The very first index write must already have seen the copied source on
    // disk. Without this, copy-then-index and index-then-copy look identical.
    expect(repo.sourcePresentAtSave, isNotEmpty);
    expect(repo.sourcePresentAtSave.first, isTrue);
    controller.dispose();
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
