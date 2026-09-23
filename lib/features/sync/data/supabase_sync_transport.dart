import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/sync_table.dart';
import '../domain/sync_transport.dart';

/// PostgREST + the `sync_push` RPC. With `supabase_media_store.dart`, the only
/// files in the feature that import `supabase_flutter`; everything above them
/// is testable without a network.
class SupabaseSyncTransport implements SyncTransport {
  SupabaseSyncTransport(this._client);

  final SupabaseClient _client;

  @override
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return const SyncPushResult(applied: 0, conflicts: <Map<String, Object?>>[]);
    final Object? raw = await _client.rpc<Object?>(
      'sync_push',
      params: <String, Object?>{'table_name': table.serverName, 'rows': rows},
    );
    return parsePushResult(raw);
  }

  /// Parses `sync_push`'s `{applied, conflicts, rejected}` shape.
  /// `rejected` arrives as `[{"row": row, "code": sqlstate}, …]` — the
  /// engine matches a rejected row back to the row it pushed by `rowId`, so
  /// each entry is unwrapped to its `row` here rather than carried through
  /// wrapped; a wrapped `{row, code}` would silently never match and every
  /// rejection would be dropped on the floor instead of counted.
  static SyncPushResult parsePushResult(Object? raw) {
    if (raw is! Map) throw StateError('sync_push answered ${raw.runtimeType}');
    final Object? conflicts = raw['conflicts'];
    final Object? rejected = raw['rejected'];
    return SyncPushResult(
      applied: raw['applied'] is int ? raw['applied'] as int : 0,
      conflicts: <Map<String, Object?>>[
        if (conflicts is List)
          for (final Object? c in conflicts)
            if (c is Map) Map<String, Object?>.from(c),
      ],
      rejected: <Map<String, Object?>>[
        if (rejected is List)
          for (final Object? r in rejected)
            if (r is Map && r['row'] is Map) Map<String, Object?>.from(r['row'] as Map),
      ],
    );
  }

  /// Orders by `updated_at` and then by **every** key column, not just the
  /// first — `segments`, `revisions` and `sync_state` key on more than one
  /// column, and `(updated_at, firstKey)` alone is only a partial order for
  /// those: two rows can tie on both and still differ on a later key
  /// column, which makes their relative position across a page boundary
  /// arbitrary and can skip a row between one `range()` call and the next.
  /// The full key tuple makes the order total, so paging is stable.
  @override
  Future<SyncPage> pull(SyncTable table, {required DateTime? since, required int offset, required int limit}) async {
    final DateTime upper = (await serverNow()).subtract(syncLagWindow);
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
        _client.from(table.serverName).select().lte('updated_at', upper.toIso8601String());
    if (since != null) {
      // `.toUtc()` first: an offset-less ISO string reads as server-local
      // in Postgres, which would silently shift the lag window if `since`
      // ever arrived un-normalized.
      query = query.gt('updated_at', since.toUtc().subtract(syncLagWindow).toIso8601String());
    }
    PostgrestTransformBuilder<List<Map<String, dynamic>>> ordered = query.order('updated_at', ascending: true);
    for (final String key in table.keyColumns) {
      ordered = ordered.order(key, ascending: true);
    }
    final List<Map<String, dynamic>> rows = await ordered.range(offset, offset + limit - 1);
    return SyncPage(
      rows: <Map<String, Object?>>[for (final Map<String, dynamic> r in rows) Map<String, Object?>.from(r)],
      hasMore: rows.length == limit,
    );
  }

  @override
  Future<DateTime> serverNow() async {
    // PostgREST has no clock endpoint; `now()` through a tiny RPC is
    // cheaper than a round trip per table, so `sync_push` ships with it.
    // The fallback below only fires if the RPC answers something that is
    // not a timestamp string — it never does in normal operation, since
    // `sync_now` always returns `timestamptz`.
    final Object? raw = await _client.rpc<Object?>('sync_now');
    return raw is String ? DateTime.parse(raw).toUtc() : DateTime.now().toUtc();
  }
}
