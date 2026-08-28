import 'dart:io';

import 'package:augustyniak_capture/features/momentum/domain/closure_event.dart';
import 'package:augustyniak_capture/features/recordings/data/capture_history.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/data/revisions_repository.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a capture *overwrote* and the moment it left the desk are the two facts
/// nothing else can reconstruct — `recordings.json` holds only the current
/// value, and it shrinks on a delete. Both were written from inside
/// `RecordingsController._update`, the funnel every mutation already passes
/// through, and both keep that property here: this class is what the funnel
/// calls, so a new setter still cannot bypass either one.
///
/// The rules below were only reachable through the controller before, which
/// meant asserting them cost a recorder, a player and a repository each time.
class _MemoryClosureLog implements ClosureLog {
  final List<ClosureEvent> events = <ClosureEvent>[];

  @override
  Future<List<ClosureEvent>> load() async => events;

  @override
  Future<void> append(ClosureEvent event) async => events.add(event);
}

/// In-memory stand-in for the JSONL file, the same shape `revision_history_test`
/// uses: only the IO is overridden, so the append-only semantics stay real.
class _MemoryRevisions extends RevisionsRepository {
  final List<RecordingRevision> appended = <RecordingRevision>[];

  @override
  Future<Map<String, List<RecordingRevision>>> load() async =>
      <String, List<RecordingRevision>>{};

  @override
  Future<void> append(List<RecordingRevision> revisions) async =>
      appended.addAll(revisions);
}

/// Refuses every append, which is the case the in-memory-first ordering exists
/// for: the session keeps a correct view of a history that is incomplete on
/// disk, rather than one that is wrong in both places.
class _RefusingClosureLog implements ClosureLog {
  @override
  Future<List<ClosureEvent>> load() async => const <ClosureEvent>[];

  @override
  Future<void> append(ClosureEvent event) async =>
      throw const FileSystemException('the log is unwritable');
}

Recording _item(
  String id, {
  String? title,
  String? transcript,
  bool processed = false,
}) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: DateTime.parse('2026-08-04T12:00:00'),
  durationMs: 1000,
  status: RecordingStatus.completed,
  title: title,
  transcript: transcript,
  isProcessedByUser: processed,
  processedAt: processed ? DateTime.parse('2026-08-04T13:00:00') : null,
);

void main() {
  group('the change history', () {
    test('records what a change overwrote', () async {
      final CaptureHistory history = CaptureHistory(
        revisionsRepository: _MemoryRevisions(),
      );

      await history.recordRevisions(
        _item('a', title: 'first'),
        _item('a', title: 'second'),
        RevisionSource.user,
      );

      final RecordingRevision entry = history.revisionsFor('a').single;
      expect(entry.field, 'title');
      expect(entry.from, 'first');
      expect(entry.to, 'second');
    });

    test('records nothing when a blank field is filled in', () async {
      final CaptureHistory history = CaptureHistory(
        revisionsRepository: _MemoryRevisions(),
      );

      await history.recordRevisions(
        _item('a', title: null, transcript: ''),
        _item('a', title: 'named', transcript: 'the first transcript'),
        RevisionSource.enrichment,
      );

      expect(history.revisionsFor('a'), isEmpty);
    });
  });

  group('closures', () {
    test('a capture closes once, however often it is re-ticked', () async {
      final _MemoryClosureLog log = _MemoryClosureLog();
      final CaptureHistory history = CaptureHistory(closureLog: log);

      final bool first = await history.recordClosure(
        _item('a'),
        _item('a', processed: true),
        ClosureKind.review,
      );
      final bool second = await history.recordClosure(
        _item('a'),
        _item('a', processed: true),
        ClosureKind.route,
      );

      expect(first, isTrue);
      expect(second, isFalse);
      expect(log.events, hasLength(1));
    });

    test('a closure is dated by when the capture was closed', () async {
      final _MemoryClosureLog log = _MemoryClosureLog();
      final CaptureHistory history = CaptureHistory(closureLog: log);

      await history.recordClosure(
        _item('a'),
        _item('a', processed: true),
        ClosureKind.review,
      );

      expect(log.events.single.at, DateTime.parse('2026-08-04T13:00:00'));
    });

    test('a refused append still deduplicates for the session', () async {
      final CaptureHistory history = CaptureHistory(
        closureLog: _RefusingClosureLog(),
      );

      await history.recordClosure(
        _item('a'),
        _item('a', processed: true),
        ClosureKind.review,
      );

      expect(history.hasClosed('a'), isTrue);
    });

    test('reopening and closing again does not count twice', () async {
      final _MemoryClosureLog log = _MemoryClosureLog();
      final CaptureHistory history = CaptureHistory(closureLog: log);

      await history.recordClosure(
        _item('a'),
        _item('a', processed: true),
        ClosureKind.review,
      );
      await history.recordClosure(
        _item('a', processed: true),
        _item('a'),
        ClosureKind.review,
      );
      await history.recordClosure(
        _item('a'),
        _item('a', processed: true),
        ClosureKind.review,
      );

      expect(log.events, hasLength(1));
    });

    test('the log repopulates the session view', () async {
      final _MemoryClosureLog log = _MemoryClosureLog()
        ..events.add(
          ClosureEvent(
            recordingId: 'a',
            at: DateTime.parse('2026-08-04T13:00:00'),
            kind: ClosureKind.review,
            type: CaptureType.audioRecording,
          ),
        );
      final CaptureHistory history = CaptureHistory(closureLog: log);

      await history.loadClosures();

      expect(history.hasClosed('a'), isTrue);
    });
  });
}
