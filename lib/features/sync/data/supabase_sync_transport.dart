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
  /// The full key tuple makes the order total, which is what lets a page
  /// continue strictly after the previous page's last tuple — see
  /// [keysetFilter].
  @override
  Future<SyncPage> pull(SyncTable table, {required DateTime? since, required Map<String, Object?>? after, required int limit}) async {
    final DateTime upper = (await serverNow()).subtract(syncLagWindow);
    PostgrestFilterBuilder<List<Map<String, dynamic>>> query =
        _client.from(table.serverName).select().lte('updated_at', upper.toIso8601String());
    if (since != null) {
      // `.toUtc()` first: an offset-less ISO string reads as server-local
      // in Postgres, which would silently shift the lag window if `since`
      // ever arrived un-normalized.
      query = query.gt('updated_at', since.toUtc().subtract(syncLagWindow).toIso8601String());
    }
    if (after != null) query = query.or(keysetFilter(table, after));
    PostgrestTransformBuilder<List<Map<String, dynamic>>> ordered = query.order('updated_at', ascending: true);
    for (final String key in table.keyColumns) {
      ordered = ordered.order(key, ascending: true);
    }
    final List<Map<String, dynamic>> rows = await ordered.limit(limit);
    return SyncPage(
      rows: <Map<String, Object?>>[for (final Map<String, dynamic> r in rows) Map<String, Object?>.from(r)],
      hasMore: rows.length == limit,
    );
  }

  /// PostgREST `or` filter for "strictly after [after]" in the pull order:
  /// `(updated_at, k1, …, kn) > (T, V1, …, Vn)` spelled out lexicographically,
  /// since PostgREST has no row-value comparison —
  /// `updated_at.gt.T, and(updated_at.eq.T, k1.gt.V1), …`.
  ///
  /// Every value is double-quoted, because a key such as `revisions.field`
  /// or `sync_state.table_name` is free text and a bare `,` or `)` would
  /// end the operand. `updated_at` is used exactly as the server returned
  /// it: re-encoding it through `DateTime` would drop microseconds on a
  /// platform that only keeps milliseconds, and `eq` would then never match.
  static String keysetFilter(SyncTable table, Map<String, Object?> after) {
    final List<(String, Object?)> columns = <(String, Object?)>[
      ('updated_at', after['updated_at']),
      for (final String key in table.keyColumns) (key, after[key]),
    ];
    final List<String> branches = <String>[];
    for (int i = 0; i < columns.length; i++) {
      final List<String> terms = <String>[
        for (final (String column, Object? value) in columns.take(i)) '$column.eq.${_quote(value)}',
        '${columns[i].$1}.gt.${_quote(columns[i].$2)}',
      ];
      branches.add(terms.length == 1 ? terms.single : 'and(${terms.join(',')})');
    }
    return branches.join(',');
  }

  static String _quote(Object? value) =>
      '"${'$value'.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

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
