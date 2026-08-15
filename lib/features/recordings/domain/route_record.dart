/// Where a capture was sent, and when.
///
/// The queue exists to move a thought somewhere — `CaptureCategory` is a set of
/// *routing destinations*, not topics. Until this existed nothing consumed that
/// classification: an item could be filed as `agentTask`, and the only way to
/// act on it was to copy the transcript by hand. `isProcessedByUser` was the
/// stand-in, and it recorded that something happened without recording *what*,
/// so "where did that thought go" was a question only the user's memory could
/// answer.
enum RouteKind {
  /// Appended to a markdown inbox inside the project's repository.
  file,

  /// Handed to a coding agent as the opening prompt of a session.
  agent,

  /// Delivered to the Command control plane as a brief, which then plans the
  /// work on a host in the fleet.
  ///
  /// **Not `agent`, and reusing it was considered and rejected.** That kind
  /// means a session was opened on this capture's own text; Command receives a
  /// brief and plans issues from it, on a machine this app does not own and
  /// with an outcome that comes back later. Collapsing the two would make the
  /// one line the card prints about a capture say the same thing about two
  /// materially different journeys.
  ///
  /// The cost is stated rather than hidden: an older build reading a row with
  /// this kind drops it, because [fromName] refuses to guess. The capture
  /// survives; only its "where did it go" line does not.
  command;

  /// Null for an unrecognised name, which drops that one row on load.
  ///
  /// Deliberately unlike [CaptureType.fromName], which defaults: there is no
  /// sensible destination to assume, and claiming a capture went to a file when
  /// a newer build sent it to something else would be a worse answer than
  /// admitting the row is unreadable. Only the row is lost — the rest of the
  /// item's history survives, the same rule the revisions log follows.
  static RouteKind? fromName(String? name) {
    for (final RouteKind kind in RouteKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// What the control plane says has become of a brief.
///
/// **Derived on the other side, cached here.** Command reads these states off
/// the issue labels it manages (`agent:todo` → [planned], `agent:in-progress` →
/// [inProgress], and so on), so there is no second source of truth about task
/// state — and fidelity is exactly label fidelity: a human closing an issue by
/// hand reads as [done], and claiming otherwise would need state nobody keeps.
enum CommandState {
  /// Filed, nothing has looked at it yet.
  submitted,

  /// Planned into issues.
  planned,

  /// Something is working on it.
  inProgress,

  /// Finished, by an agent or by a person.
  done,

  /// Stopped and waiting on something.
  blocked,

  /// Finished enough to want a human's eyes.
  needsReview;

  /// Null for a state this build does not know, which drops the whole outcome.
  ///
  /// Unlike [RouteKind], dropping costs nothing durable: an outcome is a cache
  /// of somebody else's state and the next poll refetches it. Guessing would be
  /// worse than a blank line for one refresh — a capture shown as `done`
  /// because a newer build called it something else is a wrong answer that
  /// looks like a right one.
  static CommandState? fromName(String? name) {
    for (final CommandState state in CommandState.values) {
      if (state.name == name) return state;
    }
    return null;
  }
}

/// The result of a delivery, as of the last time anything asked.
///
/// Optional on [RouteRecord] and absent on every row written before it existed
/// — and absent, too, on a delivery to a destination that cannot report back.
/// `inbox.md` is a file; it has no state to fetch.
class RouteOutcome {
  const RouteOutcome({
    required this.briefId,
    required this.state,
    required this.checkedAt,
    this.issues = const <int>[],
    this.prUrl,
  });

  /// What the control plane calls this brief, and the key every later poll uses.
  final String briefId;

  final CommandState state;

  /// Issue numbers Command planned out of the brief.
  final List<int> issues;

  final String? prUrl;

  /// When this app last got an answer — **not** when the state changed.
  ///
  /// It is the difference between "nothing has happened" and "nobody has
  /// looked", which is the whole reason an unreachable aggregator keeps the
  /// last outcome rather than clearing it.
  final DateTime checkedAt;

  RouteOutcome copyWith({
    CommandState? state,
    List<int>? issues,
    String? prUrl,
    DateTime? checkedAt,
  }) => RouteOutcome(
    briefId: briefId,
    state: state ?? this.state,
    issues: issues ?? this.issues,
    prUrl: prUrl ?? this.prUrl,
    checkedAt: checkedAt ?? this.checkedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'briefId': briefId,
    'state': state.name,
    'checkedAt': checkedAt.toIso8601String(),
    if (issues.isNotEmpty) 'issues': issues,
    if (prUrl != null) 'prUrl': prUrl,
  };

  /// Null when the row cannot be trusted. The *record* survives that — only its
  /// outcome is dropped, so a capture still says where it went even when this
  /// build cannot read what became of it.
  static RouteOutcome? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? briefId = json['briefId'];
    final CommandState? state = CommandState.fromName(json['state'] as String?);
    final Object? checkedAt = json['checkedAt'];
    if (briefId is! String || briefId.isEmpty || state == null) return null;
    final DateTime? parsed = checkedAt is String
        ? DateTime.tryParse(checkedAt)
        : null;
    if (parsed == null) return null;

    final Object? issues = json['issues'];
    final Object? prUrl = json['prUrl'];
    return RouteOutcome(
      briefId: briefId,
      state: state,
      checkedAt: parsed,
      issues: issues is List
          ? issues.whereType<int>().toList(growable: false)
          : const <int>[],
      prUrl: prUrl is String && prUrl.trim().isNotEmpty ? prUrl.trim() : null,
    );
  }
}

/// One delivery. Append-only in practice: routing the same capture twice adds a
/// second record rather than replacing the first, because both deliveries
/// really happened and the second does not undo the first.
class RouteRecord {
  const RouteRecord({
    required this.at,
    required this.kind,
    required this.target,
    this.outcome,
  });

  final DateTime at;
  final RouteKind kind;

  /// Human-meaningful destination — the file that was appended to, or the agent
  /// session that was opened. Rendered verbatim, so it must stay short enough
  /// to sit on a card.
  final String target;

  /// What came back, when anything can. Null for a destination that reports
  /// nothing — a file has no state — and null on every row written before the
  /// return path existed.
  ///
  /// This is the field `docs/plans/2026-08-05-handoff-vocabulary-design.md`
  /// named as the thing that would have to change if a hand-off ever stopped
  /// being terminal. It has.
  final RouteOutcome? outcome;

  RouteRecord withOutcome(RouteOutcome? next) =>
      RouteRecord(at: at, kind: kind, target: target, outcome: next);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': at.toIso8601String(),
    'kind': kind.name,
    'target': target,
    if (outcome != null) 'outcome': outcome!.toJson(),
  };

  /// Null when the row cannot be trusted, so the caller can drop exactly that
  /// entry. A hand-edited `recordings.json` must not be able to take the whole
  /// index down through this field.
  static RouteRecord? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final RouteKind? kind = RouteKind.fromName(json['kind'] as String?);
    final Object? at = json['at'];
    final Object? target = json['target'];
    if (kind == null || at is! String || target is! String) return null;
    final DateTime? parsed = DateTime.tryParse(at);
    if (parsed == null) return null;
    return RouteRecord(
      at: parsed,
      kind: kind,
      target: target,
      outcome: RouteOutcome.fromJson(json['outcome']),
    );
  }

  static List<RouteRecord> listFromJson(Object? json) {
    if (json is! List) return const <RouteRecord>[];
    return json
        .map(RouteRecord.fromJson)
        .whereType<RouteRecord>()
        .toList(growable: false);
  }
}
