import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../domain/sync_snapshot.dart';

/// Device-local sync bookkeeping over the `sync_rows` table and the
/// `sync.cursor.<table>` keys of the `settings` table. Synchronous like the
/// rest of `AppDatabase`.
class SyncRowsStore implements SyncBookkeeping {
  SyncRowsStore(this._db);

  final Database _db;

  @override
  Map<String, SyncRowState> loadTable(String table) {
    final ResultSet rows = _db.select(
      'SELECT id, server_version, pushed_hash FROM sync_rows WHERE table_name = ?',
      <Object>[table],
    );
    return <String, SyncRowState>{
      for (final Row row in rows)
        row['id'] as String: SyncRowState(
          serverVersion: row['server_version'] as int,
          pushedHash: row['pushed_hash'] as String,
        ),
    };
  }

  @override
  void put(String table, String id, int serverVersion, String pushedHash) {
    _db.execute(
      'INSERT INTO sync_rows (table_name, id, server_version, pushed_hash) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT (table_name, id) DO UPDATE SET '
      'server_version = excluded.server_version, '
      'pushed_hash = excluded.pushed_hash',
      <Object>[table, id, serverVersion, pushedHash],
    );
  }

  @override
  void remove(String table, String id) {
    _db.execute(
      'DELETE FROM sync_rows WHERE table_name = ? AND id = ?',
      <Object>[table, id],
    );
  }

  @override
  DateTime? cursor(String table) {
    final ResultSet rows = _db.select(
      'SELECT value_json FROM settings WHERE key = ?',
      <Object>['sync.cursor.$table'],
    );
    if (rows.isEmpty) return null;
    final Object? raw = jsonDecode(rows.single['value_json'] as String);
    return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
  }

  @override
  void setCursor(String table, DateTime value) {
    _db.execute(
      'INSERT INTO settings (key, value_json) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value_json = excluded.value_json',
      <Object>[
        'sync.cursor.$table',
        jsonEncode(value.toUtc().toIso8601String()),
      ],
    );
  }
}
