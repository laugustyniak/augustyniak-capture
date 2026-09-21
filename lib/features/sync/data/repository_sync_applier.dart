import '../../clipboard/data/clipboard_repository.dart';
import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/data/projects_repository.dart';
import '../../projects/domain/project.dart';
import '../../recordings/data/recordings_repository.dart';
import '../../recordings/data/revisions_repository.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';
import '../domain/sync_engine.dart';

/// [SyncEngine]'s pull side, applied through the same repositories the rest
/// of the app writes through — see the design doc's "Apply: through the
/// repository, never raw SQL". Every `delete*` tolerates an id it has never
/// heard of: a pulled tombstone for a row this device never had is a no-op,
/// not an error.
class RepositorySyncApplier implements SyncApplier {
  RepositorySyncApplier({
    required RecordingsRepository recordings,
    required ProjectsRepository projects,
    required ClipboardRepository clipboard,
    required RevisionsRepository? revisions,
    required Future<void> Function(String id) deleteRecording,
    Future<void> Function()? afterRecordingsWrite,
  }) : _recordings = recordings,
       _projects = projects,
       _clipboard = clipboard,
       _revisions = revisions,
       _deleteRecording = deleteRecording,
       _afterRecordingsWrite = afterRecordingsWrite;

  final RecordingsRepository _recordings;
  final ProjectsRepository _projects;
  final ClipboardRepository _clipboard;
  final RevisionsRepository? _revisions;
  final Future<void> Function(String id) _deleteRecording;

  /// Called after every recordings write lands on disk, so a caller holding
  /// its own in-memory copy of the recordings list (`RecordingsController`)
  /// can refresh it before it next rewrites the whole index from that stale
  /// copy — see `RecordingsController.deleteRecording`'s `_persistAll`, which
  /// would otherwise silently undo an upsert this applier just wrote if a
  /// pulled tombstone for a different row follows it later in the same run.
  final Future<void> Function()? _afterRecordingsWrite;

  @override
  Future<void> upsertRecordings(List<Recording> rows) async {
    if (rows.isEmpty) return;
    // `updateAll` holds the write lock across load-merge-write, so a capture
    // indexed by the running app between this read and this write is not
    // silently dropped by a merge built from a stale snapshot — see its own
    // doc comment.
    await _recordings.updateAll((List<Recording> current) async {
      final Map<String, Recording> byId = <String, Recording>{
        for (final Recording r in current) r.id: r,
      };
      for (final Recording r in rows) {
        byId[r.id] = r;
      }
      return byId.values.toList()
        ..sort((Recording a, Recording b) => b.createdAt.compareTo(a.createdAt));
    });
    await _afterRecordingsWrite?.call();
  }

  @override
  Future<void> upsertProjects(List<Project> rows) async {
    if (rows.isEmpty) return;
    final List<Project> current = await _projects.loadAll();
    final Map<String, Project> byId = <String, Project>{
      for (final Project p in current) p.id: p,
    };
    for (final Project p in rows) {
      byId[p.id] = p;
    }
    await _projects.saveAll(
      byId.values.toList(),
      activeProjectId: _projects.loadedActiveProjectId,
    );
  }

  @override
  Future<void> upsertClipboardItems(List<ClipboardItem> rows) async {
    if (rows.isEmpty) return;
    // `ClipboardRepository` has no collection-update method, so a pulled
    // row's `collections` are not applied here — an accepted gap for this
    // slice, documented in `docs/architecture/sync.md`.
    final List<ClipboardItem> existing = await _clipboard.getItems();
    final Map<String, ClipboardItem> byId = <String, ClipboardItem>{
      for (final ClipboardItem c in existing) c.id: c,
    };
    for (final ClipboardItem row in rows) {
      final ClipboardItem? current = byId[row.id];
      if (current == null) {
        await _clipboard.addItem(row);
      } else if (row.text != null && row.text != current.text) {
        await _clipboard.updateItemText(row.id, row.text!);
      }
    }
  }

  @override
  Future<void> appendRevisions(List<RecordingRevision> rows) async {
    if (rows.isEmpty) return;
    await _revisions?.append(rows);
  }

  @override
  Future<void> deleteRecording(String id) => _deleteRecording(id);

  @override
  Future<void> deleteProject(String id) async {
    final List<Project> current = await _projects.loadAll();
    if (!current.any((Project p) => p.id == id)) return; // unknown id, no-op
    final String? activeId = _projects.loadedActiveProjectId;
    final List<Project> remaining = current
        .where((Project p) => p.id != id)
        .toList();
    // Mirrors `ProjectsController._resolveActive`: a dangling active id is
    // never written, only ever carried through or replaced.
    final String? nextActiveId = activeId == id
        ? (remaining.isEmpty ? null : remaining.first.id)
        : activeId;
    await _projects.saveAll(remaining, activeProjectId: nextActiveId);
  }

  @override
  Future<void> deleteClipboardItem(String id) => _clipboard.deleteItem(id);
}
