import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/features/sync/data/sync_rows_store.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_binding.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// #206: the `sync.owner` key that binds this device's library to one
/// account, stored beside the ledger it guards.
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

  void putSetting(String key, String valueJson) => db.execute(
    'INSERT INTO settings (key, value_json) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value_json = excluded.value_json',
    <Object>[key, valueJson],
  );

  int settingCount(String key) =>
      db.select('SELECT 1 FROM settings WHERE key = ?', <Object>[key]).length;

  test('an unbound device reads as absent', () {
    expect(store.readOwner(), isA<SyncOwnerAbsent>());
  });

  test('bindOwner round-trips id and email', () {
    store.bindOwner(id: 'owner-a', email: 'a@example.com');
    final SyncOwnerRead read = store.readOwner();
    expect(read, isA<SyncOwnerBound>());
    read as SyncOwnerBound;
    expect(read.id, 'owner-a');
    expect(read.email, 'a@example.com');
  });

  test(
    'a sync.owner that is not a decodable owner record is unreadable, never absent',
    () {
      for (final String raw in <String>[
        'not json',
        '"owner-a"',
        '{}',
        '{"id": ""}',
        '{"id": 7}',
        'null',
      ]) {
        putSetting('sync.owner', raw);
        expect(
          store.readOwner(),
          isA<SyncOwnerUnreadable>(),
          reason: 'value_json $raw must not read as an unbound device',
        );
      }
    },
  );

  test('hasLedgerRows reflects sync_rows only', () {
    store.setCursor('recordings', DateTime.utc(2026, 1, 1));
    expect(store.hasLedgerRows(), isFalse);
    store.put('recordings', 'r1', 1, 'h');
    expect(store.hasLedgerRows(), isTrue);
  });

  test('unbind removes only sync_rows, sync.cursor.* and sync.owner', () {
    store.put('recordings', 'r1', 3, 'h1');
    store.put('projects', 'p1', 1, 'h2');
    store.setCursor('recordings', DateTime.utc(2026, 1, 1));
    store.setCursor('clipboard_items', DateTime.utc(2026, 1, 2));
    store.bindOwner(id: 'owner-a', email: 'a@example.com');
    putSetting('sync.cursorless', '"keep"');
    putSetting('theme', '"dark"');
    db.execute(
      'INSERT INTO clipboard_items (id, type, text, copied_at) '
      "VALUES ('c1', 'text', 'kept', 1)",
    );

    store.unbind();

    expect(store.hasLedgerRows(), isFalse);
    expect(store.loadTable('recordings'), isEmpty);
    expect(store.cursor('recordings'), isNull);
    expect(store.cursor('clipboard_items'), isNull);
    expect(store.readOwner(), isA<SyncOwnerAbsent>());
    expect(settingCount('sync.cursorless'), 1);
    expect(settingCount('theme'), 1);
    expect(db.select('SELECT 1 FROM clipboard_items').length, 1);
  });

  test('unbind also clears an unreadable binding', () {
    putSetting('sync.owner', 'garbage');
    store.unbind();
    expect(store.readOwner(), isA<SyncOwnerAbsent>());
  });
}
