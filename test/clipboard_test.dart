import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/media_picker.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/clipboard_sink.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  List<Recording> saved = <Recording>[];

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saved = List<Recording>.from(recordings);
  }
}

class _FakePicker implements MediaPicker {
  _FakePicker(this._result);
  final PickedMedia? _result;
  @override
  Future<PickedMedia?> pick(CaptureType type) async => _result;
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

/// Records what the pipeline handed to the clipboard.
class _RecordingClipboard implements ClipboardSink {
  final List<String> copied = <String>[];

  @override
  Future<void> copy(String text) async => copied.add(text);
}

/// A clipboard that refuses every write — stands in for a locked or busy
/// system clipboard.
class _FailingClipboard implements ClipboardSink {
  @override
  Future<void> copy(String text) async =>
      throw StateError('clipboard unavailable');
}

class _StubTranscription implements TranscriptionService {
  _StubTranscription(this.result);
  final String result;
  @override
  Future<String> transcribe(File audioFile) async => result;
}

void main() {
  late Directory appDir;
  late Directory pickDir;

  setUp(() {
    appDir = Directory.systemTemp.createTempSync('audivoa_clip_app_');
    pickDir = Directory.systemTemp.createTempSync('audivoa_clip_pick_');
  });

  tearDown(() {
    appDir.deleteSync(recursive: true);
    pickDir.deleteSync(recursive: true);
  });

  PickedMedia audioSource() {
    final File file = File(p.join(pickDir.path, 'memo.m4a'))
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    return PickedMedia(file: file, mimeType: 'audio/mp4');
  }

  RecordingsController build({
    required ClipboardSink clipboard,
    TranscriptionService? transcription,
    PickedMedia? picked,
  }) {
    return RecordingsController(
      repository: _FakeRepository(appDir),
      transcriptionService:
          transcription ?? const DisabledTranscriptionService(),
      mediaPicker: _FakePicker(picked),
      clipboardSink: clipboard,
      recorder: _FakeRecorder(),
      player: _FakePlayer(),
    );
  }

  test('a completed transcription lands on the clipboard', () async {
    final _RecordingClipboard clipboard = _RecordingClipboard();
    final RecordingsController controller = build(
      clipboard: clipboard,
      transcription: _StubTranscription('Dziękuję bardzo.'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();
    expect(controller.recordings.single.status, RecordingStatus.completed);
    expect(clipboard.copied, <String>['Dziękuję bardzo.']);
  });

  test('a failed job copies nothing', () async {
    final _RecordingClipboard clipboard = _RecordingClipboard();
    final RecordingsController controller = build(
      clipboard: clipboard,
      picked: audioSource(),
    );

    // No provider configured -> the processor throws.
    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();
    expect(controller.recordings.single.status, RecordingStatus.failed);
    expect(clipboard.copied, isEmpty);
  });

  test('a text note is not auto-copied — the user authored it', () async {
    final _RecordingClipboard clipboard = _RecordingClipboard();
    final RecordingsController controller = build(clipboard: clipboard);

    await controller.addTextNote('notatka pisana ręcznie');
    await controller.waitForProcessing();
    expect(controller.recordings.single.status, RecordingStatus.completed);
    expect(clipboard.copied, isEmpty);
  });

  test('a refusing clipboard never fails the capture', () async {
    final RecordingsController controller = build(
      clipboard: _FailingClipboard(),
      transcription: _StubTranscription('tekst wynikowy'),
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();
    final Recording item = controller.recordings.single;
    expect(item.status, RecordingStatus.completed);
    expect(item.transcript, 'tekst wynikowy');
    expect(item.error, isNull);
    expect(controller.error, isNull);
  });

  test('retry copies again after a failure is resolved', () async {
    final _RecordingClipboard clipboard = _RecordingClipboard();
    final RecordingsController controller = build(
      clipboard: clipboard,
      picked: audioSource(),
    );

    await controller.addUpload(CaptureType.audioUpload);
    await controller.waitForProcessing();
    expect(clipboard.copied, isEmpty);

    // Swapping the service mirrors the user fixing the profile in Models.
    controller.transcriptionService = _StubTranscription('po naprawie');
    await controller.retryTranscription(controller.recordings.single.id);
    await controller.waitForProcessing();
    expect(controller.recordings.single.status, RecordingStatus.completed);
    expect(clipboard.copied, <String>['po naprawie']);
  });
}
