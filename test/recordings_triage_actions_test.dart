import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:augustyniak_capture/features/connections/data/file_triage_log.dart';
import 'package:augustyniak_capture/features/connections/domain/daily_triage.dart';
import 'package:augustyniak_capture/features/connections/presentation/daily_triage_controller.dart';
import 'package:augustyniak_capture/features/connections/presentation/daily_triage_dialog.dart';
import 'package:augustyniak_capture/features/recordings/data/media_picker.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/revisions_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

/// `RecordingsTriageActions` is the only code that turns an accepted proposal
/// into an index write, so it is exercised here against a real
/// `RecordingsController` over a real `recordings.json` in a temp directory —
/// the fake actions the controller tests use cannot see what it actually calls.
class _MemoryRevisions extends RevisionsRepository {
  @override
  Future<Map<String, List<RecordingRevision>>> load() async =>
      <String, List<RecordingRevision>>{};

  @override
  Future<void> append(List<RecordingRevision> revisions) async {}
}

class _NoPicker implements MediaPicker {
  @override
  Future<List<PickedMedia>> pick(CaptureType type) async => <PickedMedia>[];
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

class _ScriptedService implements DailyTriageService {
  _ScriptedService(this.digest);

  final TriageDigest digest;

  @override
  Future<TriageDigest> triage(
    List<Recording> captures, {
    Map<String, String> projectNames = const <String, String>{},
  }) async => digest;
}

void main() {
  late Directory dir;
  late RecordingsRepository repository;
  late RecordingsController controller;

  Recording note(String id, {bool processed = false}) => Recording(
    id: id,
    filePath: p.join(dir.path, '$id.txt'),
    createdAt: DateTime(2026, 10, 1, 9),
    durationMs: 0,
    sizeBytes: 4,
    status: RecordingStatus.completed,
    type: CaptureType.text,
    transcript: 'text',
    isProcessedByUser: processed,
    processedAt: processed ? DateTime(2026, 10, 1, 10) : null,
  );

  Future<void> seed(List<Recording> recordings) async {
    for (final Recording recording in recordings) {
      await File(recording.filePath).writeAsString('text');
    }
    await repository.saveAll(recordings);
    controller = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      revisionsRepository: _MemoryRevisions(),
      mediaPicker: _NoPicker(),
      recorder: _FakeRecorder(),
      player: _FakePlayer(),
    );
    await controller.initialize();
    // The startup hash backfill rewrites the index once; let it land so it is
    // not mistaken for something triage did.
    await controller.waitForProcessing();
  }

  Future<Recording> onDisk(String id) async => (await repository.loadAll())
      .firstWhere((Recording recording) => recording.id == id);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('triage-actions');
    repository = RecordingsRepository(directoryProvider: () async => dir);
  });

  tearDown(() async {
    controller.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('close marks an open capture processed in the index', () async {
    await seed(<Recording>[note('open')]);

    await RecordingsTriageActions(controller).close('open');

    expect((await onDisk('open')).isProcessedByUser, isTrue);
  });

  test('close on an already-closed capture does not reopen it', () async {
    await seed(<Recording>[note('done', processed: true)]);

    await RecordingsTriageActions(controller).close('done');

    // `toggleProcessed` is a toggle: called on a closed item it would put the
    // capture back on the desk.
    expect((await onDisk('done')).isProcessedByUser, isTrue);
  });

  test('close on a capture that is gone does nothing', () async {
    await seed(<Recording>[note('open')]);

    await RecordingsTriageActions(controller).close('missing');

    expect(await repository.loadAll(), hasLength(1));
    expect((await onDisk('open')).isProcessedByUser, isFalse);
  });

  test('setPriority persists the new priority', () async {
    await seed(<Recording>[note('open')]);

    await RecordingsTriageActions(
      controller,
    ).setPriority('open', CapturePriority.p0);

    expect((await onDisk('open')).priority, CapturePriority.p0);
  });

  test('running triage leaves the index and every source untouched', () async {
    await seed(<Recording>[note('one'), note('two')]);
    final File index = File(p.join(dir.path, 'recordings.json'));
    final Uint8List indexBefore = await index.readAsBytes();
    final Map<String, Uint8List> sourcesBefore = <String, Uint8List>{
      for (final String id in <String>['one', 'two'])
        id: await File(p.join(dir.path, '$id.txt')).readAsBytes(),
    };
    final Set<String> namesBefore = dir
        .listSync()
        .map((FileSystemEntity entity) => p.basename(entity.path))
        .toSet();

    final DailyTriageController triage = DailyTriageController(
      service: _ScriptedService(
        TriageDigest(
          at: DateTime(2026, 10, 3, 9),
          proposals: const <TriageProposal>[
            TriageProposal(
              kind: TriageKind.close,
              reason: 'Done already.',
              captureIds: <String>['one'],
            ),
          ],
        ),
      ),
      log: FileTriageLog(directory: () async => dir),
      recordings: () => controller.recordings,
      actions: RecordingsTriageActions(controller),
    );
    await triage.load();
    await triage.run();
    expect(triage.error, isNull);
    expect(triage.proposals, hasLength(1));

    expect(await index.readAsBytes(), indexBefore);
    for (final MapEntry<String, Uint8List> entry in sourcesBefore.entries) {
      expect(
        await File(p.join(dir.path, '${entry.key}.txt')).readAsBytes(),
        entry.value,
      );
    }
    // The digest went to its own log and nowhere else.
    expect(
      dir
          .listSync()
          .map((FileSystemEntity entity) => p.basename(entity.path))
          .toSet(),
      <String>{...namesBefore, 'triage.jsonl'},
    );
    triage.dispose();
  });
}
