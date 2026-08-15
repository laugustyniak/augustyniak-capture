import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../core/database/app_database.dart';
import '../domain/capture_category.dart';
import '../domain/capture_type.dart';
import '../domain/capture_type.dart' as policy;
import '../domain/recording.dart';

class IndexUnreadableException implements Exception {
  const IndexUnreadableException(this.path, this.cause, {this.backupPath});

  final String path;
  final Object cause;
  final String? backupPath;

  @override
  String toString() =>
      'Recordings index at $path is unreadable: $cause'
      '${backupPath == null ? '' : ' (kept a copy at $backupPath)'}';
}

/// Same seam shape as `ProjectsDirectoryProvider`, and for the same reason:
/// the default reaches `path_provider`, which needs a platform binding, so a
/// pure-Dart suite has no way to exercise the real load/save path against a
/// temp directory without it. The subclassing fakes in `test/support` stand in
/// for the *whole* repository; this lets a caller keep the real behaviour and
/// only move where it happens.
typedef RecordingsDirectoryProvider = Future<Directory> Function();

class RecordingsRepository {
  RecordingsRepository({RecordingsDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final RecordingsDirectoryProvider _directoryProvider;

  static Future<Directory> _defaultDirectory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDirectory.path, 'recordings'));
  }

  static String extensionFor(CaptureType type, {String? sourceMimeType}) =>
      policy.extensionFor(type, mimeType: sourceMimeType);

  int? _knownCount;

  void expectRowCount(int count) => _knownCount = count;

  Future<void> deleteArtifacts(Recording recording) async {
    for (final String? path in <String?>[
      recording.filePath,
      recording.thumbPath,
      p.join(p.dirname(recording.filePath), '${recording.id}.thumb.jpg'),
    ]) {
      if (path == null || path.isEmpty) continue;
      final File file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<Directory> recordingsDirectory() async {
    final Directory directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> createSourceFile(String id, String extension) async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, '$id.$extension'));
  }

  Future<File> createAudioFile(String id) => createSourceFile(id, 'm4a');

  Future<List<Recording>> loadAll() async {
    if (!await _isDatabaseStale()) {
      final List<Recording>? fromDatabase = await _loadFromDatabase();
      if (fromDatabase != null) return fromDatabase;
    }

    final File index = await _indexFile();
    if (await index.exists()) {
      final String raw;
      final dynamic decoded;
      try {
        raw = await index.readAsString();
        if (raw.trim().isEmpty) {
          _knownCount = 0;
          return <Recording>[];
        }
        decoded = jsonDecode(raw);
      } catch (exception) {
        throw IndexUnreadableException(
          index.path,
          exception,
          backupPath: await _preserve(index, 'corrupt'),
        );
      }

      if (decoded is! List<dynamic>) {
        throw IndexUnreadableException(
          index.path,
          'expected a JSON list, got ${decoded.runtimeType}',
          backupPath: await _preserve(index, 'corrupt'),
        );
      }

      final List<Recording> recordings = <Recording>[];
      bool droppedARow = false;
      for (final dynamic item in decoded) {
        try {
          recordings.add(Recording.fromJson(item as Map<String, dynamic>));
        } catch (_) {
          droppedARow = true;
        }
      }
      if (droppedARow) {
        await _preserve(index, 'partial');
      }

      recordings.sort(
        (Recording a, Recording b) => b.createdAt.compareTo(a.createdAt),
      );
      _knownCount = recordings.length;
      return recordings;
    }

    return <Recording>[];
  }

  /// The `recordings` table's answer, or null when it has none to give — no
  /// rows yet, or a read that threw. Both mean the same thing to [loadAll]:
  /// ask the JSON index instead.
  Future<List<Recording>?> _loadFromDatabase() async {
    try {
      final AppDatabase db = await AppDatabase.getInstance();
      await db.migrateFromLegacyJsonIfNeeded();

      final ResultSet results = db.rawDb.select('''
        SELECT id, file_path, duration_ms, type, status, category, title, summary,
               tags_json, created_at, is_processed_by_user, project_id, failure_reason, json_payload
        FROM recordings
        ORDER BY created_at DESC;
      ''');

      if (results.isNotEmpty) {
        final List<Recording> recordings = <Recording>[];
        final Set<String> degraded = <String>{};
        for (final Row row in results) {
          final String? jsonPayload = row['json_payload'] as String?;
          if (jsonPayload != null && jsonPayload.isNotEmpty) {
            try {
              recordings.add(
                Recording.fromJson(
                  jsonDecode(jsonPayload) as Map<String, dynamic>,
                ),
              );
              continue;
            } catch (_) {}
          }
          degraded.add(row['id'] as String);
          final dynamic rawTags = jsonDecode(
            row['tags_json'] as String? ?? '[]',
          );
          final List<String> tags = rawTags is List<dynamic>
              ? rawTags.map((dynamic e) => e.toString()).toList()
              : <String>[];

          final String rawStatus = (row['status'] as String? ?? 'completed');
          RecordingStatus status = RecordingStatus.completed;
          for (final RecordingStatus s in RecordingStatus.values) {
            if (s.name == rawStatus) {
              status = s;
              break;
            }
          }

          recordings.add(
            Recording(
              id: row['id'] as String,
              filePath: row['file_path'] as String,
              durationMs: row['duration_ms'] as int,
              type: CaptureType.fromName(row['type'] as String?),
              status: status,
              category: row['category'] != null
                  ? CaptureCategory.fromName(row['category'] as String)
                  : null,
              title: row['title'] as String?,
              summary: row['summary'] as String?,
              tags: tags,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                row['created_at'] as int,
              ),
              isProcessedByUser: (row['is_processed_by_user'] as int) == 1,
              projectId: row['project_id'] as String?,
              error: row['failure_reason'] as String?,
            ),
          );
        }
        // The columns are a subset chosen for querying and for the sync
        // protocol — `transcript` is not among them — so a row rebuilt from
        // them is missing the capture's own text. Left as it is, the very next
        // save would write that emptied row over the JSON index, which is the
        // one place the text survives. Preferring the index row costs a file
        // read in a case that should never happen.
        if (degraded.isNotEmpty) {
          final Map<String, Recording> indexed = await _indexRowsById();
          for (int i = 0; i < recordings.length; i++) {
            final Recording? fromIndex = indexed[recordings[i].id];
            if (degraded.contains(recordings[i].id) && fromIndex != null) {
              recordings[i] = fromIndex;
            }
          }
        }

        _knownCount = recordings.length;
        return recordings;
      }
    } catch (_) {}
    return null;
  }

  /// The JSON index keyed by id, or empty when it cannot be read.
  ///
  /// Deliberately silent, unlike [loadAll]'s own read of the same file: this is
  /// a repair for rows the database answered badly, so a missing index leaves
  /// those rows degraded rather than taking the whole load down with it.
  Future<Map<String, Recording>> _indexRowsById() async {
    try {
      final File index = await _indexFile();
      if (!await index.exists()) return <String, Recording>{};
      final dynamic decoded = jsonDecode(await index.readAsString());
      if (decoded is! List<dynamic>) return <String, Recording>{};

      final Map<String, Recording> rows = <String, Recording>{};
      for (final dynamic item in decoded) {
        try {
          final Recording recording = Recording.fromJson(
            item as Map<String, dynamic>,
          );
          rows[recording.id] = recording;
        } catch (_) {}
      }
      return rows;
    } catch (_) {
      return <String, Recording>{};
    }
  }

  /// Serialized per recordings directory.
  ///
  /// `saveAll` stages the **whole** index in one `<dir>/recordings.json.tmp`
  /// before renaming it into place, so two writers overlapping tear that file
  /// and the rename then publishes the torn bytes *as* the index — precisely
  /// the failure the durability rules exist to prevent, and one the atomic
  /// rename cannot see because each half of the write is individually fine.
  ///
  /// Keyed by directory rather than held per instance: the `.tmp` path is a
  /// property of the directory, not of the object. The shell hands one
  /// repository to both the controller and the backup archive today, but a
  /// second instance built for the same directory still has to queue behind the
  /// first. `RecordingsController._saveInFlight` remains as the controller's
  /// own ordering guarantee; this is the floor underneath every caller.
  static final Map<String, Future<void>> _directoryWrites =
      <String, Future<void>>{};

  static Future<T> _serialized<T>(
    String key,
    Future<T> Function() action,
  ) async {
    while (_directoryWrites[key] != null) {
      await _directoryWrites[key];
    }
    final Completer<void> gate = Completer<void>();
    _directoryWrites[key] = gate.future;
    try {
      return await action();
    } finally {
      _directoryWrites.remove(key);
      gate.complete();
    }
  }

  Future<void> saveAll(List<Recording> recordings) async {
    final Directory directory = await recordingsDirectory();
    return _serialized(directory.path, () => _writeAll(recordings));
  }

  /// Read, merge and write back without letting go of the write gate.
  ///
  /// The backup import is the caller this exists for: it has to merge into the
  /// index it is about to write over. Loading first and saving later leaves a
  /// window in which the pipeline indexes a new capture, and the merged list —
  /// built from the older snapshot — silently drops it. The source file would
  /// survive as an orphan `recoverOrphans()` re-adopts; its transcript, which
  /// only ever lived in the index, would not.
  ///
  /// [merge] receives the freshly loaded index and returns the list to write.
  /// A throw from it leaves the index untouched, and an unreadable index throws
  /// out of here before [merge] is ever called.
  Future<void> updateAll(
    Future<List<Recording>> Function(List<Recording> current) merge,
  ) async {
    final Directory directory = await recordingsDirectory();
    return _serialized(directory.path, () async {
      final List<Recording> current = await loadAll();
      await _writeAll(await merge(current));
    });
  }

  Future<void> _writeAll(List<Recording> recordings) async {
    bool databaseWritten = false;
    try {
      final AppDatabase db = await AppDatabase.getInstance();
      db.rawDb.execute('BEGIN TRANSACTION;');
      try {
        db.rawDb.execute('DELETE FROM recordings;');
        final PreparedStatement stmt = db.rawDb.prepare('''
          INSERT INTO recordings
          (id, file_path, duration_ms, type, status, category, title, summary, tags_json, created_at, is_processed_by_user, project_id, failure_reason, json_payload)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''');

        for (final Recording r in recordings) {
          stmt.execute(<Object?>[
            r.id,
            r.filePath,
            r.durationMs,
            r.type.name,
            r.status.name,
            r.category?.name,
            r.title,
            r.summary,
            jsonEncode(r.tags),
            r.createdAt.millisecondsSinceEpoch,
            r.isProcessedByUser ? 1 : 0,
            r.projectId,
            r.error,
            jsonEncode(r.toJson()),
          ]);
        }
        stmt.close();
        db.rawDb.execute('COMMIT;');
        databaseWritten = true;
      } catch (e) {
        db.rawDb.execute('ROLLBACK;');
      }
    } catch (_) {}

    // The rollback above restores the *previous* contents of the table, and the
    // JSON write below cannot be rolled back with it. Left unmarked, the next
    // launch would read the stale table — which `loadAll` prefers — and undo
    // whatever this save was recording. The marker is written before the JSON,
    // never after, so a crash in between still leaves the table distrusted.
    await _markDatabaseStale(!databaseWritten);

    final File index = await _indexFile();
    final int? previous = _knownCount;
    if (previous != null &&
        recordings.length < previous &&
        await index.exists()) {
      await _preserve(index, 'shrank');
    }

    final String payload = const JsonEncoder.withIndent(
      '  ',
    ).convert(recordings.map((Recording item) => item.toJson()).toList());

    final File temporary = File('${index.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(index.path);
    _knownCount = recordings.length;
  }

  Future<List<Recording>> findOrphans(List<Recording> indexed) async {
    final Directory directory = await recordingsDirectory();
    final Set<String> known = indexed.map((Recording item) => item.id).toSet();

    final List<Recording> orphans = <Recording>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (name.endsWith('.thumb.jpg')) continue;

      final CaptureType? type = typeForExtension(p.extension(name));
      if (type == null) continue;

      final String id = p.basenameWithoutExtension(name);
      if (known.contains(id)) continue;

      final FileStat stat = await entity.stat();
      if (stat.size == 0) continue;

      orphans.add(
        Recording(
          id: id,
          filePath: entity.path,
          createdAt: stat.modified,
          durationMs: 0,
          sizeBytes: stat.size,
          status: RecordingStatus.saved,
          type: type,
        ),
      );
    }

    orphans.sort(
      (Recording a, Recording b) => b.createdAt.compareTo(a.createdAt),
    );
    return orphans;
  }

  Future<String?> _preserve(File file, String reason) async {
    try {
      final String stamp = DateTime.now().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final String destination = p.join(
        p.dirname(file.path),
        '${p.basenameWithoutExtension(file.path)}.$reason-$stamp.json',
      );
      await file.copy(destination);
      return destination;
    } catch (_) {
      return null;
    }
  }

  Future<File> _indexFile() async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, 'recordings.json'));
  }

  /// Marks the `recordings` table as no longer speaking for the index.
  ///
  /// It lives beside the JSON index rather than inside the database for the
  /// obvious reason: the database is the half that just proved it cannot be
  /// written. Its extension is unknown to [typeForExtension], so the orphan
  /// scan steps over it exactly as it steps over the backups.
  ///
  /// Clearing it is the job of the next save that commits, which rewrites the
  /// whole table — so a database that recovers is trusted again without anyone
  /// having to intervene.
  Future<void> _markDatabaseStale(bool stale) async {
    try {
      final File marker = await _staleMarkerFile();
      if (stale) {
        if (!await marker.exists()) {
          await marker.writeAsString('', flush: true);
        }
      } else if (await marker.exists()) {
        await marker.delete();
      }
    } catch (_) {}
  }

  Future<bool> _isDatabaseStale() async {
    try {
      return await (await _staleMarkerFile()).exists();
    } catch (_) {
      return false;
    }
  }

  Future<File> _staleMarkerFile() async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, 'recordings.db-stale'));
  }
}
