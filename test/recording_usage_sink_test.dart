import 'package:augustyniak_capture/features/costs/data/recording_usage_sink.dart';
import 'package:augustyniak_capture/features/costs/data/usage_repository.dart';
import 'package:augustyniak_capture/features/costs/domain/price_book.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_event.dart';
import 'package:augustyniak_capture/features/costs/domain/usage_parsing.dart';
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Records every call rather than persisting them, so a test can assert the
/// sink actually told someone about a drop instead of only checking that
/// nothing crashed.
class _RecordingLogSink implements LogSink {
  final List<String> messages = <String>[];

  @override
  void log(String message, {LogLevel level = LogLevel.info, String? recordingId}) {
    messages.add(message);
  }
}

void main() {
  late Database db;
  late UsageRepository repository;
  late RecordingUsageSink sink;
  late int counter;

  setUp(() {
    db = sqlite3.openInMemory();
    UsageRepository.createTable(db);
    repository = UsageRepository(db);
    counter = 0;
    sink = RecordingUsageSink(
      repository: () => repository,
      priceBook: () => const PriceBook(),
      idFactory: () => 'evt-${counter++}',
      clock: () => DateTime.utc(2026, 8, 9),
    );
  });

  tearDown(() => db.dispose());

  test('an enrichment call is priced from its tokens', () {
    sink.beginJob('cap-1', UsageStage.enrichment);
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-5.6-luna',
      usage: const MeasuredUsage(inputTokens: 1000000, outputTokens: 1000000),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-1').single;
    expect(event.stage, UsageStage.enrichment);
    expect(event.costUsd, closeTo(1.40, 1e-9));
    expect(event.unpricedReason, isNull);
  });

  test('a transcription with no reported duration falls back to the capture', () {
    sink.beginJob(
      'cap-2',
      UsageStage.transcription,
      fallbackAudioSeconds: 600,
    );
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-transcribe',
      usage: const MeasuredUsage(inputTokens: 900),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-2').single;
    expect(event.audioSeconds, closeTo(600, 1e-9));
    expect(event.costUsd, closeTo(0.045, 1e-9));
  });

  test('the reported duration wins over the fallback', () {
    sink.beginJob(
      'cap-3',
      UsageStage.transcription,
      fallbackAudioSeconds: 600,
    );
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-transcribe',
      usage: const MeasuredUsage(audioSeconds: 120),
    );
    sink.endJob();

    expect(
      repository.forCapture('cap-3').single.audioSeconds,
      closeTo(120, 1e-9),
    );
  });

  test('the fallback is applied to the first chunk only, never multiplied', () {
    sink.beginJob(
      'cap-4',
      UsageStage.transcription,
      fallbackAudioSeconds: 600,
    );
    for (int i = 0; i < 3; i++) {
      sink.record(
        provider: 'api.openai.com',
        model: 'gpt-transcribe',
        usage: const MeasuredUsage(),
      );
    }
    sink.endJob();

    final List<UsageEvent> events = repository.forCapture('cap-4');
    expect(events, hasLength(3));
    final double total = events.fold<double>(
      0,
      (double sum, UsageEvent e) => sum + (e.audioSeconds ?? 0),
    );
    expect(total, closeTo(600, 1e-9));
  });

  test('an upload with no duration anywhere records reason noQuantity', () {
    sink.beginJob('cap-5', UsageStage.transcription);
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-transcribe',
      usage: const MeasuredUsage(inputTokens: 900),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-5').single;
    expect(event.costUsd, isNull);
    expect(event.unpricedReason, UnpricedReason.noQuantity);
  });

  test('an unknown model records reason noRate with its tokens intact', () {
    sink.beginJob('cap-6', UsageStage.enrichment);
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-6-nova',
      usage: const MeasuredUsage(inputTokens: 500, outputTokens: 20),
    );
    sink.endJob();

    final UsageEvent event = repository.forCapture('cap-6').single;
    expect(event.costUsd, isNull);
    expect(event.unpricedReason, UnpricedReason.noRate);
    expect(event.inputTokens, 500);
  });

  test('a record outside any job is dropped rather than misfiled', () {
    sink.record(
      provider: 'api.openai.com',
      model: 'gpt-5.6-luna',
      usage: const MeasuredUsage(inputTokens: 10),
    );

    expect(repository.all(), isEmpty);
  });

  test('a record outside any job logs the drop rather than staying silent', () {
    final _RecordingLogSink logSink = _RecordingLogSink();
    final RecordingUsageSink logged = RecordingUsageSink(
      repository: () => repository,
      priceBook: () => const PriceBook(),
      logSink: logSink,
    );

    // No `beginJob` call at all — this is what `retryEnrichment` used to do
    // before it was made to open a job first, and the whole point of C1 was
    // that the drop must never be invisible again.
    logged.record(
      provider: 'api.openai.com',
      model: 'gpt-5.6-luna',
      usage: const MeasuredUsage(inputTokens: 10),
    );

    expect(
      logSink.messages,
      contains(contains('Cost recording dropped')),
    );
  });

  test('a repository resolver that throws never propagates out of record', () {
    final RecordingUsageSink failing = RecordingUsageSink(
      repository: () => throw StateError('database is not open yet'),
      priceBook: () => const PriceBook(),
    );

    failing.beginJob('cap-9', UsageStage.enrichment);
    expect(
      () => failing.record(
        provider: 'p',
        model: 'gpt-5.6-luna',
        usage: const MeasuredUsage(inputTokens: 1),
      ),
      returnsNormally,
    );
    failing.endJob();
  });

  test('a repository that throws never propagates out of record', () {
    final RecordingUsageSink failing = RecordingUsageSink(
      repository: () => _ThrowingRepository(db),
      priceBook: () => const PriceBook(),
    );

    failing.beginJob('cap-7', UsageStage.enrichment);
    expect(
      () => failing.record(
        provider: 'p',
        model: 'gpt-5.6-luna',
        usage: const MeasuredUsage(inputTokens: 1),
      ),
      returnsNormally,
    );
    failing.endJob();
  });

  test('a null resolver drops the event instead of throwing', () {
    final RecordingUsageSink unopened = RecordingUsageSink(
      // The database has not been opened yet — early in `_bootstrap()`.
      repository: () => null,
      priceBook: () => const PriceBook(),
    );

    unopened.beginJob('cap-8', UsageStage.enrichment);
    expect(
      () => unopened.record(
        provider: 'p',
        model: 'gpt-5.6-luna',
        usage: const MeasuredUsage(inputTokens: 1),
      ),
      returnsNormally,
    );
    unopened.endJob();

    expect(repository.all(), isEmpty);
  });
}

class _ThrowingRepository extends UsageRepository {
  // `UsageRepository`'s field is private, so this cannot be a `super.db`
  // parameter — pass it positionally.
  // ignore: use_super_parameters
  _ThrowingRepository(Database db) : super(db);

  @override
  void insert(UsageEvent event) => throw StateError('disk is gone');
}
