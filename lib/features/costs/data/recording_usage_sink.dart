import 'package:uuid/uuid.dart';

import '../../logs/domain/log_event.dart';
import '../domain/price_book.dart';
import '../domain/usage_event.dart';
import '../domain/usage_parsing.dart';
import '../domain/usage_sink.dart';
import 'usage_repository.dart';

/// Prices each reported call and writes it to the usage store.
///
/// Best-effort under the `ClipboardSink` contract: every failure is swallowed
/// into [LogSink]. A cost row that cannot be written costs a number; throwing
/// here would cost the capture the feature exists to measure.
class RecordingUsageSink implements UsageSink {
  RecordingUsageSink({
    required UsageRepository? Function() repository,
    required PriceBook Function() priceBook,
    String Function()? idFactory,
    DateTime Function()? clock,
    LogSink logSink = const NoopLogSink(),
  }) : _repository = repository,
       _priceBook = priceBook,
       _idFactory = idFactory ?? (() => const Uuid().v4()),
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _logSink = logSink;

  /// Resolved per call rather than captured, mirroring [_priceBook]: the
  /// shell builds its controllers synchronously in `initState` while the
  /// SQLite database opens asynchronously in `_bootstrap()`, so the database
  /// may not exist yet on the very first captures. A null here means exactly
  /// that — not a failure — and the event is dropped rather than queued.
  final UsageRepository? Function() _repository;

  /// Read per call rather than captured: a rate edited in the Config tab must
  /// reach the very next capture without rebuilding this object.
  final PriceBook Function() _priceBook;
  final String Function() _idFactory;
  final DateTime Function() _clock;
  final LogSink _logSink;

  String? _captureId;
  UsageStage? _stage;
  double? _pendingFallbackSeconds;

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {
    _captureId = captureId;
    _stage = stage;
    // Held for the *first* event of the job only. A twenty-minute capture is
    // split into four requests; attaching the capture's full duration to each
    // of them would bill the same audio four times.
    _pendingFallbackSeconds =
        (fallbackAudioSeconds ?? 0) > 0 ? fallbackAudioSeconds : null;
  }

  @override
  void endJob() {
    _captureId = null;
    _stage = null;
    _pendingFallbackSeconds = null;
  }

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {
    final String? captureId = _captureId;
    final UsageStage? stage = _stage;
    // A call outside any job has no capture to bill. Dropping it is better than
    // filing it under whichever capture ran last.
    if (captureId == null || stage == null) return;

    // The database is not open yet (early in `_bootstrap()`). Drop the event
    // rather than throw or queue it — a cost row lost to this window is a
    // rounding error against the alternative of failing the capture.
    final UsageRepository? repository = _repository();
    if (repository == null) return;

    try {
      final double? seconds = usage.audioSeconds ?? _takeFallbackSeconds();
      final UsageEvent unpriced = UsageEvent(
        id: _idFactory(),
        captureId: captureId,
        stage: stage,
        provider: provider,
        model: model,
        at: _clock(),
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        audioSeconds: seconds,
      );

      final PricedResult priced = _priceBook().price(unpriced);
      repository.insert(
        UsageEvent(
          id: unpriced.id,
          captureId: unpriced.captureId,
          stage: unpriced.stage,
          provider: unpriced.provider,
          model: unpriced.model,
          at: unpriced.at,
          inputTokens: unpriced.inputTokens,
          outputTokens: unpriced.outputTokens,
          audioSeconds: unpriced.audioSeconds,
          costUsd: priced.costUsd,
          unpricedReason: priced.reason,
        ),
      );
    } catch (exception) {
      _logSink.log(
        'Cost recording failed: $exception',
        level: LogLevel.warn,
        recordingId: captureId,
      );
    }
  }

  double? _takeFallbackSeconds() {
    final double? seconds = _pendingFallbackSeconds;
    _pendingFallbackSeconds = null;
    return seconds;
  }
}
