import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// The index lives in two places — the `recordings` table and `recordings.json`
/// — and `loadAll` reads the table first, falling back to the file only when
/// the select throws or answers zero rows. So the table is the authority
/// whenever it holds anything at all.
///
/// That is safe only while both writers succeed together. `saveAll` rewrites
/// the table inside a transaction and rolls back on error, then rewrites the
/// JSON unconditionally — so a failed transaction leaves the table holding the
/// *previous* state while the file holds the current one. On the next launch
/// the stale half wins and the user's edit is silently undone: a deleted
/// capture comes back, a corrected transcript reverts.
///
/// The trigger below stands in for every real way that transaction can fail —
/// a full disk, a database locked by a second instance, a constraint added by
/// a later migration. What matters is the shape: the table stays readable and
/// stale rather than becoming unreadable, which is the one failure the
/// fallback cannot see.
class TempRepository extends RecordingsRepository {
  TempRepository(this.root);

  final Directory root;

  @override
  Future<Directory> recordingsDirectory() async {
    if (!await root.exists()) await root.create(recursive: true);
    return root;
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
  late Directory root;
  late Database db;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('sqlite-divergence-');
    AppDatabase.resetForTesting();
    db = sqlite3.openInMemory();
    await AppDatabase.getInstance(overrideDb: db);
  });

  tearDown(() {
    AppDatabase.resetForTesting();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Refuses every insert into `recordings` while leaving existing rows
  /// readable — a write failure the table survives.
  void failEveryInsert() {
    db.execute('''
      CREATE TRIGGER refuse_inserts BEFORE INSERT ON recordings
      BEGIN
        SELECT RAISE(ABORT, 'simulated write failure');
      END;
    ''');
  }

  test('a failed SQLite write does not resurrect a deleted capture', () async {
    final TempRepository repository = TempRepository(root);
    await repository.saveAll(<Recording>[_item('a'), _item('b')]);

    failEveryInsert();

    // The one deliberate shrink, exactly as `deleteRecording` announces it.
    repository.expectRowCount(1);
    await repository.saveAll(<Recording>[_item('a')]);

    final List<Recording> reloaded = await TempRepository(root).loadAll();

    expect(
      reloaded.map((Recording r) => r.id).toList(),
      <String>['a'],
      reason: 'the JSON index holds the truth once the table write failed',
    );
  });

  test('a database that recovers speaks for the index again', () async {
    final TempRepository repository = TempRepository(root);
    await repository.saveAll(<Recording>[_item('a'), _item('b')]);

    failEveryInsert();
    repository.expectRowCount(1);
    await repository.saveAll(<Recording>[_item('a')]);

    db.execute('DROP TRIGGER refuse_inserts;');
    await repository.saveAll(<Recording>[_item('a')]);

    // A row that reached the table without passing through `saveAll` — which is
    // exactly what a Turso pull produces. Distrusting the table forever would
    // make every synced capture invisible, so the marker has to lift itself the
    // moment a write commits again.
    db.execute('''
      INSERT INTO recordings
      (id, file_path, duration_ms, type, status, tags_json, created_at,
       is_processed_by_user, json_payload)
      VALUES ('pulled', '/tmp/pulled.m4a', 1000, 'audioRecording', 'completed',
              '[]', 1, 0, NULL);
    ''');

    final List<Recording> reloaded = await TempRepository(root).loadAll();

    expect(
      reloaded.map((Recording r) => r.id),
      contains('pulled'),
      reason: 'the table is the read source again once it commits',
    );
  });

  /// Only `json_payload` carries the whole capture; the columns beside it are a
  /// subset chosen for querying and for the sync protocol. `transcript` is not
  /// among them, so a row whose payload cannot be read comes back **without the
  /// text** — and looks entirely healthy doing it. The next save then writes
  /// that emptied row over the JSON index, which is where the text still was.
  test('an unreadable payload falls back to the index, not to an empty row',
      () async {
    final TempRepository repository = TempRepository(root);
    await repository.saveAll(<Recording>[
      _item('a', transcript: 'the words that were captured'),
    ]);

    db.execute("UPDATE recordings SET json_payload = '{oops' WHERE id = 'a';");

    final List<Recording> reloaded = await TempRepository(root).loadAll();

    expect(
      reloaded.single.transcript,
      'the words that were captured',
      reason: 'the JSON index still holds what the columns cannot express',
    );
  });
}
