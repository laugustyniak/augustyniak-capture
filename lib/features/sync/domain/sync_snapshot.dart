import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';

/// What the server last acknowledged for one local row.
class SyncRowState {
  const SyncRowState({required this.serverVersion, required this.pushedHash});

  final int serverVersion;
  final String pushedHash;
}

/// Device-local sync bookkeeping: the server version and pushed-content hash
/// last recorded per row, plus a per-table pull cursor. A later task adds
/// more classes to this file.
abstract interface class SyncBookkeeping {
  Map<String, SyncRowState> loadTable(String table);
  void put(String table, String id, int serverVersion, String pushedHash);
  void remove(String table, String id);
  DateTime? cursor(String table);
  void setCursor(String table, DateTime value);
}

/// Everything the device holds that syncs, read once at the start of a run.
class SyncSnapshot {
  const SyncSnapshot({
    this.recordings = const <Recording>[],
    this.projects = const <Project>[],
    this.clipboardItems = const <ClipboardItem>[],
    this.revisions = const <RecordingRevision>[],
    this.device = const <String, Object?>{},
  });

  final List<Recording> recordings;
  final List<Project> projects;
  final List<ClipboardItem> clipboardItems;
  final List<RecordingRevision> revisions;
  final Map<String, Object?> device;
}

/// One `SyncEngine.run()` call's outcome.
class SupabaseSyncResult {
  const SupabaseSyncResult({
    this.pushed = 0,
    this.pulled = 0,
    this.conflicts = 0,
    this.tombstonesApplied = 0,
    this.skipped = 0,
    this.failureReason,
  });

  final int pushed;
  final int pulled;
  final int conflicts;
  final int tombstonesApplied;
  final int skipped;
  final String? failureReason;

  bool get success => failureReason == null;
}
