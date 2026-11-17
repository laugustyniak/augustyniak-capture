import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../domain/sync_binding.dart';
import '../domain/sync_snapshot.dart';

/// Device-local sync bookkeeping over the `sync_rows` table and the
/// `sync.cursor.<table>` keys of the `settings` table, plus the `sync.owner`
/// key that binds both to one account (#206). Synchronous like the rest of
/// `AppDatabase`.
class SyncRowsStore implements SyncBookkeeping, SyncBindingStore {
  SyncRowsStore(this._db);

  final Database _db;

  static const String ownerKey = 'sync.owner';
  static const String _cursorPrefix = 'sync.cursor.';

  @override
  Map<String, SyncRowState> loadTable(String table) {
    final ResultSet rows = _db.select(
      'SELECT id, server_version, pushed_hash, sealed FROM sync_rows '
      'WHERE table_name = ?',
      <Object>[table],
    );
    return <String, SyncRowState>{
      for (final Row row in rows)
        row['id'] as String: SyncRowState(
          serverVersion: row['server_version'] as int,
          pushedHash: row['pushed_hash'] as String,
          sealed: (row['sealed'] as int? ?? 0) != 0,
        ),
    };
  }

  @override
  void put(
    String table,
    String id,
    int serverVersion,
    String pushedHash, {
    bool sealed = false,
  }) {
    _db.execute(
      'INSERT INTO sync_rows '
      '(table_name, id, server_version, pushed_hash, sealed) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT (table_name, id) DO UPDATE SET '
      'server_version = excluded.server_version, '
      'pushed_hash = excluded.pushed_hash, '
      'sealed = excluded.sealed',
      <Object>[table, id, serverVersion, pushedHash, sealed ? 1 : 0],
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
      <Object>['$_cursorPrefix$table'],
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
        '$_cursorPrefix$table',
        jsonEncode(value.toUtc().toIso8601String()),
      ],
    );
  }

  @override
  SyncOwnerRead readOwner() {
    final ResultSet rows = _db.select(
      'SELECT value_json FROM settings WHERE key = ?',
      <Object>[ownerKey],
    );
    if (rows.isEmpty) return const SyncOwnerAbsent();
    final Object? raw;
    try {
      raw = jsonDecode(rows.single['value_json'] as String);
    } on FormatException {
      return const SyncOwnerUnreadable();
    }
    if (raw case {'id': final String id} when id.isNotEmpty) {
      final Object? email = raw['email'];
      return SyncOwnerBound(id: id, email: email is String ? email : '');
    }
    return const SyncOwnerUnreadable();
  }

  @override
  bool hasLedgerRows() =>
      _db.select('SELECT 1 FROM sync_rows LIMIT 1').isNotEmpty;

  @override
  void bindOwner({required String id, required String email}) {
    _db.execute(
      'INSERT INTO settings (key, value_json) VALUES (?, ?) '
      'ON CONFLICT (key) DO UPDATE SET value_json = excluded.value_json',
      <Object>[
        ownerKey,
        jsonEncode(<String, String>{'id': id, 'email': email}),
      ],
    );
  }

  @override
  void unbind() {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('DELETE FROM sync_rows');
      // `substr` rather than LIKE: `_` is a LIKE wildcard, and only keys
      // that literally start with the prefix are cursors.
      _db.execute(
        'DELETE FROM settings WHERE key = ? OR substr(key, 1, ?) = ?',
        <Object>[ownerKey, _cursorPrefix.length, _cursorPrefix],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
