import 'dart:io';

import 'package:augustyniak_capture/core/database/app_database.dart';
import 'package:augustyniak_capture/core/security/owner_only_file.dart';
import 'package:augustyniak_capture/features/logs/domain/log_event.dart';
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
    resetOwnerOnlyReportingForTesting();
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

  test('a directory becomes reachable by its owner only', () async {
    // One call covers the index, every source file and the logs inside it —
    // and there is no window at the umask's mode between a write landing and
    // a per-file chmod.
    final Directory recordings = Directory(p.join(dir.path, 'recordings'))
      ..createSync();
    Process.runSync('chmod', <String>['755', recordings.path]);

    await restrictDirectoryToOwner(recordings.path);

    expect(recordings.statSync().mode & 0x1FF, 0x1C0); // 0700
  }, skip: Platform.isWindows);

  test('a missing path is not reported', () async {
    await restrictToOwner(p.join(dir.path, 'never-written'));
    await restrictDirectoryToOwner(p.join(dir.path, 'never-made'));

    expect(ownerOnlyIssue, isNull);
  }, skip: Platform.isWindows);

  test(
    'a chmod that fails is reported once, to the sink and the getter',
    () async {
      // procfs refuses a mode change on a file that stats fine: the path
      // exists, chmod cannot change it, and that is the shape of every real
      // failure here — the save worked, the tightening did not, and nothing
      // used to say so.
      const String immutable = '/proc/self/status';
      final List<String> lines = <String>[];
      reportOwnerOnlyFailuresTo(_ListSink(lines));

      await restrictToOwner(immutable);
      await restrictToOwner(immutable);

      expect(ownerOnlyIssue, contains(immutable));
      expect(ownerOnlyIssue, contains('chmod 600'));
      expect(lines, hasLength(1));
      expect(lines.single, ownerOnlyIssue);
    },
    skip: !Platform.isLinux,
  );
}

class _ListSink implements LogSink {
  _ListSink(this.lines);

  final List<String> lines;

  @override
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    String? recordingId,
  }) {
    lines.add(message);
  }
}
