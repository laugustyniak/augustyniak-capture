import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:audivoa_core/features/recordings/data/recordings_repository.dart';
import 'package:audivoa_core/features/recordings/domain/recording.dart';
import 'package:audivoa_core/features/recordings/presentation/recordings_controller.dart';
import 'package:audivoa_core/features/transcription/data/transcription_service.dart';

class _FakeRepository extends RecordingsRepository {
  _FakeRepository(this.directory);

  final Directory directory;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => <Recording>[];

  @override
  Future<void> saveAll(List<Recording> recordings) async {}
}

/// Grants the microphone so `startRecording` runs to completion; every other
/// call is a no-op.
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

  setUp(() => appDir = Directory.systemTemp.createTempSync('audivoa_tick_'));
  tearDown(() => appDir.deleteSync(recursive: true));

  test('the recording tick drives elapsedTicker, not the whole controller',
      () async {
    final RecordingsController controller = RecordingsController(
      repository: _FakeRepository(appDir),
      transcriptionService: const DisabledTranscriptionService(),
      recorder: _GrantingRecorder(),
      player: _FakePlayer(),
    );

    int controllerNotifications = 0;
    int tickerNotifications = 0;
    controller.addListener(() => controllerNotifications++);
    controller.elapsedTicker.addListener(() => tickerNotifications++);

    await controller.startRecording();
    expect(controller.isRecording, isTrue);

    // startRecording itself notifies once — that is a real state change.
    final int afterStart = controllerNotifications;

    // The timer fires every 250ms; wait for a few ticks.
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // The ticks moved the ticker...
    expect(tickerNotifications, greaterThanOrEqualTo(2));
    // ...and did NOT rebuild the page. A controller notification here would fan
    // out through the shell's IndexedStack into all four tabs, four times a
    // second, purely to redraw one mm:ss label.
    expect(controllerNotifications, afterStart);
    expect(controller.elapsedTicker.value, greaterThan(Duration.zero));

    controller.dispose();
  });
}
