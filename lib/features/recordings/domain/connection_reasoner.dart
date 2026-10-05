import '../../enrichment/domain/enrichment_context.dart';
import 'capture_priority.dart';

enum ConnectionDecision { actNow, keepForLater, clarify }

class ConnectionCandidate {
  const ConnectionCandidate({
    required this.path,
    required this.title,
    required this.sharedTerms,
    required this.excerpt,
  });

  final String path;
  final String title;
  final List<String> sharedTerms;
  final String excerpt;
}

class ConnectionAdvice {
  const ConnectionAdvice({
    required this.decision,
    required this.reason,
    required this.nextStep,
  });

  final ConnectionDecision decision;
  final String reason;
  final String nextStep;
}

abstract interface class ConnectionReasoner {
  Future<ConnectionAdvice> assess({
    required String title,
    required String text,
    required List<ConnectionCandidate> candidates,
    required EnrichmentContext context,
    CapturePriority? priority,
    String? priorityReason,
  });
}

class ReviewConnectionReasoner implements ConnectionReasoner {
  const ReviewConnectionReasoner();

  @override
  Future<ConnectionAdvice> assess({
    required String title,
    required String text,
    required List<ConnectionCandidate> candidates,
    required EnrichmentContext context,
    CapturePriority? priority,
    String? priorityReason,
  }) async => const ConnectionAdvice(
    decision: ConnectionDecision.clarify,
    reason:
        'No analysis model is configured; relevance and priority need review.',
    nextStep: 'Review the related notes and decide whether to act.',
  );
}
