import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/features/projects/domain/project.dart';
import 'package:augustyniak_capture/features/recordings/domain/capture_priority.dart';
import 'package:augustyniak_capture/features/recordings/domain/recording.dart';
import 'package:augustyniak_capture/features/recordings/domain/route_record.dart';
import 'package:sqlite3/sqlite3.dart';

/// Same `recordings` / `projects` DDL as `core/database/app_database.dart`,
/// copied rather than imported: that file pulls in `package:flutter`.
const String _ddl = '''
  CREATE TABLE recordings (
    id TEXT PRIMARY KEY,
    file_path TEXT NOT NULL,
    duration_ms INTEGER NOT NULL,
    type TEXT NOT NULL,
    status TEXT NOT NULL,
    category TEXT,
    title TEXT,
    summary TEXT,
    tags_json TEXT NOT NULL DEFAULT '[]',
    created_at INTEGER NOT NULL,
    is_processed_by_user INTEGER NOT NULL DEFAULT 0,
    project_id TEXT,
    failure_reason TEXT,
    json_payload TEXT
  );
  CREATE TABLE projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    color_hex TEXT NOT NULL,
    repository_path TEXT,
    created_at INTEGER NOT NULL,
    json_payload TEXT
  );
''';

Recording rec(
  String id, {
  DateTime? at,
  String? title,
  String? summary,
  String? transcript,
  List<String> tags = const <String>[],
  String? projectId,
  RecordingStatus status = RecordingStatus.completed,
  List<RouteRecord> routes = const <RouteRecord>[],
}) => Recording(
  id: id,
  filePath: '/secret/path/$id.m4a',
  createdAt: at ?? DateTime.utc(2026, 1, 1),
  durationMs: 1000,
  status: status,
  title: title,
  summary: summary,
  transcript: transcript,
  tags: tags,
  projectId: projectId,
  priority: CapturePriority.p1,
  priorityReason: 'because',
  routes: routes,
);

const Project projectA = Project(
  id: 'p-1',
  name: 'Alpha Repo',
  repoPath: '/home/x/alpha',
);

class McpFixture {
  McpFixture() : dir = Directory.systemTemp.createTempSync('mcp_test') {
    dbPath = '${dir.path}/app_database.sqlite';
    recordingsDir = Directory('${dir.path}/recordings')..createSync();
    db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute(_ddl);
  }

  final Directory dir;
  late final String dbPath;
  late final Directory recordingsDir;
  late final Database db;

  void insert(Recording r, {String? payload, bool useJson = true}) {
    db.execute(
      'INSERT INTO recordings (id, file_path, duration_ms, type, status, '
      'tags_json, created_at, json_payload) VALUES (?,?,?,?,?,?,?,?)',
      <Object?>[
        r.id,
        r.filePath,
        r.durationMs,
        r.type.name,
        r.status.name,
        '[]',
        r.createdAt.millisecondsSinceEpoch,
        payload ?? (useJson ? jsonEncode(r.toJson()) : null),
      ],
    );
  }

  void insertProject(Project p) {
    db.execute(
      'INSERT INTO projects (id, name, color_hex, repository_path, '
      'created_at, json_payload) VALUES (?,?,?,?,?,?)',
      <Object?>[p.id, p.name, '#fff', p.repoPath, 1, jsonEncode(p.toJson())],
    );
  }

  void writeJsonIndex(List<Recording> rows) => File(
    '${recordingsDir.path}/recordings.json',
  ).writeAsStringSync(jsonEncode(rows.map((r) => r.toJson()).toList()));

  void markStale() =>
      File('${recordingsDir.path}/recordings.db-stale').writeAsStringSync('');

  void dispose() {
    db.close();
    dir.deleteSync(recursive: true);
  }
}
