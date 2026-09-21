import 'package:augustyniak_capture/features/sync/domain/sync_row_codec.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_table.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_transport.dart';

/// In-memory server with the same version gate as `sync_push` and the same
/// pull window. `clock` stamps `updated_at`.
///
/// The version gate mirrors the migration's upsert exactly: a row with no
/// existing match is inserted at whatever version it carries (`sync_push`
/// never checks a new row's version), and an existing row is only updated
/// when its current version is exactly one behind the incoming one —
/// otherwise the push returns the server's row as a conflict.
/// `revisions` has no version column at all: it inserts on its natural key
/// and a repeat is a no-op, never a conflict.
class FakeSyncTransport implements SyncTransport {
  FakeSyncTransport({DateTime Function()? clock})
      : clock = clock ?? (() => DateTime.now().toUtc());

  DateTime Function() clock;
  final Map<SyncTable, Map<String, Map<String, Object?>>> tables =
      <SyncTable, Map<String, Map<String, Object?>>>{};
  final List<(SyncTable, List<Map<String, Object?>>)> pushes = [];
  Object? failWith;

  Map<String, Map<String, Object?>> _table(SyncTable t) =>
      tables.putIfAbsent(t, () => <String, Map<String, Object?>>{});

  @override
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows) async {
    if (failWith != null) throw failWith!;
    pushes.add((table, rows));
    int applied = 0;
    final List<Map<String, Object?>> conflicts = [];
    for (final Map<String, Object?> row in rows) {
      final String id = SyncRowCodec.rowId(table, row);
      final Map<String, Object?>? current = _table(table)[id];
      if (!table.versioned) {
        if (current == null) {
          _table(table)[id] = {...row, 'updated_at': clock().toIso8601String()};
          applied++;
        }
        continue;
      }
      final int incoming = row['version'] as int;
      final bool ok = current == null || current['version'] == incoming - 1;
      if (ok) {
        _table(table)[id] = {...row, 'updated_at': clock().toIso8601String()};
        applied++;
      } else {
        // `!ok` only when `current` is non-null (a new row is always `ok`);
        // the analyzer promotes `current` to non-null here on that basis.
        conflicts.add(Map<String, Object?>.from(current));
      }
    }
    return SyncPushResult(applied: applied, conflicts: conflicts);
  }

  @override
  Future<SyncPage> pull(SyncTable table, {required DateTime? since, required int offset, required int limit}) async {
    if (failWith != null) throw failWith!;
    final DateTime upper = clock().subtract(syncLagWindow);
    final DateTime? lower = since?.subtract(syncLagWindow);
    final List<Map<String, Object?>> all = _table(table).values.where((row) {
      final DateTime at = DateTime.parse(row['updated_at'] as String);
      return !at.isAfter(upper) && (lower == null || at.isAfter(lower));
    }).toList()
      ..sort((a, b) {
        final int c = (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return c != 0 ? c : SyncRowCodec.rowId(table, a).compareTo(SyncRowCodec.rowId(table, b));
      });
    final List<Map<String, Object?>> page = all.skip(offset).take(limit).map((r) => Map<String, Object?>.from(r)).toList();
    return SyncPage(rows: page, hasMore: offset + limit < all.length);
  }

  @override
  Future<DateTime> serverNow() async => clock();
}
