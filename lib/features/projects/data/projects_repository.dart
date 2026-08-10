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

    try {
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

      if (results.isNotEmpty) {
        final List<Project> projects = <Project>[];
        for (final Row row in results) {
          final String? jsonPayload = row['json_payload'] as String?;
          if (jsonPayload != null && jsonPayload.isNotEmpty) {
            try {
              projects.add(
                Project.fromJson(
                  jsonDecode(jsonPayload) as Map<String, dynamic>,
                ),
              );
              continue;
            } catch (_) {}
          }
          projects.add(
            Project(
              id: row['id'] as String,
              name: (row['name'] ?? row['title'] ?? '') as String,
              repoPath: (row['repository_path'] ?? '') as String,
              description: row['description'] as String?,
            ),
          );
        }
        return projects;
      }
    } catch (_) {}

    final File file = await projectsFile();
    if (await file.exists()) {
      final String raw;
      final dynamic decoded;
      try {
        raw = await file.readAsString();
        if (raw.trim().isEmpty) return <Project>[];
        decoded = jsonDecode(raw);
      } catch (exception) {
        throw ProjectsIndexUnreadableException(
          file.path,
          exception,
          backupPath: await _preserve(file, 'corrupt'),
        );
      }

      if (decoded is Map<String, dynamic>) {
        _loadedActiveProjectId = decoded['activeProjectId'] is String
            ? decoded['activeProjectId'] as String
            : null;
      } else {
        _loadedActiveProjectId = null;
      }
      final dynamic rows = decoded is Map<String, dynamic>
          ? decoded['projects']
          : decoded;
      if (rows is! List<dynamic>) {
        throw ProjectsIndexUnreadableException(
          file.path,
          'expected a JSON list, got ${decoded.runtimeType}',
          backupPath: await _preserve(file, 'corrupt'),
        );
      }

      final List<Project> projects = <Project>[];
      bool droppedRow = false;
      for (final dynamic row in rows) {
        try {
          projects.add(Project.fromJson(row as Map<String, dynamic>));
        } catch (_) {
          droppedRow = true;
        }
      }
      if (droppedRow) await _preserve(file, 'partial');
      return projects;
    }

    return <Project>[];
  }

  Future<void> saveAll(
    List<Project> projects, {
    String? activeProjectId,
  }) async {
    _loadedActiveProjectId = activeProjectId;

    try {
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
        stmt.close();

        db.rawDb.execute('''
          INSERT OR REPLACE INTO settings (key, value_json) VALUES ('active_project_id', ?);
        ''', <Object?>[jsonEncode(activeProjectId)]);

        db.rawDb.execute('COMMIT;');
      } catch (e) {
        db.rawDb.execute('ROLLBACK;');
      }
    } catch (_) {}

    final File file = await projectsFile();
    final String payload = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{
          'version': 1,
          'activeProjectId': activeProjectId,
          'projects': projects
              .map((Project project) => project.toJson())
              .toList(),
        });

    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(file.path);
  }

  Future<String?> _preserve(File file, String reason) async {
    try {
      final String stamp = DateTime.now().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final String destination = p.join(
        p.dirname(file.path),
        'projects.$reason-$stamp.json',
      );
      await file.copy(destination);
      return destination;
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDirectory.path, 'recordings'));
  }
}
