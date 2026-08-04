import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/project.dart';

typedef ProjectsDirectoryProvider = Future<Directory> Function();

/// Raised when `projects.json` exists but its top-level payload is unreadable.
///
/// Missing and blank files still represent an empty project collection. An
/// existing malformed file is different: callers should surface the failure
/// rather than silently replace it with an empty list on the next save.
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

/// Persists projects next to the recording index as `projects.json`.
class ProjectsRepository {
  ProjectsRepository({ProjectsDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final ProjectsDirectoryProvider _directoryProvider;
  String? _loadedActiveProjectId;

  /// Selection stored alongside the projects returned by the latest load.
  String? get loadedActiveProjectId => _loadedActiveProjectId;

  /// Exposed for diagnostics and for integrations that need to back up or
  /// reveal the file. Normal callers should use [loadAll] and [saveAll].
  Future<File> projectsFile() async {
    final Directory directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, 'projects.json'));
  }

  /// Loads every valid row, preserving malformed source bytes before dropping
  /// an individual row. Unknown fields and agent kinds are ignored by
  /// [Project.fromJson] for forward compatibility.
  Future<List<Project>> loadAll() async {
    _loadedActiveProjectId = null;
    final File file = await projectsFile();
    if (!await file.exists()) return <Project>[];

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

    // Accept a versioned wrapper in addition to today's bare list so adopting
    // a schema envelope later does not strand older application builds.
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

  /// Replaces the index atomically by flushing a sibling temporary file and
  /// renaming it over the destination.
  Future<void> saveAll(
    List<Project> projects, {
    String? activeProjectId,
  }) async {
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
    _loadedActiveProjectId = activeProjectId;
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
