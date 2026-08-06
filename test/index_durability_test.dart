import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A repository rooted in a temp directory instead of `path_provider`'s app
/// documents folder. Everything else — the index format, the read/write logic,
/// the orphan scan — is the production code, which is the point: the failure
/// this suite covers lives in exactly that logic.
class TempRepository extends RecordingsRepository {
  TempRepository(this.root);

  final Directory root;

  @override
  Future<Directory> recordingsDirectory() async {
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }
}

/// Records every write so a test can prove one never happened.
class CountingRepository extends TempRepository {
  CountingRepository(super.root);

  int saves = 0;

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saves++;
    await super.saveAll(recordings);
  }
}

Recording _item(String id, {String? transcript}) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: DateTime.parse('2026-08-04T12:00:00'),
  durationMs: 1000,
  sizeBytes: 1234,
  status: RecordingStatus.completed,
  transcript: transcript,
);

void main() {
  // The controller constructs a real recorder and player; stubbing their
  // channels is what keeps this suite off any actual device, exactly as
  // `transcript_editing_test.dart` does.
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          MethodChannel(name),
          (MethodCall call) async => null,
        );
  }

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'augustyniak-capture-index-test',
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  File indexFile() => File(p.join(root.path, 'recordings.json'));

  group('reading the index', () {
    test('an absent index is an empty queue, not an error', () async {
      final TempRepository repository = TempRepository(root);
      expect(await repository.loadAll(), isEmpty);
    });

    test('a blank index is an empty queue', () async {
      await indexFile().writeAsString('   \n');
      expect(await TempRepository(root).loadAll(), isEmpty);
    });

    test('unparseable JSON throws and preserves the bytes', () async {
      await indexFile().writeAsString('{ this is not json');

      await expectLater(
        TempRepository(root).loadAll(),
        throwsA(isA<IndexUnreadableException>()),
      );

      // The original file is untouched and a copy exists alongside it.
      expect(await indexFile().readAsString(), '{ this is not json');
      final List<String> backups = root
          .listSync()
          .map((FileSystemEntity entity) => p.basename(entity.path))
          .where((String name) => name.contains('corrupt'))
          .toList();
      expect(backups, hasLength(1));
    });

    test(
      'valid JSON that is not a list throws rather than loading empty',
      () async {
        await indexFile().writeAsString('{"recordings": []}');
        await expectLater(
          TempRepository(root).loadAll(),
          throwsA(isA<IndexUnreadableException>()),
        );
      },
    );

    test('one malformed row does not cost the others', () async {
      await indexFile().writeAsString(
        jsonEncode(<dynamic>[
          _item('good-1').toJson(),
          <String, dynamic>{'id': null, 'filePath': 'x'}, // unloadable
          _item('good-2').toJson(),
        ]),
      );

      final List<Recording> loaded = await TempRepository(root).loadAll();
      expect(
        loaded.map((Recording item) => item.id),
        containsAll(<String>['good-1', 'good-2']),
      );
      // The dropped row is preserved, because the next save writes over it.
      expect(
        root.listSync().where(
          (FileSystemEntity entity) =>
              p.basename(entity.path).contains('partial'),
        ),
        hasLength(1),
      );
    });
  });

  group('writing the index', () {
    test('a shrinking index is backed up before it is overwritten', () async {
      final TempRepository repository = TempRepository(root);
      await repository.saveAll(<Recording>[_item('a'), _item('b')]);
      expect(
        root.listSync().where(
          (FileSystemEntity e) => p.basename(e.path).contains('shrank'),
        ),
        isEmpty,
        reason: 'growing is normal and must not cost a copy',
      );

      await repository.saveAll(<Recording>[_item('a')]);
      expect(
        root.listSync().where(
          (FileSystemEntity e) => p.basename(e.path).contains('shrank'),
        ),
        hasLength(1),
      );
    });
  });

  group('the controller refuses to write over an index it could not read', () {
    test('an unreadable index disables every write', () async {
      await indexFile().writeAsString('not json at all');
      final CountingRepository repository = CountingRepository(root);
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.isIndexUnreadable, isTrue);
      expect(controller.error, isNotNull);

      // The write path is the one that destroys history, so poke it directly.
      await controller.setTitle('anything', 'a new title');
      await controller.retryTranscription('anything');

      expect(repository.saves, 0, reason: 'no write may reach the index');
      expect(await indexFile().readAsString(), 'not json at all');
    });

    test('a readable index leaves writes enabled', () async {
      await indexFile().writeAsString(
        jsonEncode(<dynamic>[_item('a').toJson()]),
      );
      final CountingRepository repository = CountingRepository(root);
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.isIndexUnreadable, isFalse);

      await controller.setTitle('a', 'named by hand');
      expect(repository.saves, greaterThan(0));
      expect(controller.recordings.single.title, 'named by hand');
    });
  });

  group('recovering sources whose index row was lost', () {
    test('adopts orphans as raw, skips known ids, posters and json', () async {
      // One orphan, one already indexed, plus the artifacts that must be
      // ignored: the index itself, a poster, and an empty file.
      await File(p.join(root.path, 'orphan-1.m4a')).writeAsString('audio');
      await File(p.join(root.path, 'known-1.m4a')).writeAsString('audio');
      await File(p.join(root.path, 'known-1.thumb.jpg')).writeAsString('jpg');
      await File(p.join(root.path, 'empty.m4a')).writeAsString('');
      await indexFile().writeAsString(
        jsonEncode(<dynamic>[_item('known-1', transcript: 'kept').toJson()]),
      );

      final TempRepository repository = TempRepository(root);
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.recoverOrphans();
      await controller.waitForProcessing();

      final List<Recording> items = controller.recordings;
      expect(items, hasLength(2));

      final Recording recovered = items.firstWhere(
        (Recording item) => item.id == 'orphan-1',
      );
      expect(
        recovered.status,
        RecordingStatus.saved,
        reason: 'recovered items must not auto-spend transcription calls',
      );
      expect(recovered.type, CaptureType.audioRecording);
      expect(recovered.transcript, isNull);
      expect(
        recovered.contentHash,
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason: 'a recovered source must remain deduplicable in an import',
      );

      // The existing row keeps everything it had.
      final Recording untouched = items.firstWhere(
        (Recording item) => item.id == 'known-1',
      );
      expect(untouched.transcript, 'kept');
    });

    test('does nothing when the index is unreadable', () async {
      await File(p.join(root.path, 'orphan-1.m4a')).writeAsString('audio');
      await indexFile().writeAsString('not json');

      final CountingRepository repository = CountingRepository(root);
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.recoverOrphans();

      expect(controller.recordings, isEmpty);
      expect(repository.saves, 0);
    });
  });
}
