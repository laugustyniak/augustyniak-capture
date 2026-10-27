import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';

/// What the server last acknowledged for one local row.
class SyncRowState {
  const SyncRowState({
    required this.serverVersion,
    required this.pushedHash,
    this.sealed = false,
  });

  final int serverVersion;
  final String pushedHash;

  /// Whether this device last saw the row end-to-end encrypted, either
  /// pulled out of an envelope or pushed into one. A sealed row that later
  /// arrives unsealed is a downgrade and is refused (#377); a row bookkept
  /// unsealed is a legacy plaintext row and applies as it always did.
  ///
  /// The flag is sticky: once true it stays true while the bookkeeping row
  /// exists. The only way back is the row leaving bookkeeping (a tombstone or
  /// `remove`).
  final bool sealed;
}

/// Device-local sync bookkeeping: the server version and pushed-content hash
/// last recorded per row, plus a per-table pull cursor. A later task adds
/// more classes to this file.
abstract interface class SyncBookkeeping {
  Map<String, SyncRowState> loadTable(String table);
  void put(
    String table,
    String id,
    int serverVersion,
    String pushedHash, {
    bool sealed = false,
  });
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
    this.conflictDetails = const <SyncConflictDetail>[],
    this.tombstonesApplied = 0,
    this.tombstonesHeld = 0,
    this.skipped = 0,
    this.downgraded = 0,
    this.failureReason,
  });

  final int pushed;
  final int pulled;
  final int conflicts;
  final List<SyncConflictDetail> conflictDetails;
  final int tombstonesApplied;

  /// Of [tombstonesApplied], how many were applied under the blast-radius
  /// cap: their files went to the trash marked held, awaiting confirmation.
  final int tombstonesHeld;
  final int skipped;

  /// Rows refused because they arrived unencrypted after this device last
  /// saw them sealed.
  final int downgraded;
  final String? failureReason;

  bool get success => failureReason == null;
}

/// A version race, without any capture content or credentials.
class SyncConflictDetail {
  const SyncConflictDetail({
    required this.table,
    required this.id,
    required this.resolution,
    this.overwrittenFields = const <String>[],
  });

  final String table;
  final String id;
  final SyncConflictResolution resolution;
  final List<String> overwrittenFields;

  bool get isBookkeeping => table == 'devices' || table == 'sync_state';
}

enum SyncConflictResolution {
  serverApplied,
  serverDeleted,
  localTranscriptKept,
  serverAdopted,
  retryNeeded,
}
