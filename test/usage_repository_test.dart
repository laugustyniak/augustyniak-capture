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

  tearDown(() => db.dispose());

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

    expect(repository.totalSince(DateTime.utc(2026, 8, 1)), closeTo(2, 1e-9));
    expect(repository.totalAll(), closeTo(7, 1e-9));
  });

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

    expect(repository.missingRateCounts(), <String, int>{'gpt-6-nova': 2});
    expect(repository.unknownQuantityCount(), 1);
  });

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

  test('totalsByCapture sums two captures independently and omits an '
      'all-unpriced one', () {
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
