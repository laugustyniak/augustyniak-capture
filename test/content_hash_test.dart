import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/data/source_content_hasher.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/presentation/recordings_controller.dart';
import 'package:augustyniak_capture/features/transcription/data/transcription_service.dart';

class _Repo extends RecordingsRepository {
  _Repo(this.directory, this.seed);

  final Directory directory;
  final List<Recording> seed;
  List<Recording> saved = <Recording>[];
  int saves = 0;

  @override
  Future<File> createSourceFile(String id, String extension) async =>
      File(p.join(directory.path, '$id.$extension'));

  @override
  Future<List<Recording>> loadAll() async => List<Recording>.of(seed);

  @override
  Future<void> saveAll(List<Recording> recordings) async {
    saves++;
    saved = List<Recording>.of(recordings);
  }
}

class _GatedHasher extends SourceContentHasher {
  final Completer<void> gate = Completer<void>();
  bool started = false;

  @override
  Future<String> hash(File source) async {
    started = true;
    await gate.future;
    return super.hash(source);
  }
}

Recording _legacy(String id, File source) => Recording(
  id: id,
  filePath: source.path,
  createdAt: DateTime.utc(2026, 8, 5),
  durationMs: 1000,
  sizeBytes: source.existsSync() ? source.lengthSync() : 0,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
  transcript: 'keep this transcript',
  title: 'Keep this title',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final String name in <String>[
    'com.llfbandit.record/messages',
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (MethodCall call) async => null,
    );
  }

  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('capture_hash_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('identical source bytes produce the same lowercase SHA-256', () async {
    final File first = File(p.join(directory.path, 'first.bin'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3, 255]);
    final File second = File(p.join(directory.path, 'second.bin'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3, 255]);
    const SourceContentHasher hasher = SourceContentHasher();

    final String one = await hasher.hash(first);
    final String two = await hasher.hash(second);

    expect(one, two);
    expect(one, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('startup backfills legacy rows without changing their state', () async {
    final File source = File(p.join(directory.path, 'legacy.m4a'))
      ..writeAsStringSync('same immutable bytes');
    final Recording legacy = _legacy('legacy', source);
    final _Repo repository = _Repo(directory, <Recording>[legacy]);
    final RecordingsController controller = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.waitForProcessing();

    final Recording after = controller.recordings.single;
    expect(after.contentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(after.status, legacy.status);
    expect(after.title, legacy.title);
    expect(after.transcript, legacy.transcript);
    expect(repository.saved.single.contentHash, after.contentHash);
  });

  test(
    'two captures of identical bytes remain two rows with one hash',
    () async {
      final File first = File(p.join(directory.path, 'one.m4a'))
        ..writeAsStringSync('duplicate bytes');
      final File second = File(p.join(directory.path, 'two.m4a'))
        ..writeAsStringSync('duplicate bytes');
      final _Repo repository = _Repo(directory, <Recording>[
        _legacy('one', first),
        _legacy('two', second),
      ]);
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      expect(controller.recordings, hasLength(2));
      expect(
        controller.recordings.map((Recording item) => item.contentHash).toSet(),
        hasLength(1),
      );
    },
  );

  test('a missing source costs only the hash', () async {
    final Recording legacy = _legacy(
      'missing',
      File(p.join(directory.path, 'missing.m4a')),
    );
    final _Repo repository = _Repo(directory, <Recording>[legacy]);
    final RecordingsController controller = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.waitForProcessing();

    expect(controller.recordings.single.contentHash, isNull);
    expect(controller.recordings.single.status, RecordingStatus.completed);
  });

  test('hashing never delays acknowledgement of a new text capture', () async {
    final _GatedHasher hasher = _GatedHasher();
    final _Repo repository = _Repo(directory, <Recording>[]);
    final RecordingsController controller = RecordingsController(
      repository: repository,
      transcriptionService: const DisabledTranscriptionService(),
      contentHasher: hasher,
    );
    addTearDown(controller.dispose);

    await controller.addTextNote('captured before hashing finishes');

    expect(hasher.started, isTrue);
    expect(controller.recordings, hasLength(1));
    expect(controller.recordings.single.contentHash, isNull);

    hasher.gate.complete();
    await controller.waitForProcessing();
    expect(controller.recordings.single.contentHash, isNotNull);
  });

  test(
    'a legacy library is fingerprinted in one write, not one per row',
    () async {
      final List<Recording> legacy = <Recording>[];
      for (int i = 0; i < 5; i++) {
        final File source = File(p.join(directory.path, 'legacy$i.m4a'))
          ..writeAsStringSync('bytes for $i');
        legacy.add(_legacy('legacy$i', source));
      }
      final _Repo repository = _Repo(directory, legacy);
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      // Every row hashed...
      expect(
        controller.recordings.every(
          (Recording item) => item.contentHash != null,
        ),
        isTrue,
      );
      // ...and the index rewritten once. Routing each row through `_update` cost
      // a whole-index rewrite, a full table delete-and-reinsert and a Turso push
      // *per capture*, which on a real library is hundreds of each at start-up.
      expect(
        repository.saves,
        1,
        reason: 'the backfill must persist once, not once per row',
      );
    },
  );

  test(
    'the backfill hashes every segment and leaves the row hash alone',
    () async {
      final File first = File(p.join(directory.path, 'abc.m4a'))
        ..writeAsStringSync('first bytes');
      final File second = File(p.join(directory.path, 'abc-1.m4a'))
        ..writeAsStringSync('second bytes');

      final String rowHash = 'c' * 64;
      final Recording seeded = Recording(
        id: 'abc',
        filePath: first.path,
        createdAt: DateTime.utc(2026, 8, 28),
        durationMs: 1000,
        sizeBytes: first.lengthSync(),
        contentHash: rowHash,
        status: RecordingStatus.completed,
        type: CaptureType.audioRecording,
        transcript: 'first fragment',
        segments: <CaptureSegment>[
          CaptureSegment(
            index: 0,
            filePath: first.path,
            type: CaptureType.audioRecording,
            createdAt: DateTime.utc(2026, 8, 28),
            sizeBytes: first.lengthSync(),
            contentHash: rowHash,
            text: 'first fragment',
          ),
          CaptureSegment(
            index: 1,
            filePath: second.path,
            type: CaptureType.audioRecording,
            createdAt: DateTime.utc(2026, 8, 28),
            sizeBytes: second.lengthSync(),
            text: 'second fragment',
          ),
        ],
      );

      final _Repo repository = _Repo(directory, <Recording>[seeded]);
      final RecordingsController controller = RecordingsController(
        repository: repository,
        transcriptionService: const DisabledTranscriptionService(),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.waitForProcessing();

      final Recording item = controller.recordings.single;
      expect(item.segments[1].contentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        item.segments[1].contentHash,
        isNot(item.segments[0].contentHash),
        reason: 'different bytes, different hash',
      );
      expect(
        item.contentHash,
        rowHash,
        reason: 'the row hash describes segment 0 and must survive an append',
      );
    },
  );
}
