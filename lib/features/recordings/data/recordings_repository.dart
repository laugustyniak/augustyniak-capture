import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../core/database/app_database.dart';
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

class RecordingsRepository {
  static String extensionFor(CaptureType type, {String? sourceMimeType}) =>
      policy.extensionFor(type, mimeType: sourceMimeType);

  // ignore: unused_field
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
    final Directory appDirectory = await getApplicationDocumentsDirectory();
    final Directory directory = Directory(
      p.join(appDirectory.path, 'recordings'),
    );
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
    final AppDatabase db = await AppDatabase.getInstance();
    await db.migrateFromLegacyJsonIfNeeded();

    final ResultSet results = db.rawDb.select('''
      SELECT id, file_path, duration_ms, type, status, category, title, summary,
             tags_json, created_at, is_processed_by_user, project_id, failure_reason, json_payload
      FROM recordings
      ORDER BY created_at DESC;
    ''');

    if (results.isEmpty) {
      final File index = await _indexFile();
      if (await index.exists()) {
        try {
          final String raw = await index.readAsString();
          if (raw.trim().isNotEmpty) {
            final dynamic decoded = jsonDecode(raw);
            if (decoded is List) {
              final List<Recording> legacyList = <Recording>[];
              for (final item in decoded) {
                if (item is Map<String, dynamic>) {
                  legacyList.add(Recording.fromJson(item));
                }
              }
              await saveAll(legacyList);
              return legacyList;
            }
          }
        } catch (_) {}
      }
      _knownCount = 0;
      return <Recording>[];
    }

    final List<Recording> recordings = <Recording>[];
    for (final Row row in results) {
      final String? jsonPayload = row['json_payload'] as String?;
      if (jsonPayload != null && jsonPayload.isNotEmpty) {
        try {
          recordings.add(Recording.fromJson(jsonDecode(jsonPayload) as Map<String, dynamic>));
          continue;
        } catch (_) {}
      }

      final String typeStr = row['type'] as String? ?? 'audioRecording';
      final CaptureType type = CaptureType.values.firstWhere(
        (e) => e.name == typeStr,
        orElse: () => CaptureType.audioRecording,
      );
      final String statusStr = row['status'] as String? ?? 'saved';
      final RecordingStatus status = RecordingStatus.values.firstWhere(
        (e) => e.name == statusStr,
        orElse: () => RecordingStatus.saved,
      );

      final List<dynamic> tagsRaw =
          jsonDecode(row['tags_json'] as String? ?? '[]') as List<dynamic>;
      final List<String> tags = tagsRaw.map((e) => e.toString()).toList();

      recordings.add(
        Recording(
          id: row['id'] as String,
          filePath: row['file_path'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
          durationMs: row['duration_ms'] as int? ?? 0,
          status: status,
          type: type,
          title: row['title'] as String?,
          summary: row['summary'] as String?,
          tags: tags,
          isProcessedByUser: (row['is_processed_by_user'] as int? ?? 0) == 1,
          projectId: row['project_id'] as String?,
        ),
      );
    }

    _knownCount = recordings.length;
    return recordings;
  }

  Future<void> saveAll(List<Recording> recordings) async {
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
      stmt.dispose();
      db.rawDb.execute('COMMIT;');
    } catch (e) {
      db.rawDb.execute('ROLLBACK;');
      rethrow;
    }
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

  Future<File> _indexFile() async {
    final Directory directory = await recordingsDirectory();
    return File(p.join(directory.path, 'recordings.json'));
  }
}
