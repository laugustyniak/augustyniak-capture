import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/sync_table.dart';
import '../domain/sync_transport.dart';

/// PostgREST + the `sync_push` RPC. The only file in the feature that imports
/// `supabase_flutter`; everything above it is testable without a network.
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
    final List<Map<String, dynamic>> rows = await query
        .order('updated_at', ascending: true)
        .order(table.keyColumns.first, ascending: true)
        .range(offset, offset + limit - 1);
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
