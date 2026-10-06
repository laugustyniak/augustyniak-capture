import 'dart:io';

import 'package:augustyniak_capture/features/mcp/data/sqlite_capture_source.dart';
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

  test('corrupt payload row is skipped, others load', () async {
    fx.insert(rec('good'));
    fx.insert(rec('bad'), payload: '{not json');
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['good']);
    expect(logs.join(), contains('bad'));
  });

  test('missing database and missing JSON throws a clear message', () async {
    final SqliteCaptureSource s = SqliteCaptureSource(
      dbPath: '${fx.dir.path}/nope.sqlite',
      recordingsDir: '${fx.dir.path}/nodir',
    );
    expect(
      s.recordings(),
      throwsA(predicate((Object e) => e.toString().contains('nope.sqlite'))),
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
    writer.execute(
      "INSERT INTO recordings (id, file_path, duration_ms, type, status, "
      "created_at, json_payload) VALUES ('pending','p',1,'text','saved',5,"
      "'${rec('pending').toJson().toString().replaceAll("'", '')}')",
    );
    final List<Recording> rows = await source().recordings();
    expect(rows.map((Recording r) => r.id), <String>['committed']);
    writer.execute('ROLLBACK;');
  });

  test('reader opens read-only: no write is possible', () {
    fx.insert(rec('a'));
    final Database ro = sqlite3.open(fx.dbPath, mode: OpenMode.readOnly);
    addTearDown(ro.close);
    expect(() => ro.execute('DELETE FROM recordings'), throwsA(anything));
    expect(File(fx.dbPath).existsSync(), isTrue);
  });
}
