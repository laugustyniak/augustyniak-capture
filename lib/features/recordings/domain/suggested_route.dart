/// Where enrichment thinks a capture should go next.
///
/// The three delivery kinds mirror `RouteKind` (`file`, `command`, `agent`),
/// but this is its own enum on purpose: it also carries [none], which is not a
/// destination at all but an answer — "the model looked and would leave this on
/// the desk" — and `RouteKind` is persisted history of what *happened*, where a
/// `none` would be a lie.
enum SuggestedRouteKind {
  /// Append to the project's `inbox.md`.
  file,

  /// File a brief with the project's bound Command workspace.
  command,

  /// Open the handoff sheet for a coding agent on this machine.
  agent,

  /// Leave it on the desk.
  none;

  /// Null for an unknown name, so a row written by a newer build degrades to
  /// "no suggestion" rather than a guessed destination.
  static SuggestedRouteKind? fromName(Object? name) {
    for (final SuggestedRouteKind kind in SuggestedRouteKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// A model-proposed destination, kept on the capture.
///
/// Holds the kind and a short reason only — the project is the capture's own
/// `projectId`, never a second copy here. [auto] is the ownership flag, the
/// same idea as `Recording.projectAuto`: true while the model wrote it and may
/// replace it, false once the user dismissed it, after which enrichment never
/// writes it again.
class SuggestedRoute {
  const SuggestedRoute({required this.kind, this.reason, this.auto = true});

  static const int maxReasonChars = 200;

  final SuggestedRouteKind kind;
  final String? reason;
  final bool auto;

  /// This suggestion after the user turned it down: same content, user-owned.
  SuggestedRoute dismissed() =>
      SuggestedRoute(kind: kind, reason: reason, auto: false);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    if (reason != null) 'reason': reason,
    'auto': auto,
  };

  /// Null for anything unreadable, which reads as "never proposed". `auto`
  /// defaults to false when absent: a hand-written or damaged entry is not the
  /// model's to overwrite, nor the card's to advertise.
  static SuggestedRoute? fromJson(Object? json) {
    if (json is! Map) return null;
    final SuggestedRouteKind? kind = SuggestedRouteKind.fromName(json['kind']);
    if (kind == null) return null;
    final Object? reason = json['reason'];
    return SuggestedRoute(
      kind: kind,
      reason: reason is String && reason.trim().isNotEmpty
          ? reason.trim()
          : null,
      auto: json['auto'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SuggestedRoute &&
      other.kind == kind &&
      other.reason == reason &&
      other.auto == auto;

  @override
  int get hashCode => Object.hash(kind, reason, auto);
}

/// What the card may draw for a suggestion, after it was re-checked against the
/// item as it is *now*. Built only for a destination the existing entry point
/// would perform, so a control is never drawn that cannot deliver.
class SuggestedRouteAction {
  const SuggestedRouteAction({
    required this.kind,
    this.reason,
    this.agentLabel,
  });

  /// Never [SuggestedRouteKind.none].
  final SuggestedRouteKind kind;
  final String? reason;

  /// The agent the handoff sheet will preselect; set only for
  /// [SuggestedRouteKind.agent].
  final String? agentLabel;
}
