import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  List<Recording> saved = <Recording>[];

  @override
  Future<File> createSourceFile(String id, String extension) async {
    final File file = File(p.join(directory.path, '$id.$extension'));
    // Stands in for the recorder writing audio: `stopRecording` refuses to
    // index anything it cannot verify is non-empty.
    await file.writeAsString('audio');
    return file;
  }

  @override
  Future<List<Recording>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saved = List<Recording>.from(recordings);
  }
}

class _GrantingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  /// Typed explicitly — `noSuchMethod` answers `Future<dynamic>`, which fails
  /// the cast at the call site.
  @override
  Future<String?> stop() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

class _FakePlayer implements AudioPlayer {
  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

void main() {
  late Directory appDir;

  setUp(() => appDir = Directory.systemTemp.createTempSync('project_pick_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  RecordingsController build() {
    final RecordingsController controller = RecordingsController(
      repository: _FakeRepository(appDir),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _GrantingRecorder(),
      player: _FakePlayer(),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('a recording is seeded with the active project', () async {
    final RecordingsController controller = build()
      ..activeProjectId = 'project-a';

    await controller.startRecording();
    expect(controller.recordingProjectId, 'project-a');

    await controller.stopRecording();
    expect(controller.recordings.single.projectId, 'project-a');
  });

  test('re-filing mid-recording lands on the item, not on the next one',
      () async {
    final RecordingsController controller = build()
      ..activeProjectId = 'project-a';

    await controller.startRecording();
    controller.setRecordingProject('project-b');
    await controller.stopRecording();

    expect(controller.recordings.first.projectId, 'project-b');
    // The point of keeping this separate from `activeProjectId`: one capture
    // filed elsewhere must not silently repoint every capture that follows.
    expect(controller.activeProjectId, 'project-a');

    await controller.startRecording();
    expect(controller.recordingProjectId, 'project-a');
    await controller.stopRecording();
    expect(controller.recordings.first.projectId, 'project-a');
  });

  test('a capture can be filed under no project at all', () async {
    final RecordingsController controller = build()
      ..activeProjectId = 'project-a';

    await controller.startRecording();
    controller.setRecordingProject(null);
    await controller.stopRecording();

    expect(controller.recordings.single.projectId, isNull);
  });

  test('the picker is inert unless the mic is live', () async {
    final RecordingsController controller = build()
      ..activeProjectId = 'project-a';

    // A stray tap arriving after SAVE must not attach a project to whatever
    // gets recorded next.
    controller.setRecordingProject('project-b');
    expect(controller.recordingProjectId, isNull);

    await controller.startRecording();
    expect(controller.recordingProjectId, 'project-a');
    await controller.stopRecording();
    expect(controller.recordingProjectId, isNull);
  });
}
