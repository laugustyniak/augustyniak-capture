import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/sync/r2_media_sync_service.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

class _MemoryStore implements R2ObjectStore {
  final Map<String, List<int>> objects = <String, List<int>>{};
  final Map<String, String> hashes = <String, String>{};
  final List<String> uploads = <String>[];
  final List<String> downloads = <String>[];
  Object? validationError;
  List<int>? racedUpload;

  @override
  Future<void> validate() async {
    if (validationError case final Object error) throw error;
  }

  @override
  Future<R2RemoteObject?> head(String key) async {
    final List<int>? bytes = objects[key];
    if (bytes == null) return null;
    return R2RemoteObject(sha256: hashes[key], size: bytes.length);
  }

  @override
  Future<void> upload({
    required String key,
    required File source,
    required String sha256,
  }) async {
    if (racedUpload case final List<int> bytes) {
      objects[key] = bytes;
      hashes[key] = crypto.sha256.convert(bytes).toString();
      throw const R2ObjectAlreadyExistsException();
    }
    uploads.add(key);
    objects[key] = await source.readAsBytes();
    hashes[key] = sha256;
  }

  @override
  Future<void> download({
    required String key,
    required File destination,
  }) async {
    downloads.add(key);
    await destination.writeAsBytes(objects[key]!);
  }
}

void main() {
  late Directory directory;
  late AppDatabase database;
  late _MemoryStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('r2-sync-test-');
    AppDatabase.resetForTesting();
    database = await AppDatabase.getInstance(
      overrideDb: sqlite3.openInMemory(),
    );
    store = _MemoryStore();
  });

  tearDown(() async {
    AppDatabase.resetForTesting();
    await directory.delete(recursive: true);
  });

  void addRecording(String id, String path) {
    database.rawDb.execute(
      '''
      INSERT INTO recordings (
        id, file_path, duration_ms, type, status, tags_json, created_at
      ) VALUES (?, ?, 1, 'audioRecording', 'completed', '[]', 1)
      ''',
      <Object?>[id, path],
    );
  }

  test('uploads a local capture missing from R2', () async {
    final File source = File(p.join(directory.path, 'voice.m4a'));
    await source.writeAsBytes(<int>[1, 2, 3]);
    addRecording('capture-1', source.path);

    final R2SyncResult result = await R2MediaSyncService(
      db: database,
      store: store,
    ).sync();

    expect(result.success, isTrue);
    expect(result.uploaded, 1);
    expect(store.uploads, <String>['captures/capture-1/voice.m4a']);
  });

  test('downloads an R2 capture missing locally', () async {
    final File destination = File(p.join(directory.path, 'voice.m4a'));
    addRecording('capture-1', destination.path);
    final List<int> bytes = <int>[4, 5, 6];
    const String key = 'captures/capture-1/voice.m4a';
    store.objects[key] = bytes;
    store.hashes[key] = crypto.sha256.convert(bytes).toString();

    final R2SyncResult result = await R2MediaSyncService(
      db: database,
      store: store,
    ).sync();

    expect(result.success, isTrue);
    expect(result.downloaded, 1);
    expect(await destination.readAsBytes(), bytes);
  });

  test('leaves identical local and R2 captures unchanged', () async {
    final File source = File(p.join(directory.path, 'voice.m4a'));
    final List<int> bytes = <int>[7, 8, 9];
    await source.writeAsBytes(bytes);
    addRecording('capture-1', source.path);
    const String key = 'captures/capture-1/voice.m4a';
    store.objects[key] = bytes;
    store.hashes[key] = crypto.sha256.convert(bytes).toString();

    final R2SyncResult result = await R2MediaSyncService(
      db: database,
      store: store,
    ).sync();

    expect(result.unchanged, 1);
    expect(store.uploads, isEmpty);
    expect(store.downloads, isEmpty);
  });

  test('reports a conflict without overwriting either file', () async {
    final File source = File(p.join(directory.path, 'voice.m4a'));
    await source.writeAsBytes(<int>[1]);
    addRecording('capture-1', source.path);
    const String key = 'captures/capture-1/voice.m4a';
    store.objects[key] = <int>[2];
    store.hashes[key] = crypto.sha256.convert(<int>[2]).toString();

    final R2SyncResult result = await R2MediaSyncService(
      db: database,
      store: store,
    ).sync();

    expect(result.success, isFalse);
    expect(result.conflicts, 1);
    expect(await source.readAsBytes(), <int>[1]);
    expect(store.objects[key], <int>[2]);
    expect(store.uploads, isEmpty);
    expect(store.downloads, isEmpty);
  });

  test('returns a safe credential failure from bucket validation', () async {
    final File source = File(p.join(directory.path, 'voice.m4a'));
    await source.writeAsBytes(<int>[1]);
    addRecording('capture-1', source.path);
    store.validationError = const R2StoreException(
      'R2 rejected the access key (HTTP 403).',
    );

    final R2SyncResult result = await R2MediaSyncService(
      db: database,
      store: store,
    ).sync();

    expect(result.success, isFalse);
    expect(result.failureReason, 'R2 rejected the access key (HTTP 403).');
    expect(store.uploads, isEmpty);
  });

  test('reports a source missing both locally and remotely', () async {
    final File source = File(p.join(directory.path, 'lost.m4a'));
    addRecording('capture-1', source.path);

    final R2SyncResult result = await R2MediaSyncService(
      db: database,
      store: store,
    ).sync();

    expect(result.success, isFalse);
    expect(result.missing, 1);
    expect(result.failureReason, contains('missing'));
  });

  test('uploads every stored segment once', () async {
    final File first = File(p.join(directory.path, 'part-1.m4a'));
    final File second = File(p.join(directory.path, 'part 2.m4a'));
    await first.writeAsBytes(<int>[1]);
    await second.writeAsBytes(<int>[2]);
    addRecording('capture-1', first.path);
    database.rawDb.execute(
      'UPDATE recordings SET json_payload = ? WHERE id = ?',
      <Object?>[
        '{"segments":[{"filePath":"${first.path}"},{"filePath":"${second.path}"}]}',
        'capture-1',
      ],
    );

    final R2SyncResult result = await R2MediaSyncService(
      db: database,
      store: store,
    ).sync();

    expect(result.uploaded, 2);
    expect(
      store.uploads,
      containsAll(<String>[
        'captures/capture-1/part-1.m4a',
        'captures/capture-1/part 2.m4a',
      ]),
    );
  });

  test(
    'a concurrent first upload becomes a conflict, not an overwrite',
    () async {
      final File source = File(p.join(directory.path, 'voice.m4a'));
      await source.writeAsBytes(<int>[1]);
      addRecording('capture-1', source.path);
      store.racedUpload = <int>[2];

      final R2SyncResult result = await R2MediaSyncService(
        db: database,
        store: store,
      ).sync();

      expect(result.success, isFalse);
      expect(result.conflicts, 1);
      expect(store.objects['captures/capture-1/voice.m4a'], <int>[2]);
      expect(await source.readAsBytes(), <int>[1]);
    },
  );
}
