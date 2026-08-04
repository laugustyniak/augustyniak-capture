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
  agent;

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

/// One delivery. Append-only in practice: routing the same capture twice adds a
/// second record rather than replacing the first, because both deliveries
/// really happened and the second does not undo the first.
class RouteRecord {
  const RouteRecord({
    required this.at,
    required this.kind,
    required this.target,
  });

  final DateTime at;
  final RouteKind kind;

  /// Human-meaningful destination — the file that was appended to, or the agent
  /// session that was opened. Rendered verbatim, so it must stay short enough
  /// to sit on a card.
  final String target;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': at.toIso8601String(),
    'kind': kind.name,
    'target': target,
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
    return RouteRecord(at: parsed, kind: kind, target: target);
  }

  static List<RouteRecord> listFromJson(Object? json) {
    if (json is! List) return const <RouteRecord>[];
    return json
        .map(RouteRecord.fromJson)
        .whereType<RouteRecord>()
        .toList(growable: false);
  }
}
