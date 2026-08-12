import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../features/costs/data/usage_repository.dart';
import '../security/owner_only_file.dart';

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

    // After the WAL pragma, so the sidecars exist to be restricted. The
    // `settings` row in here holds provider bearer tokens and the sync
    // credentials — sealed while the key store works, in the clear when it
    // does not — and sqlite creates its files at whatever the umask says.
    await restrictDatabaseFiles(path);

    _instance = AppDatabase._(db: db, dbPath: path);
    _instance!._initTables();
    return _instance!;
  }

  Database get rawDb => _db;
  String get dbPath => _dbPath;

  /// Owner-only permissions for the database **and its WAL sidecars**.
  ///
  /// The sidecars are the point. Under `journal_mode = WAL` a committed row
  /// lives in `-wal` until a checkpoint moves it, so restricting the database
  /// alone leaves the most recent writes — the token just entered in the
  /// Models tab, say — at the umask's mode.
  static Future<void> restrictDatabaseFiles(String path) async {
    for (final String each in <String>[path, '$path-wal', '$path-shm']) {
      await restrictToOwner(each);
    }
  }

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

    // Per-API-call cost history. Owned by UsageRepository so the same schema
    // builds against an in-memory database in tests.
    UsageRepository.createTable(_db);
  }

  /// Bring across whatever the pre-SQLite JSON files still hold, **without
  /// ever replacing a row this database already has.**
  ///
  /// This runs from `SettingsRepository.load()`, so it runs on every launch —
  /// the legacy files are never deleted, and deleting them would throw away the
  /// only copy if the migration were ever found to be wrong. That makes "fill
  /// in what is missing" the whole contract. It used to `INSERT OR REPLACE`,
  /// which meant every launch silently reverted settings, projects and the
  /// clipboard to a snapshot frozen at the moment of the SQLite move. It went
  /// unnoticed because the settings loader immediately wrote the sync
  /// credentials back from build-time literals, which restored the one part of
  /// the row anybody was watching.
  ///
  /// [documentsDirectory] is a test seam; production reads the real app
  /// documents directory.
  Future<void> migrateFromLegacyJsonIfNeeded({
    Directory? documentsDirectory,
  }) async {
    final Directory docsDir;
    try {
      docsDir = documentsDirectory ?? await getApplicationDocumentsDirectory();
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
            INSERT OR IGNORE INTO clipboard_items 
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
          stmt.close();
          _db.execute('COMMIT;');
        }
      } catch (e) {
        debugPrint('Legacy clipboard JSON migration error: $e');
      }
    }

    // 2. Migrate Settings
    final File settingsFile = File(p.join(docsDir.path, 'recordings', 'settings.json'));
    if (await settingsFile.exists()) {
      // The legacy file is deliberately never deleted — it is the only copy if
      // this migration is ever found wrong — so it keeps holding whatever
      // tokens were current when SQLite took over, including plaintext ones
      // from a launch with no key store. It was written at the umask's mode by
      // a build that predates this; tighten it wherever it is found.
      await restrictToOwner(settingsFile.path);
      try {
        final String raw = await settingsFile.readAsString();
        final Map<String, dynamic> decoded = jsonDecode(raw) as Map<String, dynamic>;
        _db.execute('''
          INSERT OR IGNORE INTO settings (key, value_json) VALUES ('app_settings', ?);
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
            INSERT OR IGNORE INTO projects (id, name, color_hex, repository_path, created_at, json_payload)
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
          stmt.close();
          _db.execute('COMMIT;');
        }
      } catch (e) {
        debugPrint('Legacy projects JSON migration error: $e');
      }
    }
  }

  void close() {
    _db.close();
    _instance = null;
  }
}
