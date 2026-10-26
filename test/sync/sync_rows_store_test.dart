import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/features/sync/data/sync_rows_store.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late SyncRowsStore store;

  setUp(() async {
    db = sqlite3.openInMemory();
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: db);
    store = SyncRowsStore(db);
  });

  tearDown(() {
    db.close();
    AppDatabase.resetForTesting();
  });

  test('put then loadTable round-trips per table', () {
    store.put('recordings', 'a', 3, 'h1');
    store.put('projects', 'a', 1, 'h2');
    final Map<String, SyncRowState> rows = store.loadTable('recordings');
    expect(rows.keys, <String>['a']);
    expect(rows['a']!.serverVersion, 3);
    expect(rows['a']!.pushedHash, 'h1');
  });

  test('put overwrites, remove forgets', () {
    store.put('recordings', 'a', 1, 'h1');
    store.put('recordings', 'a', 2, 'h2');
    expect(store.loadTable('recordings')['a']!.serverVersion, 2);
    store.remove('recordings', 'a');
    expect(store.loadTable('recordings'), isEmpty);
  });

  test('cursor is absent until set and survives a round-trip in UTC', () {
    expect(store.cursor('recordings'), isNull);
    final DateTime at = DateTime.utc(2026, 9, 21, 10, 0, 0, 123);
    store.setCursor('recordings', at);
    expect(store.cursor('recordings'), at);
  });

  test('sealed round-trips and defaults to false', () {
    store.put('recordings', 'a', 1, 'h1');
    store.put('recordings', 'b', 1, 'h2', sealed: true);
    final Map<String, SyncRowState> rows = store.loadTable('recordings');
    expect(rows['a']!.sealed, isFalse);
    expect(rows['b']!.sealed, isTrue);
    store.put('recordings', 'b', 2, 'h3');
    expect(store.loadTable('recordings')['b']!.sealed, isFalse);
  });

  test('a database from before the sealed column gains it, existing rows unsealed', () async {
    final Database old = sqlite3.openInMemory();
    addTearDown(old.close);
    old.execute('''
      CREATE TABLE sync_rows (
        table_name TEXT NOT NULL,
        id TEXT NOT NULL,
        server_version INTEGER NOT NULL,
        pushed_hash TEXT NOT NULL,
        PRIMARY KEY (table_name, id)
      )
    ''');
    old.execute("INSERT INTO sync_rows VALUES ('recordings', 'old', 4, 'hash')");
    AppDatabase.resetForTesting();
    await AppDatabase.getInstance(overrideDb: old);

    final SyncRowsStore migrated = SyncRowsStore(old);
    final SyncRowState row = migrated.loadTable('recordings')['old']!;
    expect(row.serverVersion, 4);
    expect(row.sealed, isFalse);
    migrated.put('recordings', 'old', 5, 'hash2', sealed: true);
    expect(migrated.loadTable('recordings')['old']!.sealed, isTrue);
  });
}
