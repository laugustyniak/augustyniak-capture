import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;
  int saveCalls = 0;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saveCalls++;
  }
}

class _GrantingRecorder implements AudioRecorder {
  @override
  Future<bool> hasPermission({bool request = true}) async => true;

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

  setUp(
    () => appDir = Directory.systemTemp.createTempSync(
      'augustyniak_capture_preload_',
    ),
  );
  tearDown(() => appDir.deleteSync(recursive: true));

  test('startRecording before initialize refuses and writes nothing', () async {
    final _FakeRepository repo = _FakeRepository(appDir);
    final RecordingsController controller = RecordingsController(
      repository: repo,
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _GrantingRecorder(),
      player: _FakePlayer(),
    );

    await controller.startRecording();

    expect(controller.isRecording, isFalse);
    expect(controller.error, contains('still loading'));
    expect(repo.saveCalls, 0);
    controller.dispose();
  });
}
