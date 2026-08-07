import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../core/database/app_database.dart';
import '../domain/project.dart';

typedef ProjectsDirectoryProvider = Future<Directory> Function();

class ProjectsIndexUnreadableException implements Exception {
  const ProjectsIndexUnreadableException(
    this.path,
    this.cause, {
    this.backupPath,
  });

  final String path;
  final Object cause;
  final String? backupPath;

  @override
  String toString() =>
      'Projects index at $path is unreadable: $cause'
      '${backupPath == null ? '' : ' (kept a copy at $backupPath)'}';
}

/// Persists projects in SQLite database with fallback to legacy `projects.json`.
class ProjectsRepository {
  ProjectsRepository({ProjectsDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final ProjectsDirectoryProvider _directoryProvider;
  String? _loadedActiveProjectId;

  String? get loadedActiveProjectId => _loadedActiveProjectId;

  Future<File> projectsFile() async {
    final Directory directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'projects.json'));
  }

  Future<List<Project>> loadAll() async {
    _loadedActiveProjectId = null;
    final AppDatabase db = await AppDatabase.getInstance();
    await db.migrateFromLegacyJsonIfNeeded();

    final ResultSet activeResults = db.rawDb.select('''
      SELECT value_json FROM settings WHERE key = 'active_project_id';
    ''');
    if (activeResults.isNotEmpty) {
      final String raw = activeResults.single['value_json'] as String;
      try {
        _loadedActiveProjectId = jsonDecode(raw) as String?;
      } catch (_) {}
    }

    final ResultSet results = db.rawDb.select('''
      SELECT id, name, color_hex, repository_path, created_at, json_payload
      FROM projects
      ORDER BY created_at ASC;
    ''');

    if (results.isEmpty) {
      final File file = await projectsFile();
      if (await file.exists()) {
        try {
          final String raw = await file.readAsString();
          if (raw.trim().isNotEmpty) {
            final dynamic decoded = jsonDecode(raw);
            final List<Project> legacyList = <Project>[];
            final dynamic rows = decoded is Map<String, dynamic>
                ? decoded['projects']
                : decoded;
            if (decoded is Map<String, dynamic> && decoded['activeProjectId'] is String) {
              _loadedActiveProjectId = decoded['activeProjectId'] as String;
            }
            if (rows is List) {
              for (final row in rows) {
                if (row is Map<String, dynamic>) {
                  legacyList.add(Project.fromJson(row));
                }
              }
            }
            await saveAll(legacyList, activeProjectId: _loadedActiveProjectId);
            return legacyList;
          }
        } catch (_) {}
      }
      return <Project>[];
    }

    final List<Project> projects = <Project>[];
    for (final Row row in results) {
      final String? jsonPayload = row['json_payload'] as String?;
      if (jsonPayload != null && jsonPayload.isNotEmpty) {
        try {
          projects.add(Project.fromJson(jsonDecode(jsonPayload) as Map<String, dynamic>));
          continue;
        } catch (_) {}
      }
      projects.add(
        Project(
          id: row['id'] as String,
          name: row['name'] as String,
          repoPath: row['repository_path'] as String? ?? '',
        ),
      );
    }

    return projects;
  }

  Future<void> saveAll(
    List<Project> projects, {
    String? activeProjectId,
  }) async {
    _loadedActiveProjectId = activeProjectId;
    final AppDatabase db = await AppDatabase.getInstance();

    db.rawDb.execute('BEGIN TRANSACTION;');
    try {
      db.rawDb.execute('DELETE FROM projects;');
      final PreparedStatement stmt = db.rawDb.prepare('''
        INSERT INTO projects (id, name, color_hex, repository_path, created_at, json_payload)
        VALUES (?, ?, ?, ?, ?, ?);
      ''');
      for (final Project p in projects) {
        stmt.execute(<Object?>[
          p.id,
          p.name,
          '#89B4FA',
          p.repoPath,
          DateTime.now().millisecondsSinceEpoch,
          jsonEncode(p.toJson()),
        ]);
      }
      stmt.dispose();

      db.rawDb.execute('''
        INSERT OR REPLACE INTO settings (key, value_json) VALUES ('active_project_id', ?);
      ''', <Object?>[jsonEncode(activeProjectId)]);

      db.rawDb.execute('COMMIT;');
    } catch (e) {
      db.rawDb.execute('ROLLBACK;');
      rethrow;
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDirectory.path, 'recordings'));
  }
}
