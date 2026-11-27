/// What the user's priorities note contributed to one decision.
///
/// Plain types only, so the policy stays pure and the switchboard never
/// imports enrichment: the controller maps the parsed note into this.
///
/// [priorities] reaches the policy in memory, but [toJson] records only the
/// count: `decisions.jsonl` is a backup payload member and the note is private.
class ContextFacts {
  const ContextFacts({
    this.priorities = const <String>[],
    this.tier,
    this.status,
  });

  static const ContextFacts none = ContextFacts();

  final List<String> priorities;
  final int? tier;
  final String? status;

  bool get isEmpty => priorities.isEmpty && tier == null && status == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'priorityCount': priorities.length,
    'tier': ?tier,
    'status': ?status,
  };
}
