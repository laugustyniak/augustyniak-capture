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
  Future<void> deleteProject(String id);
  Future<void> deleteClipboardItem(String id);
}

const int syncBatchSize = 200;

/// The four tables pulled every run. `segments` rides inside a recording's
/// `payload`/columns and has no separate pull; `devices` and `sync_state`
/// are write-only bookkeeping the device never reads back.
const List<SyncTable> _pulledTables = <SyncTable>[
  SyncTable.projects,
  SyncTable.recordings,
  SyncTable.clipboardItems,
  SyncTable.revisions,
];

/// Diffs a [SyncSnapshot] against device-local bookkeeping and pushes
/// whatever changed through a [SyncTransport], one table at a time; then
/// pulls every table since its cursor and applies the server's view through
/// a [SyncApplier] — see the spec's "Pull" and "Apply" sections.
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
  final SyncApplier _applier;
  final DateTime Function() _clock;

  Future<SupabaseSyncResult> run(SyncSnapshot snapshot) async {
    int pushed = 0;
    int conflicts = 0;
    int skipped = 0;
    int pulled = 0;
    int tombstones = 0;
    // Shared with the pull loop below: a tombstone resolved while applying a
    // push conflict removes its id here so the same run's pull pass — which
    // may re-see the row inside the lag window — does not delete it twice.
    final Map<String, Recording> localRecordings = <String, Recording>{
      for (final Recording r in snapshot.recordings) r.id: r,
    };
    // Same idea for the tables `_applySimple` handles (projects, clipboard
    // items), which have no local map to remove an id from — a tombstone
    // adds `'<table.serverName>/<id>'` here so a later call this run (the
    // lag-window re-read) skips it instead of deleting it a second time.
    final Set<String> tombstonedIds = <String>{};
    final List<Recording> redirtied = <Recording>[];
    try {
      for (final _Outbox outbox in _outboxes(snapshot)) {
        final _PushOutcome outcome = await _pushTable(outbox);
        pushed += outcome.applied;
        conflicts += outcome.conflicts;
        skipped += outcome.skipped;
        // Conflicts returned by sync_push are applied with the same path as
        // pulled rows, so the pull pass below does not re-count them.
        if (outcome.conflictRows.isNotEmpty) {
          final _PullOutcome resolved = await _resolvePushConflicts(
            outbox.table,
            outcome.conflictRows,
            localRecordings,
            tombstonedIds,
          );
          pulled += resolved.pulled;
          tombstones += resolved.tombstones;
          skipped += resolved.skipped;
          redirtied.addAll(resolved.redirtied);
        }
      }

      final _PullOutcome pull = await _pullAll(snapshot, localRecordings, tombstonedIds);
      pulled += pull.pulled;
      conflicts += pull.conflicts;
      tombstones += pull.tombstones;
      skipped += pull.skipped;
      redirtied.addAll(pull.redirtied);

      if (redirtied.isNotEmpty) {
        // The transcript rule kept a local value the server tried to
        // shorten; push it back so the server converges on the longer text.
        // `sweepDeletes: false` — this outbox is a *partial* view of the
        // recordings table (only the redirtied ids), and the ordinary sweep
        // would read every other bookkept recording as locally deleted and
        // tombstone it on the server.
        final _PushOutcome again = await _pushTable(
          _Outbox(SyncTable.recordings, {
            for (final Recording r in redirtied) r.id: SyncRowCodec.recording(r),
          }),
          sweepDeletes: false,
        );
        pushed += again.applied;
        conflicts += again.conflicts;
        skipped += again.skipped;
      }
    } catch (error) {
      return SupabaseSyncResult(
        pushed: pushed,
        pulled: pulled,
        conflicts: conflicts,
        tombstonesApplied: tombstones,
        skipped: skipped,
        failureReason: '$error',
      );
    }
    return SupabaseSyncResult(
      pushed: pushed,
      pulled: pulled,
      conflicts: conflicts,
      tombstonesApplied: tombstones,
      skipped: skipped,
    );
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

  /// [sweepDeletes] governs the tombstone sweep below: it must be `false`
  /// for a *partial* outbox — one that does not represent every row this
  /// device holds for the table (the transcript rule's redirtied re-push,
  /// say) — because the sweep otherwise reads every bookkept id absent from
  /// the outbox as locally deleted and tombstones it on the server.
  Future<_PushOutcome> _pushTable(_Outbox outbox, {bool sweepDeletes = true}) async {
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
    if (outbox.table.versioned && sweepDeletes) {
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
    final List<Map<String, Object?>> conflictRows = <Map<String, Object?>>[];
    for (int i = 0; i < dirty.length; i += syncBatchSize) {
      final List<(String, Map<String, Object?>, String)> batch = dirty.sublist(
        i,
        (i + syncBatchSize).clamp(0, dirty.length),
      );
      final SyncPushResult result = await _transport.push(outbox.table, [
        for (final (String, Map<String, Object?>, String) d in batch) d.$2,
      ]);
      conflictRows.addAll(result.conflicts);
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
    }
    return _PushOutcome(applied, conflicts, skipped, conflictRows);
  }

  Map<String, Object?> _tombstone(SyncTable table, String id, int version) {
    // Single-key tables use the bookkeeping id verbatim — an id containing
    // '/' (a project id, say) must not be split. Only a composite key
    // (segments: recording_id/index) is split apart.
    if (table.keyColumns.length == 1) {
      return <String, Object?>{
        table.keyColumns.single: id,
        'version': version,
        'deleted_at': _clock().toIso8601String(),
      };
    }
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

  /// Applies the rows `sync_push` reported as conflicts through the same
  /// apply path a pull would use, for the tables that have a local domain
  /// object to apply them onto. `segments`, `devices` and `sync_state` do
  /// not — there is no repository to write them through — so those are only
  /// *adopted*: bookkeeping is set to the server's version and a hash of the
  /// server row (the same top-level key set `SyncRowCodec.hash` always
  /// canonicalizes, so it lines up with what a later unchanged local push of
  /// the same content would hash to). Nothing is applied locally, and the
  /// conflict is not re-counted here — `_pushTable` already counted it —
  /// only adopted so it is not re-conflicted every subsequent run.
  Future<_PullOutcome> _resolvePushConflicts(
    SyncTable table,
    List<Map<String, Object?>> rows,
    Map<String, Recording> localRecordings,
    Set<String> tombstonedIds,
  ) async {
    final _PullOutcome scratch = _PullOutcome();
    switch (table) {
      case SyncTable.recordings:
        await _applyRecordings(rows, localRecordings, scratch);
      case SyncTable.projects:
        await _applySimple<Project>(
          table,
          rows,
          SyncRowCodec.projectFromRow,
          SyncRowCodec.project,
          _applier.upsertProjects,
          _applier.deleteProject,
          scratch,
          tombstonedIds,
        );
      case SyncTable.clipboardItems:
        await _applySimple<ClipboardItem>(
          table,
          rows,
          SyncRowCodec.clipboardItemFromRow,
          SyncRowCodec.clipboardItem,
          _applier.upsertClipboardItems,
          _applier.deleteClipboardItem,
          scratch,
          tombstonedIds,
        );
      default:
        for (final Map<String, Object?> row in rows) {
          final String id = SyncRowCodec.rowId(table, row);
          final int version = row['version'] is int ? row['version'] as int : 0;
          _bookkeeping.put(
            table.serverName,
            id,
            version,
            SyncRowCodec.hash(_canonicalServerRow(row)),
          );
        }
    }
    return scratch;
  }

  /// Re-shapes a raw server row into the same canonical form the codec's
  /// own encoders always produce, before it is hashed for adoption.
  ///
  /// `sync_push`'s real RPC returns a conflicting row as `to_jsonb(t)`, so a
  /// timestamp column comes back as Postgres renders it
  /// (`2026-09-21T12:00:00+00:00`); `SyncRowCodec.segments()`/`device()`
  /// render the identical instant as Dart's own `toIso8601String()`
  /// (`2026-09-21T12:00:00.000Z`). Hashing the raw row directly would never
  /// match what a later, unchanged local push of the same content hashes to
  /// — one spurious push every run for every adopted row.
  Map<String, Object?> _canonicalServerRow(Map<String, Object?> row) {
    final Map<String, Object?> canonical = <String, Object?>{};
    for (final MapEntry<String, Object?> entry in row.entries) {
      if (entry.key == 'owner_id' ||
          entry.key == 'updated_at' ||
          entry.key == 'version' ||
          entry.key == 'deleted_at') {
        continue;
      }
      final Object? value = entry.value;
      if (value is String) {
        final DateTime? parsed = DateTime.tryParse(value);
        canonical[entry.key] = parsed?.toUtc().toIso8601String() ?? value;
      } else {
        canonical[entry.key] = value;
      }
    }
    return canonical;
  }

  Future<_PullOutcome> _pullAll(
    SyncSnapshot s,
    Map<String, Recording> localRecordings,
    Set<String> tombstonedIds,
  ) async {
    final _PullOutcome total = _PullOutcome();
    for (final SyncTable table in _pulledTables) {
      final DateTime? since = _bookkeeping.cursor(table.serverName);
      DateTime? newest = since;
      int offset = 0;
      final List<Map<String, Object?>> rows = [];
      while (true) {
        final SyncPage page = await _transport.pull(
          table,
          since: since,
          offset: offset,
          limit: 500,
        );
        rows.addAll(page.rows);
        offset += page.rows.length;
        if (!page.hasMore) break;
      }
      for (final Map<String, Object?> row in rows) {
        final DateTime? at = DateTime.tryParse('${row['updated_at']}')?.toUtc();
        if (at != null && (newest == null || at.isAfter(newest))) newest = at;
      }
      switch (table) {
        case SyncTable.recordings:
          await _applyRecordings(rows, localRecordings, total);
        case SyncTable.projects:
          await _applySimple<Project>(
            table,
            rows,
            SyncRowCodec.projectFromRow,
            SyncRowCodec.project,
            _applier.upsertProjects,
            _applier.deleteProject,
            total,
            tombstonedIds,
          );
        case SyncTable.clipboardItems:
          await _applySimple<ClipboardItem>(
            table,
            rows,
            SyncRowCodec.clipboardItemFromRow,
            SyncRowCodec.clipboardItem,
            _applier.upsertClipboardItems,
            _applier.deleteClipboardItem,
            total,
            tombstonedIds,
          );
        case SyncTable.revisions:
          await _applyRevisions(rows, total);
        default:
          break;
      }
      if (newest != null) _bookkeeping.setCursor(table.serverName, newest);
    }
    // Mirror the cursors to the server's sync_state row for this device so a
    // reinstall can see where its predecessor stopped. Versioned like any
    // other row; a conflict here is harmless and just counted.
    if (s.device['id'] is String) {
      final String deviceId = s.device['id']! as String;
      final _PushOutcome mirrored = await _pushTable(_Outbox(SyncTable.syncState, {
        for (final SyncTable t in _pulledTables)
          '$deviceId/${t.serverName}': <String, Object?>{
            'device_id': deviceId,
            'table_name': t.serverName,
            'pulled_through': _bookkeeping.cursor(t.serverName)?.toIso8601String(),
          },
      }));
      total.conflicts += mirrored.conflicts;
      if (mirrored.conflictRows.isNotEmpty) {
        await _resolvePushConflicts(
          SyncTable.syncState,
          mirrored.conflictRows,
          localRecordings,
          tombstonedIds,
        );
      }
    }
    return total;
  }

  Future<void> _applyRecordings(
    List<Map<String, Object?>> rows,
    Map<String, Recording> local,
    _PullOutcome out,
  ) async {
    final Map<String, SyncRowState> known = _bookkeeping.loadTable(
      SyncTable.recordings.serverName,
    );
    final List<Recording> upserts = [];
    final List<RecordingRevision> revisions = [];
    // (id, version, hash) — the actual `_bookkeeping.put` calls are deferred
    // until after `upsertRecordings` returns, below, so a repository write
    // failure (e.g. `IndexUnreadableException`) never leaves bookkeeping
    // claiming a version the local index does not actually hold.
    final List<(String, int, String)> pendingBookkeeping = [];
    for (final Map<String, Object?> row in rows) {
      final String? id = row['id'] as String?;
      if (id == null) {
        out.skipped++;
        continue;
      }
      final int serverVersion = row['version'] is int ? row['version'] as int : 0;
      final Recording? mine = local[id];
      final SyncRowState? state = known[id];
      final bool dirty = mine != null &&
          (state == null ||
              SyncRowCodec.hash(SyncRowCodec.recording(mine)) != state.pushedHash);

      if (row['deleted_at'] != null) {
        if (mine == null) {
          _bookkeeping.remove(SyncTable.recordings.serverName, id);
          known.remove(id);
          continue;
        }
        // Revisions before the delete — HISTORY must show what was thrown
        // away before the row (and its source file) are gone.
        if (dirty) {
          final List<RecordingRevision> lost = _overwritten(mine, null);
          if (lost.isNotEmpty) await _applier.appendRevisions(lost);
        }
        await _applier.deleteRecording(id);
        _bookkeeping.remove(SyncTable.recordings.serverName, id);
        known.remove(id);
        // Prevent a later apply pass in this same run (the lag-window
        // re-read, or a second push-conflict batch) from deleting again.
        local.remove(id);
        out.tombstones++;
        continue;
      }
      if (state != null && serverVersion <= state.serverVersion) continue; // already have it
      final Recording? theirs = SyncRowCodec.recordingFromRow(row, local: mine);
      if (theirs == null) {
        out.skipped++;
        continue;
      }

      // Transcript never shrinks — decided before the conflict diff below,
      // so a transcript the rule kept is never itself reported as an
      // overwritten field. An empty local transcript counts as absent:
      // there is nothing to protect.
      Recording next = theirs;
      final String? mineTranscript = mine?.transcript;
      final bool transcriptShrinks = mineTranscript != null &&
          mineTranscript.isNotEmpty &&
          (theirs.transcript == null || theirs.transcript!.length < mineTranscript.length);
      if (transcriptShrinks) {
        next = theirs.copyWith(transcript: mineTranscript);
      }

      if (mine != null && dirty) {
        out.conflicts++;
        revisions.addAll(_overwritten(mine, next));
      }

      final String hash;
      if (transcriptShrinks) {
        out.redirtied.add(next);
        hash = 'redirtied'; // hash mismatch on purpose
      } else {
        hash = SyncRowCodec.hash(SyncRowCodec.recording(next));
      }
      // Update the in-memory maps immediately so a later row in this same
      // page (a duplicate id) sees the fresh state; the persistent
      // bookkeeping write is deferred (see `pendingBookkeeping` above).
      known[id] = SyncRowState(serverVersion: serverVersion, pushedHash: hash);
      local[id] = next;
      pendingBookkeeping.add((id, serverVersion, hash));
      upserts.add(next);
      out.pulled++;
    }
    // Conflict revisions after the upsert, not before: a thrown
    // upsertRecordings must not leave a SYNC revision on disk for a row
    // that was never actually replaced — the next run would re-diff the
    // same overwrite and duplicate it. (A tombstone's revisions stay
    // before deleteRecording, above — HISTORY must show what a delete
    // threw away before the row is gone, and there is no "row never
    // replaced" case for a delete to undo.)
    if (upserts.isNotEmpty) await _applier.upsertRecordings(upserts);
    if (revisions.isNotEmpty) await _applier.appendRevisions(revisions);
    for (final (id, version, hash) in pendingBookkeeping) {
      _bookkeeping.put(SyncTable.recordings.serverName, id, version, hash);
    }
  }

  /// One revision per field the server value replaces. `theirs == null` is a
  /// tombstone: every non-empty local field is recorded as lost. Mirrors
  /// `CaptureHistory.recordRevisions` field for field: same names, same
  /// `truncate`, same "a change out of an empty value is never recorded".
  List<RecordingRevision> _overwritten(Recording mine, Recording? theirs) {
    final DateTime at = _clock();
    RecordingRevision? diff(String field, String? from, String? to) {
      if (from == null || from.isEmpty || from == to) return null;
      return RecordingRevision(
        recordingId: mine.id,
        at: at,
        field: field,
        from: RecordingRevision.truncate(from),
        to: RecordingRevision.truncate(to),
        source: RevisionSource.sync,
      );
    }

    return <RecordingRevision?>[
      diff('title', mine.title, theirs?.title),
      diff('category', mine.category?.name, theirs?.category?.name),
      diff('summary', mine.summary, theirs?.summary),
      diff('tags', mine.tags.join(', '), theirs?.tags.join(', ')),
      diff('transcript', mine.transcript, theirs?.transcript),
    ].whereType<RecordingRevision>().toList();
  }

  /// Decodes each row, skips a decode failure, bookkeeps `(version, hash)`
  /// gated the same way `_applyRecordings` gates a plain replace, counts
  /// `pulled`, and hands the batch to the applier. A tombstone calls
  /// [delete] and removes bookkeeping instead of decoding.
  ///
  /// The hash is taken by re-encoding the decoded value through [encode] —
  /// never the raw pulled `row` — because Postgres `jsonb` reorders a nested
  /// map's keys on storage (`SyncRowCodec.hash`'s own doc comment). Hashing
  /// the raw row would make an unchanged pull look locally dirty on the next
  /// push and re-push it forever.
  ///
  /// [tombstonedIds] is shared across every call this run (push-conflict
  /// resolution, then the pull pass): once a row's tombstone is applied its
  /// `'<table>/<id>'` key is added, so a later call for the same id — the
  /// row is gone from bookkeeping, so nothing else marks it "already
  /// handled" — does not call [delete] a second time.
  Future<void> _applySimple<T>(
    SyncTable table,
    List<Map<String, Object?>> rows,
    T? Function(Map<String, Object?>) decode,
    Map<String, Object?> Function(T) encode,
    Future<void> Function(List<T>) upsert,
    Future<void> Function(String id) delete,
    _PullOutcome out,
    Set<String> tombstonedIds,
  ) async {
    final Map<String, SyncRowState> known = _bookkeeping.loadTable(table.serverName);
    final List<T> upserts = <T>[];
    // (id, version, hash) — deferred until `upsert` returns; see
    // `_applyRecordings`'s matching comment for why.
    final List<(String, int, String)> pendingBookkeeping = [];
    for (final Map<String, Object?> row in rows) {
      final String id = SyncRowCodec.rowId(table, row);
      final String tombstoneKey = '${table.serverName}/$id';
      if (tombstonedIds.contains(tombstoneKey)) continue;
      final int serverVersion = row['version'] is int ? row['version'] as int : 0;
      final SyncRowState? state = known[id];
      if (state != null && serverVersion <= state.serverVersion) continue;
      if (row['deleted_at'] != null) {
        await delete(id);
        _bookkeeping.remove(table.serverName, id);
        known.remove(id);
        tombstonedIds.add(tombstoneKey);
        out.tombstones++;
        continue;
      }
      final T? decoded = decode(row);
      if (decoded == null) {
        out.skipped++;
        continue;
      }
      final String hash = SyncRowCodec.hash(encode(decoded));
      known[id] = SyncRowState(serverVersion: serverVersion, pushedHash: hash);
      pendingBookkeeping.add((id, serverVersion, hash));
      upserts.add(decoded);
      out.pulled++;
    }
    if (upserts.isNotEmpty) await upsert(upserts);
    for (final (id, version, hash) in pendingBookkeeping) {
      _bookkeeping.put(table.serverName, id, version, hash);
    }
  }

  /// Revisions are append-only: bookkeep each pulled row's id at version 0
  /// and skip ids already known, so `appendRevisions` never re-appends a
  /// line the repository already has.
  ///
  /// The id is keyed from the *decoded-then-re-encoded* row, never the raw
  /// pulled row: PostgREST renders a timestamp as `2026-09-21T08:00:00+00:00`
  /// while `SyncRowCodec.revision`'s own `_utc()` renders the same instant
  /// as `2026-09-21T08:00:00.000Z` (Dart's `toIso8601String()`). Keying by
  /// the raw string would never match the canonical id `_outboxes` bookkept
  /// when this device originally pushed the same revision, so every
  /// lag-window re-read would look unknown and get re-appended forever.
  Future<void> _applyRevisions(List<Map<String, Object?>> rows, _PullOutcome out) async {
    final Map<String, SyncRowState> known = _bookkeeping.loadTable(
      SyncTable.revisions.serverName,
    );
    final List<RecordingRevision> toAppend = [];
    final List<(String, String)> pendingBookkeeping = [];
    for (final Map<String, Object?> row in rows) {
      final RecordingRevision? rev = SyncRowCodec.revisionFromRow(row);
      if (rev == null) {
        out.skipped++;
        continue;
      }
      final Map<String, Object?> canonical = SyncRowCodec.revision(rev);
      final String id = SyncRowCodec.rowId(SyncTable.revisions, canonical);
      if (known.containsKey(id)) continue;
      final String hash = SyncRowCodec.hash(canonical);
      known[id] = SyncRowState(serverVersion: 0, pushedHash: hash);
      pendingBookkeeping.add((id, hash));
      toAppend.add(rev);
      out.pulled++;
    }
    if (toAppend.isNotEmpty) await _applier.appendRevisions(toAppend);
    for (final (id, hash) in pendingBookkeeping) {
      _bookkeeping.put(SyncTable.revisions.serverName, id, 0, hash);
    }
  }
}

class _Outbox {
  const _Outbox(this.table, this.rows);
  final SyncTable table;
  final Map<String, Map<String, Object?>> rows;
}

class _PushOutcome {
  const _PushOutcome(this.applied, this.conflicts, this.skipped, this.conflictRows);
  final int applied;
  final int conflicts;
  final int skipped;

  /// The raw server rows `sync_push` returned as conflicts — the current
  /// server content for that id — so the caller can apply them the same way
  /// a pulled row is applied.
  final List<Map<String, Object?>> conflictRows;
}

/// One pull pass's tally, mutated in place as rows are applied.
class _PullOutcome {
  int pulled = 0;
  int conflicts = 0;
  int tombstones = 0;
  int skipped = 0;
  final List<Recording> redirtied = <Recording>[];
}
