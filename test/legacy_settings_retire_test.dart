import 'dart:convert';
import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/features/settings/data/settings_repository.dart';
import 'package:augustyniak_capture/features/settings/domain/app_settings.dart';
import 'package:augustyniak_capture/features/settings/domain/token_cipher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The pre-SQLite `settings.json` was kept forever as "the only copy if the
/// migration is ever found wrong" — and so kept every token that was current
/// when SQLite took over, plaintext ones from a launch with no key store
/// included, at a path nothing rewrote (#301). It goes once the row has been
/// read back and parsed, which is the proof the migration took.
class _DocsSettingsRepository extends SettingsRepository {
  _DocsSettingsRepository(this.docs, {required super.db, super.cipher});

  final Directory docs;

  @override
  Future<Directory> documentsDirectory() async => docs;
}

/// A key store that answered "nothing here" on a launch where the row already
/// holds `enc:v1:` blobs: `unseal` hands every blob back as it is.
class _LockedCipher extends TokenCipher {
  const _LockedCipher();

  @override
  bool get encrypts => false;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<String> seal(String token) async => token;

  @override
  Future<String> unseal(String stored) async => stored;
}

void main() {
  late Directory docs;
  late Database db;
  late File legacy;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('legacy-retire-');
    Directory(p.join(docs.path, 'recordings')).createSync(recursive: true);
    legacy = File(p.join(docs.path, 'recordings', 'settings.json'));
    AppDatabase.resetForTesting();
    db = sqlite3.openInMemory();
  });

  tearDown(() {
    AppDatabase.resetForTesting();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Map<String, dynamic> withToken() => <String, dynamic>{
    'themeMode': 'dark',
    'profiles': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'p1',
        'name': 'OpenAI',
        'endpoint': 'https://api.openai.com/v1',
        'bearerToken': 'sk-plaintext',
      },
    ],
    'activeProfileId': 'p1',
  };

  test('the legacy file is deleted once the row has been read back', () async {
    legacy.writeAsStringSync(jsonEncode(withToken()));
    final _DocsSettingsRepository repository = _DocsSettingsRepository(
      docs,
      db: db,
    );

    // First load: no row yet, so the file is adopted and the row written.
    // The file is still the only copy that has been *read*, so it stays.
    // (In production `migrateFromLegacyJsonIfNeeded` inserts the row first
    // and the delete lands in the same `load`; here the path provider is
    // absent, so this exercises the repository's own fallback branch.)
    final AppSettings first = (await repository.load())!;
    expect(first.activeProfile?.bearerToken, 'sk-plaintext');
    expect(legacy.existsSync(), isTrue);

    // Second load reads the row back; that is the proof, and the file goes.
    final AppSettings second = (await repository.load())!;
    expect(second.activeProfile?.bearerToken, 'sk-plaintext');
    expect(legacy.existsSync(), isFalse);
  });

  test('a row that was never read back leaves the file alone', () async {
    // The row is there but unparsable: `load` answers null before the point
    // that deletes, so a bad migration still has its source on disk.
    legacy.writeAsStringSync(jsonEncode(withToken()));
    await AppDatabase.getInstance(overrideDb: db);
    db.execute(
      "INSERT INTO settings (key, value_json) VALUES ('app_settings', ?);",
      <Object?>['[]'],
    );

    final AppSettings? loaded = await _DocsSettingsRepository(
      docs,
      db: db,
    ).load();

    expect(loaded, isNull);
    expect(legacy.existsSync(), isTrue);
  });

  test('a token the key cannot open keeps the file', () async {
    // The row holds sealed blobs and the key is gone; the legacy file may
    // hold their plaintext, and it is the one recovery path left. It stays —
    // at the 0600 the migration gave it — until a launch opens the tokens.
    legacy.writeAsStringSync(jsonEncode(withToken()));
    await AppDatabase.getInstance(overrideDb: db);
    final Map<String, dynamic> sealed = withToken();
    (sealed['profiles'] as List<dynamic>).first['bearerToken'] =
        '${TokenCipher.sealedPrefix}opaque';
    db.execute(
      "INSERT INTO settings (key, value_json) VALUES ('app_settings', ?);",
      <Object?>[jsonEncode(sealed)],
    );

    final AppSettings? loaded = await _DocsSettingsRepository(
      docs,
      db: db,
      cipher: const _LockedCipher(),
    ).load();

    expect(
      loaded?.activeProfile?.bearerToken,
      startsWith(TokenCipher.sealedPrefix),
    );
    expect(legacy.existsSync(), isTrue);
  });
}
