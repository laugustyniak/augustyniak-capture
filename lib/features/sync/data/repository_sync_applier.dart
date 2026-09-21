import '../../clipboard/data/clipboard_repository.dart';
import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/domain/project.dart';
import '../../recordings/data/revisions_repository.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';
import '../domain/sync_engine.dart';

/// [SyncEngine]'s pull side. Recordings and projects apply through the
/// owning controller's own funnel — `RecordingsController.
/// applySyncedRecordings`/`deleteRecording`, `ProjectsController.
/// applySyncedProjects`/`applySyncedProjectDelete` — never through a second
/// `RecordingsRepository`/`ProjectsRepository` writing underneath that
/// controller: that second-writer shape is what let a concurrent
/// controller-owned write (a running capture's `_persistAll`, a user's next
/// `select`) silently revert what this applier had just written, because
/// the controller's own in-memory list never saw it. Clipboard items apply
/// straight through `ClipboardRepository`, which is safe here because its
/// writes are already row-level (`addItem`/`updateItemText`/`deleteItem`),
/// never a whole-list rewrite from a captured snapshot the way the other
/// two used to be — see `docs/architecture/sync.md`. Clipboard *inserts* go
/// through `insertItem`, never `addItem`: `addItem`'s adjacent-content
/// dedupe would silently drop a pulled row identical to the newest local
/// entry while this applier still bookkept it as applied, which caused a
/// tombstone for another device's row on the next run — see the interface
/// doc comment on `ClipboardRepository.insertItem`.
///
/// Every `delete*` tolerates an id it has never heard of: a pulled
/// tombstone for a row this device never had is a no-op, not an error.
class RepositorySyncApplier implements SyncApplier {
  RepositorySyncApplier({
    required Future<void> Function(List<Recording> upserts) applySyncedRecordings,
    required Future<void> Function(List<Project> upserts) applySyncedProjects,
    required Future<void> Function(String id) applySyncedProjectDelete,
    required ClipboardRepository clipboard,
    required RevisionsRepository? revisions,
    required Future<void> Function(String id) deleteRecording,
    required bool Function(String id) recordingExists,
  }) : _applySyncedRecordings = applySyncedRecordings,
       _applySyncedProjects = applySyncedProjects,
       _applySyncedProjectDelete = applySyncedProjectDelete,
       _clipboard = clipboard,
       _revisions = revisions,
       _deleteRecording = deleteRecording,
       _recordingExists = recordingExists;

  final Future<void> Function(List<Recording> upserts) _applySyncedRecordings;
  final Future<void> Function(List<Project> upserts) _applySyncedProjects;
  final Future<void> Function(String id) _applySyncedProjectDelete;
  final ClipboardRepository _clipboard;
  final RevisionsRepository? _revisions;
  final Future<void> Function(String id) _deleteRecording;
  final bool Function(String id) _recordingExists;

  @override
  Future<void> upsertRecordings(List<Recording> rows) => _applySyncedRecordings(rows);

  @override
  Future<void> upsertProjects(List<Project> rows) => _applySyncedProjects(rows);

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
        await _clipboard.insertItem(row);
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

  /// `RecordingsController.deleteRecording` returns normally on a refusal
  /// (the index unreadable, a source file that would not delete) rather
  /// than throwing, so it can be pressed again from the UI without an error
  /// dialog. That silence is exactly wrong for a sync tombstone: the engine
  /// needs to know the delete did not happen, so it neither bookkeeps the
  /// row as gone (it is not) nor counts the tombstone applied. Checking
  /// [_recordingExists] after the call is the only way to tell a refusal
  /// from success, since the callback's return type carries nothing else.
  @override
  Future<void> deleteRecording(String id) async {
    await _deleteRecording(id);
    if (_recordingExists(id)) {
      throw StateError('delete refused for $id');
    }
  }

  @override
  Future<void> deleteProject(String id) => _applySyncedProjectDelete(id);

  @override
  Future<void> deleteClipboardItem(String id) => _clipboard.deleteItem(id);
}
