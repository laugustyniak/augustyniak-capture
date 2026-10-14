import 'dart:io';

import 'package:augustyniak_capture/core/security/owner_only_file.dart';
import 'package:augustyniak_capture/features/recordings/data/recordings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The tokens were locked down to `0600` while every transcript and every
/// recording beside them stayed at the umask's mode — readable by every other
/// account on a shared desktop (#301). The repository owns the directory, so
/// the directory is where the mode is set: once, covering every file inside.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('recordings-mode-');
  });

  tearDown(() {
    resetOwnerOnlyReportingForTesting();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  int modeOf(FileSystemEntity entity) => entity.statSync().mode & 0x1FF;

  test(
    'the recordings directory is created readable by its owner only',
    () async {
      final Directory dir = Directory(p.join(root.path, 'recordings'));
      final RecordingsRepository repository = RecordingsRepository(
        directoryProvider: () async => dir,
      );

      final Directory created = await repository.recordingsDirectory();
      final File source = await repository.createSegmentFile('r1', 0, 'm4a');
      source.writeAsStringSync('audio');

      expect(modeOf(created), 0x1C0); // 0700
      // The file itself keeps the umask's mode; the directory is what makes it
      // unreachable from another account. Spelled out so the test says which.
      expect(modeOf(created) & 0x007, 0, reason: 'no bits for others');
      expect(p.dirname(source.path), created.path);
    },
    skip: Platform.isWindows,
  );

  test('a directory that already exists is tightened too', () async {
    // Every install predating #301 has one, at whatever the umask said.
    final Directory dir = Directory(p.join(root.path, 'recordings'))
      ..createSync();
    Process.runSync('chmod', <String>['755', dir.path]);

    await RecordingsRepository(
      directoryProvider: () async => dir,
    ).recordingsDirectory();

    expect(modeOf(dir), 0x1C0);
  }, skip: Platform.isWindows);
}
