import '../../../core/security/record_id.dart';

/// What an external agent says it did with a capture.
enum AgentDecisionAction {
  /// The agent already acted; `did` says what. Closes the capture.
  done('done'),

  /// Deliver to the project's inbox file.
  routeFile('route_file'),

  /// File a brief with the project's Command binding.
  routeCommand('route_command'),

  /// Leave the capture open; only logged.
  skip('skip');

  const AgentDecisionAction(this.wireName);

  final String wireName;

  /// Null for an unknown name, so a decision from a newer server is rejected
  /// rather than guessed at.
  static AgentDecisionAction? fromName(Object? name) {
    for (final AgentDecisionAction action in AgentDecisionAction.values) {
      if (action.wireName == name) return action;
    }
    return null;
  }
}

/// A decision file's content: written by the MCP server, read by the app.
///
/// Pure Dart, shared by both so the schema cannot drift. `decisions/` is
/// writable by any local process, so [fromJson] validates every field and
/// returns null rather than throwing.
class AgentDecision {
  const AgentDecision({
    required this.decisionId,
    required this.captureId,
    required this.version,
    required this.action,
    required this.reason,
    required this.agent,
    required this.submittedAt,
    this.did,
    this.target,
  });

  static const int maxTextChars = 2000;
  static final RegExp _agentName = RegExp(r'^[A-Za-z0-9._-]{1,40}$');

  final String decisionId;
  final String captureId;

  /// `recordingVersion` of the capture as the agent read it.
  final String version;
  final AgentDecisionAction action;
  final String reason;
  final String? did;
  final String? target;
  final String agent;
  final DateTime submittedAt;

  /// Whether [name] is an acceptable agent name.
  static bool isValidAgent(String name) => _agentName.hasMatch(name);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'decisionId': decisionId,
    'captureId': captureId,
    'version': version,
    'action': action.wireName,
    'reason': reason,
    if (did != null) 'did': did,
    if (target != null) 'target': target,
    'agent': agent,
    'submittedAt': submittedAt.toUtc().toIso8601String(),
  };

  static String? _required(Object? v, {int max = maxTextChars}) =>
      v is String && v.trim().isNotEmpty && v.length <= max ? v : null;

  /// Null when any field is missing or invalid.
  static AgentDecision? fromJson(Object? json) {
    if (json is! Map) return null;
    final String? decisionId = _required(json['decisionId'], max: 64);
    final String? captureId = _required(json['captureId'], max: 64);
    final String? version = _required(json['version'], max: 128);
    final String? reason = _required(json['reason']);
    final String? agent = _required(json['agent'], max: 40);
    final AgentDecisionAction? action = AgentDecisionAction.fromName(
      json['action'],
    );
    final Object? at = json['submittedAt'];
    final DateTime? submittedAt = at is String ? DateTime.tryParse(at) : null;
    if (decisionId == null ||
        captureId == null ||
        version == null ||
        reason == null ||
        agent == null ||
        action == null ||
        submittedAt == null ||
        !isSafeRecordId(captureId) ||
        !isValidAgent(agent)) {
      return null;
    }
    final Object? did = json['did'];
    final Object? target = json['target'];
    if ((did != null && (did is! String || did.length > maxTextChars)) ||
        (target != null &&
            (target is! String || target.length > maxTextChars))) {
      return null;
    }
    return AgentDecision(
      decisionId: decisionId,
      captureId: captureId,
      version: version,
      action: action,
      reason: reason,
      did: did is String && did.trim().isNotEmpty ? did : null,
      target: target is String && target.trim().isNotEmpty ? target : null,
      agent: agent,
      submittedAt: submittedAt,
    );
  }
}

enum DecisionOutcomeKind { applied, alreadyClosed, rejected }

/// What `RecordingsController.applyAgentDecision` did with a decision.
class DecisionOutcome {
  const DecisionOutcome.applied()
    : kind = DecisionOutcomeKind.applied,
      reason = null;
  const DecisionOutcome.alreadyClosed()
    : kind = DecisionOutcomeKind.alreadyClosed,
      reason = null;
  const DecisionOutcome.rejected(String this.reason)
    : kind = DecisionOutcomeKind.rejected;

  final DecisionOutcomeKind kind;

  /// Why, for [DecisionOutcomeKind.rejected] only.
  final String? reason;
}
