import 'package:augustyniak_capture/features/costs/data/usage_repository.dart';
import 'package:augustyniak_capture/features/costs/domain/model_price.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

UsageEvent _event({
  required String id,
  String captureId = 'cap-1',
  UsageStage stage = UsageStage.enrichment,
  String model = 'gpt-5.6-luna',
  String provider = 'api.openai.com',
  DateTime? at,
  int? inputTokens = 1000,
  double? costUsd = 0.0002,
  UnpricedReason? unpricedReason,
}) {
  return UsageEvent(
    id: id,
    captureId: captureId,
    stage: stage,
    provider: provider,
    model: model,
    at: at ?? DateTime.utc(2026, 8, 9),
    inputTokens: inputTokens,
    costUsd: costUsd,
    unpricedReason: unpricedReason,
  );
}

void main() {
  late Database db;
  late UsageRepository repository;

  setUp(() {
    db = sqlite3.openInMemory();
    UsageRepository.createTable(db);
    repository = UsageRepository(db);
  });

  tearDown(() => db.close());

  test('an inserted event reads back whole', () {
    repository.insert(_event(id: 'e1'));

    final List<UsageEvent> rows = repository.forCapture('cap-1');

    expect(rows, hasLength(1));
    expect(rows.single.id, 'e1');
    expect(rows.single.model, 'gpt-5.6-luna');
    expect(rows.single.costUsd, closeTo(0.0002, 1e-9));
  });

  test('events of one capture sum across chunks and a retry', () {
    repository.insert(_event(id: 'e1', costUsd: 0.01));
    repository.insert(_event(id: 'e2', costUsd: 0.02));
    repository.insert(_event(id: 'e3', costUsd: 0.03));
    repository.insert(_event(id: 'e4', captureId: 'other', costUsd: 9.0));

    final double total = repository
        .forCapture('cap-1')
        .fold<double>(0, (double sum, UsageEvent e) => sum + (e.costUsd ?? 0));

    expect(total, closeTo(0.06, 1e-9));
  });

  test('totalSince counts only events at or after the boundary', () {
    repository.insert(_event(id: 'old', at: DateTime.utc(2026, 7, 31), costUsd: 5));
    repository.insert(_event(id: 'new', at: DateTime.utc(2026, 8, 1), costUsd: 2));

    final UsageTotal since = repository.totalSince(DateTime.utc(2026, 8, 1));
    expect(since.amountUsd, closeTo(2, 1e-9));
    expect(since.unpricedCount, 0);

    final UsageTotal all = repository.totalAll();
    expect(all.amountUsd, closeTo(7, 1e-9));
    expect(all.unpricedCount, 0);
  });

  test(
    'a total is a floor, with the unpriced calls it excludes reported '
    'alongside it rather than silently dropped from the sum',
    () {
      repository.insert(_event(id: 'priced', costUsd: 2));
      repository.insert(_event(
        id: 'unpriced-1',
        costUsd: null,
        unpricedReason: UnpricedReason.noRate,
      ));
      repository.insert(_event(
        id: 'unpriced-2',
        costUsd: null,
        unpricedReason: UnpricedReason.noQuantity,
      ));

      final UsageTotal total = repository.totalAll();

      // The old `SUM(cost_usd)` behaviour silently skipped the two null rows
      // and reported exactly `2` here too — this assertion alone cannot tell
      // the two implementations apart, which is why `unpricedCount` is
      // checked as well.
      expect(total.amountUsd, closeTo(2, 1e-9));
      expect(total.unpricedCount, 2);
    },
  );

  test(
    'an all-unpriced history has no floor to show, and must not read as '
    'zero spent',
    () {
      repository.insert(_event(
        id: 'unpriced-1',
        costUsd: null,
        unpricedReason: UnpricedReason.noRate,
      ));
      repository.insert(_event(
        id: 'unpriced-2',
        costUsd: null,
        unpricedReason: UnpricedReason.noRate,
      ));

      final UsageTotal total = repository.totalAll();

      // `SUM` over an all-NULL group is NULL, not zero — a caller that
      // defaults it with `?? 0` produces exactly the fabricated `$0.0000`
      // this feature exists to refuse.
      expect(total.amountUsd, isNull);
      expect(total.unpricedCount, 2);
    },
  );

  test(
    'a fresh install with no events reports no floor but no unpriced calls '
    'either — the UI, not the repository, is what renders that as zero',
    () {
      final UsageTotal total = repository.totalAll();

      // `SUM` over zero rows is NULL regardless of why there are zero rows;
      // it is `unpricedCount == 0` that tells a caller this null is safe to
      // show as `$0.00` rather than as "unknown".
      expect(total.amountUsd, isNull);
      expect(total.unpricedCount, 0);
    },
  );

  test('missing-rate counts group by model and exclude other reasons', () {
    repository.insert(_event(
      id: 'a',
      model: 'gpt-6-nova',
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));
    repository.insert(_event(
      id: 'b',
      model: 'gpt-6-nova',
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));
    repository.insert(_event(
      id: 'c',
      model: 'whisper-1',
      costUsd: null,
      unpricedReason: UnpricedReason.noQuantity,
    ));

    final Map<String, MissingRateInfo> missing = repository.missingRateCounts();
    expect(missing.keys, <String>['gpt-6-nova']);
    expect(missing['gpt-6-nova']!.count, 2);
    expect(repository.unknownQuantityCount(), 1);
  });

  test(
    'a missing-rate key carries whether its calls are transcription-stage, '
    'so the Config tab can offer the field that actually prices them',
    () {
      repository.insert(_event(
        id: 'chat',
        model: 'gpt-6-nova',
        stage: UsageStage.enrichment,
        costUsd: null,
        unpricedReason: UnpricedReason.noRate,
      ));
      repository.insert(_event(
        id: 'audio',
        model: 'custom-whisper',
        stage: UsageStage.transcription,
        costUsd: null,
        unpricedReason: UnpricedReason.noRate,
      ));

      final Map<String, MissingRateInfo> missing = repository.missingRateCounts();

      expect(missing['gpt-6-nova']!.isTranscription, isFalse);
      expect(missing['custom-whisper']!.isTranscription, isTrue);
    },
  );

  test('backfill prices only the null rows of that model', () {
    repository.insert(_event(
      id: 'a',
      model: 'gpt-6-nova',
      inputTokens: 1000000,
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));
    repository.insert(_event(id: 'b', model: 'gpt-5.6-luna', costUsd: 0.5));

    const PriceBook book = PriceBook(
      overrides: <String, ModelPrice>{
        'gpt-6-nova': ModelPrice(inputPerMTok: 3, outputPerMTok: 9),
      },
    );

    final int updated = repository.backfill('gpt-6-nova', book);

    expect(updated, 1);
    final List<UsageEvent> rows = repository.all();
    final UsageEvent filled =
        rows.firstWhere((UsageEvent e) => e.id == 'a');
    final UsageEvent untouched =
        rows.firstWhere((UsageEvent e) => e.id == 'b');
    expect(filled.costUsd, closeTo(3, 1e-9));
    expect(filled.unpricedReason, isNull);
    expect(untouched.costUsd, closeTo(0.5, 1e-9));
  });

  test('totalsByCapture sums two fully priced captures independently and '
      'omits an all-unpriced one', () {
    repository.insert(_event(id: 'a1', captureId: 'cap-a', costUsd: 0.01));
    repository.insert(_event(id: 'a2', captureId: 'cap-a', costUsd: 0.02));
    repository.insert(_event(id: 'b1', captureId: 'cap-b', costUsd: 5.0));
    // Every event on this capture is unpriced, so its SUM comes back null —
    // it must be absent from the map, not present with 0.
    repository.insert(_event(
      id: 'c1',
      captureId: 'cap-c',
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));

    final Map<String, double> totals = repository.totalsByCapture();

    expect(totals['cap-a'], closeTo(0.03, 1e-9));
    expect(totals['cap-b'], closeTo(5.0, 1e-9));
    expect(totals.containsKey('cap-c'), isFalse);
    expect(totals, hasLength(2));
  });

  test('a capture with a mix of priced and unpriced events is absent, not '
      'present with a partial sum', () {
    // Three chunks priced, a fourth not — plain SUM(cost_usd) would still
    // answer 0.03 here, understating what the capture actually cost. The
    // total is unknown, not $0.03, so the capture must not appear at all.
    repository.insert(_event(id: 'm1', captureId: 'cap-mixed', costUsd: 0.01));
    repository.insert(_event(id: 'm2', captureId: 'cap-mixed', costUsd: 0.01));
    repository.insert(_event(id: 'm3', captureId: 'cap-mixed', costUsd: 0.01));
    repository.insert(_event(
      id: 'm4',
      captureId: 'cap-mixed',
      costUsd: null,
      unpricedReason: UnpricedReason.noRate,
    ));
    // A control capture, fully priced, so the test can tell "the query
    // dropped everything" apart from "the query correctly dropped the mixed
    // one".
    repository.insert(_event(id: 'p1', captureId: 'cap-priced', costUsd: 0.5));

    final Map<String, double> totals = repository.totalsByCapture();

    expect(totals, isNot(contains('cap-mixed')));
    expect(totals['cap-mixed'], isNull);
    expect(totals['cap-priced'], closeTo(0.5, 1e-9));
  });

  test('backfill never rewrites a cost that is already recorded', () {
    repository.insert(_event(id: 'a', model: 'gpt-5.6-luna', costUsd: 0.5));

    const PriceBook book = PriceBook(
      overrides: <String, ModelPrice>{
        'gpt-5.6-luna': ModelPrice(inputPerMTok: 999, outputPerMTok: 999),
      },
    );

    expect(repository.backfill('gpt-5.6-luna', book), 0);
    expect(repository.all().single.costUsd, closeTo(0.5, 1e-9));
  });
}
