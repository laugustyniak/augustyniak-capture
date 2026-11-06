import '../../recordings/domain/capture_priority.dart';
import '../../recordings/domain/recording.dart';

/// What a triage proposal asks the user to do. Each one maps onto an existing
/// controller entry point: [merge], [close] and [stale] close captures,
/// [rerank] sets a priority. Nothing here edits a capture by itself.
enum TriageKind {
  /// Duplicates: keep the oldest capture, close the rest.
  merge,

  /// The work the capture describes looks finished.
  close,

  /// Old, low priority and never routed.
  stale,

  /// The capture's rank looks wrong; [TriageProposal.priority] is the target.
  rerank;

  static TriageKind? tryName(Object? name) =>
      name is String ? TriageKind.values.asNameMap()[name.trim()] : null;
}

class TriageProposal {
  const TriageProposal({
    required this.kind,
    required this.reason,
    required this.captureIds,
    this.priority,
  });

  final TriageKind kind;
  final String reason;
  final List<String> captureIds;

  /// Only set for [TriageKind.rerank].
  final CapturePriority? priority;

  /// Identity of the proposal, independent of its wording and of id order, so
  /// a rejection still matches when the model rephrases it the next day.
  String get key {
    final List<String> ids = captureIds.toSet().toList()..sort();
    final String base = '${kind.name}:${ids.join(',')}';
    return priority == null ? base : '$base:${priority!.name}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'reason': reason,
    'captureIds': captureIds,
    if (priority case final CapturePriority priority) 'priority': priority.name,
  };

  /// Whether [ids] (already de-duplicated) is a shape [kind] can act on: a
  /// rerank names exactly one capture, a merge at least two, and nothing
  /// names none. Shared by the model's reply and the log loader, so a row
  /// the service would refuse cannot come back in through `triage.jsonl`.
  static bool idsFitKind(TriageKind kind, List<String> ids) => switch (kind) {
    TriageKind.merge => ids.length >= 2,
    TriageKind.rerank => ids.length == 1,
    TriageKind.close || TriageKind.stale => ids.isNotEmpty,
  };

  /// Null for a row this build cannot read, which is dropped on its own.
  static TriageProposal? fromJson(Object? json) {
    if (json is! Map) return null;
    final TriageKind? kind = TriageKind.tryName(json['kind']);
    final Object? reason = json['reason'];
    final Object? rawIds = json['captureIds'];
    if (kind == null || reason is! String || rawIds is! List) return null;
    if (rawIds.any((Object? id) => id is! String)) return null;
    final List<String> ids = rawIds.cast<String>().toSet().toList();
    if (!idsFitKind(kind, ids)) return null;
    final CapturePriority? priority = CapturePriority.tryName(json['priority']);
    if (kind == TriageKind.rerank && priority == null) return null;
    return TriageProposal(
      kind: kind,
      reason: reason,
      captureIds: ids,
      priority: kind == TriageKind.rerank ? priority : null,
    );
  }
}

class TriageDigest {
  const TriageDigest({required this.at, required this.proposals});

  final DateTime at;
  final List<TriageProposal> proposals;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'digest',
    'at': at.toUtc().toIso8601String(),
    'proposals': <Map<String, dynamic>>[
      for (final TriageProposal proposal in proposals) proposal.toJson(),
    ],
  };

  static TriageDigest? fromJson(Object? json) {
    if (json is! Map || json['type'] != 'digest') return null;
    final DateTime? at = DateTime.tryParse(json['at'] as String? ?? '');
    final Object? raw = json['proposals'];
    if (at == null || raw is! List) return null;
    return TriageDigest(
      at: at,
      proposals: <TriageProposal>[
        for (final Object? item in raw)
          if (TriageProposal.fromJson(item) case final TriageProposal p) p,
      ],
    );
  }
}

enum TriageOutcome { accepted, rejected }

/// The user's answer to one proposal, keyed by [TriageProposal.key].
class TriageDecision {
  const TriageDecision({
    required this.key,
    required this.outcome,
    required this.at,
  });

  final String key;
  final TriageOutcome outcome;
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'decision',
    'key': key,
    'outcome': outcome.name,
    'at': at.toUtc().toIso8601String(),
  };

  static TriageDecision? fromJson(Object? json) {
    if (json is! Map || json['type'] != 'decision') return null;
    final Object? key = json['key'];
    final TriageOutcome? outcome = TriageOutcome.values
        .asNameMap()[json['outcome']];
    final DateTime? at = DateTime.tryParse(json['at'] as String? ?? '');
    if (key is! String || key.isEmpty || outcome == null || at == null) {
      return null;
    }
    return TriageDecision(key: key, outcome: outcome, at: at);
  }
}

/// What the append-only log says: the newest digest and the decisions that
/// still apply to it.
class TriageHistory {
  const TriageHistory({
    this.latest,
    this.rejected = const <String>{},
    this.accepted = const <String>{},
  });

  factory TriageHistory.fold({
    required Iterable<TriageDigest> digests,
    required Iterable<TriageDecision> decisions,
  }) {
    TriageDigest? latest;
    for (final TriageDigest digest in digests) {
      if (latest == null || !digest.at.isBefore(latest.at)) latest = digest;
    }
    // The last answer to a key wins, so a later accept of a once-rejected
    // proposal is not shadowed by the older rejection.
    final Map<String, TriageDecision> last = <String, TriageDecision>{};
    for (final TriageDecision decision in decisions) {
      last[decision.key] = decision;
    }
    return TriageHistory(
      latest: latest,
      // A rejection holds for good: the model must not bring it back.
      rejected: <String>{
        for (final TriageDecision decision in last.values)
          if (decision.outcome == TriageOutcome.rejected) decision.key,
      },
      // An acceptance answers the digest it was made from. A later digest
      // may propose the same change again — the user may have undone it by
      // hand since — so only an acceptance at or after the newest digest
      // still hides it.
      accepted: <String>{
        for (final TriageDecision decision in last.values)
          if (decision.outcome == TriageOutcome.accepted &&
              (latest == null || !decision.at.isBefore(latest.at)))
            decision.key,
      },
    );
  }

  final TriageDigest? latest;
  final Set<String> rejected;
  final Set<String> accepted;
}

/// How often the automatic run fires.
const Duration triageInterval = Duration(hours: 24);

bool triageIsDue(DateTime? lastRun, DateTime now) =>
    lastRun == null || now.difference(lastRun) >= triageInterval;

/// Open captures with text: the only ones a proposal may cite. Closed captures
/// already left the desk, and an item with no text gives the model nothing.
List<Recording> triageCandidates(Iterable<Recording> recordings) => recordings
    .where(
      (Recording recording) =>
          !recording.isProcessedByUser &&
          (recording.transcript?.trim().isNotEmpty ?? false),
    )
    .toList();

abstract interface class DailyTriageService {
  /// Proposes changes to the open captures. Never mutates anything.
  Future<TriageDigest> triage(
    List<Recording> captures, {
    Map<String, String> projectNames = const <String, String>{},
  });
}

/// Append-only digest and decision store, never inside `recordings.json`.
abstract interface class TriageLog {
  /// Throws when the log exists but cannot be read, so a caller can tell
  /// "nothing rejected yet" from "could not read what was rejected".
  Future<TriageHistory> load();
  Future<void> appendDigest(TriageDigest digest);
  Future<void> appendDecision(TriageDecision decision);
}

/// The controller entry points an accepted proposal calls. Implemented over
/// `RecordingsController` so acceptance takes the same path as a hand edit.
abstract interface class TriageActions {
  Future<void> close(String id);
  Future<void> setPriority(String id, CapturePriority priority);
}
