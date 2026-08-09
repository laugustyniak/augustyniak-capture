import 'package:sqlite3/sqlite3.dart';

import '../domain/price_book.dart';
import '../domain/usage_event.dart';

/// Persists one row per API call.
///
/// **Append-only in practice.** The single `UPDATE` is the backfill, and it is
/// scoped to rows that were never priced — a recorded cost is a fact about what
/// was paid and a later rate change must not rewrite it.
class UsageRepository {
  UsageRepository(this._db);

  final Database _db;

  /// Kept here rather than inline in `AppDatabase` so the tests can build the
  /// schema against an in-memory database without the app's path provider.
  /// `AppDatabase._initTables()` calls this.
  static void createTable(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS usage_events (
        id TEXT PRIMARY KEY,
        capture_id TEXT NOT NULL,
        stage TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        at INTEGER NOT NULL,
        input_tokens INTEGER,
        output_tokens INTEGER,
        audio_seconds REAL,
        cost_usd REAL,
        unpriced_reason TEXT
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_usage_capture
      ON usage_events(capture_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_usage_at ON usage_events(at DESC);
    ''');
  }

  void insert(UsageEvent event) {
    _db.execute(
      '''
      INSERT OR REPLACE INTO usage_events
      (id, capture_id, stage, provider, model, at, input_tokens,
       output_tokens, audio_seconds, cost_usd, unpriced_reason)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      <Object?>[
        event.id,
        event.captureId,
        event.stage.name,
        event.provider,
        event.model,
        event.at.millisecondsSinceEpoch,
        event.inputTokens,
        event.outputTokens,
        event.audioSeconds,
        event.costUsd,
        event.unpricedReason?.name,
      ],
    );
  }

  List<UsageEvent> forCapture(String captureId) => _select(
    'SELECT * FROM usage_events WHERE capture_id = ? ORDER BY at ASC;',
    <Object?>[captureId],
  );

  List<UsageEvent> all() =>
      _select('SELECT * FROM usage_events ORDER BY at DESC;', <Object?>[]);

  double totalSince(DateTime from) {
    final ResultSet rows = _db.select(
      'SELECT SUM(cost_usd) AS total FROM usage_events WHERE at >= ?;',
      <Object?>[from.millisecondsSinceEpoch],
    );
    return (rows.first['total'] as num?)?.toDouble() ?? 0;
  }

  double totalAll() {
    final ResultSet rows =
        _db.select('SELECT SUM(cost_usd) AS total FROM usage_events;');
    return (rows.first['total'] as num?)?.toDouble() ?? 0;
  }

  /// Every **fully priced** capture's summed cost, keyed by capture id — the
  /// queue card's and compact row's source for `VerificationLine.costUsd`.
  ///
  /// One `GROUP BY` per queue build rather than `all()` plus a Dart-side fold:
  /// the queue can hold thousands of rows across their whole history, and the
  /// aggregate is the only thing a card ever needs.
  ///
  /// A capture is **absent** from the map — never present with `0`, and never
  /// present with a partial sum — unless **every** one of its events priced.
  /// Plain `SUM(cost_usd)` was tried first and is wrong: SQLite's `SUM`
  /// ignores individual `NULL`s, so three priced chunks plus one `noRate`
  /// chunk would still sum to a real number and render as, say, `$0.0047` —
  /// which states a total cost that is not the total cost. The capture cost
  /// *more* than that; the fourth chunk's price is simply unknown, and a
  /// number on screen does not say so. That silent understatement is exactly
  /// the failure this whole feature exists to prevent, and it is worse here
  /// than anywhere else: the card has no per-event breakdown to qualify it
  /// with (unlike the editor's `CostSection`, which prints each event's stage
  /// and can say `no rate` right next to the number, so `cost —` there is
  /// explained on the same screen). `HAVING COUNT(*) = COUNT(cost_usd)` is
  /// what enforces "every row priced": `COUNT(*)` counts every row in the
  /// group, `COUNT(cost_usd)` — unlike `SUM` — counts only the non-null ones,
  /// and the two are equal exactly when no row in the group is null. This is
  /// the same rule `RecordingEditor`'s `_totalCostUsd()` applies in Dart for
  /// the same capture's own `VerificationLine`; the two must agree, and this
  /// query is now this repository's half of that agreement.
  Map<String, double> totalsByCapture() {
    final ResultSet rows = _db.select('''
      SELECT capture_id, SUM(cost_usd) AS total
      FROM usage_events
      GROUP BY capture_id
      HAVING COUNT(*) = COUNT(cost_usd);
    ''');
    final Map<String, double> totals = <String, double>{};
    for (final Row row in rows) {
      final num? total = row['total'] as num?;
      // Not reachable given the HAVING clause above (a group that passes it
      // has no null cost_usd, so SUM cannot be null either) — kept as a
      // guard rather than a `!`, so a future change to the query degrades by
      // omission instead of by crash.
      if (total == null) continue;
      totals[row['capture_id'] as String] = total.toDouble();
    }
    return totals;
  }

  /// Models whose events could not be priced **because no rate existed** —
  /// the only ones a rate would fix, and so the only ones the Config tab may
  /// offer a rate field for.
  Map<String, int> missingRateCounts() {
    final ResultSet rows = _db.select('''
      SELECT model, provider, COUNT(*) AS calls
      FROM usage_events
      WHERE unpriced_reason = 'noRate'
      GROUP BY model, provider;
    ''');
    return <String, int>{
      for (final Row row in rows)
        PriceBook.keyFor(row['model'] as String, row['provider'] as String):
            (row['calls'] as num).toInt(),
    };
  }

  /// Events whose rate is known and whose billable amount is not — reported
  /// separately, because no rate the user types would price them.
  int unknownQuantityCount() {
    final ResultSet rows = _db.select('''
      SELECT COUNT(*) AS calls FROM usage_events
      WHERE unpriced_reason = 'noQuantity';
    ''');
    return (rows.first['calls'] as num).toInt();
  }

  /// Price the rows that were never priced for this key. Returns how many rows
  /// changed. Rows with a recorded cost are untouched by construction: the
  /// `WHERE` clause cannot see them.
  int backfill(String key, PriceBook book) {
    final ResultSet rows = _db.select(
      '''
      SELECT * FROM usage_events
      WHERE cost_usd IS NULL AND (model = ? OR (model = '' AND provider = ?));
      ''',
      <Object?>[key, key],
    );

    int updated = 0;
    for (final Row row in rows) {
      final UsageEvent event = _fromRow(row);
      final PricedResult priced = book.price(event);
      if (priced.costUsd == null) continue;
      _db.execute(
        'UPDATE usage_events SET cost_usd = ?, unpriced_reason = NULL WHERE id = ?;',
        <Object?>[priced.costUsd, event.id],
      );
      updated++;
    }
    return updated;
  }

  List<UsageEvent> _select(String sql, List<Object?> params) =>
      <UsageEvent>[for (final Row row in _db.select(sql, params)) _fromRow(row)];

  static UsageEvent _fromRow(Row row) => UsageEvent(
    id: row['id'] as String,
    captureId: row['capture_id'] as String,
    // A row is only ever written from a `UsageStage`, so an unreadable stage
    // here means hand-edited data; fall back rather than throw out of a query
    // that the Config tab renders from.
    stage: UsageStage.fromName(row['stage'] as String?) ??
        UsageStage.enrichment,
    provider: row['provider'] as String,
    model: row['model'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(
      (row['at'] as num).toInt(),
      isUtc: true,
    ),
    inputTokens: (row['input_tokens'] as num?)?.toInt(),
    outputTokens: (row['output_tokens'] as num?)?.toInt(),
    audioSeconds: (row['audio_seconds'] as num?)?.toDouble(),
    costUsd: (row['cost_usd'] as num?)?.toDouble(),
    unpricedReason: UnpricedReason.fromName(row['unpriced_reason'] as String?),
  );
}
