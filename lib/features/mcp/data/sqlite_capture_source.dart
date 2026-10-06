import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../projects/domain/project.dart';
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
      throw StateError(
        'No capture store found: $dbPath does not exist and neither does '
        '${_index.path}. Pass --db and --recordings-dir.',
      );
    }
    return <Recording>[];
  }

  List<Recording>? _fromDatabase() {
    final Database? db = _open();
    if (db == null) return null;
    try {
      final ResultSet results = db.select(
        'SELECT id, json_payload FROM recordings ORDER BY created_at DESC;',
      );
      final List<Recording> rows = <Recording>[];
      for (final Row row in results) {
        try {
          rows.add(
            Recording.fromJson(
              jsonDecode(row['json_payload'] as String) as Map<String, dynamic>,
            ),
          );
        } catch (_) {
          _log('skipping unreadable row ${row['id']}');
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
      throw StateError('Recordings index ${_index.path} is unreadable: $e');
    }
    if (decoded is! List<dynamic>) {
      throw StateError('Recordings index ${_index.path} is not a JSON list.');
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
