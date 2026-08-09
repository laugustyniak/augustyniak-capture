import '../../recordings/domain/capture_type.dart';

/// How a capture left the desk.
///
/// [ClosureKind.fromName] returns **null** for an unrecognised value and the
/// caller drops the row — the rule `RouteKind.fromName` follows, and the
/// opposite of `CaptureType.fromName`. There is no sensible kind to assume, and
/// recording a newer build's kind as [review] would claim the user ticked
/// something off by hand when in fact it was delivered somewhere.
enum ClosureKind {
  /// Ticked off by hand — `toggleProcessed`.
  review,

  /// Delivered to the project inbox — `route`.
  route,

  /// Handed to a coding agent in a genuinely new session.
  handoff;

  // `asNameMap()`, not `byName()`: the latter throws on an unknown name, and an
  // unrecognised value is exactly the case this has to absorb.
  static ClosureKind? fromName(String? name) =>
      name == null ? null : ClosureKind.values.asNameMap()[name];
}

/// One capture leaving the desk, for good.
///
/// **The durable record of finished work, and the reason this feature has a
/// store of its own.** `recordings.json` holds `isProcessedByUser` — a single
/// bit of *state*, rewritten wholesale on every mutation and dropped entirely
/// when the capture is deleted. Neither property survives the question this
/// answers: how much did I actually get through last Tuesday. A deletion must
/// not be able to rewrite the past.
class ClosureEvent {
  const ClosureEvent({
    required this.recordingId,
    required this.at,
    required this.kind,
    required this.type,
    this.projectId,
    this.projectName,
  });

  /// Which capture. Also the deduplication key: a capture closes once, ever, so
  /// the count cannot be farmed by re-ticking one row.
  final String recordingId;

  /// When it closed, in local time — the instant the work became a fact, and
  /// what the day is counted by. Same rule as `FocusSession.completedAt`: a
  /// capture closed at 00:30 belongs to the day it was closed on.
  final DateTime at;

  final ClosureKind kind;
  final CaptureType type;

  /// The capture's project, denormalised exactly as `FocusSession` does it: the
  /// id groups, the name is what a panel can still show after the project has
  /// been renamed or deleted. Resolving the name at read time would let
  /// deleting a project erase the work done under it.
  final String? projectId;
  final String? projectName;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recordingId': recordingId,
    'at': at.toIso8601String(),
    'kind': kind.name,
    'type': type.name,
    if (projectId != null) 'projectId': projectId,
    if (projectName != null) 'projectName': projectName,
  };

  /// Null when the row cannot be trusted, so the caller can skip exactly that
  /// line. A torn final line after a kill mid-append must cost one event, never
  /// the file — the contract `FocusSession.fromJson` follows.
  static ClosureEvent? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? recordingId = json['recordingId'];
    final Object? at = json['at'];
    if (recordingId is! String || recordingId.isEmpty || at is! String) {
      return null;
    }
    final DateTime? parsed = DateTime.tryParse(at);
    if (parsed == null) return null;
    final Object? kind = json['kind'];
    final ClosureKind? resolved = ClosureKind.fromName(
      kind is String ? kind : null,
    );
    if (resolved == null) return null;
    final Object? type = json['type'];
    final Object? projectId = json['projectId'];
    final Object? projectName = json['projectName'];
    return ClosureEvent(
      recordingId: recordingId,
      // `toIso8601String()` on a local `DateTime` emits no offset, so this is a
      // wall-clock-preserving read and a closure cannot change day between
      // write and read. `toLocal()` is here for the rows that *do* carry a `Z`
      // or an offset — a hand-edited file, or a future writer.
      at: parsed.toLocal(),
      kind: resolved,
      // Unlike the kind, an unknown capture type degrades — this mirrors
      // `CaptureType.fromName`, and getting the icon wrong is not a lie about
      // what happened.
      type: CaptureType.fromName(type is String ? type : null),
      projectId: projectId is String && projectId.trim().isNotEmpty
          ? projectId
          : null,
      projectName: projectName is String && projectName.trim().isNotEmpty
          ? projectName
          : null,
    );
  }
}

/// What one backfill sweep did.
///
/// Counts rather than a list, like `VaultMirrorSummary`: the sweep runs over
/// the whole queue and the user wants to know the shape of the result, not to
/// read a hundred ids.
///
/// [undatable] is reported rather than folded into a failure because it is not
/// one — it is the honest answer for a row closed before `processedAt` existed,
/// and it is the only number here the user can do nothing about.
class ClosureBackfill {
  const ClosureBackfill({
    this.recorded = 0,
    this.alreadyKnown = 0,
    this.undatable = 0,
    this.failed = 0,
  });

  /// Captures written into the log by this sweep.
  final int recorded;

  /// Skipped because the log already knew them — the normal result of a second
  /// press.
  final int alreadyKnown;

  /// Closed, but with no `processedAt` to date the row by.
  final int undatable;

  /// The append threw.
  final int failed;

  bool get isEmpty =>
      recorded == 0 && alreadyKnown == 0 && undatable == 0 && failed == 0;

  ClosureBackfill plus({
    int recorded = 0,
    int alreadyKnown = 0,
    int undatable = 0,
    int failed = 0,
  }) => ClosureBackfill(
    recorded: this.recorded + recorded,
    alreadyKnown: this.alreadyKnown + alreadyKnown,
    undatable: this.undatable + undatable,
    failed: this.failed + failed,
  );
}

/// Where closures are written down.
///
/// A seam for the same reason as `FocusSessionLog`: the real implementation
/// touches the user's disk, and the pure-Dart suite must be able to close a
/// capture without one. The default records nothing, so a host that never wires
/// it behaves exactly as the app did before this existed.
abstract interface class ClosureLog {
  Future<List<ClosureEvent>> load();

  /// Throws on failure. The caller swallows it — see `RecordingsController`.
  Future<void> append(ClosureEvent event);
}

class NoopClosureLog implements ClosureLog {
  const NoopClosureLog();

  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async {}
}
