import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../projects/domain/project.dart';
import '../../recordings/domain/capture_category.dart';
import '../../recordings/domain/capture_type.dart';
import '../../recordings/domain/recording.dart';
import '../domain/capture_source.dart';

/// Reads the app's store without ever writing to it.
///
/// Not `RecordingsRepository`: that one reaches `AppDatabase`, which imports
/// `package:flutter`, and a stdio binary must compile with plain `dart`. The
/// rules it follows are mirrored by hand — SQLite first, the JSON index when
/// the table is empty or unreadable, and **only** the JSON index while
/// `recordings.db-stale` exists (see `docs/architecture/persistence.md`).
///
/// The database is opened `OpenMode.readOnly` per call and closed again. The
/// app runs WAL, so a reader never blocks the writer nor sees an uncommitted
/// row.
class SqliteCaptureSource implements CaptureSource {
  SqliteCaptureSource({
    required this.dbPath,
    required this.recordingsDir,
    void Function(String)? log,
  }) : _log = log ?? ((String _) {});

  final String dbPath;
  final String recordingsDir;
  final void Function(String) _log;

  File get _index => File(p.join(recordingsDir, 'recordings.json'));
  File get _stale => File(p.join(recordingsDir, 'recordings.db-stale'));

  @override
  Future<List<Recording>> recordings() async {
    if (!_stale.existsSync()) {
      final List<Recording>? fromDb = _fromDatabase();
      if (fromDb != null && fromDb.isNotEmpty) return fromDb;
    }
    if (_index.existsSync()) return _fromJsonIndex();
    if (!File(dbPath).existsSync() && !_stale.existsSync()) {
      throw CaptureStoreUnavailable(
        'No capture store found: $dbPath does not exist and neither does '
        '${_index.path}. Pass --db and --recordings-dir.',
      );
    }
    return <Recording>[];
  }

  /// Mirrors `RecordingsRepository._loadFromDatabase`: null (ask the JSON
  /// index) only when the select throws or returns no rows. A row whose
  /// `json_payload` is NULL or unparseable is **rebuilt from the columns**, not
  /// skipped, and a table of nothing but such rows still answers — it does not
  /// fall through to the index. Rebuilt rows lack the transcript, so each is
  /// replaced by its JSON-index version when the index has one.
  List<Recording>? _fromDatabase() {
    final Database? db = _open();
    if (db == null) return null;
    try {
      final ResultSet results = db.select('''
        SELECT id, file_path, duration_ms, type, status, category, title,
               summary, tags_json, created_at, is_processed_by_user,
               project_id, failure_reason, json_payload
        FROM recordings
        ORDER BY created_at DESC;
      ''');
      if (results.isEmpty) return null;
      final List<Recording> rows = <Recording>[];
      final Set<String> degraded = <String>{};
      for (final Row row in results) {
        final String? payload = row['json_payload'] as String?;
        if (payload != null && payload.isNotEmpty) {
          try {
            rows.add(
              Recording.fromJson(jsonDecode(payload) as Map<String, dynamic>),
            );
            continue;
          } catch (_) {}
        }
        degraded.add(row['id'] as String);
        _log('row ${row['id']} has no usable payload, rebuilt from columns');
        rows.add(_fromColumns(row));
      }
      if (degraded.isNotEmpty) {
        final Map<String, Recording> indexed = _indexRowsById();
        for (int i = 0; i < rows.length; i++) {
          final Recording? fromIndex = indexed[rows[i].id];
          if (degraded.contains(rows[i].id) && fromIndex != null) {
            rows[i] = fromIndex;
          }
        }
      }
      return rows;
    } catch (e) {
      _log('database read failed, trying the JSON index: $e');
      return null;
    } finally {
      db.close();
    }
  }

  Recording _fromColumns(Row row) {
    final dynamic rawTags = jsonDecode(row['tags_json'] as String? ?? '[]');
    final String rawStatus = row['status'] as String? ?? 'completed';
    RecordingStatus status = RecordingStatus.completed;
    for (final RecordingStatus s in RecordingStatus.values) {
      if (s.name == rawStatus) {
        status = s;
        break;
      }
    }
    return Recording(
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
      tags: rawTags is List<dynamic>
          ? rawTags.map((dynamic e) => e.toString()).toList()
          : <String>[],
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      isProcessedByUser: (row['is_processed_by_user'] as int) == 1,
      projectId: row['project_id'] as String?,
      error: row['failure_reason'] as String?,
    );
  }

  /// The JSON index keyed by id, or empty when it cannot be read. Silent, like
  /// the repository's: it only repairs rows the table answered badly.
  Map<String, Recording> _indexRowsById() {
    try {
      if (!_index.existsSync()) return <String, Recording>{};
      final Object? decoded = jsonDecode(_index.readAsStringSync());
      if (decoded is! List<dynamic>) return <String, Recording>{};
      final Map<String, Recording> rows = <String, Recording>{};
      for (final dynamic item in decoded) {
        try {
          final Recording r = Recording.fromJson(item as Map<String, dynamic>);
          rows[r.id] = r;
        } catch (_) {}
      }
      return rows;
    } catch (_) {
      return <String, Recording>{};
    }
  }

  Database? _open() {
    if (!File(dbPath).existsSync()) return null;
    try {
      return sqlite3.open(dbPath, mode: OpenMode.readOnly);
    } catch (e) {
      _log('cannot open $dbPath: $e');
      return null;
    }
  }

  List<Recording> _fromJsonIndex() {
    final Object? decoded;
    try {
      final String raw = _index.readAsStringSync();
      if (raw.trim().isEmpty) return <Recording>[];
      decoded = jsonDecode(raw);
    } catch (e) {
      throw CaptureStoreUnavailable(
        'Recordings index ${_index.path} is unreadable: $e',
      );
    }
    if (decoded is! List<dynamic>) {
      throw CaptureStoreUnavailable(
        'Recordings index ${_index.path} is not a JSON list.',
      );
    }
    final List<Recording> rows = <Recording>[];
    for (final dynamic item in decoded) {
      try {
        rows.add(Recording.fromJson(item as Map<String, dynamic>));
      } catch (_) {
        _log('skipping unreadable JSON index row');
      }
    }
    rows.sort((Recording a, Recording b) => b.createdAt.compareTo(a.createdAt));
    return rows;
  }

  @override
  Future<List<Project>> projects() async {
    final Database? db = _open();
    if (db != null) {
      try {
        final List<Project> found = <Project>[];
        for (final Row row in db.select(
          'SELECT id, name, json_payload FROM projects ORDER BY created_at ASC;',
        )) {
          try {
            found.add(
              Project.fromJson(
                jsonDecode(row['json_payload'] as String)
                    as Map<String, dynamic>,
              ),
            );
          } catch (_) {
            found.add(
              Project(
                id: row['id'] as String,
                name: row['name'] as String,
                repoPath: '',
              ),
            );
          }
        }
        if (found.isNotEmpty) return found;
      } catch (e) {
        _log('projects table unreadable, trying projects.json: $e');
      } finally {
        db.close();
      }
    }
    final File file = File(p.join(recordingsDir, 'projects.json'));
    if (!file.existsSync()) return <Project>[];
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      final Object? rows = decoded is Map<String, dynamic>
          ? decoded['projects']
          : decoded;
      if (rows is! List<dynamic>) return <Project>[];
      final List<Project> projects = <Project>[];
      for (final dynamic row in rows) {
        try {
          projects.add(Project.fromJson(row as Map<String, dynamic>));
        } catch (_) {}
      }
      return projects;
    } catch (e) {
      _log('projects.json unreadable: $e');
      return <Project>[];
    }
  }
}
