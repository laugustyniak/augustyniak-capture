import 'dart:io';

import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/sync/domain/media_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// In-memory bucket with the server's write-once rule.
class FakeMediaStore implements MediaObjectStore {
  final Map<String, List<int>> objects = <String, List<int>>{};

  @override
  Future<bool> exists(String key) async => objects.containsKey(key);

  @override
  Future<void> upload(String key, File source, {required String sha256}) async {
    if (objects.containsKey(key)) throw const MediaObjectExistsException();
    objects[key] = await source.readAsBytes();
  }

  @override
  Future<List<int>> download(String key) async => objects[key]!;
}

String hashOf(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory dir;
  late FakeMediaStore store;
  const List<int> audio = <int>[1, 2, 3, 4];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('media_sync_test');
    store = FakeMediaStore();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  MediaSyncJob job(String name, {String? hash}) => MediaSyncJob(
    key: 'captures/r1/$name',
    localPath: p.join(dir.path, name),
    contentHash: hash,
  );

  test('uploads a local source the store lacks, once', () async {
    await File(p.join(dir.path, 'r1.m4a')).writeAsBytes(audio);
    final MediaSyncService real = MediaSyncService(store: store);

    final MediaSyncResult first = await real.sync(<MediaSyncJob>[
      job('r1.m4a'),
    ]);
    final MediaSyncResult second = await real.sync(<MediaSyncJob>[
      job('r1.m4a'),
    ]);

    expect(first.uploaded, 1);
    expect(second.uploaded, 0);
    expect(second.unchanged, 1);
    expect(store.objects['captures/r1/r1.m4a'], audio);
  });

  test('downloads a missing source only when it matches contentHash', () async {
    store.objects['captures/r1/r1.m4a'] = audio;

    final MediaSyncResult result = await MediaSyncService(
      store: store,
    ).sync(<MediaSyncJob>[job('r1.m4a', hash: hashOf(audio))]);

    expect(result.downloaded, 1);
    expect(result.success, isTrue);
    expect(await File(p.join(dir.path, 'r1.m4a')).readAsBytes(), audio);
    expect(dir.listSync(), hasLength(1), reason: 'no .part left behind');
  });

  test('a hash mismatch writes nothing and fails the run', () async {
    store.objects['captures/r1/r1.m4a'] = audio;

    final MediaSyncResult result = await MediaSyncService(store: store).sync(
      <MediaSyncJob>[
        job('r1.m4a', hash: hashOf(<int>[9])),
      ],
    );

    expect(result.rejected, 1);
    expect(result.success, isFalse);
    expect(dir.listSync(), isEmpty);
  });

  test(
    'an empty download is rejected even when the hash is of nothing',
    () async {
      store.objects['captures/r1/r1.m4a'] = <int>[];

      final MediaSyncResult result = await MediaSyncService(
        store: store,
      ).sync(<MediaSyncJob>[job('r1.m4a', hash: hashOf(<int>[]))]);

      expect(result.rejected, 1);
      expect(dir.listSync(), isEmpty);
    },
  );

  test('no contentHash is never downloaded', () async {
    store.objects['captures/r1/r1.m4a'] = audio;

    final MediaSyncResult result = await MediaSyncService(
      store: store,
    ).sync(<MediaSyncJob>[job('r1.m4a')]);

    expect(result.unverifiable, 1);
    expect(result.downloaded, 0);
    expect(dir.listSync(), isEmpty);
  });

  test('media not uploaded yet is waiting, not a failure', () async {
    final MediaSyncResult result = await MediaSyncService(
      store: store,
    ).sync(<MediaSyncJob>[job('r1.m4a', hash: hashOf(audio))]);

    expect(result.waiting, 1);
    expect(result.success, isTrue);
  });

  test('a store failure ends the run with a reason', () async {
    final MediaSyncResult result = await const MediaSyncService(
      store: DisabledMediaObjectStore(),
    ).sync(<MediaSyncJob>[job('r1.m4a', hash: hashOf(audio))]);

    expect(result.success, isFalse);
    expect(result.failureReason, contains('StateError'));
  });

  group('MediaSyncJob.forRecordings', () {
    Recording rec(String id, String filePath) => Recording(
      id: id,
      filePath: filePath,
      createdAt: DateTime.utc(2026, 9, 23),
      durationMs: 1,
      status: RecordingStatus.completed,
      type: CaptureType.audioRecording,
      contentHash: hashOf(audio),
    );

    test('keys by recording id and file name, carrying the hash', () {
      final List<MediaSyncJob> jobs = MediaSyncJob.forRecordings(<Recording>[
        rec('r1', p.join(dir.path, 'r1.m4a')),
      ]);

      expect(jobs.single.key, 'captures/r1/r1.m4a');
      expect(jobs.single.contentHash, hashOf(audio));
    });

    test('skips bare names and unsafe ids', () {
      final List<MediaSyncJob> jobs = MediaSyncJob.forRecordings(<Recording>[
        rec('r1', 'r1.m4a'),
        rec('../x', p.join(dir.path, 'x.m4a')),
      ]);

      expect(jobs, isEmpty);
    });
  });
}
