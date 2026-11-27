import '../../recordings/domain/suggested_route.dart';
import 'capture_facts.dart';
import 'context_facts.dart';

/// What a [CapturePolicy] decided: the rule that fired, the destination it
/// proposes and a one-line reason, with the facts it saw.
class Decision {
  const Decision({
    required this.ruleId,
    required this.kind,
    required this.reason,
    required this.facts,
    this.context = ContextFacts.none,
  });

  final String ruleId;
  final SuggestedRouteKind kind;
  final String reason;
  final CaptureFacts facts;

  /// What the priorities note contributed. No rule reads it yet.
  final ContextFacts context;
}
