import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
import 'package:augustyniak_capture/features/mcp/domain/capture_source.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mcp_fixture.dart';

void main() {
  late McpFixture fx;
  late List<String> logs;
  SqliteCaptureSource source() => SqliteCaptureSource(
    dbPath: fx.dbPath,
    recordingsDir: fx.recordingsDir.path,
    log: logs.add,
  );

  setUp(() {
    fx = McpFixture();
    logs = <String>[];
  });
  tearDown(() => fx.dispose());

  test('loads recordings from SQLite newest first', () async {
    fx.insert(rec('old', at: DateTime.utc(2026, 1, 1)));
    fx.insert(rec('new', at: DateTime.utc(2026, 2, 1)));
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['new', 'old']);
  });

  test('stale marker makes the JSON index win over the database', () async {
    fx.insert(rec('from-db', title: 'db'));
    fx.writeJsonIndex(<Recording>[rec('from-json', title: 'json')]);
    fx.markStale();
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['from-json']);
  });

  test('unparseable payload degrades to the columns, others load', () async {
    fx.insert(rec('good', at: DateTime.utc(2026, 2, 1)));
    fx.insert(rec('bad', title: 'col'), payload: '{not json');
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['good', 'bad']);
  });

  test('missing database and missing JSON throws a clear message', () async {
    final SqliteCaptureSource s = SqliteCaptureSource(
      dbPath: '${fx.dir.path}/nope.sqlite',
      recordingsDir: '${fx.dir.path}/nodir',
    );
    expect(
      s.recordings(),
      throwsA(
        isA<CaptureStoreUnavailable>().having(
          (CaptureStoreUnavailable e) => e.detail,
          'detail',
          contains('nope.sqlite'),
        ),
      ),
    );
  });

  test('empty table falls back to the JSON index like loadAll', () async {
    fx.writeJsonIndex(<Recording>[rec('json-only')]);
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['json-only']);
  });

  test('projects load from SQLite', () async {
    fx.insertProject(projectA);
    expect((await source().projects()).single.name, 'Alpha Repo');
  });

  test('reader sees committed rows while a writer holds an open '
      'transaction, and never the uncommitted one', () async {
    fx.insert(rec('committed'));
    final Database writer = sqlite3.open(fx.dbPath);
    addTearDown(writer.close);
    writer.execute('BEGIN IMMEDIATE;');
    // A real, decodable payload: were the reader to see this row it would
    // load it, so its absence proves isolation rather than a skipped row.
    final Recording pending = rec('pending');
    writer.execute(
      'INSERT INTO recordings (id, file_path, duration_ms, type, status, '
      'created_at, json_payload) VALUES (?,?,?,?,?,?,?)',
      <Object?>[
        pending.id,
        pending.filePath,
        pending.durationMs,
        pending.type.name,
        pending.status.name,
        pending.createdAt.millisecondsSinceEpoch,
        jsonEncode(pending.toJson()),
      ],
    );
    addTearDown(() {
      try {
        writer.execute('ROLLBACK;');
      } catch (_) {}
    });
    expect(logs, isEmpty);
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['committed']);
    expect(logs, isEmpty, reason: 'no row was skipped as unreadable');
  });

  test('reads change nothing on disk: SQLite, JSON fallback, stale marker, '
      'corrupt index', () async {
    Map<String, String> snapshot() => <String, String>{
      for (final Directory d in <Directory>[fx.dir, fx.recordingsDir])
        for (final File f in d.listSync().whereType<File>())
          f.path:
              '${f.lengthSync()}@${f.lastModifiedSync().microsecondsSinceEpoch}',
    };

    Future<void> readEverything() async {
      try {
        await source().recordings();
      } catch (_) {}
      await source().projects();
    }

    // 1. SQLite path.
    fx.insert(rec('a'));
    fx.insertProject(projectA);
    Map<String, String> before = snapshot();
    await readEverything();
    expect(snapshot(), before, reason: 'sqlite path');

    // 2. JSON fallback: the table is empty.
    fx.db.execute('DELETE FROM recordings');
    fx.writeJsonIndex(<Recording>[rec('j')]);
    File('${fx.recordingsDir.path}/projects.json').writeAsStringSync('[]');
    before = snapshot();
    await readEverything();
    expect(snapshot(), before, reason: 'json fallback');

    // 3. Stale marker.
    fx.markStale();
    before = snapshot();
    await readEverything();
    expect(snapshot(), before, reason: 'stale marker');

    // 4. A corrupt index must not be backed up, only reported.
    File('${fx.recordingsDir.path}/recordings.json').writeAsStringSync('{bad');
    before = snapshot();
    await readEverything();
    expect(snapshot(), before, reason: 'corrupt index');
  });

  test(
    'NULL payload rebuilds the row from its columns, like loadAll',
    () async {
      fx.db.execute(
        "INSERT INTO recordings (id, file_path, duration_ms, type, status, "
        "title, summary, tags_json, created_at, project_id, json_payload) "
        "VALUES ('col','/x/col.m4a',5,'audioRecording','failed','From columns',"
        "'sum','[\"t1\"]',1700000000000,'p-1',NULL)",
      );
      final List<Recording> rows = await source().recordings();
      expect(rows, hasLength(1));
      expect(rows.single.title, 'From columns');
      expect(rows.single.summary, 'sum');
      expect(rows.single.tags, <String>['t1']);
      expect(rows.single.status, RecordingStatus.failed);
      expect(rows.single.projectId, 'p-1');
      expect(rows.single.transcript, isNull);
    },
  );

  test(
    'a degraded row takes the JSON index version, which has the text',
    () async {
      fx.insert(rec('d', title: 'col title'), useJson: false);
      fx.writeJsonIndex(<Recording>[rec('d', transcript: 'the full text')]);
      final List<Recording> rows = await source().recordings();
      expect(rows.single.transcript, 'the full text');
    },
  );

  test('an all-degraded table does not fall back to the JSON index', () async {
    fx.insert(rec('only-db', title: 'db'), useJson: false);
    fx.writeJsonIndex(<Recording>[rec('only-json')]);
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['only-db']);
  });
}
