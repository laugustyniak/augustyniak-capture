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
}
