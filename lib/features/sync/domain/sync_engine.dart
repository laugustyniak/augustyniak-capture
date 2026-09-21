import '../../clipboard/domain/clipboard_item.dart';
import '../../projects/domain/project.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/domain/recording_revision.dart';
import 'sync_row_codec.dart';
import 'sync_snapshot.dart';
import 'sync_table.dart';
import 'sync_transport.dart';

/// What the pull side does to the device — see Task 7. Declared here so the
/// engine has one constructor from the start.
abstract interface class SyncApplier {
  Future<void> upsertRecordings(List<Recording> rows);
  Future<void> upsertProjects(List<Project> rows);
  Future<void> upsertClipboardItems(List<ClipboardItem> rows);
  Future<void> appendRevisions(List<RecordingRevision> rows);
  Future<void> deleteRecording(String id);
}

const int syncBatchSize = 200;

/// Diffs a [SyncSnapshot] against device-local bookkeeping and pushes
/// whatever changed through a [SyncTransport], one table at a time.
class SyncEngine {
  SyncEngine({
    required SyncTransport transport,
    required SyncBookkeeping bookkeeping,
    required SyncApplier applier,
    DateTime Function()? clock,
  }) : _transport = transport,
       _bookkeeping = bookkeeping,
       _applier = applier,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final SyncTransport _transport;
  final SyncBookkeeping _bookkeeping;
  // Wired but unused until Task 7 adds the pull side that applies rows
  // through it.
  // ignore: unused_field
  final SyncApplier _applier;
  final DateTime Function() _clock;

  Future<SupabaseSyncResult> run(SyncSnapshot snapshot) async {
    int pushed = 0;
    int conflicts = 0;
    int skipped = 0;
    try {
      for (final _Outbox outbox in _outboxes(snapshot)) {
        final _PushOutcome outcome = await _pushTable(outbox);
        pushed += outcome.applied;
        conflicts += outcome.conflicts;
        skipped += outcome.skipped;
      }
    } catch (error) {
      return SupabaseSyncResult(
        pushed: pushed,
        conflicts: conflicts,
        skipped: skipped,
        failureReason: '$error',
      );
    }
    return SupabaseSyncResult(pushed: pushed, conflicts: conflicts, skipped: skipped);
    // Task 7 adds the pull between the push and the return.
  }

  /// One table's local rows in server shape, keyed by row id.
  Iterable<_Outbox> _outboxes(SyncSnapshot s) sync* {
    yield _Outbox(SyncTable.projects, {
      for (final Project p in s.projects) p.id: SyncRowCodec.project(p),
    });
    yield _Outbox(SyncTable.recordings, {
      for (final Recording r in s.recordings) r.id: SyncRowCodec.recording(r),
    });
    yield _Outbox(SyncTable.segments, {
      for (final Recording r in s.recordings)
        for (final Map<String, Object?> seg in SyncRowCodec.segments(r))
          SyncRowCodec.rowId(SyncTable.segments, seg): seg,
    });
    yield _Outbox(SyncTable.clipboardItems, {
      for (final ClipboardItem c in s.clipboardItems)
        c.id: SyncRowCodec.clipboardItem(c),
    });
    yield _Outbox(SyncTable.revisions, {
      for (final RecordingRevision rev in s.revisions)
        SyncRowCodec.rowId(SyncTable.revisions, SyncRowCodec.revision(rev)):
            SyncRowCodec.revision(rev),
    });
    if (s.device.isNotEmpty) {
      yield _Outbox(SyncTable.devices, {s.device['id'] as String: s.device});
    }
  }

  Future<_PushOutcome> _pushTable(_Outbox outbox) async {
    final Map<String, SyncRowState> known = _bookkeeping.loadTable(
      outbox.table.serverName,
    );
    // id, row, hash
    final List<(String, Map<String, Object?>, String)> dirty =
        <(String, Map<String, Object?>, String)>[];

    for (final MapEntry<String, Map<String, Object?>> e in outbox.rows.entries) {
      final String hash = SyncRowCodec.hash(e.value);
      final SyncRowState? state = known[e.key];
      if (state != null && state.pushedHash == hash) continue;
      final Map<String, Object?> row = Map<String, Object?>.from(e.value);
      if (outbox.table.versioned) row['version'] = (state?.serverVersion ?? 0) + 1;
      dirty.add((e.key, row, hash));
    }
    // Known to the server, gone from the device: tombstone at the next version.
    if (outbox.table.versioned) {
      for (final MapEntry<String, SyncRowState> e in known.entries) {
        if (outbox.rows.containsKey(e.key)) continue;
        dirty.add((
          e.key,
          _tombstone(outbox.table, e.key, e.value.serverVersion + 1),
          '',
        ));
      }
    }

    int applied = 0;
    int conflicts = 0;
    int skipped = 0;
    for (int i = 0; i < dirty.length; i += syncBatchSize) {
      final List<(String, Map<String, Object?>, String)> batch = dirty.sublist(
        i,
        (i + syncBatchSize).clamp(0, dirty.length),
      );
      final SyncPushResult result = await _transport.push(outbox.table, [
        for (final (String, Map<String, Object?>, String) d in batch) d.$2,
      ]);
      final Set<String> conflicted = {
        for (final Map<String, Object?> c in result.conflicts)
          SyncRowCodec.rowId(outbox.table, c),
      };
      final Set<String> rejected = {
        for (final Map<String, Object?> r in result.rejected)
          SyncRowCodec.rowId(outbox.table, r),
      };
      for (final (String id, Map<String, Object?> row, String hash) in batch) {
        if (conflicted.contains(id)) {
          conflicts++;
          continue;
        }
        if (rejected.contains(id)) {
          skipped++;
          continue;
        }
        applied++;
        if (row['deleted_at'] != null) {
          _bookkeeping.remove(outbox.table.serverName, id);
        } else {
          _bookkeeping.put(
            outbox.table.serverName,
            id,
            outbox.table.versioned ? row['version'] as int : 0,
            hash,
          );
        }
      }
      // Task 7 applies `result.conflicts` through the same path as pulled rows.
    }
    return _PushOutcome(applied, conflicts, skipped);
  }

  Map<String, Object?> _tombstone(SyncTable table, String id, int version) {
    final List<String> parts = id.split('/');
    return <String, Object?>{
      for (int i = 0; i < table.keyColumns.length; i++)
        table.keyColumns[i]: table.keyColumns[i] == 'index'
            ? int.parse(parts[i])
            : parts[i],
      'version': version,
      'deleted_at': _clock().toIso8601String(),
    };
  }
}

class _Outbox {
  const _Outbox(this.table, this.rows);
  final SyncTable table;
  final Map<String, Map<String, Object?>> rows;
}

class _PushOutcome {
  const _PushOutcome(this.applied, this.conflicts, this.skipped);
  final int applied;
  final int conflicts;
  final int skipped;
}
