import 'package:augustyniak_capture/features/clipboard/domain/clipboard_item.dart';
import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_segment.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_type.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording_revision.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_engine.dart';
import 'package:augustyniak_capture/features/sync/domain/sync_snapshot.dart';

/// Shared fixtures and test doubles for the sync engine tests. Lifted from
/// `sync_row_codec_test.dart`'s local builders and given names the push and
/// pull suites can both import.

Recording recording({
  required String id,
  String? title,
  String? summary,
  String? transcript,
}) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: DateTime.utc(2026, 9, 21, 8),
  durationMs: 1200,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
  title: title,
  summary: summary,
  transcript: transcript,
);

Recording recordingWithSegments({
  required String id,
  required int segmentCount,
}) => Recording(
  id: id,
  filePath: '/tmp/$id.m4a',
  createdAt: DateTime.utc(2026, 9, 21, 8),
  durationMs: 1200,
  status: RecordingStatus.completed,
  type: CaptureType.audioRecording,
  segments: <CaptureSegment>[
    for (int i = 0; i < segmentCount; i++)
      CaptureSegment(
        // Segment 0 mirrors the recording's own filePath ("segment 0 is
        // <id>.<ext>, segment n is <id>-<n>.<ext>" — capture_segment.dart).
        index: i,
        filePath: i == 0 ? '/tmp/$id.m4a' : '/tmp/$id-$i.m4a',
        type: CaptureType.audioRecording,
        createdAt: DateTime.utc(2026, 9, 21, 8),
      ),
  ],
);

RecordingRevision revision({required String recordingId}) =>
    RecordingRevision(
      recordingId: recordingId,
      at: DateTime.utc(2026, 9, 21, 8),
      field: 'title',
      from: 'a',
      to: 'b',
      source: RevisionSource.user,
    );

ClipboardItem clipboardItem({required String id}) => ClipboardItem(
  id: id,
  type: ClipboardItemType.text,
  copiedAt: DateTime.utc(2026, 9, 21, 8),
  text: 'text-$id',
);

Project project({required String id}) =>
    Project(id: id, name: 'Project $id', repoPath: '/tmp/$id');

/// In-memory [SyncBookkeeping] — a map standing in for `SyncRowsStore`.
class MemoryBookkeeping implements SyncBookkeeping {
  final Map<String, Map<String, SyncRowState>> _tables =
      <String, Map<String, SyncRowState>>{};
  final Map<String, DateTime> _cursors = <String, DateTime>{};

  @override
  Map<String, SyncRowState> loadTable(String table) =>
      _tables[table] ?? <String, SyncRowState>{};

  @override
  void put(String table, String id, int serverVersion, String pushedHash) {
    (_tables[table] ??= <String, SyncRowState>{})[id] = SyncRowState(
      serverVersion: serverVersion,
      pushedHash: pushedHash,
    );
  }

  @override
  void remove(String table, String id) {
    _tables[table]?.remove(id);
  }

  @override
  DateTime? cursor(String table) => _cursors[table];

  @override
  void setCursor(String table, DateTime value) {
    _cursors[table] = value;
  }
}

/// A [SyncApplier] that does nothing — the push suite never exercises pull,
/// so every method is a no-op. Task 7 adds the real implementation.
class NoopApplier implements SyncApplier {
  @override
  Future<void> upsertRecordings(List<Recording> rows) async {}

  @override
  Future<void> upsertProjects(List<Project> rows) async {}

  @override
  Future<void> upsertClipboardItems(List<ClipboardItem> rows) async {}

  @override
  Future<void> appendRevisions(List<RecordingRevision> rows) async {}

  @override
  Future<void> deleteRecording(String id) async {}
}

/// A [SyncApplier] that records every call — the pull suite's fake
/// repository stand-in. `upserts` logs each `upsertRecordings` batch (a
/// pull-test clears it and asserts it stays empty to prove nothing new was
/// applied); `recordings`/`projects`/`clipboardItems` mirror the latest
/// upserted state keyed by id; `deleteRecording` removes from `recordings`.
class RecordingApplier implements SyncApplier {
  final Map<String, Recording> recordings = <String, Recording>{};
  final Map<String, Project> projects = <String, Project>{};
  final Map<String, ClipboardItem> clipboardItems = <String, ClipboardItem>{};
  final List<RecordingRevision> revisions = <RecordingRevision>[];
  final List<String> deleted = <String>[];
  final List<List<Recording>> upserts = <List<Recording>>[];

  @override
  Future<void> upsertRecordings(List<Recording> rows) async {
    upserts.add(rows);
    for (final Recording r in rows) {
      recordings[r.id] = r;
    }
  }

  @override
  Future<void> upsertProjects(List<Project> rows) async {
    for (final Project p in rows) {
      projects[p.id] = p;
    }
  }

  @override
  Future<void> upsertClipboardItems(List<ClipboardItem> rows) async {
    for (final ClipboardItem c in rows) {
      clipboardItems[c.id] = c;
    }
  }

  @override
  Future<void> appendRevisions(List<RecordingRevision> rows) async {
    revisions.addAll(rows);
  }

  @override
  Future<void> deleteRecording(String id) async {
    deleted.add(id);
    recordings.remove(id);
  }
}
