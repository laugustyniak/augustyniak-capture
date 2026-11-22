import '../../recordings/domain/capture_category.dart';
import '../../recordings/domain/suggested_route.dart';
import '../domain/capture_facts.dart';
import '../domain/capture_policy.dart';
import '../domain/decision.dart';

/// The ordered rule table; the first rule that matches wins.
///
/// - R10 command: a command category whose project resolves to Command.
/// - R20 agent: a command category with an agent available.
/// - R30 file: a command category that can only be filed.
/// - R80 model: the kind the enrichment model answered, when available.
/// - R90 none: nothing matched.
///
/// R10 is `ProjectCaptureRouter`'s own condition by construction: the
/// controller derives `availableRouteKinds` from the router's `resolvedKind`,
/// which names Command only for a command category on a bound project.
class RuleTableCapturePolicy implements CapturePolicy {
  const RuleTableCapturePolicy({required this.commandCategories});

  final Set<CaptureCategory> commandCategories;

  @override
  Decision? decide(CaptureFacts facts) {
    final CaptureCategory? category = facts.category;
    if (category == null) return null;
    final List<SuggestedRouteKind> available = facts.availableRouteKinds;
    final bool agentTask = commandCategories.contains(category);

    Decision decision(String ruleId, SuggestedRouteKind kind, String reason) =>
        Decision(ruleId: ruleId, kind: kind, reason: reason, facts: facts);

    if (agentTask && available.contains(SuggestedRouteKind.command)) {
      return decision(
        'R10',
        SuggestedRouteKind.command,
        'Agent task on a project bound to Command',
      );
    }
    if (agentTask && available.contains(SuggestedRouteKind.agent)) {
      return decision(
        'R20',
        SuggestedRouteKind.agent,
        'Agent task with a coding agent available',
      );
    }
    if (agentTask && available.contains(SuggestedRouteKind.file)) {
      return decision(
        'R30',
        SuggestedRouteKind.file,
        'Agent task that can be filed to the project inbox',
      );
    }
    final SuggestedRouteKind? model = facts.modelRoute;
    if (model != null &&
        (model == SuggestedRouteKind.none || available.contains(model))) {
      return decision(
        'R80',
        model,
        model == SuggestedRouteKind.none
            ? 'The model would leave it on the desk'
            : 'The model suggested this destination',
      );
    }
    return decision(
      'R90',
      SuggestedRouteKind.none,
      'No rule matched, leave it on the desk',
    );
  }
}
