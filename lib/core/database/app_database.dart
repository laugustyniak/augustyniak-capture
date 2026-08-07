import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

class AppDatabase {
  AppDatabase._({required Database db, required String dbPath})
      : _db = db,
        _dbPath = dbPath;

  final Database _db;
  final String _dbPath;

  static AppDatabase? _instance;
  @visibleForTesting
  static void resetForTesting() => _instance = null;

  static Future<AppDatabase> getInstance({Database? overrideDb}) async {
    if (_instance != null) return _instance!;
    if (overrideDb != null) {
      _instance = AppDatabase._(db: overrideDb, dbPath: ':memory:');
      _instance!._initTables();
      return _instance!;
    }

    final Directory dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final String path = p.join(dir.path, 'app_database.sqlite');
    final Database db = sqlite3.open(path);

    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA foreign_keys = ON;');

    _instance = AppDatabase._(db: db, dbPath: path);
    _instance!._initTables();
    return _instance!;
  }

  Database get rawDb => _db;
  String get dbPath => _dbPath;

  void _initTables() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS clipboard_items (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        text TEXT,
        image_path TEXT,
        copied_at INTEGER NOT NULL,
        preview TEXT,
        collections_json TEXT NOT NULL DEFAULT '[]'
      );
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_clipboard_copied_at 
      ON clipboard_items(copied_at DESC);
    ''');

    try {
      _db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
          text,
          preview,
          content='clipboard_items',
          content_rowid='rowid',
          tokenize='unicode61 remove_diacritics 2'
        );
      ''');
    } catch (e) {
      debugPrint('FTS5 virtual table init warning: $e');
    }

    _db.execute('''
      CREATE TABLE IF NOT EXISTS recordings (
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
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_recordings_created_at 
      ON recordings(created_at DESC);
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS encrypted_secrets (
        key TEXT PRIMARY KEY,
        cipher_text BLOB NOT NULL,
        iv BLOB NOT NULL,
        tag BLOB NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        color_hex TEXT NOT NULL,
        repository_path TEXT,
        created_at INTEGER NOT NULL,
        json_payload TEXT
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS logs (
        id TEXT PRIMARY KEY,
        timestamp INTEGER NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        recording_id TEXT
      );
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_logs_timestamp 
      ON logs(timestamp DESC);
    ''');
  }

  /// Migrates legacy JSON files into SQLite tables atomically on initial setup.
  Future<void> migrateFromLegacyJsonIfNeeded() async {
    final Directory docsDir;
    try {
      docsDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      return;
    }

    // 1. Migrate Clipboard
    final File clipFile = File(p.join(docsDir.path, 'clipboard_history.json'));
    if (await clipFile.exists()) {
      try {
        final String raw = await clipFile.readAsString();
        final dynamic decoded = jsonDecode(raw);
        if (decoded is List) {
          _db.execute('BEGIN TRANSACTION;');
          final PreparedStatement stmt = _db.prepare('''
            INSERT OR REPLACE INTO clipboard_items 
            (id, type, text, image_path, copied_at, preview, collections_json)
            VALUES (?, ?, ?, ?, ?, ?, ?);
          ''');
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              stmt.execute(<Object?>[
                item['id'] ?? '',
                item['type'] ?? 'text',
                item['text'],
                item['imagePath'],
                DateTime.parse(item['copiedAt'] as String? ?? DateTime.now().toIso8601String()).millisecondsSinceEpoch,
                item['preview'],
                jsonEncode(item['collections'] ?? <String>[]),
              ]);
            }
          }
          stmt.dispose();
          _db.execute('COMMIT;');
        }
      } catch (e) {
        debugPrint('Legacy clipboard JSON migration error: $e');
      }
    }

    // 2. Migrate Settings
    final File settingsFile = File(p.join(docsDir.path, 'recordings', 'settings.json'));
    if (await settingsFile.exists()) {
      try {
        final String raw = await settingsFile.readAsString();
        final Map<String, dynamic> decoded = jsonDecode(raw) as Map<String, dynamic>;
        _db.execute('''
          INSERT OR REPLACE INTO settings (key, value_json) VALUES ('app_settings', ?);
        ''', <Object?>[jsonEncode(decoded)]);
      } catch (e) {
        debugPrint('Legacy settings JSON migration error: $e');
      }
    }

    // 3. Migrate Projects
    final File projectsFile = File(p.join(docsDir.path, 'recordings', 'projects.json'));
    if (await projectsFile.exists()) {
      try {
        final String raw = await projectsFile.readAsString();
        final dynamic decoded = jsonDecode(raw);
        if (decoded is List) {
          _db.execute('BEGIN TRANSACTION;');
          final PreparedStatement stmt = _db.prepare('''
            INSERT OR REPLACE INTO projects (id, name, color_hex, repository_path, created_at, json_payload)
            VALUES (?, ?, ?, ?, ?, ?);
          ''');
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              stmt.execute(<Object?>[
                item['id'] ?? '',
                item['name'] ?? '',
                '#89B4FA',
                item['repoPath'],
                DateTime.now().millisecondsSinceEpoch,
                jsonEncode(item),
              ]);
            }
          }
          stmt.dispose();
          _db.execute('COMMIT;');
        }
      } catch (e) {
        debugPrint('Legacy projects JSON migration error: $e');
      }
    }
  }

  void close() {
    _db.dispose();
    _instance = null;
  }
}
