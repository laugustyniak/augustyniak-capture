import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:augustyniak_capture/core/database/app_database.dart';

/// The legacy JSON files are still on disk on every install that predates the
/// SQLite move, and `migrateFromLegacyJsonIfNeeded` runs from
/// `SettingsRepository.load()` — that is, on **every launch**, not once. What
/// makes that safe is that it may only ever fill in what is missing.
void main() {
  late Directory docs;
  late Database db;
  late AppDatabase app;

  setUp(() async {
    docs = Directory.systemTemp.createTempSync('legacy-migration-');
    Directory('${docs.path}/recordings').createSync(recursive: true);
    AppDatabase.resetForTesting();
    db = sqlite3.openInMemory();
    app = await AppDatabase.getInstance(overrideDb: db);
  });

  tearDown(() {
    AppDatabase.resetForTesting();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  void writeLegacySettings(Map<String, dynamic> value) {
    File('${docs.path}/recordings/settings.json')
        .writeAsStringSync(jsonEncode(value));
  }

  Map<String, dynamic>? storedSettings() {
    final ResultSet rows = db.select(
      "SELECT value_json FROM settings WHERE key = 'app_settings';",
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.single['value_json'] as String)
        as Map<String, dynamic>;
  }

  test('the legacy settings file is tightened wherever it is found', () async {
    // It is never deleted — it is the only copy if this migration is ever
    // found wrong — so it keeps holding whatever tokens were current when
    // SQLite took over, plaintext ones included. A build that predates
    // `restrictToOwner` wrote it at the umask's mode.
    writeLegacySettings(<String, dynamic>{'themeMode': 'dark'});
    final File file = File('${docs.path}/recordings/settings.json');
    Process.runSync('chmod', <String>['644', file.path]);

    await app.migrateFromLegacyJsonIfNeeded(documentsDirectory: docs);

    expect(file.statSync().mode & 0x1FF, 0x180); // 0600
  }, skip: Platform.isWindows);

  test('an empty database adopts the legacy settings file', () async {
    writeLegacySettings(<String, dynamic>{'themeMode': 'dark'});

    await app.migrateFromLegacyJsonIfNeeded(documentsDirectory: docs);

    expect(storedSettings()?['themeMode'], 'dark');
  });

  test('settings already in the database are never overwritten', () async {
    // The regression. This ran `INSERT OR REPLACE` unconditionally, so every
    // launch reset the row to a file frozen at the moment of the SQLite move —
    // silently reverting the Turso and R2 credentials, and anything else added
    // since. It was invisible only because another bug wrote those credentials
    // back from build-time literals on the very next line.
    db.execute(
      "INSERT INTO settings (key, value_json) VALUES ('app_settings', ?);",
      <Object?>[
        jsonEncode(<String, dynamic>{'themeMode': 'light', 'tursoDbUrl': 'x'}),
      ],
    );
    writeLegacySettings(<String, dynamic>{'themeMode': 'dark'});

    await app.migrateFromLegacyJsonIfNeeded(documentsDirectory: docs);

    expect(storedSettings()?['themeMode'], 'light');
    expect(storedSettings()?['tursoDbUrl'], 'x');
  });

  test('a project already in the database keeps its current row', () async {
    db.execute(
      'INSERT INTO projects (id, name, color_hex, repository_path, '
      'created_at, json_payload) VALUES (?, ?, ?, ?, ?, ?);',
      <Object?>['p1', 'Renamed', '#89B4FA', null, 0, '{}'],
    );
    File('${docs.path}/recordings/projects.json').writeAsStringSync(
      jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'p1', 'name': 'Old name'},
      ]),
    );

    await app.migrateFromLegacyJsonIfNeeded(documentsDirectory: docs);

    final ResultSet rows =
        db.select('SELECT name FROM projects WHERE id = ?;', <Object?>['p1']);
    expect(rows.single['name'], 'Renamed');
  });

  test('a project missing from the database is still brought over', () async {
    File('${docs.path}/recordings/projects.json').writeAsStringSync(
      jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'p2', 'name': 'Brought over'},
      ]),
    );

    await app.migrateFromLegacyJsonIfNeeded(documentsDirectory: docs);

    final ResultSet rows =
        db.select('SELECT name FROM projects WHERE id = ?;', <Object?>['p2']);
    expect(rows.single['name'], 'Brought over');
  });

  test('running twice changes nothing the second time', () async {
    writeLegacySettings(<String, dynamic>{'themeMode': 'dark'});
    await app.migrateFromLegacyJsonIfNeeded(documentsDirectory: docs);

    db.execute(
      "UPDATE settings SET value_json = ? WHERE key = 'app_settings';",
      <Object?>[jsonEncode(<String, dynamic>{'themeMode': 'light'})],
    );
    await app.migrateFromLegacyJsonIfNeeded(documentsDirectory: docs);

    expect(storedSettings()?['themeMode'], 'light');
  });
}
