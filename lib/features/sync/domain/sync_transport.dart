import 'sync_table.dart';

class SyncPushResult {
  const SyncPushResult({
    required this.applied,
    required this.conflicts,
    this.rejected = const <Map<String, Object?>>[],
  });
  final int applied;
  final List<Map<String, Object?>> conflicts;

  /// Rows `sync_push` could not apply to their table at all (a bad cast, a
  /// missing not-null column, an unknown column) — distinct from a
  /// `conflicts` row, which is well-formed but lost the version race. The
  /// fake never populates this; the real transport (Task 8) unwraps each
  /// `{row, code}` entry the RPC returns down to its `row`.
  final List<Map<String, Object?>> rejected;
}

class SyncPage {
  const SyncPage({required this.rows, required this.hasMore});
  final List<Map<String, Object?>> rows;
  final bool hasMore;
}

/// The wire. One implementation talks PostgREST; tests hand the engine an
/// in-memory fake that enforces the same version gate.
abstract interface class SyncTransport {
  /// `sync_push` for one table. Rows carry `version` (versioned tables) and
  /// never `owner_id`/`updated_at`.
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows);

  /// Rows with `updated_at > since - 30 s` and `updated_at <= now() - 30 s`,
  /// ordered by `updated_at` and then every key column, one page at a time.
  ///
  /// [after] is the last row of the previous page (null for the first): a
  /// page continues strictly after its `(updated_at, keys…)` tuple rather
  /// than from an offset, so a row another device updates between two pages
  /// only moves itself — it cannot shift the rows behind it past the next
  /// page's start (#195).
  Future<SyncPage> pull(
    SyncTable table, {
    required DateTime? since,
    required Map<String, Object?>? after,
    required int limit,
  });

  Future<DateTime> serverNow();
}

/// The seam's default: wiring never fails, use does.
class DisabledSyncTransport implements SyncTransport {
  const DisabledSyncTransport();

  Never _unavailable() => throw StateError('Cloud sync is not configured');

  @override
  Future<SyncPushResult> push(SyncTable table, List<Map<String, Object?>> rows) async =>
      _unavailable();

  @override
  Future<SyncPage> pull(SyncTable table, {required DateTime? since, required Map<String, Object?>? after, required int limit}) async =>
      _unavailable();

  @override
  Future<DateTime> serverNow() async => _unavailable();
}

const Duration syncLagWindow = Duration(seconds: 30);
