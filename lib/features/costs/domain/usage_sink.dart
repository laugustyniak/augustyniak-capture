import 'usage_event.dart';
import 'usage_parsing.dart';

/// Write-only seam that receives one call's usage.
///
/// **Deliberately not part of any service's return type.** The three HTTP
/// classes sit under one or two decorators that all declare `Future<String>`;
/// widening those would rewrite `Processor`, both audio processors, the
/// chunking decorator and every hand-written fake in the suite, and would force
/// the chunking decorator to sum usage itself. A sink changes no contract, and
/// chunking emits N events for free because every part goes through the same
/// HTTP class.
///
/// The HTTP classes do not know which capture they are working on;
/// [beginJob]/[endJob] supply it. That is ambient state, and it is safe
/// because exactly one job is ever open at a time: `RecordingsController`
/// serializes every path that can call [beginJob] behind its `_processingId`
/// guard. `_drainProcessingQueue` is single-flight and `_enrich` runs inside
/// the same `_processOne` job, so the drain alone never overlaps itself —
/// and `retryEnrichment` claims `_processingId` before opening its own job
/// and defers instead of starting one while the drain (or another retry)
/// already holds it, so a retry can neither run underneath the drain nor
/// have the drain land on top of it.
///
/// Defaults to a no-op so the pure-Dart suites need no database, exactly as
/// `NoopLogSink` and `NoopClipboardSink` do.
abstract interface class UsageSink {
  /// Scope subsequent [record] calls to this capture and stage.
  ///
  /// [fallbackAudioSeconds] is the capture's own measured duration, used only
  /// when the provider reports none. It is a measurement of the billed quantity
  /// rather than an estimate of it — but it is absent for uploads, which carry
  /// `durationMs: 0`.
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  });

  /// Leave the scope. Always called from a `finally`.
  void endJob();

  /// One successful API call.
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  });
}

class NoopUsageSink implements UsageSink {
  const NoopUsageSink();

  @override
  void beginJob(
    String captureId,
    UsageStage stage, {
    double? fallbackAudioSeconds,
  }) {}

  @override
  void endJob() {}

  @override
  void record({
    required String provider,
    required String model,
    required MeasuredUsage usage,
  }) {}
}
