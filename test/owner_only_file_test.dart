import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/security/owner_only_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Provider keys, the Turso token and the R2 secret all end up in the SQLite
/// database, sealed while the keyring works and **in the clear when it does
/// not** — the documented fallback. The master key beside them has been
/// `chmod 600` since it was introduced; the file holding the values it opens
/// was left at whatever the umask said, which on a shared or backed-up machine
/// is world-readable.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('owner-only-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// The permission bits, as `chmod` speaks them.
  int modeOf(File file) => file.statSync().mode & 0x1FF;

  File writeFile(String name) =>
      File(p.join(dir.path, name))..writeAsStringSync('secret');

  test('a file readable by everyone becomes readable by its owner only', () async {
    final File file = writeFile('tokens.json');
    // The state a default umask leaves, spelled out rather than assumed.
    Process.runSync('chmod', <String>['644', file.path]);

    await restrictToOwner(file.path);

    expect(modeOf(file), 0x180); // 0600
  }, skip: Platform.isWindows);

  test('a missing file is not an error', () async {
    // The caller restricts a path it is about to write, or one that may never
    // have existed — a throw here would fail a save that otherwise worked.
    await expectLater(
      restrictToOwner(p.join(dir.path, 'never-written')),
      completes,
    );
  }, skip: Platform.isWindows);

  test('the database is restricted along with its WAL sidecars', () async {
    // `PRAGMA journal_mode = WAL` means the rows also live in `-wal` until a
    // checkpoint, so restricting the database alone leaves the most recent
    // writes — the ones most likely to hold a token just entered — readable.
    final File db = writeFile('app_database.sqlite');
    final File wal = writeFile('app_database.sqlite-wal');
    final File shm = writeFile('app_database.sqlite-shm');
    for (final File file in <File>[db, wal, shm]) {
      Process.runSync('chmod', <String>['644', file.path]);
    }

    await AppDatabase.restrictDatabaseFiles(db.path);

    expect(modeOf(db), 0x180);
    expect(modeOf(wal), 0x180);
    expect(modeOf(shm), 0x180);
  }, skip: Platform.isWindows);
}
