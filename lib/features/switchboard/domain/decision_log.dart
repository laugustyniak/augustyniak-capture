import 'decision.dart';

/// Append-only record of every decision, applied or not.
///
/// Best-effort sink: called after the capture is persisted, and its failure
/// never reaches the capture.
abstract class DecisionLog {
  Future<void> append({
    required DateTime at,
    required String captureId,
    required Decision decision,
    required bool applied,
    String? skipReason,
  });
}

class NoopDecisionLog implements DecisionLog {
  const NoopDecisionLog();

  @override
  Future<void> append({
    required DateTime at,
    required String captureId,
    required Decision decision,
    required bool applied,
    String? skipReason,
  }) async {}
}
