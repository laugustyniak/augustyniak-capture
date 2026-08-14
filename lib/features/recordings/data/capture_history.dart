import '../../../features/momentum/domain/closure_event.dart';
import '../../logs/domain/log_event.dart';
import '../../projects/domain/project.dart';
import '../domain/recording.dart';
import '../domain/recording_revision.dart';
import 'revisions_repository.dart';

/// What a capture *overwrote*, and the moment it left the desk.
///
/// Two append-only histories with one thing in common: neither can be
/// reconstructed from `recordings.json`. That file holds only the current value
/// of every field and it *shrinks* on a delete, so an overwritten transcript is
/// gone from it by definition, and `isProcessedByUser` is one bit of state that
/// cannot answer a question about last Tuesday however it is read.
///
/// **Both are driven from `RecordingsController._update` and nowhere else**,
/// which is the property that matters more than where the code lives. Three
/// paths close a capture — the review toggle, routing and the agent handoff,
/// the latter two because closing the item is the *consequence* of delivering
/// it — and counting at each of them is what the controller did before: the
/// handoff path was simply forgotten, so the most laborious way to finish a
/// capture was the one that never counted. A funnel cannot be bypassed by
/// adding a new setter. Moving the work out of the controller keeps that
/// funnel; it only stops the controller from also owning the bookkeeping.
///
/// Every write here is best-effort under the [ClosureLog] contract, and in one
/// specific order: the in-memory view is updated **first**, so a failed append
/// leaves this session correct and the file merely incomplete, rather than
/// wrong in both places.
class CaptureHistory {
  CaptureHistory({
    RevisionsRepository? revisionsRepository,
    ClosureLog closureLog = const NoopClosureLog(),
    Project? Function(String projectId)? projectById,
    LogSink logSink = const NoopLogSink(),
  }) : _revisionsRepository = revisionsRepository,
       _closureLog = closureLog,
       _projectById = projectById,
       _logSink = logSink;

  /// Null disables the change history entirely — the same optional-seam shape
  /// as `ClipboardSink` and `MediaOpener`, so the pure-Dart suites never reach
  /// a platform channel and the shell is the one place that opts in.
  final RevisionsRepository? _revisionsRepository;
  final ClosureLog _closureLog;
  final Project? Function(String projectId)? _projectById;
  final LogSink _logSink;

  /// Change history by capture id, newest first. Loaded once and kept in step
  /// by [recordRevisions]; the file is append-only, so memory and disk can only
  /// ever diverge by a write that failed and was logged.
  Map<String, List<RecordingRevision>> _revisions =
      <String, List<RecordingRevision>>{};

  /// Ids already counted as closed, so a capture closes once and only once
  /// however many times it is re-ticked or re-delivered.
  ///
  /// In memory and transient, the same class of fact as the controller's
  /// `_enrichingIds`: nothing about it survives a restart, and the log on disk
  /// is what repopulates it — see [loadClosures].
  final Set<String> _closedIds = <String>{};

  List<RecordingRevision> revisionsFor(String id) =>
      List<RecordingRevision>.unmodifiable(
        _revisions[id] ?? const <RecordingRevision>[],
      );

  bool hasClosed(String id) => _closedIds.contains(id);

  /// Supporting evidence, never a precondition: a history that will not load
  /// costs the edit sheet's HISTORY section, not the queue.
  Future<void> loadRevisions() async {
    try {
      _revisions =
          await _revisionsRepository?.load() ??
          <String, List<RecordingRevision>>{};
    } catch (exception) {
      _logSink.log(
        'Change history could not be read: $exception',
        level: LogLevel.warn,
      );
    }
  }

  /// Populates the closed-id set from the log.
  ///
  /// Called by the shell after `initialize`, never from inside it — the rule
  /// `recoverOrphans` follows, and for the same reason: it is IO that an
  /// in-memory repository fake cannot stand in for, and running it from
  /// `initialize` would make every widget test reach the developer's real disk.
  Future<void> loadClosures() async {
    try {
      for (final ClosureEvent event in await _closureLog.load()) {
        _closedIds.add(event.recordingId);
      }
    } catch (exception) {
      // Best-effort: an unreadable log costs deduplication accuracy for this
      // session, never a close. Reporting the unreadable state to the user is
      // `MomentumController`'s job; this side only has to keep working.
      _logSink.log('Closure history not read: $exception', level: LogLevel.warn);
    }
  }

  /// Drops a deleted capture's entries from the session view.
  ///
  /// The rows on disk stay — the file is append-only by design — so this only
  /// stops a later capture that happens to reuse the id from inheriting them,
  /// which `uuid.v4()` makes theoretical.
  void forget(String id) => _revisions.remove(id);

  /// Appends one entry per field this change overwrote.
  ///
  /// **A change out of an empty value is never recorded.** Filling a blank
  /// title, or writing a transcript for the first time, overwrites nothing —
  /// and the new value is already in `recordings.json`. That is what keeps the
  /// file small: a capture's first transcript never reaches it, and only a
  /// re-run that genuinely replaces text pays for a copy.
  Future<void> recordRevisions(
    Recording before,
    Recording after,
    RevisionSource source,
  ) async {
    final RevisionsRepository? repository = _revisionsRepository;
    if (repository == null) return;

    final List<RecordingRevision> changes = <RecordingRevision>[];
    void diff(String field, String? from, String? to) {
      if (from == to) return;
      // Nothing was overwritten — see the doc comment above.
      if (from == null || from.isEmpty) return;
      changes.add(
        RecordingRevision(
          recordingId: after.id,
          at: DateTime.now(),
          field: field,
          from: RecordingRevision.truncate(from),
          to: RecordingRevision.truncate(to),
          source: source,
        ),
      );
    }

    diff('title', before.title, after.title);
    diff('category', before.category?.name, after.category?.name);
    diff('summary', before.summary, after.summary);
    diff('tags', before.tags.join(', '), after.tags.join(', '));
    diff('transcript', before.transcript, after.transcript);
    if (changes.isEmpty) return;

    _revisions
        .putIfAbsent(after.id, () => <RecordingRevision>[])
        .insertAll(0, changes);
    try {
      await repository.append(changes);
    } catch (exception) {
      _logSink.log(
        'Change history not written: $exception',
        level: LogLevel.warn,
        recordingId: after.id,
      );
    }
  }

  /// Appends one [ClosureEvent] the first time a capture becomes closed.
  ///
  /// Answers whether this was that first time, which is what lets the caller
  /// raise the lifetime counter from the same funnel without either of them
  /// having to know how the capture was closed.
  Future<bool> recordClosure(
    Recording before,
    Recording after,
    ClosureKind kind,
  ) async {
    if (before.isProcessedByUser || !after.isProcessedByUser) return false;
    if (!_closedIds.add(after.id)) return false;

    try {
      await _closureLog.append(
        ClosureEvent(
          recordingId: after.id,
          at: after.processedAt ?? DateTime.now(),
          kind: kind,
          type: after.type,
          projectId: after.projectId,
          projectName: after.projectId == null
              ? null
              : _projectById?.call(after.projectId!)?.name,
        ),
      );
    } catch (exception) {
      _logSink.log(
        'Closure not written: $exception',
        level: LogLevel.warn,
        recordingId: after.id,
      );
    }
    return true;
  }

  /// Records a capture that was already closed before the log existed, and
  /// answers whether the row reached disk.
  ///
  /// Unlike [recordClosure] the id is marked **only on success**, so a sweep
  /// that failed halfway can be pressed again and pick up where it stopped.
  Future<bool> recordBackfilled(ClosureEvent event) async {
    try {
      await _closureLog.append(event);
      _closedIds.add(event.recordingId);
      return true;
    } catch (exception) {
      _logSink.log(
        'Closure backfill failed: $exception',
        level: LogLevel.warn,
        recordingId: event.recordingId,
      );
      return false;
    }
  }
}
